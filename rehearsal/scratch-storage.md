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
(4) after approval, bounded read/write/deny tests touch **only the scratch bucket** from the scratch hosts: with the read-only key a
write returns AccessDenied (if it unexpectedly succeeds, stop and clean up the synthetic object under the approved cleanup);
(5) the passphrase for this rehearsal is different from the live one and is stored with the operator's other secrets. The application host gets no S3 access.

## Scripts reused on scratch hosts, and how they are fenced

`dbserver/install-backup.sh`, `restore-test-prepare.sh` and `restore-test.sh` are **unmodified** (hashes in `MANIFEST.sha256`). They source
`lib.sh`, using only its `info`, `ok`, `warn`, `err` helpers and colour constants. They have **no guard of their own** against the
live bucket, so `rehearsal/scratch-preflight.sh` is run before and after (`source`, `restore`, `verify-config`): exact scratch host
name, bucket equals the scratch name and not the live one, `eu-west-2`, no ping URL anywhere, localhost-only PostgreSQL on the source,
`archive_mode` off on the restore host, and the written `pgbackrest.conf` names only the scratch bucket.

Findings from reading them: `install-backup.sh` with blank ping URLs makes no alert-service call (the monitor and watch scripts only
`curl` when a URL is set), but it **installs cron jobs** (hourly monitor, minute watch, backups) on the scratch host. It **prints a generated
passphrase once** to the terminal: on the scratch source answer `n` to "Generate a random passphrase?" and type a passphrase from the
operator's secret manager instead, so nothing is printed. `restore-test-prepare.sh` writes marker rows with microsecond timestamps and a
later `heartbeat` commit, so a restore target always has a commit after it (the earlier fault where the target landed before the last
commit cannot recur). `restore-test.sh` refuses if `archive_mode` is on and restores with `--archive-mode=off`.

Network use on the scratch hosts: package mirrors (apt) and S3 `eu-west-2`, nothing else.

## Cleanup

Delete the bucket's objects and the bucket, both IAM users and their keys, and the three temporary servers; record each deletion.
The routine shared-cluster backups still contain the synthetic rehearsal database for about 3-4 weeks unless the client chooses a
dedicated rehearsal server instead (see the approval checklist).
