#!/usr/bin/env bash
# Creates (or removes) an isolated, EMPTY rehearsal database, its two roles and its two TLS-only
# access lines, on the shared database server. Nothing else is touched.
#
#   sudo bash dbserver/create-rehearsal-db.sh plan      # DEFAULT. Checks and prints what would change; changes nothing.
#   sudo SECRET_OUT=/root/rehearsal-secrets/db.txt bash dbserver/create-rehearsal-db.sh apply
#   sudo bash dbserver/create-rehearsal-db.sh cleanup   # Removes ONLY what this script created.
#
# Inputs (prompted; or set as environment variables and accept with Enter)
#   DB_NAME       default dbscheckcrm_rehearsal
#   OWNER_ROLE    default <db>_owner     migration role: owns the database; used only to run DDL
#   APP_ROLE      default <db>_app       runtime role: rows only; used by the running application
#   HOST_IP       the rehearsal application host's PRIVATE IPv4 (no default)
#   OWNER_CONN_LIMIT (default 5), APP_CONN_LIMIT (default 24): integers 1-100
#   DB_SERVER_IP  default 172.26.9.114: this script refuses to run on a machine that does not have it
#   PG_PORT       default 5432, PG_HOST default /var/run/postgresql (the cluster that is contacted is pinned)
#   SECRET_OUT    where `apply` puts the generated passwords: /root/rehearsal-secrets/<name> (see below)
#
# What `apply` does, and nothing more
#   1. CREATE ROLE x2 (LOGIN, no superuser/createdb/createrole/replication/bypassrls, connection limits)
#      and CREATE DATABASE owned by the owner role; each is tagged with a provenance comment
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
# firewall (a separate, reviewed step).
#
# Passwords
#   Generated here, never printed, never put in a command line. The server receives only a SCRAM-SHA-256
#   verifier (computed locally), so the plain password cannot appear in a CREATE ROLE statement, an
#   error message, or a statement log (a statement log would hold the salted verifier, which is also
#   sensitive: keep the database and audit logs protected). The plain passwords are written once, BEFORE
#   anything is created, to a NEW file named by SECRET_OUT, and ONLY inside the reviewed directory
#   /root/rehearsal-secrets, which must be root-owned with mode 0700 (the file is created mode 0600).
#   Arbitrary file descriptors are NOT accepted: a descriptor can point at a log collector or a readable
#   file. Move the passwords through the agreed secure channel, then delete the file (shred -u).
#
# Safeguards: refuses if the database or either role already exists, if a name does not contain
# "rehearsal", if a name is a protected production name, if HOST_IP is not a private address or is the
# production application server, if shell tracing is on, if a query fails (a failed query is never
# read as "does not exist"), if pg_hba.conf has errors, if configuration files changed since the last
# reload (a reload would activate someone else's unreviewed change; checked again immediately before EVERY
# reload, including rollback and cleanup, against a snapshot taken at the start), or if any existing rule
# could already match the new database/roles from HOST_IP. The candidate pg_hba.conf is proven to be the
# existing file plus exactly the two template lines BEFORE it is installed. A typed confirmation records
# that nobody else is changing this server's PostgreSQL configuration during the run: the script's own
# lock only stops two copies of this script, and a timestamp/hash check cannot stop a concurrent edit
# that happens a moment later, so the change exclusion is an operator commitment, not something code can prove. `cleanup` refuses any object that lacks this
# script's provenance comment.
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/rehearsal-common.sh"
refuse_tracing

PG_RUN=${PG_RUN:-runuser -u postgres --}
PG_HOST=${PG_HOST:-/var/run/postgresql}
PG_PORT=${PG_PORT:-5432}
PG_MAJOR=${PG_MAJOR:-16}
DB_SERVER_IP=${DB_SERVER_IP:-172.26.9.114}
PROD_DB=${PROD_DB:-dbscheckcrm}                  # protected: never created, changed or dropped
PROD_APP_IP=${PROD_APP_IP:-172.26.0.238}         # protected: the existing application server
APP_CONN_LIMIT=${APP_CONN_LIMIT:-24}             # two pools of 10 plus a small reserve
OWNER_CONN_LIMIT=${OWNER_CONN_LIMIT:-5}
LOCK_FILE=${LOCK_FILE:-/run/lock/create-rehearsal-db.lock}
TAG='crm-rehearsal synthetic; created by dbserver/create-rehearsal-db.sh'

# What this run has created, so a failure can undo exactly that and nothing else.
CREATED_OWNER=0; CREATED_APP=0; CREATED_DB=0; HBA_ADDED=0
SECRET_DIR=/root/rehearsal-secrets   # fixed on purpose: not an environment setting
SNAP_INV=

pg() { $PG_RUN env "PGHOST=$PG_HOST" "PGPORT=$PG_PORT" PGDATABASE=postgres psql -v ON_ERROR_STOP=1 -X -Atq "$@"; }
ask() { local v=; read -rp "$1${3:+ [$3]}: " v || true; printf -v "$2" '%s' "${v:-${3:-}}"; }

# Runs SQL from stdin in database $1. On failure prints the error with any SCRAM verifier hidden.
run_sql() {
    local db=$1 out
    if ! out=$(pg -d "$db" 2>&1); then
        sed -E 's/SCRAM-SHA-256\$[^'"'"' ]*/<verifier hidden>/g' <<<"$out" >&2
        return 1
    fi
}

# probe_exists db|role NAME  ->  prints yes or no. A query error stops the script: it is never "no".
probe_exists() {
    local out
    case $1 in
        db)   out=$(pg -c "SELECT count(*) FROM pg_database WHERE datname = '$2'") ;;
        role) out=$(pg -c "SELECT count(*) FROM pg_roles WHERE rolname = '$2'") ;;
        *)    err "internal error: probe_exists $1"; exit 1 ;;
    esac || { err "Could not query the server for $1 '$2'. Stopping: a failed query is not 'does not exist'."; exit 1; }
    case $out in
        0) echo no ;;
        1) echo yes ;;
        *) err "Unexpected answer '$out' looking up $1 '$2'. Stopping."; exit 1 ;;
    esac
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
    [[ $HOST_IP != "$DB_SERVER_IP" ]] || { err "HOST_IP is this database server."; exit 1; }
    valid_ipv4 "$DB_SERVER_IP" || { err "DB_SERVER_IP is not a valid IPv4 address."; exit 1; }
    bounded_int "$OWNER_CONN_LIMIT" 1 100 || { err "OWNER_CONN_LIMIT must be an integer from 1 to 100."; exit 1; }
    bounded_int "$APP_CONN_LIMIT" 1 100 || { err "APP_CONN_LIMIT must be an integer from 1 to 100."; exit 1; }
    bounded_int "$PG_PORT" 1 65535 || { err "PG_PORT must be a port number."; exit 1; }
}

# ---- pin and describe the server that is actually being contacted ----
connect_checks() {
    local info addrs
    info=$(pg -F '|' -c "SELECT current_setting('server_version'), current_setting('port'), current_setting('data_directory'), current_setting('hba_file'), current_setting('config_file'), current_setting('ident_file'), current_setting('ssl'), current_setting('listen_addresses')") \
        || { err "Cannot query PostgreSQL at $PG_HOST port $PG_PORT as the postgres user."; exit 1; }
    IFS='|' read -r S_VER S_PORT S_DATA HBA S_CONF S_IDENT S_SSL S_LISTEN <<<"$info"
    [[ $S_VER == "$PG_MAJOR".* ]] || { err "PostgreSQL is version $S_VER, expected $PG_MAJOR.x. Stopping."; exit 1; }
    [[ $S_PORT == "$PG_PORT" ]] || { err "The server reports port $S_PORT, expected $PG_PORT. Stopping."; exit 1; }
    [[ $S_SSL == on ]] || { err "The server has ssl=$S_SSL. TLS-only access lines cannot work. Stopping."; exit 1; }
    addrs=$(ip -4 -o addr show 2>/dev/null) || addrs=
    grep -qF " $DB_SERVER_IP/" <<<"$addrs" \
        || { err "This machine does not have the database server address $DB_SERVER_IP. Wrong server? Stopping."; exit 1; }
    [[ -f $HBA && -w $HBA ]] || { err "pg_hba.conf ($HBA, reported by the server) is missing or not writable."; exit 1; }
}

# The server's configuration files (main file, includes, auto.conf, ident file). pg_hba.conf is handled separately.
conf_file_list() {
    pg -c "SELECT DISTINCT f FROM (
             SELECT current_setting('config_file') AS f UNION ALL SELECT current_setting('ident_file')
             UNION ALL SELECT current_setting('data_directory') || '/postgresql.auto.conf'
             UNION ALL SELECT sourcefile FROM pg_file_settings WHERE sourcefile IS NOT NULL) t
           WHERE f IS NOT NULL AND f <> current_setting('hba_file') ORDER BY f"
}

# sha256 of every configuration file except pg_hba.conf. Status is checked; a failed query is a failure.
config_inventory() {
    local files f
    files=$(conf_file_list) || { err "Could not list the server's configuration files."; return 1; }
    [[ -n $files ]] || { err "The server reported no configuration files."; return 1; }
    while IFS= read -r f; do
        if [[ -e $f ]]; then printf '%s  %s\n' "$(sha256sum < "$f" | cut -d' ' -f1)" "$f"; else printf 'absent  %s\n' "$f"; fi
    done <<<"$files"
}

# Files modified after the server last loaded its configuration: a reload would activate changes nobody asked for.
# check_no_unloaded_changes 1  also covers pg_hba.conf (before we touch it); 0 leaves it out (after we replaced it).
check_no_unloaded_changes() {
    local with_hba=${1:-1} loaded files f mt changed=()
    loaded=$(pg -c "SELECT extract(epoch FROM pg_conf_load_time())") || { err "Cannot read the configuration load time."; return 1; }
    files=$(conf_file_list) || { err "Could not list the server's configuration files."; return 1; }
    [[ $with_hba == 1 ]] && files+=$'\n'"$HBA"
    while IFS= read -r f; do
        [[ -n $f && -e $f ]] || continue
        mt=$(find "$f" -maxdepth 0 -printf '%T@') || { err "Cannot read the modification time of $f."; return 1; }
        if awk -v m="$mt" -v l="$loaded" 'BEGIN { exit !(m > l) }'; then changed+=("$f"); fi
    done <<<"$files"
    if ((${#changed[@]})); then
        err "These configuration files were modified after the server last loaded its configuration:"
        printf '    %s\n' "${changed[@]}" >&2
        err "A reload would activate those changes too. Review them (and reload deliberately) before running this script."
        return 1
    fi
}

# Run immediately before EVERY reload (apply, rollback, cleanup). $1 = the sha256 pg_hba.conf must have right now.
reload_guard() {
    local want_hba=$1 inv n
    [[ $(hba_sha) == "$want_hba" ]] || { err "pg_hba.conf is not the file this script installed (changed by someone else?). Not reloading."; return 1; }
    check_no_unloaded_changes 0 || return 1
    inv=$(config_inventory) || return 1
    [[ $inv == "$SNAP_INV" ]] || { err "A configuration file's content changed since this run started. Not reloading."; diff <(echo "$SNAP_INV") <(echo "$inv") | sed 's/^/    /' >&2 || true; return 1; }
    n=$(pg -c "SELECT count(*) FROM pg_file_settings WHERE error IS NOT NULL") || { err "Cannot read pg_file_settings. Not reloading."; return 1; }
    [[ $n == 0 ]] || { err "$n configuration entr(ies) have errors (pg_file_settings). Not reloading."; return 1; }
    [[ $(hba_error_count) == 0 ]] || { err "pg_hba.conf already has parse errors. Not reloading."; return 1; }
}

hba_error_count() { pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL"; }

# Existing rules that could match a connection to the rehearsal database by either role from HOST_IP.
# Anything that cannot be ruled out (all, @file, a hostname, samehost/samenet) counts as a possible match.
hba_possible_matches() {
    pg -F '  ' -v db="$DB_NAME" -v own="$OWNER_ROLE" -v app="$APP_ROLE" -v host="$HOST_IP" <<'SQL'
SELECT line_number, type, database::text, user_name::text, coalesce(address, '-'), coalesce(netmask, ''), auth_method
FROM pg_hba_file_rules
WHERE error IS NULL
  AND type IN ('host', 'hostssl', 'hostnossl', 'hostgssenc', 'hostnogssenc')
  AND (database && ARRAY['all', :'db'] OR EXISTS (SELECT 1 FROM unnest(database) d WHERE d LIKE '@%'))
  AND (user_name && ARRAY['all', :'own', :'app'] OR EXISTS (SELECT 1 FROM unnest(user_name) u WHERE u LIKE '@%'))
  AND CASE
        WHEN address IS NULL OR address IN ('all', 'samehost', 'samenet') THEN true
        WHEN address ~ '^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$' AND netmask ~ '^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$'
             THEN (:'host'::inet & netmask::inet) = address::inet
        WHEN address LIKE '%:%' THEN false
        ELSE true
      END
ORDER BY line_number;
SQL
}

hba_snapshot() {
    pg -F '|' -c "SELECT line_number, type, database::text, user_name::text, coalesce(address,''), coalesce(netmask,''), coalesce(auth_method,''), coalesce(options::text,''), coalesce(error,'') FROM pg_hba_file_rules ORDER BY line_number"
}

hba_sha() { sha256sum "$HBA" | cut -d' ' -f1; }

hba_lines() {
    printf 'hostssl\t%s\t%s\t%s/32\tscram-sha-256\n' "$DB_NAME" "$OWNER_ROLE" "$HOST_IP"
    printf 'hostssl\t%s\t%s\t%s/32\tscram-sha-256\n' "$DB_NAME" "$APP_ROLE" "$HOST_IP"
}

# Number of lines in pg_hba.conf that are exactly one of our two rules (five tokens, nothing else).
hba_our_line_count() {
    awk -v db="$DB_NAME" -v o="$OWNER_ROLE" -v a="$APP_ROLE" -v ip="$HOST_IP/32" '
        NF == 5 && $1 == "hostssl" && $2 == db && ($3 == o || $3 == a) && $4 == ip && $5 == "scram-sha-256" { n++ }
        END { print n + 0 }' "$HBA"
}

# Prove, BEFORE installing, that candidate $1 is exactly the current file plus (add) or minus (remove) our two
# template lines, and that nothing else differs. The existing file had zero parse errors (checked), and our lines
# come from a fixed template with validated names and address, so the candidate is valid by construction.
# PostgreSQL has no offline pg_hba parser; if a reload nevertheless found an error it would keep the previous rules.
hba_validate_candidate() {
    local cand=$1 mode=$2 want
    case $mode in
        add)
            want=$(cat "$HBA"; [[ -z $(tail -c1 "$HBA") ]] || printf '\n'; hba_lines)
            [[ $(cat "$cand") == "$want" ]] || { err "Candidate pg_hba.conf is not the current file plus exactly the two intended lines."; return 1; }
            [[ $(tail -n 2 "$cand" | grep -cE "^hostssl[[:space:]]+$DB_NAME[[:space:]]+($OWNER_ROLE|$APP_ROLE)[[:space:]]+$HOST_IP/32[[:space:]]+scram-sha-256\$") == 2 ]] \
                || { err "The two appended lines do not match the template."; return 1; } ;;
        remove)
            [[ $(( $(grep -c '' "$HBA") - $(grep -c '' "$cand") )) == "$(hba_our_line_count)" ]] || { err "Candidate removes a different number of lines than ours."; return 1; }
            [[ $(grep -vxFf "$cand" "$HBA" | awk -v db="$DB_NAME" -v o="$OWNER_ROLE" -v a="$APP_ROLE" -v ip="$HOST_IP/32" \
                  'NF == 5 && $1 == "hostssl" && $2 == db && ($3 == o || $3 == a) && $4 == ip && $5 == "scram-sha-256" { n++ } END { print n + 0 }') == "$(hba_our_line_count)" ]] \
                || { err "Candidate removes something other than our exact lines."; return 1; } ;;
    esac
}

# Replace pg_hba.conf atomically with $1, only if it has not changed since $2 (its sha256).
hba_install() {
    local cand=$1 expect=$2
    [[ $(hba_sha) == "$expect" ]] || { rm -f "$cand"; err "pg_hba.conf changed while this script was running. Nothing was written."; return 1; }
    sync "$cand"
    mv -f "$cand" "$HBA"
}

hba_candidate_add() {   # copy with identical owner/mode, our two lines appended after a newline check
    local cand
    cand=$(mktemp "$HBA.new.XXXXXX")
    cp --preserve=mode,ownership "$HBA" "$cand"
    cat "$HBA" > "$cand"
    [[ -z $(tail -c1 "$cand") ]] || printf '\n' >> "$cand"
    hba_lines >> "$cand"
    echo "$cand"
}

hba_candidate_remove() {   # copy with only our exact lines removed
    local cand
    cand=$(mktemp "$HBA.new.XXXXXX")
    cp --preserve=mode,ownership "$HBA" "$cand"
    awk -v db="$DB_NAME" -v o="$OWNER_ROLE" -v a="$APP_ROLE" -v ip="$HOST_IP/32" '
        !(NF == 5 && $1 == "hostssl" && $2 == db && ($3 == o || $3 == a) && $4 == ip && $5 == "scram-sha-256")' "$HBA" > "$cand"
    echo "$cand"
}

# reload_conf EXPECTED_HBA_SHA: guard first, then reload. Every reload in this script goes through here.
reload_conf() {
    reload_guard "$1" || return 1
    [[ $(pg -c "SELECT pg_reload_conf()") == t ]] || { err "pg_reload_conf() did not report success."; return 1; }
    sleep 1
}

# ---- credential handoff: validated before anything is created ----
# Only a NEW file inside the reviewed directory $SECRET_DIR (root-owned, mode 0700). No descriptors, no other paths.
secret_sink_check() {
    [[ -n ${SECRET_OUT:-} ]] || { err "Set SECRET_OUT=$SECRET_DIR/<file name>. Passwords are never printed to the terminal."; return 1; }
    [[ -z ${SECRET_FD:-} ]] || { err "SECRET_FD is not accepted: a descriptor can point at a log collector or a readable file. Use SECRET_OUT."; return 1; }
    [[ $SECRET_OUT == /* && $SECRET_OUT != *..* ]] || { err "SECRET_OUT must be an absolute path without '..'."; return 1; }
    [[ $(dirname "$SECRET_OUT") == "$SECRET_DIR" ]] || { err "SECRET_OUT must be directly inside $SECRET_DIR (the reviewed secret directory)."; return 1; }
    [[ $(basename "$SECRET_OUT") =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { err "SECRET_OUT's file name may use only letters, digits, dot, underscore and hyphen."; return 1; }
    [[ -d $SECRET_DIR && ! -L $SECRET_DIR ]] || { err "$SECRET_DIR must be an existing directory (not a symlink)."; return 1; }
    [[ $(stat -c '%u %a' "$SECRET_DIR") == "0 700" ]] || { err "$SECRET_DIR must be owned by root with mode 0700 (it is $(stat -c '%U %a' "$SECRET_DIR"))."; return 1; }
    [[ ! -e $SECRET_OUT && ! -L $SECRET_OUT ]] || { err "$SECRET_OUT already exists. Refusing to overwrite or reuse it."; return 1; }
}

secret_sink_open() {
    ( umask 077; set -o noclobber; : > "$SECRET_OUT" ) || { err "Could not create $SECRET_OUT."; return 1; }
    [[ $(stat -c '%u %a' "$SECRET_OUT") == "0 600" ]] || { err "$SECRET_OUT does not have mode 0600 owned by root."; return 1; }
    exec 8>>"$SECRET_OUT"
    SECRET_FD=8
    trap secret_sink_tidy EXIT
}

# If the run stops before anything was written, do not leave an empty credentials file behind.
secret_sink_tidy() { if [[ -n ${SECRET_OUT:-} && -e $SECRET_OUT && ! -s $SECRET_OUT ]]; then rm -f "$SECRET_OUT"; fi; }

secret_sink_where() { echo "file $SECRET_OUT (0600)"; }

# ---- the exact SQL; printed in `plan` and run by `apply` ----
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
create_role_sql() {   # create_role_sql ROLE LIMIT VERIFIER-or-placeholder
    printf 'CREATE ROLE "%s" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT %s PASSWORD '"'"'%s'"'"';\n' "$1" "$2" "$3"
}
comment_sql() {   # comment_sql ROLE|DATABASE NAME RUN
    printf 'COMMENT ON %s "%s" IS '"'"'%s; run %s; application host %s'"'"';\n' "$1" "$2" "$TAG" "$3" "$HOST_IP"
}
cleanup_sql() {
    cat <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND usename IN ('$OWNER_ROLE', '$APP_ROLE') AND pid <> pg_backend_pid();
DROP DATABASE "$DB_NAME";
DROP ROLE "$APP_ROLE";
DROP ROLE "$OWNER_ROLE";
SQL
}

provenance_ok() {   # provenance_ok db|role NAME -> 0 if tagged by this script
    local d
    case $1 in
        db)   d=$(pg -c "SELECT coalesce(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = '$2'") ;;
        role) d=$(pg -c "SELECT coalesce(shobj_description(oid, 'pg_authid'), '') FROM pg_roles WHERE rolname = '$2'") ;;
    esac || { err "Could not read the provenance comment of $1 $2."; exit 1; }
    [[ $d == "$TAG"* ]]
}

# ---- pre-checks shared by plan and apply; sets DB_EXISTS, OWNER_EXISTS, APP_EXISTS ----
prechecks() {
    DB_EXISTS=$(probe_exists db "$DB_NAME")
    OWNER_EXISTS=$(probe_exists role "$OWNER_ROLE")
    APP_EXISTS=$(probe_exists role "$APP_ROLE")
    PRE_ERRORS=$(hba_error_count) || { err "Cannot read pg_hba_file_rules."; exit 1; }
    PRE_MATCHES=$(hba_possible_matches) || { err "Cannot evaluate existing access rules."; exit 1; }
    PRE_OURS=$(hba_our_line_count)
    PRE_SHA=$(hba_sha)
    SNAP_INV=$(config_inventory) || exit 1
}

# The operator's commitment that nothing else changes this server's PostgreSQL configuration during the run.
change_exclusion() {
    local c
    echo "Change exclusion: while this runs, nobody else may edit or reload this server's PostgreSQL configuration."
    echo "(This script checks for changes immediately before each reload, but it cannot stop one that happens a moment later.)"
    read -rp "Type NO-OTHER-CHANGES to confirm: " c || c=
    [[ $c == NO-OTHER-CHANGES ]] || { echo "Cancelled. Nothing changed."; exit 0; }
}

cmd_plan() {
    info "PLAN ONLY: nothing is changed by this command."
    echo
    echo "Server actually contacted (pinned):"
    echo "  PostgreSQL $S_VER on port $S_PORT, socket directory $PG_HOST, this machine has $DB_SERVER_IP"
    echo "  data directory:       $S_DATA"
    echo "  pg_hba.conf:          $HBA   (sha256 now: $PRE_SHA)"
    echo "  ssl=$S_SSL, listen_addresses=$S_LISTEN"
    echo
    echo "Target:"
    echo "  database:             $DB_NAME"
    echo "  owner/migration role: $OWNER_ROLE   (connection limit $OWNER_CONN_LIMIT)"
    echo "  runtime role:         $APP_ROLE   (connection limit $APP_CONN_LIMIT)"
    echo "  rehearsal host:       $HOST_IP/32   (protected production app server: $PROD_APP_IP; protected database: $PROD_DB)"
    echo
    echo "Current state (apply refuses unless all three do not exist):"
    echo "  database $DB_NAME: $([[ $DB_EXISTS == yes ]] && echo EXISTS || echo "does not exist")"
    echo "  role $OWNER_ROLE: $([[ $OWNER_EXISTS == yes ]] && echo EXISTS || echo "does not exist")"
    echo "  role $APP_ROLE: $([[ $APP_EXISTS == yes ]] && echo EXISTS || echo "does not exist")"
    echo "  pg_hba.conf lines already naming exactly these two rules: $PRE_OURS (apply needs 0)"
    echo "  pg_hba.conf parse errors now: $PRE_ERRORS (apply needs 0)"
    echo "  existing rules that could already match this database/roles from $HOST_IP (apply needs none):"
    if [[ -n $PRE_MATCHES ]]; then sed 's/^/    /' <<<"$PRE_MATCHES"; else echo "    none"; fi
    echo
    echo "Credential handoff: $(if [[ -n ${SECRET_OUT:-} ]]; then secret_sink_where; else echo "NOT SET (apply refuses until SECRET_OUT=$SECRET_DIR/<name> is set)"; fi)"
    echo "  Passwords are never printed. The server receives only SCRAM-SHA-256 verifiers."
    echo
    echo "Step 1, three separate statements in the postgres database (verifier computed locally at apply time):"
    create_role_sql "$OWNER_ROLE" "$OWNER_CONN_LIMIT" '<SCRAM-SHA-256 verifier>' | sed 's/^/    /'
    create_role_sql "$APP_ROLE" "$APP_CONN_LIMIT" '<SCRAM-SHA-256 verifier>' | sed 's/^/    /'
    echo "    CREATE DATABASE \"$DB_NAME\" OWNER \"$OWNER_ROLE\";"
    comment_sql ROLE "$OWNER_ROLE" '<run id>' | sed 's/^/    /'
    comment_sql ROLE "$APP_ROLE" '<run id>' | sed 's/^/    /'
    comment_sql DATABASE "$DB_NAME" '<run id>' | sed 's/^/    /'
    echo
    echo "Step 2, run inside $DB_NAME:"
    stage2_sql | sed 's/^/    /'
    echo
    echo "Step 3, pg_hba.conf: append exactly these two lines at the end (nothing else in the file changes;"
    echo "the file is replaced atomically with the same owner and mode, after a timestamped backup, only if"
    echo "its sha256 is still $PRE_SHA), then SELECT pg_reload_conf():"
    hba_lines | sed 's/^/    + /'
    echo
    echo "After the reload the script proves: the rules in the file before are unchanged and in the same order,"
    echo "the two new rules are parsed with no errors, and each is the FIRST rule that matches its role from $HOST_IP."
    echo
    echo "Not done by this script: PostgreSQL restart, any global/archiving/WAL setting, certificates, table grants"
    echo "(the application's runtime-grants.sql does those), the cloud firewall rule for $HOST_IP (separate, reviewed step)."
    echo "A parsed rule is not proof of a working connection: the verified-TLS login from the rehearsal host is a Gate B check."
    echo
    echo "Cleanup (cleanup mode, typed confirmation; only objects carrying this script's provenance comment):"
    cleanup_sql | sed 's/^/    /'
    echo "    ...and exactly the two lines above are removed from pg_hba.conf, then SELECT pg_reload_conf()."
}

# Undo only what THIS run created, in reverse order. Never touches anything else.
ROLLBACK_OK=1
rollback_partial() {
    warn "Undoing what this run created (and nothing else)..."
    local cand sha csha
    if ((HBA_ADDED)); then
        sha=$(hba_sha); cand=$(hba_candidate_remove)
        if hba_validate_candidate "$cand" remove && csha=$(sha256sum < "$cand" | cut -d' ' -f1) && hba_install "$cand" "$sha"; then
            HBA_ADDED=0
            if reload_conf "$csha"; then warn "  removed the two access lines"
            else warn "  the two lines were removed from the FILE but the reload was refused: reload deliberately after checking the configuration."; ROLLBACK_OK=0; fi
        else warn "  COULD NOT remove the access lines automatically. Check pg_hba.conf by hand."; ROLLBACK_OK=0; fi
    fi
    if ((CREATED_DB)); then
        if pg -c "DROP DATABASE IF EXISTS \"$DB_NAME\"" >/dev/null; then warn "  dropped database $DB_NAME"; else warn "  COULD NOT drop database $DB_NAME"; ROLLBACK_OK=0; fi
    fi
    if ((CREATED_APP)); then
        if pg -c "DROP ROLE IF EXISTS \"$APP_ROLE\"" >/dev/null; then warn "  dropped role $APP_ROLE"; else warn "  COULD NOT drop role $APP_ROLE"; ROLLBACK_OK=0; fi
    fi
    if ((CREATED_OWNER)); then
        if pg -c "DROP ROLE IF EXISTS \"$OWNER_ROLE\"" >/dev/null; then warn "  dropped role $OWNER_ROLE"; else warn "  COULD NOT drop role $OWNER_ROLE"; ROLLBACK_OK=0; fi
    fi
}
fail_apply() {
    err "$1"
    rollback_partial
    if ((ROLLBACK_OK)); then
        # Everything this run created is gone, so the passwords it saved belong to nothing.
        if [[ -e $SECRET_OUT ]]; then shred -u "$SECRET_OUT" 2>/dev/null || rm -f "$SECRET_OUT"; err "Removed the credentials file $SECRET_OUT (it described objects that no longer exist)."; fi
    else
        err "Some objects could NOT be undone. Credentials in $(secret_sink_where) are still valid for them: handle that file as a secret."
    fi
    exit 1
}

hba_verify_after() {   # hba_verify_after BEFORE_SNAPSHOT
    local before=$1 after nb na errs ours r first last2
    after=$(hba_snapshot) || return 1
    errs=$(hba_error_count)
    [[ $errs == 0 ]] || { err "pg_hba.conf has $errs parse error(s) after the change."; return 1; }
    nb=$(grep -c '' <<<"$before" || true); na=$(grep -c '' <<<"$after" || true)
    [[ -z $before ]] && nb=0
    ((na == nb + 2)) || { err "Expected exactly 2 new rules (had $nb, now $na)."; return 1; }
    if ((nb > 0)); then
        [[ $(head -n "$nb" <<<"$after") == "$before" ]] || { err "Existing rules changed or were reordered."; return 1; }
    fi
    ours=$(pg -v db="$DB_NAME" -v own="$OWNER_ROLE" -v app="$APP_ROLE" -v host="$HOST_IP" <<'SQL'
SELECT count(*) FROM pg_hba_file_rules
WHERE error IS NULL AND type = 'hostssl' AND database = ARRAY[:'db'] AND address = :'host'
  AND netmask = '255.255.255.255' AND auth_method = 'scram-sha-256' AND options IS NULL
  AND (user_name = ARRAY[:'own'] OR user_name = ARRAY[:'app']);
SQL
    )
    [[ $ours == 2 ]] || { err "The two new rules are not both parsed exactly as intended (found $ours)."; return 1; }
    # each role's FIRST possibly-matching rule must be ours (the last two lines of the file)
    last2=" $(tail -n 2 <<<"$after" | cut -d'|' -f1 | tr '\n' ' ')"
    for r in "$OWNER_ROLE" "$APP_ROLE"; do
        first=$(OWNER_ROLE=$r APP_ROLE=$r hba_possible_matches | head -n 1 | awk '{print $1}')
        [[ -n $first && $last2 == *"$first "* ]] || { err "Role $r: the first matching rule is not the one this script added (line '${first:-none}')."; return 1; }
    done
}

cmd_apply() {
    local c run pw_o pw_a v_o v_a before cand csha
    [[ $DB_EXISTS == no ]] || { err "Database $DB_NAME already exists. Refusing (it must be new and empty)."; exit 1; }
    [[ $OWNER_EXISTS == no ]] || { err "Role $OWNER_ROLE already exists. Refusing."; exit 1; }
    [[ $APP_EXISTS == no ]] || { err "Role $APP_ROLE already exists. Refusing."; exit 1; }
    [[ $PRE_ERRORS == 0 ]] || { err "pg_hba.conf already has parse errors. Fix them first."; exit 1; }
    [[ $PRE_OURS == 0 ]] || { err "pg_hba.conf already contains lines for these exact rules (left over?). Run cleanup first."; exit 1; }
    if [[ -n $PRE_MATCHES ]]; then
        err "Existing rules could already match this database/roles from $HOST_IP:"; sed 's/^/    /' <<<"$PRE_MATCHES" >&2
        err "Review them first: this script will not add rules that could be shadowed or that duplicate broader access."; exit 1
    fi
    secret_sink_check || exit 1
    check_no_unloaded_changes 1 || exit 1

    exec 7>"$LOCK_FILE"
    flock -n 7 || { err "Another run of this script holds $LOCK_FILE."; exit 1; }

    cmd_plan
    echo
    change_exclusion
    read -rp "Type CREATE $DB_NAME to make exactly these changes: " c || c=
    [[ $c == "CREATE $DB_NAME" ]] || { echo "Cancelled. Nothing changed."; exit 0; }

    secret_sink_open || exit 1
    run=$(date -u +%Y%m%dT%H%M%SZ)
    pw_o=$(random_password); pw_a=$(random_password)
    # The plain passwords are saved BEFORE any role exists, so a crash cannot lose them.
    {
        printf '# CRM rehearsal database credentials. SYNTHETIC ONLY. Run %s. Move via the agreed secure channel, then delete this file.\n' "$run"
        printf 'database=%s\nhost=%s\nport=%s\nowner_role=%s\nowner_password=%s\napp_role=%s\napp_password=%s\n' "$DB_NAME" "$DB_SERVER_IP" "$PG_PORT" "$OWNER_ROLE" "$pw_o" "$APP_ROLE" "$pw_a"
    } >&"$SECRET_FD" || { err "Could not write the credentials. Nothing was created."; exit 1; }
    v_o=$(printf '%s' "$pw_o" | scram_verifier) || { err "Could not compute the SCRAM verifier."; exit 1; }
    v_a=$(printf '%s' "$pw_a" | scram_verifier) || { err "Could not compute the SCRAM verifier."; exit 1; }
    pw_o=; pw_a=

    info "Creating roles and database..."
    create_role_sql "$OWNER_ROLE" "$OWNER_CONN_LIMIT" "$v_o" | run_sql postgres || fail_apply "Creating role $OWNER_ROLE failed."
    CREATED_OWNER=1
    create_role_sql "$APP_ROLE" "$APP_CONN_LIMIT" "$v_a" | run_sql postgres || fail_apply "Creating role $APP_ROLE failed."
    CREATED_APP=1
    v_o=; v_a=
    echo "CREATE DATABASE \"$DB_NAME\" OWNER \"$OWNER_ROLE\";" | run_sql postgres || fail_apply "Creating database $DB_NAME failed."
    CREATED_DB=1
    { comment_sql ROLE "$OWNER_ROLE" "$run"; comment_sql ROLE "$APP_ROLE" "$run"; comment_sql DATABASE "$DB_NAME" "$run"; } | run_sql postgres \
        || fail_apply "Recording provenance failed."

    info "Applying rights and role settings..."
    stage2_sql | run_sql "$DB_NAME" || fail_apply "Applying rights failed."

    info "Adding the two TLS-only access lines and reloading..."
    before=$(hba_snapshot) || fail_apply "Cannot read pg_hba_file_rules."
    [[ $(hba_sha) == "$PRE_SHA" ]] || fail_apply "pg_hba.conf changed after the plan was shown. Nothing was written to it."
    cp -p "$HBA" "$HBA.bak.$(date +%Y%m%d%H%M%S)"
    cand=$(hba_candidate_add)
    hba_validate_candidate "$cand" add || { rm -f "$cand"; fail_apply "The candidate pg_hba.conf failed validation. Nothing was written to it."; }
    csha=$(sha256sum < "$cand" | cut -d' ' -f1)
    hba_install "$cand" "$PRE_SHA" || fail_apply "Could not install the new pg_hba.conf."
    HBA_ADDED=1
    reload_conf "$csha" || fail_apply "Reload refused or failed."
    hba_verify_after "$before" || fail_apply "pg_hba.conf verification failed."
    ok "Access lines accepted by PostgreSQL: valid, TLS-only, one per role, each the first matching rule for $HOST_IP/32; earlier rules untouched."

    echo
    ok "============ Rehearsal database ready (empty) ============"
    pg -d "$DB_NAME" -F ' | ' -c "SELECT 'database: ' || datname || ', encoding ' || pg_encoding_to_char(encoding) || ', collation ' || datcollate || ', ctype ' || datctype FROM pg_database WHERE datname = current_database()"
    pg -F ' | ' -c "SELECT 'role: ' || rolname || ', login ' || rolcanlogin || ', superuser ' || rolsuper || ', createdb ' || rolcreatedb || ', createrole ' || rolcreaterole || ', replication ' || rolreplication || ', connection limit ' || rolconnlimit FROM pg_roles WHERE rolname IN ('$OWNER_ROLE','$APP_ROLE') ORDER BY 1"
    echo "Connect to $DB_SERVER_IP:$PG_PORT over TLS, sslmode=verify-full, CA /etc/ssl/pg/ca.crt on the rehearsal host."
    echo
    warn "Credentials were written to $(secret_sink_where). They were NOT printed."
    echo "  Send them only through the agreed secure channel, then delete the file:  shred -u <file>"
    echo "Next: sudo bash dbserver/verify-roles.sh  (catalog checks only by default). Do NOT start the application yet."
}

cmd_cleanup() {
    local c n=0 conns ours cand sha before after csha
    info "CLEANUP of the rehearsal resources this script created. Nothing else."
    local have_db=$DB_EXISTS have_o=$OWNER_EXISTS have_a=$APP_EXISTS
    if [[ $have_db == yes ]]; then
        provenance_ok db "$DB_NAME" || { err "Database $DB_NAME does not carry this script's provenance comment. Refusing."; exit 1; }
        [[ $(pg -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$DB_NAME'") == "$OWNER_ROLE" ]] \
            || { err "Database $DB_NAME is not owned by $OWNER_ROLE. Refusing."; exit 1; }
        n=$(pg -d "$DB_NAME" -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')")
    fi
    if [[ $have_o == yes ]]; then provenance_ok role "$OWNER_ROLE" || { err "Role $OWNER_ROLE does not carry this script's provenance comment. Refusing."; exit 1; }; fi
    if [[ $have_a == yes ]]; then provenance_ok role "$APP_ROLE" || { err "Role $APP_ROLE does not carry this script's provenance comment. Refusing."; exit 1; }; fi
    conns=$(pg -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid()")
    ours=$PRE_OURS
    echo "  database $DB_NAME exists: $have_db   (tables in it: $n; connections now: $conns)"
    echo "  role $OWNER_ROLE exists:  $have_o"
    echo "  role $APP_ROLE exists:  $have_a"
    echo "  access lines present (exact matches): $ours"
    echo
    echo "This will run (terminating only connections made by those two roles; no FORCE, no CASCADE):"
    cleanup_sql | sed 's/^/    /'
    echo "and remove exactly those access lines from pg_hba.conf (atomic replace; other lines untouched), then reload."
    check_no_unloaded_changes 1 || exit 1
    exec 7>"$LOCK_FILE"
    flock -n 7 || { err "Another run of this script holds $LOCK_FILE."; exit 1; }
    change_exclusion
    read -rp "Type DELETE $DB_NAME to confirm (this removes the database and its data): " c || c=
    [[ $c == "DELETE $DB_NAME" ]] || { echo "Cancelled. Nothing changed."; exit 0; }

    if [[ $have_db == yes ]]; then
        pg -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND usename IN ('$OWNER_ROLE', '$APP_ROLE') AND pid <> pg_backend_pid()" >/dev/null
        sleep 1
        pg -c "DROP DATABASE \"$DB_NAME\"" >/dev/null || { err "DROP DATABASE failed (other connections?). Nothing else was removed."; exit 1; }
    fi
    if [[ $have_a == yes ]]; then pg -c "DROP ROLE \"$APP_ROLE\"" >/dev/null || { err "DROP ROLE $APP_ROLE failed (it may own objects elsewhere)."; exit 1; }; fi
    if [[ $have_o == yes ]]; then pg -c "DROP ROLE \"$OWNER_ROLE\"" >/dev/null || { err "DROP ROLE $OWNER_ROLE failed (it may own objects elsewhere)."; exit 1; }; fi

    if ((ours > 0)); then
        before=$(hba_snapshot)
        sha=$(hba_sha); cp -p "$HBA" "$HBA.bak.$(date +%Y%m%d%H%M%S)"
        cand=$(hba_candidate_remove)
        hba_validate_candidate "$cand" remove || { rm -f "$cand"; exit 1; }
        csha=$(sha256sum < "$cand" | cut -d' ' -f1)
        hba_install "$cand" "$sha" || exit 1
        reload_conf "$csha" || { err "The lines were removed from the FILE but the reload was refused. Reload deliberately after checking the configuration."; exit 1; }
        after=$(hba_snapshot)
        [[ $(( $(grep -c '' <<<"$before") - $(grep -c '' <<<"$after") )) == "$ours" ]] || { err "Unexpected number of rules removed. Compare pg_hba.conf with the backup next to it."; exit 1; }
    fi
    if [[ $(probe_exists db "$DB_NAME") == yes || $(probe_exists role "$OWNER_ROLE") == yes || $(probe_exists role "$APP_ROLE") == yes || $(hba_our_line_count) != 0 ]]; then
        err "Something remains. Check the database, roles and pg_hba.conf by hand."; exit 1
    fi
    [[ $(hba_error_count) == 0 ]] || { err "pg_hba.conf now has parse errors. Compare it with the backup next to it."; exit 1; }
    ok "Rehearsal database, roles and exactly these access lines removed. pg_hba.conf has no errors."
    echo "Remember to delete any credentials file written by apply (shred -u)."
}

main() {
    [[ $EUID -eq 0 || -n ${PG_RUN_NO_ROOT:-} ]] || { err "Run as root: sudo $0 [plan|apply|cleanup]"; exit 1; }
    local mode=${1:-plan}
    case $mode in plan|apply|cleanup) ;; *) echo "Usage: $0 [plan|apply|cleanup]"; exit 1 ;; esac
    gather
    connect_checks
    prechecks
    case $mode in
        plan)    if [[ -n ${SECRET_OUT:-} ]]; then secret_sink_check || exit 1; fi
                 check_no_unloaded_changes 1 || exit 1
                 cmd_plan ;;
        apply)   cmd_apply ;;
        cleanup) cmd_cleanup ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
