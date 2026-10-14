# Scratch backup storage for the synthetic PITR test (review only; not yet created)

Purpose: the scratch PostgreSQL cluster (`crm-rehearsal-pitr-src`) needs its own backup repository, so the
synthetic point-in-time test never touches the live repository (`dbs-check-crm-backups`). This file is the exact
configuration proposed for review. Nothing here has been created.

No secrets in this file. Access keys are created at provisioning, passed only through the agreed secure channel,
and deleted at cleanup.

## Bucket

| Setting | Value |
| --- | --- |
| Name | `dbs-check-crm-rehearsal-backups` |
| Region | `eu-west-2` (London) only |
| Block Public Access | all four settings ON |
| Default encryption | SSE-S3 (AES-256), on. pgBackRest also encrypts client-side (`aes-256-cbc`) with a passphrase generated for this rehearsal only |
| Transport | bucket policy denies any request where `aws:SecureTransport` is false |
| Lifecycle | expire all objects after 7 days (safety net; cleanup deletes the bucket sooner) |
| Contents | synthetic data only |

## Two IAM users, each limited to the rehearsal bucket

Both policies also carry an explicit Deny on the live bucket, so the keys cannot read or change the live
repository even if another policy is ever attached by mistake.

`crm-rehearsal-pgbackrest-rw` (used only on `crm-rehearsal-pitr-src`, to archive and back up):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ListRehearsalBucket", "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::dbs-check-crm-rehearsal-backups" },
    { "Sid": "ObjectsInRehearsalBucket", "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::dbs-check-crm-rehearsal-backups/*" },
    { "Sid": "NeverTheLiveBucket", "Effect": "Deny",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::dbs-check-crm-backups", "arn:aws:s3:::dbs-check-crm-backups/*"] }
  ]
}
```

`crm-rehearsal-pgbackrest-ro` (used only on `crm-rehearsal-pitr-restore`, to restore; cannot write):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ListRehearsalBucket", "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::dbs-check-crm-rehearsal-backups" },
    { "Sid": "ReadObjectsInRehearsalBucket", "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::dbs-check-crm-rehearsal-backups/*" },
    { "Sid": "NeverTheLiveBucket", "Effect": "Deny",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::dbs-check-crm-backups", "arn:aws:s3:::dbs-check-crm-backups/*"] }
  ]
}
```

## Evidence to record before any backup is taken

1. Bucket region is `eu-west-2`, Block Public Access is on, default encryption is on, the TLS-only policy is attached.
2. With the read-write key, a list of the **live** bucket returns AccessDenied (record the sanitised result).
3. With the read-only key, a write to the rehearsal bucket returns AccessDenied.
4. The pgBackRest passphrase for this rehearsal is stored with the operator's other secrets and is different from the live one.

## Setup and scripts (repository scripts are reused unchanged)

- Scratch source setup: Ubuntu 24.04 in London, PostgreSQL 16 from the Ubuntu packages, listening on localhost only, no remote access rules, no TLS or application access needed.
- `dbserver/install-backup.sh`: on the scratch source only, pointed at this bucket and the read-write key. Its monitor and
  archive-watch ping URLs are left blank (log only), so no real alert service is called.
- `dbserver/restore-test-prepare.sh`: on the scratch source only (marker rows with microsecond timestamps and a later
  heartbeat commit, so the earlier pre-commit timestamp fault cannot recur).
- `dbserver/restore-test.sh`: on the scratch restore server only, with the read-only key. It refuses to run where
  archiving is on and starts the restored copy with archiving off.

## Cleanup

Delete the bucket's objects and the bucket, delete both IAM users and their keys, delete the three temporary servers,
and record each deletion.
