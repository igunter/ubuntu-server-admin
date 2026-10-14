# Scratch backup storage for the synthetic PITR test (review only; not yet created)

The scratch PostgreSQL cluster (`crm-rehearsal-pitr-src`) gets its own backup repository, so the synthetic point-in-time test never
touches the live repository (`dbs-check-crm-backups`). Nothing here has been created. No secrets in this file: keys are created at
provisioning, passed only through the agreed secure channel, and deleted at cleanup.

## Machine-readable policies (reviewed as files, checked offline)

`rehearsal/policies/iam-rw.json`, `iam-ro.json`, `bucket-policy.json`, `lifecycle.json`. Run
`python3 -I rehearsal/check-policies.py`: it makes **no AWS call** and checks that each IAM policy allows only the named actions on
the scratch bucket, both carry an explicit `Deny s3:*` on the live bucket, the read-only policy has no write action, the bucket policy
denies non-TLS requests, and the lifecycle expires objects within 7 days and aborts incomplete multipart uploads. This is a static
aid: after creation, the **effective** permissions (all attached policies, permission boundaries, bucket policy, principals) still
have to be inspected and recorded.

| Setting | Value |
| --- | --- |
| Name / region | `dbs-check-crm-rehearsal-backups`, `eu-west-2` only |
| Block Public Access | all four settings on |
| Encryption | SSE-S3 default; pgBackRest also encrypts client-side (`aes-256-cbc`) with a rehearsal-only passphrase |
| Versioning | never enabled (the lifecycle also expires noncurrent versions and incomplete uploads in case it is) |
| Lifecycle | expire at 7 days: **a safety net, not proof of deletion**. Cleanup deletes the objects and the bucket sooner and records it |
| Users | `crm-rehearsal-pgbackrest-rw` (source host only), `crm-rehearsal-pgbackrest-ro` (restore host only) |

## Evidence before any backup (corrected)

The earlier step "list the live bucket with the rw key and expect AccessDenied" is **removed**: even an expected refusal contacts a
live resource. Instead: (1) the offline check above passes; (2) the created policies, bucket policy and effective principals are
exported and compared with the files; (3) bucket region, Block Public Access, default encryption and the TLS-only policy are recorded;
(4) after approval, bounded read/write/deny tests touch **only the scratch bucket** from the scratch hosts, before any backup: with the read-only key a
write returns AccessDenied (if it unexpectedly succeeds, stop and clean up the synthetic object under the approved cleanup);
(5) the passphrase for this rehearsal is different from the live one and is stored with the operator's other secrets. The application host gets no S3 access.

## Scratch scripts: one guarded entrypoint (replaces the reused scripts)

`dbserver/install-backup.sh`, `restore-test-prepare.sh` and `restore-test.sh` are **not to be run on the scratch hosts**. They are
unmodified, have no scratch guard, prompt for the bucket and region, install cron jobs and alert hooks, and (the installer) can print a
generated passphrase. Their hashes stay in `MANIFEST.sha256` only because they are the live scripts under review elsewhere.

`rehearsal/scratch/scratch-pitr.sh` is the entrypoint for the scratch hosts: `check`, `source-install`, `source-prepare` (on
`crm-rehearsal-pitr-src`) and `restore` (on `crm-rehearsal-pitr-restore`). Its header lists the full contract. In short:

- **The guard is part of the script and re-runs before every step** that installs, writes configuration, changes WAL settings,
  restarts, backs up or restores (`guard passed before '...'` is printed each time). Bucket, region, ping URLs and host are never read
  from the environment or a prompt.
- **Identity:** a root-owned 0600 `/etc/rehearsal-scratch/identity` created by the operator when the host is created (role, exact
  hostname, `/etc/machine-id`, scratch bucket, region, PG major, data directory, stanza). It must agree with the constants in the
  reviewed file, the machine's real hostname and machine-id, and not be a protected live host or hold a protected live address
  (`172.26.9.114`, `172.26.0.238`, `18.169.221.228`). Hostname and environment are not treated as AWS resource identity; the
  AWS-side identity of the scratch bucket and users is evidenced by the export in "Evidence before any backup" (no metadata or AWS
  call is made by the script).
- **Also checked:** no `PING_URL`/`ARCHIVE_PING_URL` in the environment (even empty) or `alert.env`; no `/etc/cron.d/pgbackrest`;
  an existing `pgbackrest.conf` names only the scratch bucket, is mode 0600 and never the live bucket; on a running server
  `archive_mode` is read (a failed query is a **failure**, `always` is refused; the restore host must be exactly `off`), the data
  directory must match, no database named like `dbscheckcrm*` may exist, and on the source `listen_addresses` is localhost only and
  `pg_hba_file_rules` is queried for any remote rule. After a restore the **last** `archive_mode` in the restored
  `postgresql.auto.conf` must be `off` or the restored cluster is not started.
- **Secrets:** `/root/rehearsal-secrets/scratch-pitr-rw.env` (source) and `scratch-pitr-ro.env` (restore); root 0700 directory, 0600
  file, strict `S3_KEY`/`S3_SECRET`/`PASSPHRASE` lines (never `source`d, anything else such as a ping URL is refused). There is no
  generate/print-passphrase branch; tracing (`bash -x`, `SHELLOPTS`) is refused before a secret is read. The restore uses the
  read-only file only and never falls back to the read-write one.
- **Not installed:** cron jobs, the monitor, the archive watch, any alert URL.
- Tested (`rehearsal/tests/test-scratch.sh`, 57 checks) with every system call replaced by a recording fake and fictional sentinel
  secrets: each guard failure above stops the run with no install/WAL/backup/restore call; drift between steps (hostname changes after the package step;
  a cron file appears after the restart) stops the next step; the sentinels appear in no output and no command argument. **Not tested:** real apt, PostgreSQL,
  pgBackRest or S3 behaviour: those first run on the scratch hosts, after approval.

`scratch-preflight.sh` remains as a read-only report (`verify-config` after the fact) but is no longer the safeguard.

## Cleanup

Delete the bucket's objects and the bucket, both IAM users and their keys, and the three temporary servers; record each deletion.
The routine shared-cluster backups still contain the synthetic rehearsal database for about 3-4 weeks unless the client chooses a
dedicated rehearsal server instead (see the approval checklist).
