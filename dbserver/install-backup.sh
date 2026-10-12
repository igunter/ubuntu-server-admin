#!/usr/bin/env bash
# Point-in-time-recovery backups for PostgreSQL, using pgBackRest and an
# encrypted S3 bucket.
#
#   sudo bash dbserver/install-backup.sh
#
# What it sets up
#   - WAL archiving to S3 (archive_timeout = 60s, so changes are shipped at
#     least once a minute while the database is busy)
#   - pgBackRest repository encryption (aes-256-cbc), on top of S3 encryption
#   - weekly full + daily differential backups (cron), keeping 3 full backups
#     so any point in the previous 14 days can be restored
#   - an hourly monitor that alerts when the 14-day window or archiving breaks
#   - a weekly `pgbackrest verify` that checks the WAL history has no gaps
#
# Needs: PostgreSQL already installed (dbserver/install-db.sh), an S3 bucket in
# eu-west-2 and an IAM access key for it. Credentials are typed in here, never
# stored in the repo.
#
# Safe to re-run: an existing config is only replaced if you say so.
set -eu
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"

CONF=/etc/pgbackrest/pgbackrest.conf
MONITOR=/usr/local/sbin/pgbackrest-monitor
CRON=/etc/cron.d/pgbackrest
ALERT_ENV=/etc/pgbackrest/alert.env
STANZA=${STANZA:-main}
KEEP_FULL=${KEEP_FULL:-4}        # weekly fulls kept (4 => 21-28 days of history, margin over 14)
WINDOW_DAYS=${WINDOW_DAYS:-14}   # the monitor alerts if history is shorter

[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

pg() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -Atq "$@"; }

ask() {   # ask "Prompt" VAR [default]
    local v
    read -rp "$1${3:+ [$3]}: " v
    printf -v "$2" '%s' "${v:-${3:-}}"
}

ask_secret() {   # ask_secret "Prompt" VAR
    local v
    read -rsp "$1: " v; echo
    printf -v "$2" '%s' "$v"
}

yes_no() {   # yes_no "Question?" y|n
    local a def=${2:-n} hint='[y/N]'
    if [[ $def == y ]]; then hint='[Y/n]'; fi
    read -rp "$1 $hint: " a
    a=${a:-$def}
    [[ ${a,,} == y* ]]
}

random_string() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

preflight() {
    command -v psql >/dev/null || { err "PostgreSQL is not installed. Run dbserver/install-db.sh first."; exit 1; }
    systemctl is-active --quiet postgresql || { err "PostgreSQL is not running."; exit 1; }
}

install_packages() {
    info "Installing pgBackRest..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pgbackrest jq curl cron
}

gather_settings() {
    echo
    info "S3 bucket (must be in the UK: Europe (London) eu-west-2)"
    ask "Bucket name" BUCKET "${BUCKET:-}"
    [[ -n $BUCKET ]] || { err "A bucket name is required."; exit 1; }
    ask "Region" REGION "${REGION:-eu-west-2}"
    if [[ $REGION != eu-west-2 ]]; then
        warn "$REGION is not the London region. Backups must be retained in the UK."
        yes_no "Continue anyway?" n || exit 1
    fi
    ask "Access key ID" S3_KEY "${S3_KEY:-}"
    ask_secret "Secret access key (hidden)" S3_SECRET
    [[ -n $S3_KEY && -n $S3_SECRET ]] || { err "Access key and secret are required."; exit 1; }

    echo
    info "Encryption passphrase"
    echo "  Without this passphrase the backups CANNOT be restored, even if the bucket is fine."
    echo "  Store it in your password manager (and with a second named person) before you go on."
    if yes_no "Generate a random passphrase?" y; then
        PASSPHRASE=$(random_string 48)
        GENERATED=1
    else
        ask_secret "Passphrase (hidden, 24+ characters)" PASSPHRASE
        [[ ${#PASSPHRASE} -ge 24 ]] || { err "Use at least 24 characters."; exit 1; }
        GENERATED=0
    fi

    echo
    info "Alerts (optional)"
    echo "  Paste a Healthchecks.io-style ping URL (or similar). The monitor pings it when all"
    echo "  is well and signals failure when not, and the service alerts you if pings stop"
    echo "  altogether - which catches a dead server. Leave blank to skip (logs only)."
    ask "Ping URL" PING_URL "${PING_URL:-}"
}

write_config() {
    local data_dir
    data_dir=$(pg -c 'SHOW data_directory')
    if [[ -f $CONF ]] && ! yes_no "$CONF already exists. Replace it?" n; then
        warn "Keeping existing config."
        return
    fi
    install -d -o postgres -g postgres -m 750 /etc/pgbackrest /var/spool/pgbackrest /var/log/pgbackrest
    umask 077
    cat > "$CONF" <<EOF
[global]
repo1-type=s3
repo1-s3-bucket=$BUCKET
repo1-s3-endpoint=s3.$REGION.amazonaws.com
repo1-s3-region=$REGION
repo1-s3-key=$S3_KEY
repo1-s3-key-secret=$S3_SECRET
repo1-path=/pgbackrest
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$PASSPHRASE
repo1-retention-full-type=count
repo1-retention-full=$KEEP_FULL
repo1-retention-diff=14
compress-type=zst
start-fast=y
archive-async=y
spool-path=/var/spool/pgbackrest
log-path=/var/log/pgbackrest
log-level-console=info
log-level-file=detail

[$STANZA]
pg1-path=$data_dir
EOF
    chown postgres:postgres "$CONF"
    chmod 600 "$CONF"
    ok "Wrote $CONF (readable by the postgres user only)."
}

configure_archiving() {
    info "Configuring PostgreSQL WAL archiving..."
    local mode
    mode=$(pg -c 'SHOW archive_mode')
    pg -c "ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=$STANZA archive-push %p'"
    pg -c "ALTER SYSTEM SET archive_timeout = '60s'"
    pg -c "ALTER SYSTEM SET wal_level = 'replica'"
    pg -c "ALTER SYSTEM SET archive_mode = 'on'"
    if [[ $mode != on ]]; then
        warn "Turning archive_mode on needs a PostgreSQL restart (a few seconds of downtime)."
        if yes_no "Restart PostgreSQL now?" y; then
            systemctl restart postgresql
            sleep 3
        else
            err "Archiving is NOT active until PostgreSQL is restarted. Re-run this script afterwards."
            exit 1
        fi
    else
        pg -c 'SELECT pg_reload_conf()' >/dev/null
    fi
}

init_stanza() {
    info "Creating the backup stanza and checking archiving..."
    runuser -u postgres -- pgbackrest --stanza="$STANZA" stanza-create
    runuser -u postgres -- pgbackrest --stanza="$STANZA" check
    ok "Archiving works: a test WAL segment reached the bucket."
}

first_backup() {
    if yes_no "Take the first full backup now?" y; then
        runuser -u postgres -- pgbackrest --stanza="$STANZA" --type=full backup
        ok "First full backup complete."
    else
        warn "No backup yet. Run: sudo -u postgres pgbackrest --stanza=$STANZA --type=full backup"
    fi
}

write_alert_env() {
    umask 077
    cat > "$ALERT_ENV" <<EOF
PING_URL='${PING_URL//\'/}'
EOF
    chown postgres:postgres "$ALERT_ENV"
    chmod 600 "$ALERT_ENV"
}

write_monitor() {
    cat > "$MONITOR" <<'EOF'
#!/usr/bin/env bash
# Hourly health check for pgBackRest. Run as the postgres user.
# Fails (and signals the ping URL) if:
#   - the archive check fails (WAL can't reach the bucket)
#   - PostgreSQL has recorded archive failures since the last good archive
#   - there is no backup, the newest full backup is over 8 days old, or the
#     oldest backup is younger than the required window (history too short)
# Settings come from /etc/pgbackrest/alert.env and the variables below.
STANZA=__STANZA__
WINDOW_DAYS=__WINDOW__
KEEP_FULL=__KEEP__
. /etc/pgbackrest/alert.env 2>/dev/null || true
problems=()

pgb() { pgbackrest --stanza="$STANZA" "$@"; }

if ! out=$(pgb check 2>&1); then problems+=("pgbackrest check failed: ${out##*$'\n'}"); fi

arch=$(psql -Atc "SELECT failed_count || '|' || coalesce(extract(epoch FROM now()-last_archived_time)::int,-1) || '|' || (coalesce(last_failed_time,'-infinity') > coalesce(last_archived_time,'-infinity'))::text FROM pg_stat_archiver" 2>/dev/null) || arch=
if [[ -z $arch ]]; then
    problems+=("cannot read pg_stat_archiver")
else
    IFS='|' read -r _failed age failing <<<"$arch"
    [[ $failing == true ]] && problems+=("PostgreSQL reports the latest archive attempt FAILED")
    # The hourly 'pgbackrest check' above forces a WAL switch and confirms it reached
    # the bucket, so an idle database is covered too.
    :
fi

info=$(pgb info --output=json 2>/dev/null) || info=
if [[ -z $info ]] || [[ $(jq '.[0].backup | length' <<<"$info" 2>/dev/null) == 0 ]]; then
    problems+=("no backups found in the repository")
else
    now=$(date +%s)
    oldest=$(jq '[.[0].backup[].timestamp.start] | min' <<<"$info")
    newest_full=$(jq '[.[0].backup[] | select(.type=="full") | .timestamp.start] | max' <<<"$info")
    ((now - newest_full > 8*86400)) && problems+=("newest full backup is $(((now-newest_full)/86400)) days old")
    # The window can only be met once the repository is old enough. Remember when the
    # oldest backup was first seen, and only require the full window after that.
    first_file=${FIRST_FILE:-/var/spool/pgbackrest/.monitor_first_backup}
    [[ -s $first_file ]] || echo "$oldest" > "$first_file" 2>/dev/null
    first=$(cat "$first_file" 2>/dev/null || echo "$oldest")
    if ((now - first >= WINDOW_DAYS*86400)) && ((now - oldest < WINDOW_DAYS*86400)); then
        problems+=("history only goes back $(((now-oldest)/86400)) days (need $WINDOW_DAYS)")
    fi
fi

if ((${#problems[@]})); then
    msg="pgbackrest on $(hostname): ${problems[*]}"
    logger -p user.err -t pgbackrest-monitor "$msg"
    echo "$msg" >&2
    [[ -n ${PING_URL:-} ]] && curl -fsS -m 15 --retry 3 --data-raw "$msg" "${PING_URL%/}/fail" >/dev/null 2>&1
    exit 1
fi
logger -t pgbackrest-monitor "ok"
[[ -n ${PING_URL:-} ]] && curl -fsS -m 15 --retry 3 "$PING_URL" >/dev/null 2>&1
exit 0
EOF
    sed -i "s/__STANZA__/$STANZA/; s/__WINDOW__/$WINDOW_DAYS/; s/__KEEP__/$KEEP_FULL/" "$MONITOR"
    chmod 755 "$MONITOR"
}

write_cron() {
    cat > "$CRON" <<EOF
# Managed by dbserver/install-backup.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Full backup Sunday 02:00, differential Monday-Saturday 02:00
0 2 * * 0   postgres  pgbackrest --stanza=$STANZA --type=full backup
0 2 * * 1-6 postgres  pgbackrest --stanza=$STANZA --type=diff backup
# Weekly integrity check of the backups and the WAL history (Wednesday 04:00)
0 4 * * 3   postgres  pgbackrest --stanza=$STANZA verify
# Hourly health check; a ping URL is signalled either way
7 * * * *   postgres  $MONITOR
EOF
    chmod 644 "$CRON"
}

report() {
    echo
    ok "============ Backups configured ============"
    echo "  Bucket:        s3://$BUCKET  ($REGION)"
    echo "  WAL archiving: every 60s while busy (archive_timeout)"
    echo "  Backups:       full Sun 02:00, differential Mon-Sat 02:00, $KEEP_FULL fulls kept"
    echo "  Monitor:       hourly (/usr/local/sbin/pgbackrest-monitor), alerts: ${PING_URL:-log only (no ping URL)}"
    echo "  Check:         sudo -u postgres pgbackrest --stanza=$STANZA info"
    if [[ ${GENERATED:-0} == 1 ]]; then
        echo
        warn "ENCRYPTION PASSPHRASE (shown once - save it in your password manager NOW):"
        echo "  $PASSPHRASE"
        echo "  It is also in $CONF, but that file is lost with this server."
    fi
    echo
    warn "Not done until a restore has been tested: see dbserver/RESTORE.md"
}

main() {
    if [[ ${1:-} == monitor ]]; then   # refresh only the monitor script and cron file
        preflight
        write_monitor
        write_cron
        ok "Monitor and schedule updated."
        return
    fi
    preflight
    install_packages
    gather_settings
    write_config
    configure_archiving
    init_stanza
    first_backup
    write_alert_env
    write_monitor
    write_cron
    report
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
