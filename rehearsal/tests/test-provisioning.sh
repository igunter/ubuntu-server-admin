#!/usr/bin/env bash
# Regression tests for dbserver/create-rehearsal-db.sh (findings F3 and F4) against a THROWAWAY PostgreSQL 16 cluster
# on the machine running the test. It never touches a real server. Run as root: bash rehearsal/tests/test-provisioning.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixture.sh"
SD=/root/rehearsal-secrets
CR=$S/create-rehearsal-db.sh
OUT=$TEST_ROOT/out
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
[[ -e $SD ]] && { echo "$SD already exists on this machine; refusing to use it for tests"; exit 2; }
trap 'rm -rf "$SD"; fixture_stop' EXIT
fixture_start; mkdir -p "$OUT"; chown root "$OUT"
mkdir -m 700 "$SD"
IN4=$'\n\n\n\n'   # accept the four defaults (HOST_IP comes from the environment)
run() { # run MODE INPUT [env...] -> output in $OUT/last, status in RC
    local mode=$1 input=$2; shift 2
    env "$@" bash "$CR" "$mode" <<<"$input" >"$OUT/last" 2>&1; RC=$?; strip <"$OUT/last" >"$OUT/last.txt"
}
state() { PSQL -c "select (select count(*) from pg_database where datname='$DB_NAME')||'/'||(select count(*) from pg_roles where rolname like 'dbscheckcrm_rehearsal%')"; }
hba_lines_n() { grep -c rehearsal "$TEST_ROOT/data/pg_hba.conf" || true; }
ORIG_HBA_SHA=$(sha256sum <"$TEST_ROOT/data/pg_hba.conf" | cut -d' ' -f1)

echo "== plan changes nothing"
run plan "$IN4" SECRET_OUT=$SD/db.txt
check "plan exits 0" $((RC != 0)); check "plan shows the typed-confirmation SQL" $(grep -q 'CREATE DATABASE' "$OUT/last.txt"; echo $?)
check "nothing created" $([[ $(state) == 0/0 ]]; echo $?); check "no credentials file" $([[ ! -e $SD/db.txt ]]; echo $?)

echo "== secret destination restrictions (F3)"
run apply "$IN4" SECRET_FD=5 SECRET_OUT=$SD/db.txt
check "SECRET_FD refused" $(grep -q 'SECRET_FD is not accepted' "$OUT/last.txt"; echo $?); check "  and nothing created" $([[ $(state) == 0/0 ]]; echo $?)
run apply "$IN4" SECRET_OUT=/tmp/db.txt
check "SECRET_OUT outside the reviewed directory refused" $(grep -q 'directly inside' "$OUT/last.txt"; echo $?)
run apply "$IN4" SECRET_OUT=$SD/sub/db.txt
check "SECRET_OUT in a subdirectory refused" $(grep -q 'directly inside' "$OUT/last.txt"; echo $?)
run apply "$IN4" SECRET_OUT=$SD/../tmp/db.txt
check "SECRET_OUT with .. refused" $(grep -q "without '..'" "$OUT/last.txt"; echo $?)
run apply "$IN4" "SECRET_OUT=$SD/a b.txt"
check "SECRET_OUT with a space refused" $(grep -q 'letters, digits' "$OUT/last.txt"; echo $?)
: >"$SD/exists.txt"; run apply "$IN4" SECRET_OUT=$SD/exists.txt
check "existing SECRET_OUT refused" $(grep -q 'already exists' "$OUT/last.txt"; echo $?); rm -f "$SD/exists.txt"
run apply "$IN4"
check "missing SECRET_OUT refused" $(grep -q 'Set SECRET_OUT' "$OUT/last.txt"; echo $?)
chmod 755 "$SD"; run apply "$IN4" SECRET_OUT=$SD/db.txt
check "directory with mode 0755 refused" $(grep -q 'mode 0700' "$OUT/last.txt"; echo $?); chmod 700 "$SD"
check "nothing created by any refusal" $([[ $(state) == 0/0 ]]; echo $?)
check "pg_hba.conf untouched by refusals" $([[ $(sha256sum <"$TEST_ROOT/data/pg_hba.conf" | cut -d' ' -f1) == "$ORIG_HBA_SHA" ]]; echo $?)

echo "== change exclusion must be typed"
run apply $'\n\n\n\nyes\n' SECRET_OUT=$SD/db.txt
check "wrong change-exclusion answer cancels" $(grep -q 'Cancelled' "$OUT/last.txt"; echo $?); check "  nothing created" $([[ $(state) == 0/0 && ! -e $SD/db.txt ]]; echo $?)

echo "== failed configuration inventory stops the run (F4: no empty loop)"
( . "$CR"; conf_file_list() { return 1; }; main plan ) <<<"$IN4" >"$OUT/last" 2>&1; RC=$?; strip <"$OUT/last" >"$OUT/last.txt"
check "plan stops with a nonzero status" $((RC == 0)); check "  and says why" $(grep -q 'Could not list the server' "$OUT/last.txt"; echo $?)

echo "== a configuration file changing between plan and reload blocks the reload (F4)"
SOCK_CONF=$TEST_ROOT/data/postgresql.conf
inject() { # inject TAG BACKDATE(0|1): after hba_install, someone else edits postgresql.conf; BACKDATE=1 hides it from mtime checks
cat >"$OUT/inject.sh" <<INJ
. "$CR"
eval "\$(declare -f hba_install | sed '1s/hba_install/real_hba_install/')"
hba_install() { real_hba_install "\$@" || return 1; ref=\$(mktemp); touch -r "$SOCK_CONF" "\$ref"
    echo "work_mem = '7MB'   # someone else's unreviewed change" >> "$SOCK_CONF"; if [[ $2 == 1 ]]; then touch -r "\$ref" "$SOCK_CONF"; fi; rm -f "\$ref"; }
main apply
INJ
SECRET_OUT=$SD/inj.txt bash "$OUT/inject.sh" <<<"${IN4}NO-OTHER-CHANGES"$'\n'"CREATE $DB_NAME" >"$OUT/last" 2>&1; RC=$?; strip <"$OUT/last" >"$OUT/last.txt"
}
restore_fixture() { sed -i '/someone else/d' "$SOCK_CONF"; cp "$TEST_ROOT/hba.orig" "$TEST_ROOT/data/pg_hba.conf"; chown postgres: "$TEST_ROOT/data/pg_hba.conf"; shred -u "$SD/inj.txt"; reload; }
inject a 0
check "edit with a new mtime: run fails" $((RC == 0)); check "  reload refused (modified after the last load)" $(grep -q 'modified after the server last loaded' "$OUT/last.txt"; echo $?)
check "  rollback reload also refused, and says so" $(grep -q 'reload was refused' "$OUT/last.txt"; echo $?)
check "  unreviewed setting was NOT activated" $([[ $(PSQL -c "show work_mem") != 7MB ]]; echo $?)
check "  database and roles rolled back" $([[ $(state) == 0/0 ]]; echo $?)
check "  credentials file kept (rollback incomplete) and is 0600" $([[ -s $SD/inj.txt && $(stat -c %a "$SD/inj.txt") == 600 ]]; echo $?)
restore_fixture
inject b 1
check "edit with the mtime put back (mtime alone cannot see it): run fails" $((RC == 0)); check "  reload refused by the content comparison" $(grep -q 'changed since this run started' "$OUT/last.txt"; echo $?)
check "  unreviewed setting was NOT activated" $([[ $(PSQL -c "show work_mem") != 7MB ]]; echo $?)
check "  database and roles rolled back" $([[ $(state) == 0/0 ]]; echo $?)
restore_fixture

echo "== candidate pg_hba.conf validation happens before install (F4)"
( . "$CR"; DB_NAME=dbscheckcrm_rehearsal OWNER_ROLE=o_rehearsal APP_ROLE=a_rehearsal HOST_IP=172.26.5.5 HBA=$TEST_ROOT/data/pg_hba.conf
  c=$(hba_candidate_add); hba_validate_candidate "$c" add; a=$?
  echo "host all all 0.0.0.0/0 trust" >> "$c"; ! hba_validate_candidate "$c" add 2>/dev/null; b=$?
  c2=$(hba_candidate_add); sed -i '$d' "$c2"; echo "hostssl $DB_NAME $APP_ROLE 0.0.0.0/0 scram-sha-256" >> "$c2"; ! hba_validate_candidate "$c2" add 2>/dev/null; d=$?
  rm -f "$c" "$c2"; exit $((a+b+d)) ) >/dev/null 2>&1
check "exact candidate accepted; extra line rejected; altered template line rejected" $?

echo "== successful apply, then sentinel scan of every output (F3)"
run apply "${IN4}NO-OTHER-CHANGES"$'\n'"CREATE $DB_NAME" SECRET_OUT=$SD/db.txt
check "apply exits 0" $RC; check "database + 2 roles exist" $([[ $(state) == 1/2 ]]; echo $?)
check "credentials file is root 0600" $([[ $(stat -c '%U %a' "$SD/db.txt") == "root 600" ]]; echo $?)
check "pg_hba.conf has exactly our 2 new lines" $([[ $(hba_lines_n) == 2 ]]; echo $?)
check "reload happened (rules visible to the server)" $([[ $(PSQL -c "select count(*) from pg_hba_file_rules where database='{dbscheckcrm_rehearsal}'") == 2 ]]; echo $?)
leak=0; for sv in owner_password app_password; do p=$(sed -n "s/^$sv=//p" "$SD/db.txt"); [[ ${#p} -ge 20 ]] || leak=1
    grep -rqF -- "$p" "$OUT/last" "$TEST_ROOT/server.log" "$TEST_ROOT/data/pg_hba.conf" && leak=1
    ls "$SD" | grep -qF -- "$p" && leak=1; done
check "neither generated password appears in terminal output, server log or pg_hba.conf" $leak
check "no SCRAM verifier printed" $(grep -q 'SCRAM-SHA-256\$' "$OUT/last"; echo $((1 - $?)))
run apply "$IN4" SECRET_OUT=$SD/db2.txt
check "a second apply is refused (already exists)" $(grep -q 'already exists' "$OUT/last.txt"; echo $?)

echo "== cleanup, then an event-trigger-free end state"
run cleanup "${IN4}NO-OTHER-CHANGES"$'\n'"DELETE $DB_NAME"
check "cleanup exits 0" $RC; check "everything removed" $([[ $(state) == 0/0 && $(hba_lines_n) == 0 ]]; echo $?)
check "pg_hba.conf back to the original" $([[ $(sha256sum <"$TEST_ROOT/data/pg_hba.conf" | cut -d' ' -f1) == "$ORIG_HBA_SHA" ]]; echo $?)
shred -u "$SD/db.txt"
summary
