#!/usr/bin/env bash
# Throwaway PostgreSQL 16 (with TLS) for the regression tests. Sourced by the test scripts.
# Needs: root, postgresql-16 server binaries (/usr/lib/postgresql/16/bin), openssl.
# Everything lives under $TEST_ROOT (default /run/rehearsal-tests) and is removed by fixture_stop.
TEST_ROOT=${TEST_ROOT:-/run/rehearsal-tests}
PGBIN=/usr/lib/postgresql/16/bin
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
S=$REPO/dbserver; R=$REPO/rehearsal
export PG_RUN="runuser -u postgres --" PG_HOST=$TEST_ROOT/sock PG_PORT=55432 DB_SERVER_IP=127.0.0.1 PG_MAJOR=16
export DB_NAME=dbscheckcrm_rehearsal HOST_IP=172.26.5.5 LOCK_FILE=$TEST_ROOT/lock
export PATH=$PGBIN:$PATH
PSQL() { runuser -u postgres -- "$PGBIN/psql" -h "$PG_HOST" -p "$PG_PORT" -X -Atq "$@" postgres; }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
PASSN=0; FAILN=0
check() { # check "label" condition-exit-status
    if [[ $2 == 0 ]]; then PASSN=$((PASSN+1)); echo "  ok    $1"; else FAILN=$((FAILN+1)); echo "  FAIL  $1"; fi
}
fixture_start() {
    fixture_stop
    mkdir -p "$TEST_ROOT/sock" "$TEST_ROOT/sec"; chown -R postgres:postgres "$TEST_ROOT"; chmod 755 "$TEST_ROOT"
    chown root:root "$TEST_ROOT/sec"; chmod 700 "$TEST_ROOT/sec"
    runuser -u postgres -- bash -c "
        set -eu; T=$TEST_ROOT
        $PGBIN/initdb -D \$T/data -A trust -U postgres >/dev/null
        openssl req -x509 -newkey rsa:2048 -nodes -keyout \$T/data/server.key -out \$T/data/server.crt -subj /CN=pg-test -addext 'subjectAltName=IP:127.0.0.1' -days 2 2>/dev/null
        chmod 600 \$T/data/server.key
        cat >> \$T/data/postgresql.conf <<CONF
port = 55432
listen_addresses = '127.0.0.1'
unix_socket_directories = '\$T/sock'
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
password_encryption = scram-sha-256
CONF
        cat > \$T/data/pg_hba.conf <<HBA
local   all             postgres                                peer
local   all             all                                     peer
hostssl all             all             127.0.0.1/32            scram-sha-256
hostssl dbscheckcrm     dbscheckcrm_app 172.26.0.238/32         scram-sha-256
host    replication     all             127.0.0.1/32            scram-sha-256
HBA
        $PGBIN/pg_ctl -D \$T/data -l \$T/server.log -w start >/dev/null"
    cp -a "$TEST_ROOT/data/pg_hba.conf" "$TEST_ROOT/hba.orig"
    cp "$TEST_ROOT/data/server.crt" "$TEST_ROOT/ca.crt"; chmod 644 "$TEST_ROOT/ca.crt"
}
fixture_stop() {
    if [[ -d $TEST_ROOT/data ]]; then runuser -u postgres -- "$PGBIN/pg_ctl" -D "$TEST_ROOT/data" stop -m immediate >/dev/null 2>&1 || true; fi
    rm -rf "$TEST_ROOT"
}
reload() { PSQL -c "select pg_reload_conf()" >/dev/null; sleep 1; }
summary() { echo; echo "RESULT: $PASSN passed, $FAILN failed"; ((FAILN == 0)); }
