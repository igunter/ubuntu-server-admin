#!/usr/bin/env bash
# READ-ONLY check of a database's two roles and their access lines, on the database server.
#
#   sudo bash dbserver/verify-roles.sh
#
# Changes nothing and needs no passwords: it runs as the postgres superuser. Every "attempt" below
# (for example CREATE TABLE as the runtime role) is made inside a transaction that is rolled back
# (and the denied ones never run at all), so no object is left behind.
#
# It proves EFFECTIVE rights, not just what was granted:
#   - the roles are distinct, can log in with SCRAM passwords, and have no elevated attributes
#   - neither role belongs to any other role, so nothing is inherited (including from the owner)
#   - the runtime role owns nothing, and cannot create tables, schemas or temporary tables
#     (shown by actually trying, as that role)
#   - the owner role CAN create tables (so migrations work)
#   - PUBLIC has no rights on the database or the public schema
#   - timezone is UTC and search_path is public for both roles in this database
#   - the access lines are TLS-only, one per role, limited to the rehearsal host, and the file has no errors
#   - once the schema is loaded: the runtime role has SELECT/INSERT/UPDATE/DELETE on every table and
#     USAGE on every sequence, and no TRUNCATE, REFERENCES or TRIGGER
#
# The output contains no secrets and is suitable as sanitised evidence. Exits non-zero on any FAIL, on
# any query error, or if fewer checks ran than expected.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"

PG_RUN=${PG_RUN:-runuser -u postgres --}
EXPECTED_CHECKS=26
pg() { $PG_RUN psql -v ON_ERROR_STOP=1 -X -Atq "$@"; }
ask() { local v=; read -rp "$1${3:+ [$3]}: " v || true; printf -v "$2" '%s' "${v:-${3:-}}"; }

gather() {
    ask "Database name" DB_NAME "${DB_NAME:-dbscheckcrm_rehearsal}"
    ask "Owner (migration) role" OWNER_ROLE "${OWNER_ROLE:-${DB_NAME}_owner}"
    ask "Runtime role" APP_ROLE "${APP_ROLE:-${DB_NAME}_app}"
    ask "Rehearsal application host private IPv4" HOST_IP "${HOST_IP:-}"
    local n
    for n in "$DB_NAME" "$OWNER_ROLE" "$APP_ROLE"; do
        valid_dbname "$n" || { err "'$n' is not a valid name."; exit 1; }
    done
    valid_ipv4 "$HOST_IP" || { err "HOST_IP is not a valid IPv4 address."; exit 1; }
    [[ $(pg -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'") == 1 ]] || { err "Database $DB_NAME does not exist."; exit 1; }
    [[ $(pg -c "SELECT count(*) FROM pg_roles WHERE rolname IN ('$OWNER_ROLE','$APP_ROLE')") == 2 ]] || { err "One or both roles do not exist."; exit 1; }
}

catalog_checks() {
    pg -d "$DB_NAME" <<SQL
\\set app '$APP_ROLE'
\\set own '$OWNER_ROLE'
\\set host '$HOST_IP'
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END || E'\t' || what FROM (VALUES
 ('the two roles exist and are different',
   (SELECT count(DISTINCT rolname) = 2 FROM pg_roles WHERE rolname IN (:'own', :'app'))),
 ('both roles can log in and have SCRAM-SHA-256 passwords',
   (SELECT bool_and(r.rolcanlogin AND a.rolpassword LIKE 'SCRAM-SHA-256\$%') FROM pg_roles r JOIN pg_authid a ON a.oid = r.oid WHERE r.rolname IN (:'own', :'app'))),
 ('neither role is superuser / createdb / createrole / replication / bypassrls',
   (SELECT NOT bool_or(rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname IN (:'own', :'app'))),
 ('neither role is a member of any role (nothing inherited, including pg_* roles)',
   NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname IN (:'own', :'app'))),
 ('runtime role is not a member of the owner role',
   NOT pg_has_role(:'app', :'own', 'MEMBER')),
 ('database is owned by the owner role',
   (SELECT pg_get_userbyid(datdba) = :'own' FROM pg_database WHERE datname = current_database())),
 ('schema public is owned by the owner role',
   (SELECT pg_get_userbyid(nspowner) = :'own' FROM pg_namespace WHERE nspname = 'public')),
 ('runtime role owns nothing (relations, functions, types, schemas, database)',
   (SELECT (SELECT count(*) FROM pg_class WHERE relowner = r.oid) + (SELECT count(*) FROM pg_proc WHERE proowner = r.oid)
         + (SELECT count(*) FROM pg_type WHERE typowner = r.oid) + (SELECT count(*) FROM pg_namespace WHERE nspowner = r.oid)
         + (SELECT count(*) FROM pg_database WHERE datdba = r.oid) = 0
    FROM pg_roles r WHERE r.rolname = :'app')),
 ('runtime role can connect',
   has_database_privilege(:'app', current_database(), 'CONNECT')),
 ('runtime role has no CREATE or TEMPORARY on the database',
   NOT (has_database_privilege(:'app', current_database(), 'CREATE') OR has_database_privilege(:'app', current_database(), 'TEMPORARY'))),
 ('runtime role can use the public schema but not create in it',
   has_schema_privilege(:'app', 'public', 'USAGE') AND NOT has_schema_privilege(:'app', 'public', 'CREATE')),
 ('PUBLIC has no CONNECT / TEMPORARY / CREATE on the database',
   NOT (has_database_privilege('public', current_database(), 'CONNECT') OR has_database_privilege('public', current_database(), 'TEMPORARY') OR has_database_privilege('public', current_database(), 'CREATE'))),
 ('PUBLIC has no rights on the public schema',
   NOT (has_schema_privilege('public', 'public', 'USAGE') OR has_schema_privilege('public', 'public', 'CREATE'))),
 ('timezone is UTC for both roles in this database',
   (SELECT count(*) = 2 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
     WHERE s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND r.rolname IN (:'own', :'app') AND EXISTS (SELECT 1 FROM unnest(s.setconfig) c WHERE lower(c) = 'timezone=utc'))),
 ('search_path is public for both roles in this database',
   (SELECT count(*) = 2 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
     WHERE s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND r.rolname IN (:'own', :'app') AND s.setconfig @> ARRAY['search_path=public'])),
 ('both roles have a connection limit',
   (SELECT bool_and(rolconnlimit > 0) FROM pg_roles WHERE rolname IN (:'own', :'app'))),
 ('exactly two access rules name this database: hostssl, one per role, host/32, scram-sha-256',
   (SELECT count(*) FILTER (WHERE database && ARRAY[current_database()::text]) = 2
       AND count(*) FILTER (WHERE error IS NULL AND type = 'hostssl' AND database = ARRAY[current_database()::text]
             AND address = :'host' AND netmask = '255.255.255.255' AND auth_method = 'scram-sha-256'
             AND (user_name = ARRAY[:'own'] OR user_name = ARRAY[:'app'])) = 2
    FROM pg_hba_file_rules)),
 ('no non-TLS rule can match this database or these roles from a remote address',
   NOT EXISTS (SELECT 1 FROM pg_hba_file_rules
       WHERE type IN ('host', 'hostnossl') AND error IS NULL
         AND database && ARRAY[current_database()::text, 'all']
         AND user_name && ARRAY[:'own', :'app', 'all']
         AND coalesce(address, '') NOT IN ('127.0.0.1', '::1'))),
 ('pg_hba.conf has no errors',
   NOT EXISTS (SELECT 1 FROM pg_hba_file_rules WHERE error IS NOT NULL)),
 ('runtime role has SELECT, INSERT, UPDATE and DELETE on every table',
   NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT (
         has_table_privilege(:'app', c.oid, 'SELECT') AND has_table_privilege(:'app', c.oid, 'INSERT')
         AND has_table_privilege(:'app', c.oid, 'UPDATE') AND has_table_privilege(:'app', c.oid, 'DELETE')))),
 ('runtime role has no TRUNCATE, REFERENCES or TRIGGER on any table',
   NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND (
         has_table_privilege(:'app', c.oid, 'TRUNCATE') OR has_table_privilege(:'app', c.oid, 'REFERENCES')
         OR has_table_privilege(:'app', c.oid, 'TRIGGER')))),
 ('runtime role has USAGE on every sequence',
   NOT EXISTS (SELECT 1 FROM pg_sequences q WHERE q.schemaname = 'public'
       AND NOT has_sequence_privilege(:'app', quote_ident(q.schemaname) || '.' || quote_ident(q.sequencename), 'USAGE')))
) AS t(what, ok);
SQL
}

# probe "description" role "SQL" deny|allow : tries the SQL AS that role inside a rolled-back transaction.
probe() {
    local what=$1 role=$2 sql=$3 expect=$4 out rc=0
    out=$(pg -d "$DB_NAME" -c "BEGIN; SET LOCAL ROLE \"$role\"; $sql; ROLLBACK;" 2>&1) || rc=$?
    if [[ $expect == deny ]]; then
        if ((rc != 0)) && grep -q 'permission denied' <<<"$out"; then printf 'PASS\t%s\n' "$what"; else printf 'FAIL\t%s\n' "$what"; fi
    else
        if ((rc == 0)); then printf 'PASS\t%s\n' "$what"; else printf 'FAIL\t%s\n' "$what"; fi
    fi
}

probe_checks() {
    probe "attempt: runtime role CREATE TABLE is denied" "$APP_ROLE" "CREATE TABLE public._verify_probe (i int)" deny
    probe "attempt: runtime role CREATE TEMPORARY TABLE is denied" "$APP_ROLE" "CREATE TEMPORARY TABLE _verify_probe (i int)" deny
    probe "attempt: runtime role CREATE SCHEMA is denied" "$APP_ROLE" "CREATE SCHEMA _verify_probe" deny
    probe "attempt: owner role CREATE TABLE succeeds (rolled back)" "$OWNER_ROLE" "CREATE TABLE public._verify_probe (i int)" allow
}

main() {
    [[ $EUID -eq 0 || -n ${PG_RUN_NO_ROOT:-} ]] || { err "Run as root: sudo $0"; exit 1; }
    gather
    echo "Verification (read-only)"
    echo "  time (UTC):    $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "  host:          $(hostname)"
    echo "  PostgreSQL:    $(pg -c 'SHOW server_version')"
    echo "  database:      $DB_NAME   collation/encoding: $(pg -d "$DB_NAME" -c "SELECT datcollate || ' / ' || pg_encoding_to_char(encoding) FROM pg_database WHERE datname = current_database()")"
    echo "  owner role:    $OWNER_ROLE"
    echo "  runtime role:  $APP_ROLE"
    echo "  access host:   $HOST_IP/32"
    echo "  tables in public: $(pg -d "$DB_NAME" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")   (table-level checks pass trivially while this is 0)"
    echo
    local out n
    out=$(catalog_checks) || { err "A verification query failed, so the result is NOT confirmed."; exit 1; }
    out+=$'\n'$(probe_checks)
    echo "$out"
    n=$(grep -cE '^(PASS|FAIL)' <<<"$out" || true)
    echo
    if ((n != EXPECTED_CHECKS)); then
        err "Only $n of $EXPECTED_CHECKS checks produced a result, so the outcome is NOT confirmed."
        exit 1
    fi
    if grep -q '^FAIL' <<<"$out"; then
        err "$(grep -c '^FAIL' <<<"$out") of $n checks FAILED. Stop: do not start the application."
        exit 1
    fi
    ok "All $n checks passed."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
