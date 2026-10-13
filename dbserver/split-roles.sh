#!/usr/bin/env bash
# Splits database access into two roles, for a PostgreSQL database that so far has
# ONE role that owns the database and is also used by the application.
#
#   sudo bash dbserver/split-roles.sh
#
#   <db>_owner  migration role. Owns the database and every object in it, so it can
#               change the schema. Used only to run migrations, never by the running app.
#   <db>_app    runtime role. Can read and write rows (SELECT, INSERT, UPDATE, DELETE
#               on tables; USAGE and SELECT on sequences) and nothing else: it owns
#               nothing and cannot create, alter or drop anything, or truncate tables.
#
# What it does
#   - creates both roles with random passwords (shown once, never written to a file)
#   - moves ownership of the database and its existing objects from the old role to <db>_owner
#   - grants the runtime role its row-level rights, including on tables the owner creates later
#     (default privileges), so migrations need no extra grants
#   - removes PUBLIC's rights on the database and the public schema
#   - allows both new roles from the app server over TLS only (hostssl), retires the old
#     role's rule and locks the old role (login disabled; nothing is dropped)
#   - checks the result and exits non-zero if any check fails
#
# Anything that must create tables (for example a session table that a library creates on
# first use) has to be created by the migration/owner role, because the runtime role can't.
#
# Safe to re-run: roles and grants are re-applied; passwords are only reset if you say so.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"

PG_ETC=${PG_ETC:-/etc/postgresql}
PG_RUN=${PG_RUN:-runuser -u postgres --}
EXPECTED_CHECKS=14   # 13 in the main query + 1 default-privileges check
pg() { $PG_RUN psql -v ON_ERROR_STOP=1 -X -Atq "$@"; }
# shellcheck disable=SC2086
yes_no() { local a def=${2:-n} hint='[y/N]'; [[ $def == y ]] && hint='[Y/n]'; read -rp "$1 $hint: " a; a=${a:-$def}; [[ ${a,,} == y* ]]; }
ask() { local v; read -rp "$1${3:+ [$3]}: " v; printf -v "$2" '%s' "${v:-${3:-}}"; }

role_exists() { [[ $(pg -c "SELECT 1 FROM pg_roles WHERE rolname='$1'") == 1 ]]; }

find_hba() {
    local v; v=$(ls "$PG_ETC" 2>/dev/null | sort -n | tail -1)
    [[ -n $v ]] && echo "$PG_ETC/$v/main/pg_hba.conf"
}

gather() {
    ask "Database name" DB_NAME "${DB_NAME:-}"
    valid_dbname "$DB_NAME" || { err "Invalid database name."; exit 1; }
    [[ $(pg -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'") == 1 ]] || { err "Database $DB_NAME does not exist."; exit 1; }

    local cur; cur=$(pg -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB_NAME'")
    ask "Role that owns it now (the old combined role)" OLD_ROLE "${OLD_ROLE:-$cur}"
    ask "New migration/owner role" OWNER_ROLE "${OWNER_ROLE:-${DB_NAME}_owner}"
    ask "New runtime application role" APP_ROLE "${APP_ROLE:-${DB_NAME}_app}"
    valid_dbname "$OWNER_ROLE" && valid_dbname "$APP_ROLE" || { err "Role names: lowercase letters, digits, underscore."; exit 1; }
    [[ $OWNER_ROLE != "$APP_ROLE" ]] || { err "The two roles must differ."; exit 1; }
    if [[ $OLD_ROLE == "$APP_ROLE" ]]; then
        err "The runtime role must be a NEW role, not the old combined role: the old role is demoted and locked."
        exit 1
    fi

    HBA=${HBA:-$(find_hba)}
    local guess=""
    if [[ -f $HBA ]]; then
        guess=$(awk -v d="$DB_NAME" -v u="$OLD_ROLE" '$1 ~ /^host(ssl)?$/ && $2==d && $3==u {sub(/\/32$/,"",$4); print $4; exit}' "$HBA")
    fi
    ask "App server private IP (allowed to connect)" APP_IP "${APP_IP:-$guess}"
    valid_ipv4 "$APP_IP" || { err "Not a valid IPv4 address."; exit 1; }
    [[ -f $HBA ]] || { err "pg_hba.conf not found (set HBA=/path)."; exit 1; }
}

summary() {
    echo
    info "About to:"
    echo "  database:        $DB_NAME"
    if [[ -n $OLD_ROLE && $OLD_ROLE != "$OWNER_ROLE" && $OLD_ROLE != postgres ]]; then
        echo "  old role:        $OLD_ROLE   (ownership moves away; login can be disabled afterwards)"
    fi
    echo "  owner/migration: $OWNER_ROLE   (owns everything; for migrations only)"
    echo "  runtime app:     $APP_ROLE   (rows only; no ownership, no schema changes)"
    echo "  allowed from:    $APP_IP/32 over TLS only"
    yes_no "Continue?" y || exit 0
}

make_role() {   # make_role name  -> sets pass_<name> when a password was set
    local r=$1 pass
    if role_exists "$r"; then
        if yes_no "Role $r already exists. Reset its password?" n; then
            pass=$(random_password)
            pg <<SQL
ALTER ROLE "$r" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '$pass';
SQL
            RESULTS+=("$r|$pass")
        else
            pg -c "ALTER ROLE \"$r\" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"
        fi
    else
        pass=$(random_password)
        pg <<SQL
CREATE ROLE "$r" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '$pass';
SQL
        RESULTS+=("$r|$pass")
    fi
}

apply_grants() {
    info "Moving ownership and applying grants..."
    pg -d "$DB_NAME" <<SQL
$( [[ -n $OLD_ROLE && $OLD_ROLE != "$OWNER_ROLE" && $OLD_ROLE != postgres ]] && echo "REASSIGN OWNED BY \"$OLD_ROLE\" TO \"$OWNER_ROLE\";" )
ALTER DATABASE "$DB_NAME" OWNER TO "$OWNER_ROLE";
ALTER SCHEMA public OWNER TO "$OWNER_ROLE";

REVOKE ALL ON DATABASE "$DB_NAME" FROM PUBLIC;
REVOKE ALL ON DATABASE "$DB_NAME" FROM "$APP_ROLE";
GRANT CONNECT ON DATABASE "$DB_NAME" TO "$OWNER_ROLE", "$APP_ROLE";
$( [[ -n $OLD_ROLE && $OLD_ROLE != "$OWNER_ROLE" && $OLD_ROLE != postgres ]] && echo "REVOKE ALL ON DATABASE \"$DB_NAME\" FROM \"$OLD_ROLE\";" )

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM "$APP_ROLE";
GRANT USAGE ON SCHEMA public TO "$APP_ROLE";

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$APP_ROLE";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$APP_ROLE";
REVOKE TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public FROM "$APP_ROLE";

ALTER DEFAULT PRIVILEGES FOR ROLE "$OWNER_ROLE" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "$APP_ROLE";
ALTER DEFAULT PRIVILEGES FOR ROLE "$OWNER_ROLE" IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO "$APP_ROLE";
SQL
}

hba_add() {   # hba_add db role
    if ! grep -qE "^hostssl[[:space:]]+$1[[:space:]]+$2[[:space:]]+$APP_IP/32[[:space:]]" "$HBA"; then
        printf 'hostssl\t%s\t%s\t%s/32\tscram-sha-256\n' "$1" "$2" "$APP_IP" >> "$HBA"
    fi
}

update_hba() {
    info "Updating pg_hba.conf (TLS only)..."
    cp -a "$HBA" "$HBA.bak.$(date +%Y%m%d%H%M%S)"
    hba_add "$DB_NAME" "$OWNER_ROLE"
    hba_add "$DB_NAME" "$APP_ROLE"
    if [[ -n $OLD_ROLE && $OLD_ROLE != "$OWNER_ROLE" && $OLD_ROLE != postgres ]]; then
        awk -v d="$DB_NAME" -v u="$OLD_ROLE" '
            $1 ~ /^host(ssl|nossl)?$/ && $2==d && $3==u { print "#retired by split-roles: " $0; next }
            { print }' "$HBA" > "$HBA.new"
        cat "$HBA.new" > "$HBA"; rm -f "$HBA.new"
        if yes_no "Disable login for the old role $OLD_ROLE (reversible with ALTER ROLE ... LOGIN)?" y; then
            pg -c "ALTER ROLE \"$OLD_ROLE\" NOLOGIN"
        fi
    fi
    pg -c "SELECT pg_reload_conf()" >/dev/null
}

# Prints "PASS|FAIL<TAB>description" for each check; returns non-zero if any failed.
verify() {
    info "Checking the result..."
    local out dp
    out=$(pg -d "$DB_NAME" <<SQL
\\set app '$APP_ROLE'
\\set own '$OWNER_ROLE'
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END || E'\t' || what FROM (VALUES
 ('runtime role is not superuser / createdb / createrole / replication / bypassrls',
   (SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname = :'app')),
 ('owner role is not superuser / createdb / createrole / replication / bypassrls',
   (SELECT NOT (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls) FROM pg_roles WHERE rolname = :'own')),
 ('database is owned by the owner role',
   (SELECT pg_get_userbyid(datdba) = :'own' FROM pg_database WHERE datname = current_database())),
 ('runtime role owns no objects in this database',
   (SELECT count(*) = 0 FROM pg_class WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = :'app'))),
 ('runtime role can connect',
   has_database_privilege(:'app', current_database(), 'CONNECT')),
 ('runtime role cannot create schemas',
   NOT has_database_privilege(:'app', current_database(), 'CREATE')),
 ('runtime role cannot create temporary tables',
   NOT has_database_privilege(:'app', current_database(), 'TEMPORARY')),
 ('runtime role can use the public schema',
   has_schema_privilege(:'app', 'public', 'USAGE')),
 ('runtime role cannot create objects in the public schema',
   NOT has_schema_privilege(:'app', 'public', 'CREATE')),
 ('PUBLIC has no rights on the database',
   NOT has_database_privilege('public', current_database(), 'CONNECT')),
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
 ('runtime role can use every sequence',
   NOT EXISTS (SELECT 1 FROM pg_sequences q WHERE q.schemaname = 'public'
       AND NOT has_sequence_privilege(:'app', quote_ident(q.schemaname) || '.' || quote_ident(q.sequencename), 'USAGE')))
) AS t(what, ok);
SQL
    ) || { err "The verification query failed, so the result is NOT confirmed."; return 1; }
    # A table the OWNER creates later must automatically be usable by the runtime role.
    dp=$(pg -d "$DB_NAME" <<SQL
BEGIN;
SET LOCAL ROLE "$OWNER_ROLE";
CREATE TABLE public._split_roles_check (id serial PRIMARY KEY, v text);
SELECT CASE WHEN has_table_privilege('$APP_ROLE', 'public._split_roles_check', 'INSERT')
             AND has_table_privilege('$APP_ROLE', 'public._split_roles_check', 'SELECT')
             AND NOT has_table_privilege('$APP_ROLE', 'public._split_roles_check', 'TRUNCATE')
             AND has_sequence_privilege('$APP_ROLE', 'public._split_roles_check_id_seq', 'USAGE')
            THEN 'PASS' ELSE 'FAIL' END || E'\ta table created later by the owner role is usable by the runtime role (default privileges)';
ROLLBACK;
SQL
    ) || { err "The default-privileges check failed, so the result is NOT confirmed."; return 1; }
    echo "$out"; echo "$dp"
    local all=$out$'\n'$dp n
    n=$(grep -cE '^(PASS|FAIL)' <<<"$all" || true)
    if ((n != EXPECTED_CHECKS)); then
        err "Only $n of $EXPECTED_CHECKS checks produced a result, so the outcome is NOT confirmed."
        return 1
    fi
    ! grep -q '^FAIL' <<<"$all"
}

report() {
    echo
    ok "============ Roles ready ============"
    echo "Database:          $DB_NAME   (host: this server's private IP, port 5432, sslmode=verify-full)"
    echo "Migration role:    $OWNER_ROLE   - use ONLY to run migrations / schema changes"
    echo "Runtime role:      $APP_ROLE   - use for the running application and its sessions"
    echo "Both connect from: $APP_IP over TLS only."
    if ((${#RESULTS[@]})); then
        echo
        warn "PASSWORDS (shown once; not stored anywhere). Send them through the agreed secure channel:"
        local r
        for r in "${RESULTS[@]}"; do echo "  ${r%%|*}:  ${r#*|}"; done
    fi
    echo
    echo "Note: a table that the application library creates on first use (for example a session"
    echo "table) must be created by the migration role; the runtime role cannot create tables."
}

main() {
    [[ $EUID -eq 0 || -n ${PG_RUN_NO_ROOT:-} ]] || { err "Run as root: sudo $0"; exit 1; }
    RESULTS=()
    gather
    summary
    make_role "$OWNER_ROLE"
    make_role "$APP_ROLE"
    apply_grants
    update_hba
    if verify; then ok "All checks passed."; else err "Some checks FAILED - see above."; report; exit 1; fi
    report
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
