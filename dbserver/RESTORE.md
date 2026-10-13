# Restoring PostgreSQL from backup (point-in-time recovery)

Backups are made by `dbserver/install-backup.sh` with pgBackRest: weekly full, daily differential, WAL shipped to an encrypted S3 bucket in London (`eu-west-2`). Any moment in the retained window (about 14-21 days) can be restored.

**Never restore over the live database to test.** Use a separate scratch instance.

## What you need

| Item | Where it should be |
| --- | --- |
| Bucket name and region | Password manager / ops notes (not secret) |
| Read-only IAM access key for the bucket | Password manager |
| Backup encryption passphrase | Password manager + second named holder + sealed offline copy |
| PostgreSQL major version used by the source server | `psql --version` on the DB server (the restore server must match) |

If you only have these, you can recover after losing the original server completely.

## Restore to a point in time (scratch instance)

1. Create a new Ubuntu 24.04 Lightsail instance (e.g. `RestoreTest`). Give it **no** route to the live app server's database, and no public PostgreSQL port.
2. Install the same PostgreSQL major version and pgBackRest, then **stop and empty** the default cluster:
   ```bash
   sudo apt install -y postgresql pgbackrest
   sudo systemctl stop postgresql
   sudo rm -rf /var/lib/postgresql/16/main/*     # use your version number
   ```
3. Create `/etc/pgbackrest/pgbackrest.conf` (owner `postgres`, mode 600) with the same bucket settings, the **same passphrase**, and the read-only key:
   ```ini
   [global]
   repo1-type=s3
   repo1-s3-bucket=BUCKET
   repo1-s3-endpoint=s3.eu-west-2.amazonaws.com
   repo1-s3-region=eu-west-2
   repo1-s3-key=READONLY_KEY_ID
   repo1-s3-key-secret=READONLY_SECRET
   repo1-path=/pgbackrest
   repo1-cipher-type=aes-256-cbc
   repo1-cipher-pass=PASSPHRASE

   [main]
   pg1-path=/var/lib/postgresql/16/main
   ```
4. See what is available: `sudo -u postgres pgbackrest --stanza=main info`
5. Restore to the chosen time (use the server's timezone, or add an offset):
   ```bash
   sudo -u postgres pgbackrest --stanza=main --delta \
        --type=time --target="2026-10-09 14:05:00+01" \
        --target-action=promote restore
   sudo systemctl start postgresql
   ```
   Use `--type=immediate` to restore to the end of the chosen backup only, or omit `--type` to replay all archived WAL up to the latest point.
6. Check the result: `sudo -u postgres psql -c "SELECT now(), pg_is_in_recovery();"` should show `f` once recovery has finished. Query the data to confirm it is what you expect for that timestamp.

## Keep the restored copy from doing anything external

The restored database contains real data and the application settings that send emails and DBS submissions. If an application is run against it:

- Run it on the scratch instance only, never against the live domain.
- `MAIL_MAILER=log` (or equivalent), and DBS submissions disabled by a config flag.
- Replace the DBS, email and any other third-party credentials with dummy values.
- Block outbound traffic from the instance except what the test needs: no TCP 444 to DBS, no SMTP.
- Check the app for other outbound integrations (SMS, payments, webhooks, scheduled jobs/queues that fire on start) and disable them **before** starting it. Stop the queue workers and scheduler.

## Scripted restore test

On the live DB server: `sudo bash dbserver/restore-test-prepare.sh` creates a `restore_test` database, inserts and deletes marked rows, and prints the times to restore to.

On a scratch server: `sudo bash dbserver/restore-test.sh` installs PostgreSQL and pgBackRest, restores to the time you give using a read-only key (with `archive-mode=off`, so it can't write to the live repository), and shows the result. Run it once for the time when the rows existed (expect 5) and once for after the delete (expect 0).

## Test checklist (required before production cutover)

Record the date, who ran it, and the timings.

- [ ] Backups are running: `pgbackrest info` shows a full backup and WAL archive range; the monitor reports OK.
- [ ] On the live DB server, insert a marked set of test rows and note the exact time (T1).
- [ ] Wait 2 minutes, delete those rows, note the time (T2).
- [ ] Restore to a moment between T1 and T2 on the scratch instance. The test rows are present.
- [ ] Restore to after T2. The rows are gone.
- [ ] Repeat the restore using **only** the bucket, the read-only key and the passphrase from the password manager (as if the original server was lost).
- [ ] The restored application (if tested) made no external calls: no emails, no DBS submissions.
- [ ] Archive-stall alert tested on the live server: `sudo bash dbserver/archive-stall-test.sh` (breaks archiving for about 4 to 6 minutes, times the alert, restores it and proves the queued WAL was archived). Record the times.
- [ ] Failure alert tested: break archiving briefly (e.g. rename the bucket in the test config on a non-production copy, or run the monitor with a bad stanza) and confirm the alert recipients get it.
- [ ] Timings recorded: restore of base backup, WAL replay, rebuild server, deploy app, repoint access. Total is the measured recovery time.
- [ ] Scratch instance deleted afterwards.

## Real recovery after losing the server

1. Build a new DB server (`setup.sh` -> DB server, PostgreSQL), stopping before it creates data.
2. Follow "Restore" above, using `--type=time` if you know when the problem started, otherwise restore to the latest point.
3. Point the app server's `DB_HOST` at the new server's private IP, and re-run `install-db.sh` for the app database user and firewall rules if needed.
4. Run `install-backup.sh` again on the new server **using the same bucket and the same passphrase** so the existing repository stays usable.

## Choosing a restore time

PostgreSQL works out times from commit records in the WAL. A `--target` that is later than the last commit in the archive fails with "recovery ended before configured recovery target was reached". For a real recovery, pick a time at which the database was still busy, or leave out `--type`/`--target` to restore to the latest archived point.
