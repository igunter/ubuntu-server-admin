#!/usr/bin/env bash
# Checks a rehearsal database's two roles and their access lines, on the database server.
#
#   sudo bash dbserver/verify-roles.sh                         # catalog checks only, empty database (phase pre)
#   sudo bash dbserver/verify-roles.sh --phase post            # catalog checks once the application's schema is loaded
#   sudo EXPECTED_TABLES="a,b,c" bash dbserver/verify-roles.sh --phase post
#   sudo bash dbserver/verify-roles.sh --phase post --probes   # ALSO runs the rolled-back DDL probes (see below)
#
# TWO KINDS OF CHECK - they are NOT the same risk, so they are separate:
#
# 1. Catalog checks (the default). Every query runs in one READ ONLY transaction that is rolled back,
#    on a connection opened with default_transaction_read_only=on. They only read the system catalogs.
#    They need no passwords: they run as the postgres superuser.
#
# 2. DDL probes (only with --probes, after a typed confirmation). Each one switches to the runtime or
#    owner role and tries CREATE TABLE / CREATE TEMPORARY TABLE / CREATE SCHEMA inside a transaction that
#    is then rolled back. NOTHING IS LEFT BEHIND, but this is NOT read-only: it takes locks and writes
#    catalog/WAL activity, may be recorded by audit logging, and would fire event triggers (so it is
#    refused if any event trigger exists). It needs separate, explicit approval. Each probe has a 2 s lock
#    timeout and 5 s statement timeout, its own session (which rolls back on any exit), and a unique
#    object name. A denial counts only if PostgreSQL returns SQLSTATE 42501 (insufficient_privilege)
#    AFTER the role switch was shown to have worked.
#
# Restricted to the rehearsal database and roles: both names must contain "rehearsal", must not be
# protected production names, and the database and both roles must carry the provenance comment written
# by create-rehearsal-db.sh. Any other database is refused, so this cannot be pointed at production.
#
# Phases (so an empty database cannot pass table-level checks vacuously):
#   pre   the database must be empty (no tables, sequences, views or functions in schema public)
#   post  the schema is loaded: tables must exist (and match EXPECTED_TABLES exactly when set), be owned by
#         the owner role, and the runtime role must have exactly the rights the application needs on each
#         table and sequence. Re-run it after every schema or grants change.
#
# This is database-side evidence about GRANTED and EFFECTIVE rights. It does not replace the live checks
# from the rehearsal host (rehearsal/verify-session.sh): fresh verified-TLS logins as each role showing
# UTC, search_path and identity, and the application's two real connection pools.
#
# The output contains no secrets. Exits non-zero on any FAIL, on any query error, or if fewer checks ran
# than expected.
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/rehearsal-common.sh"
refuse_tracing

PG_RUN=${PG_RUN:-runuser -u postgres --}
PG_HOST=${PG_HOST:-/var/run/postgresql}
PG_PORT=${PG_PORT:-5432}
PROD_DB=${PROD_DB:-dbscheckcrm}
OWNER_CONN_LIMIT=${OWNER_CONN_LIMIT:-5}
APP_CONN_LIMIT=${APP_CONN_LIMIT:-24}
TAG='crm-rehearsal synthetic; created by dbserver/create-rehearsal-db.sh'
PHASE=pre; PROBES=0

pg() { $PG_RUN env "PGHOST=$PG_HOST" "PGPORT=$PG_PORT" PGDATABASE=postgres "PGOPTIONS=-c default_transaction_read_only=on" psql -v ON_ERROR_STOP=1 -X -Atq "$@"; }
# the probes need a connection that is NOT read-only (they run DDL that is rolled back)
pgw() { $PG_RUN env "PGHOST=$PG_HOST" "PGPORT=$PG_PORT" PGDATABASE=postgres psql -v ON_ERROR_STOP=1 -X -Atq "$@"; }
ask() { local v=; read -rp "$1${3:+ [$3]}: " v || true; printf -v "$2" '%s' "${v:-${3:-}}"; }

parse_args() {
    while (($#)); do
        case $1 in
            --phase) shift; PHASE=${1:-}; [[ $PHASE == pre || $PHASE == post ]] || { err "--phase must be pre or post."; exit 1; } ;;
            --probes) PROBES=1 ;;
            -h|--help) sed -n '2,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
            *) err "Unknown argument: $1 (see --help)"; exit 1 ;;
        esac
        shift
    done
}

gather() {
    ask "Database name" DB_NAME "${DB_NAME:-dbscheckcrm_rehearsal}"
    ask "Owner (migration) role" OWNER_ROLE "${OWNER_ROLE:-${DB_NAME}_owner}"
    ask "Runtime role" APP_ROLE "${APP_ROLE:-${DB_NAME}_app}"
    ask "Rehearsal application host private IPv4" HOST_IP "${HOST_IP:-}"
    local n
    for n in "$DB_NAME" "$OWNER_ROLE" "$APP_ROLE"; do
        valid_dbname "$n" || { err "'$n' is not a valid name."; exit 1; }
        [[ $n == *rehearsal* ]] || { err "'$n' does not contain 'rehearsal'. Refusing: this script only checks rehearsal databases."; exit 1; }
        case $n in "$PROD_DB"|"${PROD_DB}_owner"|"${PROD_DB}_app"|postgres|template0|template1) err "'$n' is a protected name. Refusing."; exit 1 ;; esac
    done
    [[ $OWNER_ROLE != "$APP_ROLE" ]] || { err "The owner and runtime roles must differ."; exit 1; }
    valid_ipv4 "$HOST_IP" || { err "HOST_IP is not a valid IPv4 address."; exit 1; }
    bounded_int "$OWNER_CONN_LIMIT" 1 100 && bounded_int "$APP_CONN_LIMIT" 1 100 || { err "Connection limits must be integers from 1 to 100."; exit 1; }
    if [[ -n ${EXPECTED_TABLES:-} ]]; then
        [[ $EXPECTED_TABLES =~ ^[a-z_][a-z0-9_]*(,[a-z_][a-z0-9_]*)*$ ]] || { err "EXPECTED_TABLES must be a comma-separated list of simple lowercase table names."; exit 1; }
    fi
    # The names are validated above (letters, digits, underscore), so they are safe to put in these queries.
    local t
    t=$(pg -c "SELECT count(*) FROM pg_database WHERE datname = '$DB_NAME'") || { err "Cannot query PostgreSQL at $PG_HOST port $PG_PORT."; exit 1; }
    [[ $t == 1 ]] || { err "Database $DB_NAME does not exist."; exit 1; }
    t=$(pg -c "SELECT count(*) FROM pg_roles WHERE rolname IN ('$OWNER_ROLE','$APP_ROLE')")
    [[ $t == 2 ]] || { err "One or both roles do not exist."; exit 1; }
    t=$(pg -c "SELECT (coalesce(shobj_description(d.oid,'pg_database'),'') LIKE '$TAG%')::int + (SELECT count(*) FROM pg_roles r WHERE r.rolname IN ('$OWNER_ROLE','$APP_ROLE') AND coalesce(shobj_description(r.oid,'pg_authid'),'') LIKE '$TAG%') FROM pg_database d WHERE d.datname = '$DB_NAME'")
    [[ $t == 3 ]] || { err "The database and both roles must carry the provenance comment from create-rehearsal-db.sh. Refusing to check anything else."; exit 1; }
}

ROWS=()
row() { local r; r=$(cat); ROWS+=("$r"); }

build_rows() {
    ROWS=()
    row <<'SQL'
 ('the two roles exist and are different',
   (SELECT count(DISTINCT rolname) = 2 FROM pg_roles WHERE rolname IN (:'own', :'app')))
SQL
    row <<'SQL'
 ('both roles can log in and have SCRAM-SHA-256 passwords',
   (SELECT bool_and(r.rolcanlogin AND a.rolpassword LIKE 'SCRAM-SHA-256$%') FROM pg_roles r JOIN pg_authid a ON a.oid = r.oid WHERE r.rolname IN (:'own', :'app')))
SQL
    row <<'SQL'
 ('neither role is superuser / createdb / createrole / replication / bypassrls',
   (SELECT NOT bool_or(rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname IN (:'own', :'app')))
SQL
    row <<'SQL'
 ('neither role is a member of any role (nothing inherited, including pg_* roles)',
   NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname IN (:'own', :'app')))
SQL
    row <<'SQL'
 ('runtime role is not a member of the owner role',
   NOT pg_has_role(:'app', :'own', 'MEMBER'))
SQL
    row <<'SQL'
 ('database is owned by the owner role',
   (SELECT pg_get_userbyid(datdba) = :'own' FROM pg_database WHERE datname = current_database()))
SQL
    row <<'SQL'
 ('schema public is owned by the owner role',
   (SELECT pg_get_userbyid(nspowner) = :'own' FROM pg_namespace WHERE nspname = 'public'))
SQL
    row <<'SQL'
 ('runtime role owns nothing (relations, functions, types, schemas, database)',
   (SELECT (SELECT count(*) FROM pg_class WHERE relowner = r.oid) + (SELECT count(*) FROM pg_proc WHERE proowner = r.oid)
         + (SELECT count(*) FROM pg_type WHERE typowner = r.oid) + (SELECT count(*) FROM pg_namespace WHERE nspowner = r.oid)
         + (SELECT count(*) FROM pg_database WHERE datdba = r.oid) = 0
    FROM pg_roles r WHERE r.rolname = :'app'))
SQL
    row <<'SQL'
 ('runtime role can connect',
   has_database_privilege(:'app', current_database(), 'CONNECT'))
SQL
    row <<'SQL'
 ('runtime role has no CREATE or TEMPORARY on the database',
   NOT (has_database_privilege(:'app', current_database(), 'CREATE') OR has_database_privilege(:'app', current_database(), 'TEMPORARY')))
SQL
    row <<'SQL'
 ('runtime role can use the public schema but not create in it',
   has_schema_privilege(:'app', 'public', 'USAGE') AND NOT has_schema_privilege(:'app', 'public', 'CREATE'))
SQL
    row <<'SQL'
 ('PUBLIC has no CONNECT / TEMPORARY / CREATE on the database (effective)',
   NOT (has_database_privilege('public', current_database(), 'CONNECT') OR has_database_privilege('public', current_database(), 'TEMPORARY') OR has_database_privilege('public', current_database(), 'CREATE')))
SQL
    row <<'SQL'
 ('PUBLIC has no rights on the public schema (effective)',
   NOT (has_schema_privilege('public', 'public', 'USAGE') OR has_schema_privilege('public', 'public', 'CREATE')))
SQL
    row <<'SQL'
 ('PUBLIC holds no ACL entry on the database (explicit ACL cross-check)',
   NOT EXISTS (SELECT 1 FROM pg_database d
     CROSS JOIN LATERAL aclexplode(NULLIF(COALESCE(d.datacl, acldefault('d', d.datdba)), '{}'::aclitem[])) a
     WHERE d.datname = current_database() AND a.grantee = 0))
SQL
    row <<'SQL'
 ('PUBLIC holds no ACL entry on schema public (explicit ACL cross-check)',
   NOT EXISTS (SELECT 1 FROM pg_namespace n
     CROSS JOIN LATERAL aclexplode(NULLIF(COALESCE(n.nspacl, acldefault('n', n.nspowner)), '{}'::aclitem[])) a
     WHERE n.nspname = 'public' AND a.grantee = 0))
SQL
    row <<'SQL'
 ('timezone is UTC for both roles in this database (catalog setting)',
   (SELECT count(*) = 2 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
     WHERE s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND r.rolname IN (:'own', :'app') AND EXISTS (SELECT 1 FROM unnest(s.setconfig) c WHERE lower(c) = 'timezone=utc')))
SQL
    row <<'SQL'
 ('search_path is public for both roles in this database (catalog setting)',
   (SELECT count(*) = 2 FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole
     WHERE s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
       AND r.rolname IN (:'own', :'app') AND s.setconfig @> ARRAY['search_path=public']))
SQL
    row <<'SQL'
 ('connection limits are exactly the approved values',
   (SELECT bool_and(rolconnlimit = CASE rolname WHEN :'own' THEN :'ownlim'::int ELSE :'applim'::int END) FROM pg_roles WHERE rolname IN (:'own', :'app')))
SQL
    row <<'SQL'
 ('exactly two access rules name this database: hostssl, one per role, host/32, scram-sha-256, no options',
   (SELECT count(*) FILTER (WHERE database && ARRAY[current_database()::text]) = 2
       AND count(*) FILTER (WHERE error IS NULL AND type = 'hostssl' AND database = ARRAY[current_database()::text]
             AND address = :'host' AND netmask = '255.255.255.255' AND auth_method = 'scram-sha-256' AND options IS NULL
             AND (user_name = ARRAY[:'own'] OR user_name = ARRAY[:'app'])) = 2
    FROM pg_hba_file_rules))
SQL
    row <<'SQL'
 ('for each role, the FIRST rule that could match from the rehearsal host is its own hostssl rule',
   (WITH cand AS (
      SELECT line_number, user_name, type, address, netmask FROM pg_hba_file_rules
      WHERE error IS NULL AND type IN ('host', 'hostssl', 'hostnossl', 'hostgssenc', 'hostnogssenc')
        AND (database && ARRAY['all', current_database()::text] OR EXISTS (SELECT 1 FROM unnest(database) d WHERE d LIKE '@%'))
        AND CASE
              WHEN address IS NULL OR address IN ('all', 'samehost', 'samenet') THEN true
              WHEN address ~ '^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$' AND netmask ~ '^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$'
                   THEN (:'host'::inet & netmask::inet) = address::inet
              WHEN address LIKE '%:%' THEN false
              ELSE true END),
    roles(r) AS (VALUES (:'own'), (:'app'))
    SELECT bool_and(
      (SELECT line_number FROM cand WHERE user_name && ARRAY['all', r] OR EXISTS (SELECT 1 FROM unnest(user_name) u WHERE u LIKE '@%') ORDER BY line_number LIMIT 1)
      = (SELECT line_number FROM cand WHERE type = 'hostssl' AND user_name = ARRAY[r] AND address = :'host' ORDER BY line_number LIMIT 1))
    FROM roles))
SQL
    row <<'SQL'
 ('no non-TLS rule can match this database or these roles from a remote address',
   NOT EXISTS (SELECT 1 FROM pg_hba_file_rules
       WHERE type IN ('host', 'hostnossl') AND error IS NULL
         AND database && ARRAY[current_database()::text, 'all']
         AND user_name && ARRAY[:'own', :'app', 'all']
         AND coalesce(address, '') NOT IN ('127.0.0.1', '::1')))
SQL
    row <<'SQL'
 ('pg_hba.conf has no errors',
   NOT EXISTS (SELECT 1 FROM pg_hba_file_rules WHERE error IS NOT NULL))
SQL
    row <<'SQL'
 ('the database and both roles carry the rehearsal provenance comment',
   (SELECT coalesce(shobj_description(d.oid, 'pg_database'), '') LIKE :'tag' || '%' FROM pg_database d WHERE d.datname = current_database())
   AND (SELECT bool_and(coalesce(shobj_description(r.oid, 'pg_authid'), '') LIKE :'tag' || '%') FROM pg_roles r WHERE r.rolname IN (:'own', :'app')))
SQL
    if [[ $PHASE == pre ]]; then
        row <<'SQL'
 ('phase pre: schema public is empty (no tables, views, sequences, functions)',
   NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public')
   AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'))
SQL
    else
        row <<'SQL'
 ('phase post: the table inventory is as expected (EXPECTED_TABLES exactly, or at least one table)',
   CASE WHEN :'expected' = '' THEN (SELECT count(*) > 0 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p'))
        ELSE (SELECT coalesce(array_agg(c.relname::text ORDER BY c.relname::text), '{}') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r','p'))
             = (SELECT array_agg(t ORDER BY t) FROM unnest(string_to_array(:'expected', ',')) t) END)
SQL
        row <<'SQL'
 ('phase post: every table in public is owned by the owner role',
   NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p','S','v','m') AND pg_get_userbyid(c.relowner) <> :'own'))
SQL
        row <<'SQL'
 ('phase post: runtime role has SELECT, INSERT, UPDATE and DELETE on every table',
   NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT (
         has_table_privilege(:'app', c.oid, 'SELECT') AND has_table_privilege(:'app', c.oid, 'INSERT')
         AND has_table_privilege(:'app', c.oid, 'UPDATE') AND has_table_privilege(:'app', c.oid, 'DELETE'))))
SQL
        row <<'SQL'
 ('phase post: runtime role has no TRUNCATE, REFERENCES or TRIGGER on any table',
   NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND (
         has_table_privilege(:'app', c.oid, 'TRUNCATE') OR has_table_privilege(:'app', c.oid, 'REFERENCES')
         OR has_table_privilege(:'app', c.oid, 'TRIGGER'))))
SQL
        row <<'SQL'
 ('phase post: runtime role has USAGE on every sequence',
   NOT EXISTS (SELECT 1 FROM pg_sequences q WHERE q.schemaname = 'public'
       AND NOT has_sequence_privilege(:'app', quote_ident(q.schemaname) || '.' || quote_ident(q.sequencename), 'USAGE')))
SQL
    fi
}

catalog_checks() {
    local values i
    build_rows
    values=
    for i in "${!ROWS[@]}"; do values+="${ROWS[$i]}"; ((i < ${#ROWS[@]} - 1)) && values+=","$'\n'; done
    pg -d "$DB_NAME" -v own="$OWNER_ROLE" -v app="$APP_ROLE" -v host="$HOST_IP" -v tag="$TAG" \
        -v ownlim="$OWNER_CONN_LIMIT" -v applim="$APP_CONN_LIMIT" -v expected="${EXPECTED_TABLES:-}" <<SQL
BEGIN READ ONLY;
SET LOCAL statement_timeout = '15s';
SET LOCAL lock_timeout = '2s';
SELECT CASE WHEN ok IS TRUE THEN 'PASS' ELSE 'FAIL' END || E'\t' || what FROM (VALUES
$values
) AS t(what, ok);
ROLLBACK;
SQL
}

# probe "description" ROLE "SQL" deny|allow
# The role switch must be shown to have worked (ROLE=<name> is printed), and a denial must be SQLSTATE 42501.
probe() {
    local what=$1 role=$2 sql=$3 expect=$4 out nerr
    out=$(pgw -d "$DB_NAME" 2>&1 <<SQL || true
\\set ON_ERROR_STOP off
\\set VERBOSITY sqlstate
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '5s';
SET LOCAL ROLE "$role";
SELECT 'ROLE=' || current_user;
$sql;
ROLLBACK;
SQL
    )
    if ! grep -qx "ROLE=$role" <<<"$out"; then printf 'FAIL\t%s (could not switch to role %s)\n' "$what" "$role"; return; fi
    nerr=$(grep -c '^ERROR:' <<<"$out" || true)
    if [[ $expect == deny ]]; then
        if ((nerr == 1)) && grep -qx 'ERROR:  42501' <<<"$out"; then printf 'PASS\t%s (SQLSTATE 42501)\n' "$what"; else printf 'FAIL\t%s\n' "$what"; fi
    else
        if ((nerr == 0)); then printf 'PASS\t%s\n' "$what"; else printf 'FAIL\t%s\n' "$what"; fi
    fi
}

probe_checks() {
    local n="_verify_probe_$$_$RANDOM"
    probe "attempt: runtime role CREATE TABLE is denied" "$APP_ROLE" "CREATE TABLE public.$n (i int)" deny
    probe "attempt: runtime role CREATE TEMPORARY TABLE is denied" "$APP_ROLE" "CREATE TEMPORARY TABLE $n (i int)" deny
    probe "attempt: runtime role CREATE SCHEMA is denied" "$APP_ROLE" "CREATE SCHEMA $n" deny
    probe "attempt: owner role CREATE TABLE succeeds (rolled back)" "$OWNER_ROLE" "CREATE TABLE public.$n (i int)" allow
}

main() {
    [[ $EUID -eq 0 || -n ${PG_RUN_NO_ROOT:-} ]] || { err "Run as root: sudo $0"; exit 1; }
    parse_args "$@"
    gather
    local out n expected_total mode_line
    if ((PROBES)); then
        local ev
        ev=$(pg -c "SELECT count(*) FROM pg_event_trigger") || { err "Cannot read event triggers."; exit 1; }
        [[ $ev == 0 ]] || { err "$ev event trigger(s) exist: a DDL probe could fire them. Refusing to run probes."; exit 1; }
        echo "The DDL probes are NOT read-only: they run CREATE statements inside transactions that are rolled back,"
        echo "taking locks and writing catalog/WAL activity, and may be recorded by audit logging."
        local c; read -rp "Type PROBE $DB_NAME to run them: " c || c=
        [[ $c == "PROBE $DB_NAME" ]] || { echo "Cancelled. Nothing was run."; exit 0; }
        mode_line="catalog checks (READ ONLY transaction) PLUS rolled-back DDL probes (a mutation probe, not read-only)"
    else
        mode_line="catalog checks only (READ ONLY transaction; no DDL attempted)"
    fi
    echo "Verification: $mode_line"
    echo "  phase:         $PHASE"
    echo "  time (UTC):    $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "  host:          $(hostname)"
    echo "  PostgreSQL:    $(pg -c 'SHOW server_version')"
    echo "  database:      $DB_NAME   collation/encoding: $(pg -d "$DB_NAME" -c "SELECT datcollate || ' / ' || pg_encoding_to_char(encoding) FROM pg_database WHERE datname = current_database()")"
    echo "  owner role:    $OWNER_ROLE"
    echo "  runtime role:  $APP_ROLE"
    echo "  access host:   $HOST_IP/32"
    echo "  tables in public: $(pg -d "$DB_NAME" -c "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")   sequences: $(pg -d "$DB_NAME" -c "SELECT count(*) FROM pg_sequences WHERE schemaname = 'public'")"
    [[ -z ${EXPECTED_TABLES:-} ]] || echo "  expected tables: $EXPECTED_TABLES"
    echo
    build_rows; expected_total=${#ROWS[@]}   # (the count is taken here, not inside the command substitution below)
    out=$(catalog_checks) || { err "A verification query failed, so the result is NOT confirmed."; exit 1; }
    if ((PROBES)); then out+=$'\n'$(probe_checks); expected_total=$((expected_total + 4)); fi
    echo "$out"
    n=$(grep -cE '^(PASS|FAIL)' <<<"$out" || true)
    echo
    if ((n != expected_total)); then
        err "Only $n of $expected_total checks produced a result, so the outcome is NOT confirmed."
        exit 1
    fi
    if grep -q '^FAIL' <<<"$out"; then
        err "$(grep -c '^FAIL' <<<"$out") of $n checks FAILED. Stop: do not start the application."
        exit 1
    fi
    ok "All $n checks passed (phase $PHASE$( ((PROBES)) && echo ', with DDL probes')$( ((PROBES)) || echo ', catalog only'))."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
