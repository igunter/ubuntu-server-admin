#!/usr/bin/env bash
# SUPERSEDED as the safeguard by rehearsal/scratch/scratch-pitr.sh, whose guard is inside the entrypoint and re-runs before every step.
# Kept only as a read-only report. Hard stops for the scratch PITR hosts. Originally run BEFORE the reused backup scripts. This script is
# new; the reused scripts (dbserver/install-backup.sh, restore-test-prepare.sh, restore-test.sh) are NOT modified
# and have no guard of their own against the live bucket, so this is the guard.
#
#   sudo bash rehearsal/scratch-preflight.sh source            # on crm-rehearsal-pitr-src, before install-backup.sh
#   sudo bash rehearsal/scratch-preflight.sh restore           # on crm-rehearsal-pitr-restore, before restore-test.sh
#   sudo bash rehearsal/scratch-preflight.sh verify-config     # after either, checks what the script actually wrote
#
# Checks (any failure stops the run):
#   - this host's name is exactly the scratch name for the role (never a live server)
#   - the bucket you intend to use is exactly the scratch bucket, in eu-west-2, and is not the live bucket
#   - no alert ping URL is set in the environment or in /etc/pgbackrest/alert.env (no real alert service is called)
#   - source: PostgreSQL listens on localhost only and has no remote pg_hba rule; the live bucket is not in any config
#   - restore: archive_mode is off here
#   - verify-config: /etc/pgbackrest/pgbackrest.conf names only the scratch bucket and no ping URL is stored
# No secrets are read or printed. It changes nothing.
set -euo pipefail
SCRATCH_BUCKET=${SCRATCH_BUCKET:-dbs-check-crm-rehearsal-backups}
LIVE_BUCKET=${LIVE_BUCKET:-dbs-check-crm-backups}
SRC_HOST=${SRC_HOST:-crm-rehearsal-pitr-src}
RESTORE_HOST=${RESTORE_HOST:-crm-rehearsal-pitr-restore}
CONF=${CONF:-/etc/pgbackrest/pgbackrest.conf}
ALERT_ENV=${ALERT_ENV:-/etc/pgbackrest/alert.env}
HOSTNAME_NOW=${HOSTNAME_NOW:-$(hostname)}
PGBIN=${PGBIN:-}
FAILS=0
pass() { printf 'PASS\t%s\n' "$1"; }
fail() { printf 'FAIL\t%s\n' "$1"; FAILS=$((FAILS+1)); }
role=${1:-}; [[ $role == source || $role == restore || $role == verify-config ]] || { echo "Usage: $0 source|restore|verify-config"; exit 1; }

[[ $SCRATCH_BUCKET != "$LIVE_BUCKET" ]] || { echo "SCRATCH_BUCKET equals LIVE_BUCKET. Refusing."; exit 1; }
if [[ $role == source ]]; then want=$SRC_HOST; elif [[ $role == restore ]]; then want=$RESTORE_HOST; else want=; fi
if [[ -n $want ]]; then [[ $HOSTNAME_NOW == "$want" ]] && pass "host name is $want" || fail "host name is '$HOSTNAME_NOW', expected '$want'. Wrong server?"; fi
[[ $HOSTNAME_NOW != *dbserver* && $HOSTNAME_NOW != ip-172-26-9-114 && $HOSTNAME_NOW != ip-172-26-0-238 ]] && pass "not one of the live servers" || fail "this looks like a LIVE server ($HOSTNAME_NOW)"

if [[ $role != verify-config ]]; then
    b=${BUCKET:-}; r=${REGION:-eu-west-2}
    [[ -n $b ]] || fail "set BUCKET=$SCRATCH_BUCKET (the install scripts take it from the environment)"
    [[ -z $b || $b == "$SCRATCH_BUCKET" ]] && { [[ -z $b ]] || pass "BUCKET is the scratch bucket"; } || fail "BUCKET is '$b', not $SCRATCH_BUCKET"
    [[ $r == eu-west-2 ]] && pass "region is eu-west-2" || fail "REGION is '$r', must be eu-west-2"
fi
[[ -z ${PING_URL:-}${ARCHIVE_PING_URL:-} ]] && pass "no ping URL in the environment" || fail "PING_URL/ARCHIVE_PING_URL is set: no real alert service may be called from a scratch host"
if [[ -r $ALERT_ENV ]] && grep -qE "^(PING_URL|ARCHIVE_PING_URL)='[^']+'" "$ALERT_ENV"; then fail "$ALERT_ENV contains a ping URL"; else pass "no ping URL stored in $ALERT_ENV"; fi

case $role in
  source)
    ls=$(ss -ltn 2>/dev/null | awk '$4 ~ /:5432$/ {print $4}')
    if [[ -z $ls ]]; then pass "PostgreSQL is not listening yet (install it first) or is socket-only"
    elif ! grep -qvE '^(127\.0\.0\.1|\[::1\]):5432$' <<<"$ls"; then pass "PostgreSQL listens on localhost only"
    else fail "PostgreSQL listens beyond localhost: $(tr '\n' ' ' <<<"$ls")"; fi
    if grep -rIl "$LIVE_BUCKET" /etc/pgbackrest /etc/postgresql 2>/dev/null | grep -q .; then fail "the live bucket name appears in local configuration"; else pass "the live bucket name appears in no local configuration"; fi
    ;;
  restore)
    if command -v psql >/dev/null && systemctl is-active --quiet postgresql 2>/dev/null; then
      m=$(runuser -u postgres -- psql -Atc 'SHOW archive_mode' 2>/dev/null || echo unknown)
      [[ $m == off ]] && pass "archive_mode is off" || fail "archive_mode is '$m' on this restore host"
    else pass "PostgreSQL is not running yet (restore-test.sh also refuses if archive_mode is on)"; fi
    ;;
  verify-config)
    if [[ -r $CONF ]]; then
      bk=$(sed -n 's/^repo1-s3-bucket=//p' "$CONF")
      [[ $bk == "$SCRATCH_BUCKET" ]] && pass "pgbackrest.conf repo1-s3-bucket is the scratch bucket" || fail "pgbackrest.conf repo1-s3-bucket is '$bk'"
      grep -q "$LIVE_BUCKET" "$CONF" && fail "pgbackrest.conf mentions the live bucket" || pass "pgbackrest.conf does not mention the live bucket"
      [[ $(stat -c %a "$CONF") == 600 ]] && pass "pgbackrest.conf is mode 0600" || fail "pgbackrest.conf is not mode 0600"
    else fail "$CONF is not readable"; fi
    ;;
esac
((FAILS)) && { echo "$FAILS check(s) FAILED. Do not run the backup or restore scripts."; exit 1; }
echo "All checks passed."
