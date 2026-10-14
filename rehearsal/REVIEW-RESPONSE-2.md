# Response to the review of 4d94396 (findings F1 to F5 and the remaining handover)

Nothing has been provisioned, created, installed, connected to or run on any real server, and nothing was approved to be. Every
test below ran in a sandbox against a throwaway PostgreSQL 16, Linux network namespaces, or recording fakes, with fictional
sentinel secrets. The full output is `rehearsal/tests/TRANSCRIPT.txt`; rerun with `sudo bash rehearsal/tests/run-all.sh`.
The full 40-character commit ID and the hash of `MANIFEST.sha256` are sent by a different channel from the files. The original
application archive checksum is unchanged: `a681ed3bb2cec72f7d60bc1def17c842ffdc227a81871b87812db020819bb330`.

| # | Finding | Fix | Evidence | Not shown |
| --- | --- | --- | --- | --- |
| F1a | Event-trigger check looked in `postgres`, not the rehearsal DB | `verify-roles.sh --probes` reads `pg_event_trigger` in the rehearsal database (event triggers are database-local) | trigger present only in the rehearsal DB blocks the probes while `postgres` has none; catalog-only mode still runs | triggers created later, during a probe, by someone else |
| F1b | `probe()` discarded the psql status; FATAL/disconnect could pass | markers `ROLE=`, `READY`, `DDL_OK`, `DONE`; psql status and stderr examined; deny passes only on rc 3, exactly one error, SQLSTATE 42501, after the role switch and READY, with no `DDL_OK`; allow passes only on rc 0, empty stderr and all four markers | backend killed mid-probe (allow and deny), another SQLSTATE, statement timeout, role-switch failure, statement unexpectedly succeeding, 42501 raised where allowed: all FAIL | real audit-log behaviour |
| F2 | Scratch guard not bound to the scripts that run | new `rehearsal/scratch/scratch-pitr.sh`: the guard is inside the entrypoint and re-runs before each install/config/WAL/restart/backup/restore step; bucket, region, ping URLs never from the environment or a prompt; the three reused scripts are **not** used on scratch hosts; `restore-test-prepare.sh`'s logic is reproduced inside the guard; config-read and query failures fail; `archive_mode=always` refused; HBA queried; restore host must be exactly `off` and the restored `auto.conf` is checked before start | 57 checks: each guard failure, mid-run drift, identity/secret-file restrictions, no fallback to read-write keys | real apt/PostgreSQL/pgBackRest/S3; AWS-side resource identity (evidenced by the export in `scratch-storage.md`, never by a metadata or AWS call) |
| F3a | Reused installer could print a passphrase; no tracing refusal | no generate/print branch exists; tracing refused before any secret is read; strict credentials file (0700 dir, 0600 file, three keys, never `source`d) | sentinel scan of output and every command argument: nothing; shell syntax in a value is not executed | the pgBackRest config necessarily contains the keys (postgres-only 0600) |
| F3b | `SECRET_FD` could be any descriptor | removed. `SECRET_OUT` only, directly inside `/root/rehearsal-secrets` (fixed, not an environment setting; root, 0700, not a symlink), new file, mode 0600 | `SECRET_FD`, other directory, subdirectory, `..`, spaces, existing file, missing, directory 0755: all refused with nothing created | a secret-manager destination is not offered |
| F4 | Reload guard incomplete | inventory captured with explicit status (a failed query stops the run); `reload_guard` runs immediately before **every** reload (apply, rollback, cleanup): pg_hba.conf must still be the file we installed, no config file newer than the last load, **content** of every config file unchanged since the start (mtime is not trusted), `pg_file_settings` and HBA error counts zero; the candidate pg_hba.conf is proven to be the current file plus exactly the two template lines **before** it is installed; typed `NO-OTHER-CHANGES` | edit with a new mtime blocked; edit with the mtime put back blocked by the content comparison; the unreviewed setting was never activated; rollback and cleanup reloads guarded; tampered candidates rejected | a change made after the final check but before `pg_reload_conf()` returns (a script cannot exclude it: that is why the operator change exclusion is typed) |
| F5 | Firewall | see below | 61 checks in namespaces | IPv6, boot, DHCP, the real host |

## F5 in detail

- **Reply scope.** Output allows only the database connection and replies to `OPS_IP` from the approved ports. Tested with an
  unapproved inbound session open before the lockdown and the server pushing data: nothing more is delivered and the drops are counted.
- **A defect in my own design, found while fixing this.** With `ct direction` in the rules, an already-open operator session was cut
  in about one run in four, because a session that predates conntrack is adopted with whichever side speaks first as "original". The
  `ct direction` matches are gone (the 4d94396 rules had the same weakness); 8 consecutive full runs afterwards were clean.
- **Fail closed.** A failure of enable, daemon-reload, writing or comparing the rules or unit, `is-enabled`, or the state record
  makes `apply` exit non-zero with the rules left loaded and no state record, so `status` and `require` fail. The record holds the
  hashes of the loaded table, rules file and unit; edits to any of them are detected.
- **Legacy timers.** `status` takes the systemctl inventory with checked statuses; a failing `systemctl` is a FAIL (it used to PASS);
  any rollback unit, timer or unit file, and any queued `at` job, is a FAIL.
- **Application start.** `egress-lockdown.sh require` is a silent gate. The application unit must `Requires=`/`After=` the firewall
  unit and call `require` in `ExecStartPre`. That unit is the application owner's and is not supplied here.
- **No weakening under a live app.** `remove` and re-`apply` refuse when the secrets file exists, a process runs as `SVC_USER`, or
  `APP_UNIT` is active. No override.
- **IPv6.** Status prints sysctls, all-scope addresses and routes. The probe now includes IPv6 TCP 444, and without `--sink6` it
  **fails** unless IPv6 is demonstrably disabled (sysctl and no non-loopback address); "no global address" is not accepted.
- **Exceptions need explicit approval.** DHCP, IPv6 neighbour discovery and RELATED ICMP are off by default; each loads only if named
  in `APPROVED_EXCEPTIONS`, scoped to the interface, DHCP server and approved peers. The plan prints which are loaded. **Decision
  needed from the client:** approve `dhcp` (and confirm the interface and DHCP server in the `plan` output), `nd` (only if IPv6 stays
  on) and `icmp-related`, or accept a host whose IPv4 lease may lapse.

## Files changed since 4d94396

Corrected: `dbserver/create-rehearsal-db.sh`, `dbserver/verify-roles.sh`, `rehearsal/egress-lockdown.sh`, `rehearsal/egress-probe.py`,
`rehearsal/egress-plan.md`, `rehearsal/scratch-storage.md`, `rehearsal/scratch-preflight.sh` (header only), `rehearsal/make-manifest.sh`.
New: `rehearsal/scratch/scratch-pitr.sh`, `rehearsal/REVIEW-RESPONSE-2.md`, `rehearsal/tests/*`. Unchanged: `lib.sh`,
`dbserver/rehearsal-common.sh`, `dbserver/install-backup.sh`, `restore-test-prepare.sh`, `restore-test.sh` (kept for review only; not for scratch hosts),
`egress-sink.py`, `verify-session.sh`, `check-policies.py`, the four policies, `REVIEW-RESPONSE.md` (superseded where it conflicts, notably items 3 and 5).
The two sentences in the old response about `SECRET_FD` and the ufw/DHCP defaults are replaced by this document.

## Still open (not code)

Thursday's end time and approval cutoff (Ian); the exact cloud-firewall change for TCP 5432 (or that none is needed) and what
restricts it today; the account ID through the agreed secure channel; individual approval of each shared-server change; the
independent delivery of the archive checksum, commit ID and manifest hash; IPv6, boot-failure and DHCP evidence on the real empty host.
