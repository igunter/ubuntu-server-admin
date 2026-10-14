#!/usr/bin/env bash
# Guarded entrypoint for the SYNTHETIC scratch point-in-time-recovery test. It REPLACES the use of
# dbserver/install-backup.sh, restore-test-prepare.sh and restore-test.sh on the scratch hosts: those three are
# unmodified, have no scratch guard, and are NOT to be run on the rehearsal hosts. This file contains its own
# checks and re-runs ALL of them immediately before every step that installs, writes configuration, changes WAL
# settings, restarts, backs up or restores. Nothing is taken from the environment or typed at a prompt except
# the restore target time.
#
#   sudo bash rehearsal/scratch/scratch-pitr.sh check            # the guard only; changes nothing
#   sudo bash rehearsal/scratch/scratch-pitr.sh source-install   # crm-rehearsal-pitr-src: pgBackRest + WAL archiving + first full backup
#   sudo bash rehearsal/scratch/scratch-pitr.sh source-prepare   # crm-rehearsal-pitr-src: synthetic marker rows, targets saved to /var/tmp/restore-test.txt
#   sudo bash rehearsal/scratch/scratch-pitr.sh restore          # crm-rehearsal-pitr-restore: restore with the READ-ONLY key
#
# Identity (what makes a machine "the scratch host", beyond its name): /etc/rehearsal-scratch/identity, created BY THE
# OPERATOR when the scratch host is created (root:root, mode 0600), with exactly these keys:
#     ROLE=source|restore  HOSTNAME=<exact name>  MACHINE_ID=<contents of /etc/machine-id>
#     BUCKET=dbs-check-crm-rehearsal-backups  REGION=eu-west-2  PG_MAJOR=16  DATA_DIR=/var/lib/postgresql/16/main  STANZA=main
# The guard requires that file to agree with the constants in THIS reviewed file, with the machine's real hostname
# and /etc/machine-id, and with the live servers' protected names and addresses. A hostname or an environment
# variable alone is not identity: BUCKET, REGION and ping URLs are never read from the environment. No call is
# made to the cloud metadata service or to any AWS API to "prove" identity (those are not permitted); the checks
# are local, and the AWS-side identity of the scratch resources is evidenced separately (scratch-storage.md).
#
# Credentials: /root/rehearsal-secrets/<file> (root:root 0700 directory, 0600 file, strict KEY=VALUE lines, never
# sourced, never printed): S3_KEY, S3_SECRET, PASSPHRASE (24+ letters/digits/+/=_.-). source-install needs
# scratch-pitr-rw.env, restore needs scratch-pitr-ro.env. There is NO option to generate or print a passphrase,
# and shell tracing is refused before any secret is read. The pgBackRest configuration necessarily contains the
# keys (postgres-only, mode 0600) and is deleted with the scratch host.
#
# What it does NOT do: install cron jobs, the monitor or the archive watch (so no alert URL exists anywhere), contact
# any alert service, use any bucket other than the scratch bucket, or touch the live servers.
set -euo pipefail
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../../dbserver/rehearsal-common.sh"
refuse_tracing

# ---- constants of this reviewed file (not overridable from the environment) ----
SCRATCH_BUCKET=dbs-check-crm-rehearsal-backups
LIVE_BUCKET=dbs-check-crm-backups
SCRATCH_REGION=eu-west-2
SRC_HOST=crm-rehearsal-pitr-src
RESTORE_HOST=crm-rehearsal-pitr-restore
PROTECTED_HOSTS="ip-172-26-9-114 ip-172-26-0-238"
PROTECTED_IPS="172.26.9.114 172.26.0.238 18.169.221.228"
IDENTITY=/etc/rehearsal-scratch/identity
SECRET_DIR=/root/rehearsal-secrets
CONF=/etc/pgbackrest/pgbackrest.conf
ALERT_ENV=/etc/pgbackrest/alert.env
CRON_FILE=/etc/cron.d/pgbackrest
OUT=/var/tmp/restore-test.txt
PREPARE_WAIT=90
# BUCKET, REGION and the ping URLs are never read from the environment; a ping URL in the environment is a guard failure.
SPOOL_DIR=/var/spool/pgbackrest
LOG_DIR=/var/log/pgbackrest
ROOT_PREFIX=""   # empty on a real host; only the tests set it

# ---- system access, one function each so tests can replace them (they cannot be replaced from the environment) ----
g_hostname()   { hostname; }
g_machine_id() { cat /etc/machine-id; }
g_ipv4()       { ip -4 -o addr show; }
# Prints "<exit status> <output>" so the caller can tell "inactive" from "could not ask" (bus, permission, transport errors).
g_active_state() { local o r=0; o=$(systemctl is-active "postgresql@${ID_PG_MAJOR:-16}-main" 2>&1) || r=$?; echo "$r $(head -n 1 <<<"$o")"; }
g_pg()         { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -X -Atq "$@"; }
g_apt()        { DEBIAN_FRONTEND=noninteractive apt-get "$@"; }
g_pgbackrest() { runuser -u postgres -- pgbackrest "$@"; }
g_systemctl()  { systemctl "$@"; }
g_ping_env()   { env | grep -E '^(PING_URL|ARCHIVE_PING_URL)=' || true; }   # any value, even empty, counts

# ---- identity ----
ID_ROLE=; ID_HOSTNAME=; ID_MACHINE_ID=; ID_BUCKET=; ID_REGION=; ID_PG_MAJOR=; ID_DATA_DIR=; ID_STANZA=
load_identity() {
    local f=$IDENTITY k v seen=0 line
    [[ -f $f && ! -L $f ]] || { G_WHY+=("identity file $f is missing (or a symlink)"); return 1; }
    [[ $(stat -c '%u %a' "$f") == "0 600" ]] || { G_WHY+=("$f must be owned by root with mode 0600"); return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        [[ $line =~ ^([A-Z_]+)=([A-Za-z0-9_./:-]+)$ ]] || { G_WHY+=("identity file has an invalid line"); return 1; }
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        case $k in
            ROLE) ID_ROLE=$v ;; HOSTNAME) ID_HOSTNAME=$v ;; MACHINE_ID) ID_MACHINE_ID=$v ;; BUCKET) ID_BUCKET=$v ;;
            REGION) ID_REGION=$v ;; PG_MAJOR) ID_PG_MAJOR=$v ;; DATA_DIR) ID_DATA_DIR=$v ;; STANZA) ID_STANZA=$v ;;
            *) G_WHY+=("identity file has an unknown key $k"); return 1 ;;
        esac; seen=$((seen+1))
    done < "$f"
    ((seen == 8)) || { G_WHY+=("identity file must contain exactly the 8 keys (found $seen)"); return 1; }
}

# guard WANTED_ROLE STEP: every check, every time. Failure messages are printed; returns 1 if any failed.
G_WHY=()
guard() {
    local want=$1 step=$2 h mid ips ip a n listen rules dbs conf_buckets
    G_WHY=()
    if load_identity; then
        [[ $ID_ROLE == "$want" ]] || G_WHY+=("identity ROLE is '$ID_ROLE', this step needs '$want'")
        local want_host; [[ $want == source ]] && want_host=$SRC_HOST || want_host=$RESTORE_HOST
        [[ $ID_HOSTNAME == "$want_host" ]] || G_WHY+=("identity HOSTNAME '$ID_HOSTNAME' is not $want_host")
        h=$(g_hostname) || h=; [[ $h == "$want_host" ]] || G_WHY+=("the machine's hostname is '$h', expected $want_host")
        mid=$(g_machine_id) || mid=; [[ -n $mid && $mid == "$ID_MACHINE_ID" ]] || G_WHY+=("MACHINE_ID in the identity file does not match this machine (copied from another host?)")
        [[ $ID_BUCKET == "$SCRATCH_BUCKET" && $SCRATCH_BUCKET != "$LIVE_BUCKET" ]] || G_WHY+=("identity BUCKET is not the scratch bucket $SCRATCH_BUCKET")
        [[ $ID_REGION == "$SCRATCH_REGION" ]] || G_WHY+=("identity REGION is not $SCRATCH_REGION")
        [[ $ID_PG_MAJOR =~ ^[0-9]{2}$ && $ID_DATA_DIR == "/var/lib/postgresql/$ID_PG_MAJOR/main" ]] || G_WHY+=("identity PG_MAJOR/DATA_DIR are not the standard cluster path")
        [[ $ID_STANZA =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || G_WHY+=("identity STANZA is invalid")
        for a in $PROTECTED_HOSTS; do [[ $h != "$a" && $ID_HOSTNAME != "$a" ]] || G_WHY+=("this is a protected live host ($a)"); done
    fi
    ips=$(g_ipv4) || { ips=; G_WHY+=("cannot read this machine's addresses"); }
    for ip in $PROTECTED_IPS; do grep -qF " $ip/" <<<"$ips" && G_WHY+=("this machine has the protected live address $ip") || true; done
    [[ -z $(g_ping_env) ]] || G_WHY+=("PING_URL/ARCHIVE_PING_URL is set in the environment: no alert service may be called from a scratch host")
    if [[ -e $ALERT_ENV ]] && grep -qE "^(PING_URL|ARCHIVE_PING_URL)=" "$ALERT_ENV" 2>/dev/null; then G_WHY+=("$ALERT_ENV defines a ping URL"); fi
    [[ ! -e $CRON_FILE ]] || G_WHY+=("$CRON_FILE exists (the live installer has been run here?): remove the host and recreate it")
    if [[ -e $CONF ]]; then
        [[ -r $CONF ]] || G_WHY+=("$CONF exists but cannot be read")
        grep -qF "$LIVE_BUCKET" "$CONF" 2>/dev/null && G_WHY+=("$CONF mentions the live bucket") || true
        conf_buckets=$(sed -n 's/^repo[0-9]*-s3-bucket=//p' "$CONF" 2>/dev/null | sort -u)
        [[ -z $conf_buckets || $conf_buckets == "$SCRATCH_BUCKET" ]] || G_WHY+=("$CONF names a bucket other than the scratch bucket")
        [[ $(stat -c '%a' "$CONF" 2>/dev/null || echo x) == 600 ]] || G_WHY+=("$CONF is not mode 0600")
    fi
    local running=0 st=
    if [[ -n $ID_PG_MAJOR ]]; then
        st=$(g_active_state) || st="error"
        case $st in
            "0 active") running=1 ;;
            "3 inactive"|"3 failed"|"3 unknown"|"4 unknown"|"4 inactive") running=0 ;;   # the documented "not running / no such unit" answers
            *) G_WHY+=("cannot tell whether PostgreSQL is running (systemctl is-active returned: '$st'); an inspection failure is not 'not running'") ;;
        esac
    fi
    if ((running)); then
        n=$(g_pg -c 'SHOW archive_mode') || { n=; G_WHY+=("cannot read archive_mode from the running server"); }
        if [[ -n $n ]]; then
            if [[ $want == restore ]]; then [[ $n == off ]] || G_WHY+=("archive_mode is '$n' on the restore host (must be off)")
            else [[ $n == on || $n == off ]] || G_WHY+=("archive_mode is '$n' on the source (on or off only; 'always' refused)"); fi
        fi
        a=$(g_pg -c 'SHOW data_directory') || { a=; G_WHY+=("cannot read data_directory"); }
        [[ -z $a || $a == "$ID_DATA_DIR" ]] || G_WHY+=("the running cluster's data directory is $a, not $ID_DATA_DIR")
        dbs=$(g_pg -c "SELECT datname FROM pg_database WHERE NOT datistemplate") || { dbs=; G_WHY+=("cannot list databases"); }
        grep -qiE '^dbscheckcrm' <<<"$dbs" && G_WHY+=("the cluster holds a database named like the live one (dbscheckcrm*)") || true
        if [[ $want == source ]]; then
            listen=$(g_pg -c 'SHOW listen_addresses') || { listen=; G_WHY+=("cannot read listen_addresses"); }
            [[ -z $listen || $listen =~ ^(localhost|127\.0\.0\.1|::1)(,[[:space:]]*(localhost|127\.0\.0\.1|::1))*$ ]] || G_WHY+=("listen_addresses is '$listen': the source must listen on localhost only")
            rules=$(g_pg -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NULL AND type LIKE 'host%' AND (address IS NULL OR address NOT IN ('127.0.0.1','::1'))") || { rules=; G_WHY+=("cannot read pg_hba_file_rules"); }
            [[ -z $rules || $rules == 0 ]] || G_WHY+=("$rules pg_hba rule(s) allow a remote address; the source must accept local connections only")
        fi
    fi
    if ((${#G_WHY[@]})); then
        err "GUARD FAILED before '$step':"; printf '    - %s\n' "${G_WHY[@]}" >&2
        return 1
    fi
    ok "guard passed before '$step'"
}
must() { guard "$@" || exit 1; }

# ---- credentials ----
S3_KEY=; S3_SECRET=; PASSPHRASE=
load_secrets() { # load_secrets FILENAME
    local f=$SECRET_DIR/$1 line k v seen=0
    [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || { err "bad secrets file name"; return 1; }
    [[ -d $SECRET_DIR && ! -L $SECRET_DIR && $(stat -c '%u %a' "$SECRET_DIR") == "0 700" ]] || { err "$SECRET_DIR must be a real directory owned by root with mode 0700."; return 1; }
    [[ -f $f && ! -L $f && $(stat -c '%u %a' "$f") == "0 600" ]] || { err "$f must be a regular file owned by root with mode 0600."; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        [[ $line =~ ^(S3_KEY|S3_SECRET|PASSPHRASE)=([A-Za-z0-9+/=_.-]+)$ ]] || { err "$f: only S3_KEY, S3_SECRET and PASSPHRASE lines of letters, digits and + / = _ . - are accepted (a ping URL or anything else is refused)."; return 1; }
        k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
        printf -v "$k" '%s' "$v"; seen=$((seen+1))
    done < "$f"
    ((seen == 3)) || { err "$f must contain exactly S3_KEY, S3_SECRET and PASSPHRASE."; return 1; }
    [[ ${#PASSPHRASE} -ge 24 ]] || { err "PASSPHRASE must be at least 24 characters."; return 1; }
    [[ $S3_KEY =~ ^[A-Z0-9]{16,32}$ ]] || { err "S3_KEY does not look like an access key id."; return 1; }
}

write_conf() { # write_conf  (writes ONLY the scratch bucket from the identity/constants)
    install -d -o postgres -g postgres -m 750 "$(dirname "$CONF")" "$SPOOL_DIR" "$LOG_DIR"
    local tmp; tmp=$(umask 077; mktemp "$CONF.XXXXXX")
    cat > "$tmp" <<CFG
[global]
repo1-type=s3
repo1-s3-bucket=$SCRATCH_BUCKET
repo1-s3-endpoint=s3.$SCRATCH_REGION.amazonaws.com
repo1-s3-region=$SCRATCH_REGION
repo1-s3-key=$S3_KEY
repo1-s3-key-secret=$S3_SECRET
repo1-path=/pgbackrest
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$PASSPHRASE
repo1-retention-full-type=count
repo1-retention-full=2
compress-type=zst
start-fast=y
archive-async=y
spool-path=$SPOOL_DIR
log-path=$LOG_DIR
log-level-console=info
log-level-file=detail

[$ID_STANZA]
pg1-path=$ID_DATA_DIR
CFG
    chown postgres:postgres "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$CONF"
}

confirm() { local c; read -rp "$1" c || c=; [[ $c == "$2" ]] || { echo "Cancelled. Nothing changed."; exit 0; }; }

cmd_check() { local r; for r in source restore; do if [[ -r $IDENTITY ]] && load_identity 2>/dev/null && [[ $ID_ROLE == "$r" ]]; then must "$r" check; return; fi; done; must source check; }

cmd_source_install() {
    must source "start of source-install"
    load_secrets scratch-pitr-rw.env || exit 1
    echo "This will, on $(g_hostname) ONLY: install pgBackRest and PostgreSQL $ID_PG_MAJOR if missing, write $CONF for bucket $SCRATCH_BUCKET,"
    echo "set WAL archiving (a restart of THIS scratch cluster is needed), create the stanza, check it and take one full backup."
    echo "No cron job, monitor, archive watch or alert URL is installed."
    confirm "Type SCRATCH-SOURCE to continue: " SCRATCH-SOURCE
    must source "package install"
    g_apt update -qq; g_apt install -y -qq "postgresql-$ID_PG_MAJOR" pgbackrest
    must source "writing $CONF"
    write_conf
    must source "WAL settings"
    local q
    for q in "archive_command = 'pgbackrest --stanza=$ID_STANZA archive-push %p'" "archive_timeout = '60s'" "wal_level = 'replica'" "archive_mode = 'on'"; do
        g_pg -c "ALTER SYSTEM SET $q"
    done
    must source "restart of the scratch cluster"
    g_systemctl restart "postgresql@$ID_PG_MAJOR-main"; sleep 3
    must source "stanza-create"
    g_pgbackrest --stanza="$ID_STANZA" stanza-create
    must source "archive check"
    g_pgbackrest --stanza="$ID_STANZA" check
    must source "first full backup"
    g_pgbackrest --stanza="$ID_STANZA" --type=full backup
    must source "final check"
    ok "Scratch source ready: archiving to $SCRATCH_BUCKET works and a full backup exists. The passphrase was never printed; it is only in $SECRET_DIR and $CONF."
}

cmd_source_prepare() {
    must source "start of source-prepare"
    command -v pgbackrest >/dev/null || { err "pgBackRest is not installed: run source-install first."; exit 1; }
    local ts inserted target deleted
    ts() { g_pg -c "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS.USOF')"; }
    must source "creating the marker database"
    [[ $(g_pg -c "SELECT 1 FROM pg_database WHERE datname='restore_test'") == 1 ]] || runuser -u postgres -- createdb restore_test
    g_pg -d restore_test -c "CREATE TABLE IF NOT EXISTS marker (id serial PRIMARY KEY, note text, created_at timestamptz DEFAULT now())"
    g_pg -d restore_test -c "TRUNCATE marker"
    info "Inserting 5 synthetic marker rows..."
    g_pg -d restore_test -c "INSERT INTO marker(note) SELECT 'restore-test row ' || g FROM generate_series(1,5) g"
    inserted=$(ts); echo "  Rows inserted at $inserted"
    info "Waiting ${PREPARE_WAIT}s so the restore target is clearly after the insert..."
    sleep "$PREPARE_WAIT"; target=$(ts); echo "  Restore target (rows present): $target"; sleep 5
    must source "deleting the marker rows"
    g_pg -d restore_test -c "DELETE FROM marker"; deleted=$(ts); echo "  Rows deleted at $deleted"
    g_pg -d restore_test -c "CREATE TABLE IF NOT EXISTS heartbeat (t timestamptz); INSERT INTO heartbeat VALUES (now())"
    must source "forcing WAL to the bucket"
    g_pg -c "SELECT pg_switch_wal()" >/dev/null; sleep 5
    g_pgbackrest --stanza="$ID_STANZA" check
    ( umask 022; printf 'rows_inserted_at=%s\nrestore_target_rows_present=%s\nrows_deleted_at=%s\n' "$inserted" "$target" "$deleted" > "$OUT" )
    ok "Ready for the restore test. Times saved to $OUT:"; cat "$OUT"
}

cmd_restore() {
    must restore "start of restore"
    load_secrets scratch-pitr-ro.env || exit 1
    local target=${TARGET:-}
    [[ -n $target ]] || read -rp "Restore to time (with offset, e.g. 2026-10-16 15:05:30.123456+01): " target || target=
    [[ $target =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?[+-][0-9]{2}(:?[0-9]{2})?$ ]] || { err "The restore time must look like '2026-10-16 15:05:30.123456+01'."; exit 1; }
    echo "This REPLACES the PostgreSQL data on $(g_hostname) (the scratch restore host) with a copy restored from $SCRATCH_BUCKET at $target, using a READ-ONLY key."
    confirm "Type RESTORE-TEST to continue: " RESTORE-TEST
    must restore "package install"
    g_apt update -qq; g_apt install -y -qq "postgresql-$ID_PG_MAJOR" pgbackrest
    must restore "stopping the local cluster"
    g_systemctl stop "postgresql@$ID_PG_MAJOR-main" || true
    must restore "writing $CONF"
    write_conf
    must restore "listing backups"
    g_pgbackrest --stanza="$ID_STANZA" info
    must restore "restore"
    g_pgbackrest --stanza="$ID_STANZA" --delta --type=time "--target=$target" --target-action=promote --archive-mode=off restore
    # the restored settings must not archive anywhere: the LAST archive_mode in the restored auto.conf must be off
    local auto=$ROOT_PREFIX$ID_DATA_DIR/postgresql.auto.conf am
    am=$(sed -n 's/^[[:space:]]*archive_mode[[:space:]]*=[[:space:]]*//p' "$auto" | tail -n 1 | tr -d "' \t") || am=
    [[ $am == off ]] || { err "After the restore, archive_mode in $auto is '${am:-unset}', not off. NOT starting the restored cluster."; exit 1; }
    sed -i '/^listen_addresses/d' "$auto"; echo "listen_addresses = 'localhost'" >> "$auto"
    must restore "starting the restored cluster"
    g_systemctl start "postgresql@$ID_PG_MAJOR-main"
    local i; for i in $(seq 1 120); do [[ $(g_pg -c 'SELECT pg_is_in_recovery()' 2>/dev/null || echo t) == f ]] && break; sleep 2; done
    [[ $(g_pg -c 'SELECT pg_is_in_recovery()') == f ]] || { err "Recovery did not finish."; exit 1; }
    must restore "final check"
    ok "Restore complete (archive_mode off, localhost only)."
    g_pg -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1" | sed 's/^/  /'
    [[ $(g_pg -c "SELECT 1 FROM pg_database WHERE datname='restore_test'") == 1 ]] && g_pg -d restore_test -c "SELECT 'restore_test.marker rows: ' || count(*) FROM marker"
}

main() {
    [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
    case ${1:-} in
        check) cmd_check ;; source-install) cmd_source_install ;; source-prepare) cmd_source_prepare ;; restore) cmd_restore ;;
        *) echo "Usage: $0 check|source-install|source-prepare|restore"; exit 1 ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
