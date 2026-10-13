# Restore test record (migration record)

No secrets in this file: no keys, passphrase or passwords.

## Summary

| Item | Value |
| --- | --- |
| Date of test | 2026-10-09 |
| Run by | Ian Gunter |
| Backup tool | pgBackRest 2.50, PostgreSQL 16 |
| Repository | S3 bucket `dbs-check-crm-backups`, region `eu-west-2` (London) |
| Encryption | pgBackRest `aes-256-cbc` (client-side) plus S3 server-side encryption |
| Base backup restored | `20261009-134714F` (full, taken 2026-10-09 14:47 UK time) |
| Source database size | 29.3 MB (3.6 MB in the repository) |
| Restore target | A separate scratch server (Ubuntu 24.04, London), built from nothing and given only the bucket name, a read-only access key and the passphrase. It was deleted afterwards. |

## Point-in-time results

Method: on the live DB server, a separate `restore_test` database was given 5 marked rows, which were then deleted. The database was then restored to a point just before the delete and to a point just after it.

| Restore target (UK time) | Expected | Actual |
| --- | --- | --- |
| 2026-10-09 15:54:57.876558 +01 (rows present) | 5 rows | **5 rows** |
| 2026-10-09 15:55:02.969813 +01 (after delete) | 0 rows | **0 rows** |

## Time taken to restore

| Run | Base backup restore | Database ready (incl. WAL replay) |
| --- | --- | --- |
| Rows present | 5 s | 11 s |
| After delete | 5 s | 10 s |

These timings are for a 29 MB database and do not represent production. Re-time once real data is loaded, and add the time to build a server, deploy the application and repoint access.

## Notes on the test

- Earlier runs on the same day failed or gave the wrong count because the first version of the test script printed a timestamp that was not after the delete's commit. This was a fault in the test script, not in the backups. The script was fixed (it now writes a later commit and prints microseconds), and the passing runs above used the fixed script.
- The restored copy was started with archiving turned off and a read-only key, so it could not write to the live repository. No application was started against it, so no emails, DBS submissions or other external actions occurred.

## Monitoring and alerts

| Item | Value |
| --- | --- |
| Monitor | Hourly check at 7 minutes past (`pgbackrest-monitor`), plus weekly `pgbackrest verify` |
| Alert service | In-house monitoring service on a separate server from the database server. Check "DBServer pgBackRest backup monitor": expected every 1 hour, grace 30 minutes. A missed ping or an explicit failure signal raises an alert. |
| Alert recipients | The team Slack group (tested 2026-10-13). A Telegram route is being set up and is not yet counted; it will be listed once a test alert has been received there. Email to `directors@verifyonline.co.uk` is configured as a further route where enabled. |
| Failure alert tested | 2026-10-13 about 13:26 UK time: a failure signal from the monitor raised a "[DOWN] ... backup monitor reported a failure" alert in the team Slack group. At about 13:28 a successful run raised "[RECOVERED] ... is checking in again". (The failure was caused by running the monitor as the wrong user, which is how it was triggered; the monitor is run as the `postgres` user by cron.) |
| Still to test | Missed-ping alert (no check-in within period plus grace) and delivery of alerts to Telegram (a 2026-10-13 test alert did not arrive there; being fixed). To be recorded when done. |

## Outstanding before cutover

- Done: disk encryption at rest confirmed in writing by AWS (see `tls-test-record.md`, section 5).
- Done: TLS enforcement and verification details handed to the application (see `tls-test-record.md`).
- Outbound IP observed and recorded (`tls-test-record.md`). Outbound TCP 444 to the DBS host is still to be tested, only when separately agreed.
- Re-time the restore with production-sized data.
