#!/usr/bin/env bash
# Regression tests for dbserver/verify-roles.sh (finding F1) against a THROWAWAY PostgreSQL 16 cluster. Run as root.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/fixture.sh"
SD=/root/rehearsal-secrets; CR=$S/create-rehearsal-db.sh; VR=$S/verify-roles.sh; OUT=$TEST_ROOT/out
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
[[ -e $SD ]] && { echo "$SD already exists on this machine; refusing"; exit 2; }
trap 'rm -rf "$SD"; [[ -n ${KEEP:-} ]] || fixture_stop' EXIT
fixture_start; mkdir -p "$OUT"; mkdir -m 700 "$SD"
IN4=$'\n\n\n\n'
SECRET_OUT=$SD/db.txt bash "$CR" apply <<<"${IN4}NO-OTHER-CHANGES"$'\n'"CREATE $DB_NAME" >"$OUT/create" 2>&1 || { echo "setup failed"; tail "$OUT/create"; exit 2; }
vr() { bash "$VR" "$@" <<<"$VIN" >"$OUT/v" 2>&1; RC=$?; strip <"$OUT/v" >"$OUT/v.txt"; }
VIN=$'\n\n\n\n'
echo "== catalog-only run on the empty rehearsal database"
vr; check "passes (rc 0)" $RC; check "says catalog only" $(grep -q 'catalog only' "$OUT/v.txt"; echo $?)
check "ran no DDL (no probe lines)" $(grep -q 'attempt:' "$OUT/v.txt"; echo $((1 - $?)))

echo "== probes: normal run"
VIN=$'\n\n\n\n'"PROBE $DB_NAME"
vr --probes; check "all probes pass (rc 0)" $RC
check "4 probe lines PASS" $([[ $(grep -c '^PASS.*attempt:' "$OUT/v.txt") == 4 ]]; echo $?)
check "deny lines cite SQLSTATE 42501" $([[ $(grep -c '42501' "$OUT/v.txt") == 3 ]]; echo $?)
check "nothing left behind by the probes" $([[ $(PSQL -c "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where relname like '_verify_probe%'" ) == 0 ]]; echo $?)
VIN=$'\n\n\n\n'"no"
vr --probes; check "wrong typed confirmation runs nothing" $(grep -q 'Cancelled' "$OUT/v.txt"; echo $?)

echo "== event trigger in the REHEARSAL database blocks probes although postgres has none (F1)"
PSQL -d postgres -c "select count(*) from pg_event_trigger" | grep -qx 0; check "postgres database has no event trigger" $?
runuser -u postgres -- "$PGBIN/psql" -h "$PG_HOST" -p "$PG_PORT" -X -Atq "$DB_NAME" -c "create schema evs; create function evs.evt() returns event_trigger language plpgsql as 'begin end'; create event trigger evt_t on ddl_command_start execute function evs.evt()" >/dev/null 2>&1; check "created in rehearsal DB only" $?
VIN=$'\n\n\n\n'"PROBE $DB_NAME"
vr --probes; check "probes refused (rc != 0)" $((RC == 0)); check "  with the event-trigger message" $(grep -q 'event trigger' "$OUT/v.txt"; echo $?)
check "  and no probe ran" $(grep -q 'attempt:' "$OUT/v.txt"; echo $((1 - $?)))
vr; check "catalog-only mode is not blocked by the trigger (it runs no DDL)" $RC
runuser -u postgres -- "$PGBIN/psql" -h "$PG_HOST" -p "$PG_PORT" -X -Atq "$DB_NAME" -c "drop event trigger evt_t; drop schema evs cascade" >/dev/null 2>&1

echo "== probe() cannot be fooled by a session that dies or errors (F1)"
probe_t() { # probe_t "label" ROLE SQL expect expected-prefix   (calls the real probe function)
    local r; r=$( . "$VR"; DB_NAME=$DB_NAME; OWNER_ROLE=${DB_NAME}_owner; APP_ROLE=${DB_NAME}_app; probe "$1" "$2" "$3" "$4" )
    [[ $r == "$5"* ]]; }
O=${DB_NAME}_owner; A=${DB_NAME}_app
probe_t x "$O" "CREATE TABLE public.pt (i int)" allow PASS; check "owner CREATE TABLE: allow passes" $?
probe_t x "$A" "CREATE TABLE public.pt (i int)" deny PASS; check "runtime CREATE TABLE: deny passes (42501)" $?
probe_t x "$O" "CREATE TABLE public.pt AS SELECT pg_terminate_backend(pg_backend_pid())" allow FAIL; check "backend killed mid-probe: allow FAILS (was a false PASS)" $?
( sleep 1; PSQL -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='$DB_NAME' and query like '%pg_sleep(4)%' and pid<>pg_backend_pid()" >/dev/null ) &
probe_t x "$A" "SELECT pg_sleep(4)" deny FAIL; check "backend killed by an outside terminate during a deny probe: FAILS" $?; wait
probe_t x "$O" "SELECT 1/0" allow FAIL; check "owner statement errors with another SQLSTATE: allow FAILS" $?
probe_t x "$A" "SELECT 1/0" deny FAIL; check "deny with a non-42501 error (22012): FAILS" $?
probe_t x "$A" "SELECT 1" deny FAIL; check "deny where the statement unexpectedly succeeds: FAILS" $?
probe_t x "$O" "SELECT pg_sleep(8)" allow FAIL; check "statement timeout (57014): allow FAILS" $?
probe_t x "nosuchrole" "SELECT 1" allow FAIL; check "role switch failure: FAILS" $?
probe_t x "$O" "DO \$\$ BEGIN RAISE EXCEPTION 'x' USING ERRCODE='42501'; END \$\$" allow FAIL; check "owner statement raising 42501 where allowed: FAILS" $?
probe_t x "$A" "DO \$\$ BEGIN RAISE EXCEPTION 'x' USING ERRCODE='42501'; END \$\$" deny PASS; check "42501 raised by the intended denied statement: passes (SQLSTATE is the contract)" $?
check "no test object left behind" $([[ $(PSQL -c "select count(*) from pg_class where relname='pt'") == 0 ]]; echo $?)
summary
