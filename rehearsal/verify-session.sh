#!/usr/bin/env bash
# Live connection check, run ON THE REHEARSAL APPLICATION HOST (crm-rehearsal-app), not on the database server.
#
#   bash rehearsal/verify-session.sh
#
# The catalog checks in dbserver/verify-roles.sh show what rights were GRANTED. They cannot show what a fresh
# session actually sees, or that the connection really is verified TLS. This script opens fresh connections
# from this host, as each of the two roles, and shows:
#
#   - the verified-TLS login succeeds (sslmode=verify-full against the private CA) and reports, from the
#     server's point of view: the user, the session TimeZone (must be UTC), the search_path (must be public),
#     and that the backend really is using TLS (pg_stat_ssl)
#   - a login that trusts the WRONG CA is refused by the client
#   - a login that connects to the right address but expects the WRONG server name is refused by the client
#   - a login with TLS switched off is refused by the server (the access lines are hostssl)
#   - a login with a wrong password is refused
#
# It runs no DDL and changes nothing. It starts no application. It needs the psql client (postgresql-client-16).
# The passwords are typed hidden, held in a private temporary password file (mode 0600 in a 0700 directory)
# that is removed on exit, and are never put in a command line, an environment variable or the output.
#
# The application's own Node client and its two connection pools are a separate Gate B check: this script is
# evidence about the database side and this host's network path, not a substitute for it.
set -euo pipefail
case $- in *x*|*v*) echo "Refusing to run with shell tracing on: it would print secrets." >&2; exit 1 ;; esac

DB_HOST=${DB_HOST:-172.26.9.114}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-dbscheckcrm_rehearsal}
OWNER_ROLE=${OWNER_ROLE:-${DB_NAME}_owner}
APP_ROLE=${APP_ROLE:-${DB_NAME}_app}
CA=${CA:-/etc/ssl/pg/ca.crt}
BAD_CA=${BAD_CA:-/etc/ssl/certs/ca-certificates.crt}   # a real CA bundle that does NOT contain the private CA
WRONG_NAME=${WRONG_NAME:-db.wrong-identity.invalid}
EXPECT_TZ=${EXPECT_TZ:-UTC}

for n in "$DB_NAME" "$OWNER_ROLE" "$APP_ROLE"; do
    [[ $n =~ ^[a-z][a-z0-9_]{0,30}$ ]] || { echo "Invalid name: $n" >&2; exit 1; }
done
[[ $DB_HOST =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { echo "DB_HOST must be an IPv4 address (the server certificate is for the address, not a name)." >&2; exit 1; }
command -v psql >/dev/null || { echo "psql is not installed (apt-get install postgresql-client-16)." >&2; exit 1; }
[[ -r $CA ]] || { echo "CA file $CA is not readable." >&2; exit 1; }
[[ -r $BAD_CA ]] || { echo "BAD_CA file $BAD_CA is not readable." >&2; exit 1; }
[[ $CA != "$BAD_CA" ]] || { echo "CA and BAD_CA must be different files." >&2; exit 1; }

umask 077
WORK=$(mktemp -d); chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
export PGPASSFILE=$WORK/pgpass PGCONNECT_TIMEOUT=8
: > "$PGPASSFILE"; chmod 600 "$PGPASSFILE"

read -rsp "Password for $OWNER_ROLE (hidden): " OWNER_PW; echo
read -rsp "Password for $APP_ROLE (hidden): " APP_PW; echo
[[ -n $OWNER_PW && -n $APP_PW ]] || { echo "Both passwords are required." >&2; exit 1; }
# pgpass escapes: backslash and colon
esc() { local s=$1; s=${s//\\/\\\\}; printf '%s' "${s//:/\\:}"; }
printf '%s:%s:%s:%s:%s\n' "$DB_HOST" "$DB_PORT" "$DB_NAME" "$OWNER_ROLE" "$(esc "$OWNER_PW")" >> "$PGPASSFILE"
printf '%s:%s:%s:%s:%s\n' "$DB_HOST" "$DB_PORT" "$DB_NAME" "$APP_ROLE" "$(esc "$APP_PW")" >> "$PGPASSFILE"
printf '%s:%s:%s:%s:%s\n' "$DB_HOST" "$DB_PORT" "$DB_NAME" "$APP_ROLE" "definitely-not-the-password" >> "$PGPASSFILE.wrong"
OWNER_PW=; APP_PW=

FAILS=0; CHECKS=0
pass() { CHECKS=$((CHECKS+1)); printf 'PASS\t%s\n' "$1"; }
fail() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf 'FAIL\t%s\n' "$1"; }

# conn ROLE SSLMODE ROOTCERT [HOST_NAME]  -> runs the query; prints its output; returns psql's status.
# When HOST_NAME is given, the client connects to DB_HOST's address but expects that name in the certificate.
conn() {
    local role=$1 mode=$2 root=$3 name=${4:-} q
    q="SELECT current_user || '|' || current_setting('TimeZone') || '|' || current_setting('search_path') || '|' || (SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid())"
    if [[ -n $name ]]; then
        psql -X -Atq -w "host=$name hostaddr=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$role sslmode=$mode sslrootcert=$root" -c "$q" 2>&1
    else
        psql -X -Atq -w "host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$role sslmode=$mode sslrootcert=$root" -c "$q" 2>&1
    fi
}

echo "Live connection check from $(hostname) to $DB_HOST:$DB_PORT, database $DB_NAME"
echo "  time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
echo

for role in "$OWNER_ROLE" "$APP_ROLE"; do
    out=$(conn "$role" verify-full "$CA") && rc=0 || rc=$?
    if ((rc == 0)) && [[ $out == "$role|$EXPECT_TZ|public|true" ]]; then
        pass "$role: verified-TLS login; session shows user=$role, TimeZone=$EXPECT_TZ, search_path=public, TLS in use"
    else
        fail "$role: verified-TLS login did not report the expected session (got: ${out//$'\n'/ / })"
    fi
    out=$(conn "$role" verify-full "$BAD_CA") && rc=0 || rc=$?
    if ((rc != 0)) && grep -qiE 'certificate verify failed|self[- ]signed|unable to get local issuer' <<<"$out"; then
        pass "$role: refused when the client trusts the wrong CA (certificate verify failed)"
    else
        fail "$role: a login trusting the wrong CA was NOT refused for the right reason (rc=$rc)"
    fi
    out=$(conn "$role" verify-full "$CA" "$WRONG_NAME") && rc=0 || rc=$?
    if ((rc != 0)) && grep -qiE 'server certificate for .* does not match host name|does not match' <<<"$out"; then
        pass "$role: refused when the expected server name is wrong (identity mismatch)"
    else
        fail "$role: a login expecting the wrong server name was NOT refused for the right reason (rc=$rc)"
    fi
    out=$(conn "$role" disable "$CA") && rc=0 || rc=$?
    if ((rc != 0)) && grep -qiE 'no pg_hba.conf entry|encryption|SSL' <<<"$out"; then
        pass "$role: refused by the server with TLS switched off (access rule is hostssl)"
    else
        fail "$role: a login with TLS off was NOT refused by the server (rc=$rc)"
    fi
done
out=$(PGPASSFILE=$PGPASSFILE.wrong conn "$APP_ROLE" verify-full "$CA") && rc=0 || rc=$?
if ((rc != 0)) && grep -qi 'password authentication failed' <<<"$out"; then
    pass "$APP_ROLE: refused with a wrong password"
else
    fail "$APP_ROLE: a login with a wrong password was NOT refused as expected (rc=$rc)"
fi

echo
if ((FAILS)); then echo "$FAILS of $CHECKS checks FAILED. Do not start the application."; exit 1; fi
echo "All $CHECKS checks passed."
