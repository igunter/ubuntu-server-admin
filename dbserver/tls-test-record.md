# TLS enforcement and outbound IP test record (release checks)

No secrets in this file: no passwords, private keys, access keys or passphrases. The CA certificate is public and is shared separately with its SHA-256 fingerprint.

## Summary

| Item | Value |
| --- | --- |
| Date of test | 2026-10-12, about 10:55 to 11:01 UK time |
| Run by | Ian Gunter |
| Database server | Ubuntu 24.04, PostgreSQL 16, private IP `172.26.9.114`, port 5432 |
| Application server | Ubuntu 24.04, private IP `172.26.0.238` (host `ip-172-26-0-238`) |
| Database / user tested | `dbscheckcrm` / `dbscheckcrm` |
| TLS setup | Private CA and server certificate created by `dbserver/enable-tls.sh`; certificate valid for the IP `172.26.9.114`; minimum protocol TLS 1.2 |
| Listening addresses | `localhost` and the private IP `172.26.9.114` only (no public address). |

## 1. Server-side enforcement (on the database server)

Command: `sudo bash dbserver/enable-tls.sh enforce`, then `sudo bash dbserver/enable-tls.sh check`.

```
Rules now requiring TLS:
hostssl dbscheckcrm     dbscheckcrm     172.26.0.238/32 scram-sha-256

ssl:                     on
ssl_min_protocol_version: TLSv1.2
listen_addresses:        localhost,172.26.9.114
Active remote rules:
  hostssl       dbscheckcrm     dbscheckcrm     172.26.0.238/32 scram-sha-256
No remote rule allows unencrypted connections.
```

The only remote access rule is `hostssl` (encrypted connections only), limited to the application server's private IP.

## 2. Unencrypted connection rejected (from the application server)

Command (run on `ip-172-26-0-238`):
`psql "host=172.26.9.114 dbname=dbscheckcrm user=dbscheckcrm sslmode=disable"`

```
psql: error: connection to server at "172.26.9.114", port 5432 failed: FATAL:  no pg_hba.conf entry for host "172.26.0.238", user "dbscheckcrm", database "dbscheckcrm", no encryption
```

Result: **rejected**. The host named in the error is the application server's private IP.

## 3. Verified connection succeeds (from the application server)

Command (run on `ip-172-26-0-238`):
`psql "host=172.26.9.114 dbname=dbscheckcrm user=dbscheckcrm sslmode=verify-full sslrootcert=/etc/ssl/pg/ca.crt"`

```
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off)
```

Result: **connected** with certificate verification (`verify-full`) against the supplied CA, using the exact IP `172.26.9.114`. The password was entered at the prompt and is not recorded here.

## 4. Application server observed outbound IP

Command (run on `ip-172-26-0-238`): `curl -4 -s https://checkip.amazonaws.com`

```
18.169.221.228
```

Result: matches the fixed outbound IP agreed for DBS. TCP 444 to DBS UAT has **not** been tested, by agreement, until the DBS UAT connectivity test is coordinated.

## Notes

- If the application server or its static IP is ever rebuilt or replaced, re-attach the same static IP and repeat test 4 before relying on it.
- If the application server's private IP changes, update the database access rule (`dbserver/install-db.sh`) and repeat tests 2 and 3.
- The CA is valid for 10 years and the server certificate for 3 years (issued 2026-10-09). Renewal of the server certificate is due before it expires: re-run `dbserver/enable-tls.sh`, which issues a new server certificate from the same CA.

## Outstanding before cutover

- Confirmation of which encrypted disk holds PostgreSQL's data (AWS written confirmation, or data moved to an attached disk).
- Production-sized restore rehearsal (see `restore-test-record.md`).
- DBS UAT TCP 444 connectivity test, when agreed.
