#!/usr/bin/env bash
# Creates (or removes) an isolated, EMPTY rehearsal database, its two roles and its two
# TLS-only access lines, on the shared database server. Nothing else is touched.
#
#   sudo bash dbserver/create-rehearsal-db.sh plan      # DEFAULT. Prints exactly what would change; changes nothing.
#   sudo bash dbserver/create-rehearsal-db.sh apply     # Makes the changes (you must type a confirmation).
#   sudo bash dbserver/create-rehearsal-db.sh cleanup   # Removes ONLY the rehearsal database, roles and access lines.
#
# Inputs (prompted; or set as environment variables to accept them with Enter)
#   DB_NAME       default dbscheckcrm_rehearsal
#   OWNER_ROLE    default <db>_owner     migration role: owns the database; used only to run DDL
#   APP_ROLE      default <db>_app       runtime role: rows only; used by the running application
#   HOST_IP       the rehearsal application host's PRIVATE IPv4 (no default)
#
# What `apply` does, and nothing more
#   1. CREATE ROLE x2 (LOGIN, no superuser/createdb/createrole/replication/bypassrls, connection limits,
#      random passwords shown once and never written to a file) and CREATE DATABASE owned by the owner role
#   2. REVOKE all PUBLIC rights on the database and the public schema; GRANT CONNECT and USAGE to the
#      runtime role only; make the owner role own the public schema
#   3. ALTER ROLE ... IN DATABASE ... SET timezone = 'UTC' and search_path = public (scoped to this
#      database; the server timezone is not changed)
#   4. append two lines to pg_hba.conf (TLS only, this database, one role each, HOST_IP/32,
#      scram-sha-256) and run pg_reload_conf()
#
# What it never does: restart PostgreSQL; change any global or archiving/WAL setting; touch the
# certificates; touch any existing database, role or access line; create tables or grants on tables
# (the application's own runtime-grants.sql does that, after its schema is loaded); open the cloud
# firewall (a separate, listed step).
#
# Safeguards: it refuses if the database or either role already exists, if a name does not contain
# "rehearsal", if a name is a protected production name, if HOST_IP is not a private address or is the
# production application server, and `cleanup` refuses to touch anything that is not a rehearsal name.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"

PG_ETC=${PG_ETC:-/etc/postgresql}
PG_RUN=${PG_RUN:-runuser -u postgres --}
PROD_DB=${PROD_DB:-dbscheckcrm}                  # protected: never created, changed or dropped
PROD_APP_IP=${PROD_APP_IP:-172.26.0.238}         # protected: the existing application server
APP_CONN_LIMIT=${APP_CONN_LIMIT:-24}             # two pools of 10 plus a small reserve
OWNER_CONN_LIMIT=${OWNER_CONN_LIMIT:-5}

pg() { $PG_RUN psql -v ON_ERROR_STOP=1 -X -Atq "$@"; }
ask() { local v=; read -rp "$1${3:+ [$3]}: " v || true; printf -v "$2" '%s' "${v:-${3:-}}"; }
db_exists()   { [[ $(pg -c "SELECT 1 FROM pg_database WHERE datname='$1'") == 1 ]]; }
role_exists() { [[ $(pg -c "SELECT 1 FROM pg_roles WHERE rolname='$1'") == 1 ]]; }
is_private_ipv4() { local a b; IFS=. read -r a b _ <<<"$1"; a=$((10#$a)); b=$((10#$b)); ((a==10)) || ((a==172 && b>=16 && b<=31)) || ((a==192 && b==168)); }

find_hba() {
    local v; v=$(ls "$PG_ETC" 2>/dev/null | sort -n | tail -1)
    [[ -n $v ]] && echo "$PG_ETC/$v/main/pg_hba.conf"
}

gather() {
    ask "Rehearsal database name" DB_NAME "${DB_NAME:-dbscheckcrm_rehearsal}"
    ask "Owner (migration) role" OWNER_ROLE "${OWNER_ROLE:-${DB_NAME}_owner}"
    ask "Runtime role" APP_ROLE "${APP_ROLE:-${DB_NAME}_app}"
    ask "Rehearsal application host PRIVATE IPv4" HOST_IP "${HOST_IP:-}"

    local n
    for n in "$DB_NAME" "$OWNER_ROLE" "$APP_ROLE"; do
        valid_dbname "$n" || { err "'$n': use lowercase letters, digits and underscore, starting with a letter (max 31)."; exit 1; }
        [[ $n == *rehearsal* ]] || { err "'$n' does not contain 'rehearsal'. Refusing: this script only handles rehearsal names."; exit 1; }
        case $n in
            "$PROD_DB"|"${PROD_DB}_owner"|"${PROD_DB}_app"|postgres|template0|template1)
                err "'$n' is a protected name. Refusing."; exit 1 ;;
        esac
    done
    [[ $OWNER_ROLE != "$APP_ROLE" ]] || { err "The owner and runtime roles must differ."; exit 1; }
    [[ $OWNER_ROLE != "$DB_NAME" && $APP_ROLE != "$DB_NAME" ]] || { err "A role must not share the database's name."; exit 1; }
    valid_ipv4 "$HOST_IP" || { err "HOST_IP is not a valid IPv4 address."; exit 1; }
    is_private_ipv4 "$HOST_IP" || { err "HOST_IP $HOST_IP is not a private address."; exit 1; }
    [[ $HOST_IP != "$PROD_APP_IP" ]] || { err "HOST_IP is the production application server ($PROD_APP_IP). The rehearsal uses a separate host."; exit 1; }
    HBA=${HBA:-$(find_hba)}
    [[ -f $HBA ]] || { err "pg_hba.conf not found (set HBA=/path)."; exit 1; }
}

# ---- the exact SQL, shared by plan and apply, so what is printed is what runs ----
stage1_sql() {
    cat <<SQL
CREATE ROLE "$OWNER_ROLE" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT $OWNER_CONN_LIMIT PASSWORD '@@OWNER_PW@@';
CREATE ROLE "$APP_ROLE" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT $APP_CONN_LIMIT PASSWORD '@@APP_PW@@';
CREATE DATABASE "$DB_NAME" OWNER "$OWNER_ROLE";
SQL
}
stage2_sql() {   # run inside the new database
    cat <<SQL
REVOKE ALL ON DATABASE "$DB_NAME" FROM PUBLIC;
GRANT CONNECT ON DATABASE "$DB_NAME" TO "$APP_ROLE";
ALTER SCHEMA public OWNER TO "$OWNER_ROLE";
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO "$APP_ROLE";
ALTER ROLE "$OWNER_ROLE" IN DATABASE "$DB_NAME" SET timezone = 'UTC';
ALTER ROLE "$APP_ROLE" IN DATABASE "$DB_NAME" SET timezone = 'UTC';
ALTER ROLE "$OWNER_ROLE" IN DATABASE "$DB_NAME" SET search_path = public;
ALTER ROLE "$APP_ROLE" IN DATABASE "$DB_NAME" SET search_path = public;
SQL
}
cleanup_sql() {
    cat <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "$DB_NAME";
DROP ROLE IF EXISTS "$APP_ROLE";
DROP ROLE IF EXISTS "$OWNER_ROLE";
SQL
}
hba_lines() {
    printf 'hostssl\t%s\t%s\t%s/32\tscram-sha-256\n' "$DB_NAME" "$OWNER_ROLE" "$HOST_IP"
    printf 'hostssl\t%s\t%s\t%s/32\tscram-sha-256\n' "$DB_NAME" "$APP_ROLE" "$HOST_IP"
}

state_line() {   # state_line label exists?
    if [[ $2 == yes ]]; then echo "  $1: EXISTS (apply would refuse)"; else echo "  $1: does not exist (good)"; fi
}

cmd_plan() {
    local de oe ae
    db_exists "$DB_NAME" && de=yes || de=no
    role_exists "$OWNER_ROLE" && oe=yes || oe=no
    role_exists "$APP_ROLE" && ae=yes || ae=no
    info "PLAN ONLY: nothing is changed by this command."
    echo
    echo "Target:"
    echo "  database:             $DB_NAME"
    echo "  owner/migration role: $OWNER_ROLE   (connection limit $OWNER_CONN_LIMIT)"
    echo "  runtime role:         $APP_ROLE   (connection limit $APP_CONN_LIMIT)"
    echo "  rehearsal host:       $HOST_IP/32   (protected production app server: $PROD_APP_IP; protected database: $PROD_DB)"
    echo "  pg_hba.conf:          $HBA"
    echo
    echo "Current state:"
    state_line "database $DB_NAME" $de
    state_line "role $OWNER_ROLE" $oe
    state_line "role $APP_ROLE" $ae
    echo
    echo "Step 1, run in the postgres database (passwords are generated at apply time and shown once):"
    stage1_sql | sed 's/^/    /' | sed "s/'@@[A-Z]*_PW@@'/'<generated>'/"
    echo
    echo "Step 2, run inside $DB_NAME:"
    stage2_sql | sed 's/^/    /'
    echo
    echo "Step 3, lines appended to pg_hba.conf (a timestamped backup is made first), then SELECT pg_reload_conf():"
    hba_lines | sed 's/^/    /'
    echo
    echo "Not done by this script: PostgreSQL restart, any global/archiving/WAL setting, certificates, table grants"
    echo "(the application's runtime-grants.sql does those), the cloud firewall rule for $HOST_IP (separate, listed step)."
    echo
    echo "To undo all of this later (cleanup mode, after a typed confirmation):"
    cleanup_sql | sed 's/^/    /'
    echo "    ...and the two lines above are removed from pg_hba.conf, then SELECT pg_reload_conf()."
}

hba_add() {   # all lines appended in one go, idempotent per line
    local l
    while IFS= read -r l; do
        grep -qxF -- "$l" "$HBA" || printf '%s\n' "$l" >> "$HBA"
    done < <(hba_lines)
}

hba_check() {   # both lines valid, no errors anywhere in the file
    local good bad
    good=$(pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NULL AND type='hostssl' AND database = ARRAY['$DB_NAME'] AND address = '$HOST_IP' AND netmask = '255.255.255.255' AND auth_method='scram-sha-256' AND (user_name = ARRAY['$OWNER_ROLE'] OR user_name = ARRAY['$APP_ROLE'])")
    bad=$(pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")
    [[ $good == 2 && $bad == 0 ]]
}

cmd_apply() {
    local pw_o pw_a s1 c
    db_exists "$DB_NAME" && { err "Database $DB_NAME already exists. Refusing (it must be new and empty)."; exit 1; }
    role_exists "$OWNER_ROLE" && { err "Role $OWNER_ROLE already exists. Refusing."; exit 1; }
    role_exists "$APP_ROLE" && { err "Role $APP_ROLE already exists. Refusing."; exit 1; }
    cmd_plan
    echo
    read -rp "Type CREATE $DB_NAME to make exactly these changes: " c
    [[ $c == "CREATE $DB_NAME" ]] || { echo "Cancelled. Nothing changed."; exit 0; }

    pw_o=$(random_password); pw_a=$(random_password)
    s1=$(stage1_sql); s1=${s1//@@OWNER_PW@@/$pw_o}; s1=${s1//@@APP_PW@@/$pw_a}
    info "Creating roles and database..."
    pg -d postgres <<<"$s1" >/dev/null || { err "Step 1 failed. Review, then run: sudo bash $0 cleanup"; exit 1; }
    info "Applying rights and role settings..."
    pg -d "$DB_NAME" <<<"$(stage2_sql)" >/dev/null || { err "Step 2 failed. Review, then run: sudo bash $0 cleanup"; exit 1; }
    info "Adding the two TLS-only access lines and reloading..."
    cp -a "$HBA" "$HBA.bak.$(date +%Y%m%d%H%M%S)"
    hba_add
    pg -c "SELECT pg_reload_conf()" >/dev/null
    sleep 1
    hba_check || { err "pg_hba.conf check failed (lines missing or file has errors). Backup is next to the file. Review before going on."; exit 1; }
    ok "Access lines accepted by PostgreSQL (valid, TLS-only, one role each, $HOST_IP/32)."

    echo
    ok "============ Rehearsal database ready (empty) ============"
    pg -d "$DB_NAME" -F ' | ' -c "SELECT 'database: ' || datname || ', encoding ' || pg_encoding_to_char(encoding) || ', collation ' || datcollate || ', ctype ' || datctype FROM pg_database WHERE datname = current_database()"
    pg -F ' | ' -c "SELECT 'role: ' || rolname || ', login ' || rolcanlogin || ', superuser ' || rolsuper || ', createdb ' || rolcreatedb || ', createrole ' || rolcreaterole || ', replication ' || rolreplication || ', connection limit ' || rolconnlimit FROM pg_roles WHERE rolname IN ('$OWNER_ROLE','$APP_ROLE') ORDER BY 1"
    echo "Connect with host (this server's private IP) over TLS, sslmode=verify-full, CA /etc/ssl/pg/ca.crt on the rehearsal host."
    echo
    warn "PASSWORDS (shown once; not stored anywhere). Pass them only through the agreed secure channel:"
    echo "  $OWNER_ROLE:  $pw_o"
    echo "  $APP_ROLE:  $pw_a"
    echo
    echo "Next: sudo bash dbserver/verify-roles.sh  (read-only checks). Do NOT start the application yet."
}

cmd_cleanup() {
    local c n
    info "CLEANUP of the rehearsal resources only."
    db_exists "$DB_NAME" && n=$(pg -d "$DB_NAME" -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')") || n=0
    echo "  database $DB_NAME exists: $(db_exists "$DB_NAME" && echo yes || echo no)   (tables in it: $n)"
    echo "  role $OWNER_ROLE exists:  $(role_exists "$OWNER_ROLE" && echo yes || echo no)"
    echo "  role $APP_ROLE exists:  $(role_exists "$APP_ROLE" && echo yes || echo no)"
    echo "  access lines present:"; hba_lines | while IFS= read -r l; do grep -qxF -- "$l" "$HBA" && echo "    $l"; done
    echo
    echo "This will run:"; cleanup_sql | sed 's/^/    /'
    echo "and remove the lines above from pg_hba.conf, then reload."
    read -rp "Type DELETE $DB_NAME to confirm (this removes the database and its data): " c
    [[ $c == "DELETE $DB_NAME" ]] || { echo "Cancelled. Nothing changed."; exit 0; }
    pg -d postgres <<<"$(cleanup_sql)" >/dev/null
    cp -a "$HBA" "$HBA.bak.$(date +%Y%m%d%H%M%S)"
    grep -vxF -f <(hba_lines) "$HBA" > "$HBA.new" || true
    cat "$HBA.new" > "$HBA"; rm -f "$HBA.new"
    pg -c "SELECT pg_reload_conf()" >/dev/null
    sleep 1
    if db_exists "$DB_NAME" || role_exists "$OWNER_ROLE" || role_exists "$APP_ROLE" || grep -qF -- "$DB_NAME" "$HBA"; then
        err "Something remains. Check the database, roles and pg_hba.conf by hand."; exit 1
    fi
    pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL" | grep -qx 0 || { err "pg_hba.conf now has errors. Restore the backup next to it."; exit 1; }
    ok "Rehearsal database, roles and access lines removed. pg_hba.conf has no errors."
}

main() {
    [[ $EUID -eq 0 || -n ${PG_RUN_NO_ROOT:-} ]] || { err "Run as root: sudo $0 [plan|apply|cleanup]"; exit 1; }
    case ${1:-plan} in
        plan)    gather; cmd_plan ;;
        apply)   gather; cmd_apply ;;
        cleanup) gather; cmd_cleanup ;;
        *) echo "Usage: $0 [plan|apply|cleanup]"; exit 1 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
