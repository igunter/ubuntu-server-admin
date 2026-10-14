# Response to the 14 October script review (client review of revision 44f60de)

The four reviewed digests match commit 44f60de exactly (create-rehearsal-db.sh c12535c5…, verify-roles.sh 21091d6d…,
egress-plan.md 625bfd52…, scratch-storage.md c2ca7108…), so the right files were reviewed. The corrected files below have **new
hashes**; the full commit ID and `MANIFEST.sha256` are sent separately. Nothing has been run on any real host. Test results are from
a throwaway PostgreSQL 16 (with TLS) and sandbox network namespaces; each claim says what was and was not tested.

## 1. PUBLIC ACL checks
Agreed they are valid on PostgreSQL 16. Kept, and your explicit-ACL cross-check (`aclexplode`, NULL/empty handled) is added as two
more checks in `verify-roles.sh`. Verified a deliberately granted PUBLIC right is caught by both forms.

## 2. Rolled-back DDL is not read-only
Agreed. `verify-roles.sh` now defaults to catalog-only checks in a READ ONLY transaction on a read-only connection. The DDL probes
run only with `--probes` after typing `PROBE <db>`, refuse if any event trigger exists, use per-probe sessions with 2 s lock and
5 s statement timeouts and unique names, confirm the role switch worked, and count a denial only for SQLSTATE 42501. Restricted to
the exact rehearsal names (must contain "rehearsal", not protected, and the database and both roles must carry the provenance
comment). Separate `--phase pre` (database must be empty) and `--phase post` (table inventory, optionally exact via
`EXPECTED_TABLES`; owner; per-table and per-sequence rights), so empty tables cannot pass vacuously. Fresh-session evidence
(UTC, search_path, identity, verified TLS, bad-CA/wrong-identity/no-TLS/wrong-password refusals) is `rehearsal/verify-session.sh`,
run from the application host. Tested: 28 catalog checks pass; 18 deliberate breaks each caught; probes fail when a privilege leaks.
Not covered: the real Node client and its two pools (Gate B).

## 3. Password handling
Agreed and fixed. Passwords are never printed. They go to `SECRET_OUT` (new file, root-owned 0700 directory, mode 0600) or an open
`SECRET_FD`, validated before anything is created and written before any role exists. The server receives only a locally computed
SCRAM-SHA-256 verifier, so plaintext cannot appear in a CREATE ROLE statement, an error, or a statement log (a log would hold only
the salted verifier). Shell tracing is refused. psql errors have verifiers masked. Tested with the generated passwords scanned for in
all output, the server log and pg_hba.conf: none; SCRAM logins with the plain passwords work. If apply fails and rolls back fully, the
credentials file is removed.

## 4. Provisioning, cleanup and HBA safety
- **lib.sh**: not needed any more. The scripts depend on one ~65-line `dbserver/rehearsal-common.sh` (no top-level side effects).
  `lib.sh` is still listed in the manifest because the reused backup scripts source it (they use only its message helpers).
- **Server pinned**: explicit socket directory and port; must be PostgreSQL 16 with ssl on; this machine must hold `DB_SERVER_IP`; the
  HBA path comes from the server's own `hba_file`, not a directory guess.
- Connection limits are validated integers 1-100. A failed query stops the script; it is never read as "does not exist".
- **Non-atomic creation**: each object is created separately and tracked; any failure undoes exactly what that run created.
  Tested by injecting a failure at four different statements (including after the HBA lines were in place): nothing left, pg_hba.conf byte-identical.
- **Provenance**: every created object gets a comment; `cleanup` refuses anything without it (tested with an untagged decoy), and
  requires the database owner to be the named owner role. A name containing "rehearsal" is no longer enough.
- **HBA**: the exact appended lines are shown before reload; the file is replaced atomically (same owner/mode) only if its sha256 is
  unchanged since the plan; apply refuses if any existing rule could already match the new database/roles from the host (shadowing or
  broader access) and if any configuration file changed since the server last loaded it (a reload would activate someone else's edit);
  after reload it proves earlier rules unchanged and in order, both new rules parsed with no errors, and each the first matching rule.
  Tested: broad allow, reject-all, unloaded edits to postgresql.conf and pg_hba.conf, concurrent edit between plan and write.
  Honest limit: a parsed rule is not a working connection; the real test is `verify-session.sh` from the host.
- **Cleanup** removes exactly the two lines (atomic, optimistic check), terminates only the two roles' connections (no FORCE, no
  CASCADE), and left pg_hba.conf byte-identical to the original in test.
- **A bug found by testing**: with `set -o pipefail`, the password generator died of SIGPIPE; fixed, and an empty credentials file is no longer left behind.

## 5. Firewall, connection tracking, timer
Replaced, see `egress-plan.md`: nftables with direction-based rules (pre-existing outbound connections are dropped without a conntrack flush),
IPv4 and IPv6 in one table, metadata addresses dropped first and **never contacted**, DHCP/neighbour-discovery allowed, **no rollback
timer**, an executable script, a controlled sink and probe with a real UDP payload, drop counters plus sink log as evidence.
Tested (IPv4, namespaces): an outbound connection open before the lockdown was cut, the operator session survived, a non-operator
inbound session was cut, probes blocked with nothing at the sink, the database path stayed open, `status` detected a hand-added rule.
**Not tested**: IPv6 (the test kernel has no IPv6; the rules were only syntax-checked), boot persistence, DHCP renewal, a real Lightsail
host. The cloud rule remains BLOCKED until Ian identifies the exact rule (below).

## 6. Scratch bucket and the live-bucket probe
Agreed: the live-bucket List request is removed from scope; evidence is offline policy inspection (`check-policies.py`, no AWS call)
plus effective-permission inspection after creation. Policies are separate JSON files; lifecycle also aborts incomplete multipart
uploads and expires noncurrent versions; 7-day expiry is stated as a safety net, not deletion evidence. The three reused scratch
scripts are **unmodified** and pinned by hash; they have no live-bucket guard, so `scratch-preflight.sh` adds hard stops (host name,
bucket, region, no ping URL, localhost-only, archive off, written config). Their dependencies (only `lib.sh` message helpers; apt and S3
network use) and findings are in `scratch-storage.md`, including that the installer prints a generated passphrase (use the typed-passphrase path).

## Items that are decisions, not code (still open)
Window and deadline (Ian's confirmation), account ID via the agreed channel, the backup-retention choice (accept ~3-4 weeks of synthetic
rows in routine backups, or a dedicated server), the exact `/32` and cloud-firewall rule (what currently restricts 5432 on the
database server's Lightsail firewall), approval or refusal of each shared-server change, and independent delivery of the archive checksum.
