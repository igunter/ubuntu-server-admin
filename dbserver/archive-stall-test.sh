#!/usr/bin/env bash
# Live test of the archive-stall alert (run on the DATABASE server, as root).
#
#   sudo bash dbserver/archive-stall-test.sh            # run the test
#   sudo bash dbserver/archive-stall-test.sh restore    # put archiving back (only if a run was interrupted)
#
# What it does: it temporarily breaks the archive command, so finished WAL cannot
# reach the bucket, then times how long the every-minute watch takes to alert.
# It then restores archiving, waits for the queued WAL to be shipped, and runs
# `pgbackrest check`. Nothing is lost: PostgreSQL keeps the WAL until it has been
# archived. While archiving is broken (about 4 to 6 minutes) the recovery point is
# NOT protected, so do not run this while real applicant data is changing.
#
# Needs: dbserver/install-backup.sh already run, and the archive-watch ping URL set
# (sudo bash dbserver/install-backup.sh archive-url).
set -u
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
. "$DIR/../lib.sh"
[[ $EUID -eq 0 ]] || { err "Run as root: sudo $0"; exit 1; }

STANZA=${STANZA:-main}
WATCH=${WATCH:-/usr/local/sbin/pgbackrest-archive-watch}
ALERT_ENV=${ALERT_ENV:-/etc/pgbackrest/alert.env}
SAVE=${SAVE:-/var/tmp/archive-stall-test.orig}
MAX_WAIT=${MAX_WAIT:-600}          # give up waiting for the alert after this many seconds
POLL=${POLL:-15}
PG_RUN=${PG_RUN:-runuser -u postgres --}   # tests override this
REQUIRE_PGBACKREST=${REQUIRE_PGBACKREST:-1}

pg() { $PG_RUN psql -Atq -v ON_ERROR_STOP=1 "$@"; }
now() { date '+%Y-%m-%d %H:%M:%S %Z'; }
sql_quote() { printf "%s" "${1//\'/\'\'}"; }

set_archive_command() {   # set_archive_command VALUE
    pg -c "ALTER SYSTEM SET archive_command = '$(sql_quote "$1")'" -c "SELECT pg_reload_conf()" >/dev/null || return 1
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ $(pg -c 'SHOW archive_command') == "$1" ]] && return 0
        sleep 1
    done
    return 1
}

restore_archiving() {
    [[ -f $SAVE ]] || return 0
    local orig
    orig=$(cat "$SAVE")
    if set_archive_command "$orig"; then
        rm -f "$SAVE"
        ok "Archiving restored: archive_command is back to its original value."
    else
        err "COULD NOT restore archive_command. Original saved in $SAVE. Fix now:"
        err "  sudo bash $0 restore"
        return 1
    fi
}

ready_count() {
    local d
    d=$(pg -c 'SHOW data_directory') || { echo '?'; return; }
    find "$d/pg_wal/archive_status" -maxdepth 1 -name '*.ready' 2>/dev/null | wc -l
}

if [[ ${1:-} == restore ]]; then
    [[ -f $SAVE ]] || { ok "Nothing to restore: no interrupted test found."; exit 0; }
    restore_archiving
    exit $?
fi

# ---- preconditions ----------------------------------------------------------
[[ ! -f $SAVE ]] || { err "A previous run did not finish. Run: sudo bash $0 restore"; exit 1; }
[[ -x $WATCH ]] || { err "$WATCH not found. Run: sudo bash dbserver/install-backup.sh monitor"; exit 1; }
mode=$(pg -c 'SHOW archive_mode') || { err "Cannot connect to PostgreSQL."; exit 1; }
[[ $mode == on || $mode == always ]] || { err "archive_mode is '$mode'. Archiving is not on."; exit 1; }
orig=$(pg -c 'SHOW archive_command')
if [[ $REQUIRE_PGBACKREST == 1 && $orig != *archive-push* ]]; then
    err "archive_command is not the pgBackRest one ('$orig'). Refusing to continue."
    exit 1
fi
grep -q "^ARCHIVE_PING_URL='.\+'" "$ALERT_ENV" 2>/dev/null || {
    err "The archive-watch ping URL is not set, so no alert would be sent."
    err "Set it first: sudo bash dbserver/install-backup.sh archive-url"
    exit 1
}

echo
warn "This will BREAK WAL archiving on purpose for about 4 to 6 minutes."
echo "  - The original archive_command is saved and restored afterwards."
echo "  - You should see an alert in your alert channel (Slack) a few minutes in."
echo "  - Do not run this while real applicant data is being written."
read -rp "Type STALL-TEST to continue: " c
[[ $c == STALL-TEST ]] || { echo "Cancelled. Nothing changed."; exit 0; }

# ---- baseline ---------------------------------------------------------------
info "Baseline: running the archive watch while archiving is healthy..."
if ! $PG_RUN env ALERT_ENV="$ALERT_ENV" ${STALL_SEC:+STALL_SEC=$STALL_SEC} "$WATCH"; then
    err "The watch already reports a problem. Fix that before testing."; exit 1
fi
ok "Baseline healthy."

# ---- break archiving --------------------------------------------------------
printf '%s' "$orig" > "$SAVE"
trap 'echo; warn "Interrupted: restoring archiving..."; restore_archiving; exit 130' INT TERM HUP
trap 'restore_archiving' EXIT

set_archive_command '/bin/false' || { err "Could not change archive_command."; exit 1; }
pg -c "SELECT pg_logical_emit_message(true,'archive-stall-test','x')" -c "SELECT pg_switch_wal()" >/dev/null
t_break=$(date +%s); t_break_txt=$(now)
warn "Archiving is now BROKEN (started $t_break_txt). Waiting for the alert..."

# ---- wait for detection -----------------------------------------------------
t_detect=; detect_txt=; detect_msg=
while (( $(date +%s) - t_break < MAX_WAIT )); do
    sleep "$POLL"
    out=$($PG_RUN env ALERT_ENV="$ALERT_ENV" ${STALL_SEC:+STALL_SEC=$STALL_SEC} "$WATCH" 2>&1); rc=$?
    el=$(( $(date +%s) - t_break ))
    printf '  %s  +%dm%02ds  watch exit %d\n' "$(date +%T)" $((el/60)) $((el%60)) "$rc"
    if (( rc != 0 )); then
        t_detect=$(date +%s); detect_txt=$(now); detect_msg=$out
        break
    fi
done

if [[ -n $t_detect ]]; then
    d=$(( t_detect - t_break ))
    ok "ALERT RAISED at $detect_txt, $((d/60)) min $((d%60)) s after archiving broke."
    echo "  Message sent: $detect_msg"
    echo
    echo "Now check that it arrived in Slack, and note the time it arrived."
    read -rt 600 -p "Press Enter when you have seen it (archiving is restored after this): " _ || true
else
    err "No alert was raised within $((MAX_WAIT/60)) minutes. The test FAILED."
fi

# ---- restore and prove nothing was lost -------------------------------------
echo
restore_archiving; rrc=$?
t_restored_txt=$(now)
info "Waiting for the queued WAL to reach the bucket..."
left=?; for _ in $(seq 1 36); do left=$(ready_count); [[ $left == 0 ]] && break; sleep 5; done
if [[ $left == 0 ]]; then ok "All queued WAL has been archived."; else err "$left WAL segment(s) still waiting after 3 minutes. Investigate."; fi

if [[ $REQUIRE_PGBACKREST == 1 ]]; then
    if $PG_RUN pgbackrest --stanza="$STANZA" check >/dev/null 2>&1; then ok "pgbackrest check: archiving works end to end."
    else err "pgbackrest check FAILED. Investigate before relying on the backups."; rrc=1; fi
fi
if $PG_RUN env ALERT_ENV="$ALERT_ENV" ${STALL_SEC:+STALL_SEC=$STALL_SEC} "$WATCH"; then
    ok "Watch is healthy again: your alert service should show a recovery."
else
    err "Watch still reports a problem."; rrc=1
fi

echo
echo "===================== Result for the record ====================="
echo "Archiving broken at:    $t_break_txt"
if [[ -n $t_detect ]]; then
    echo "Alert raised at:        $detect_txt  ($((d/60)) min $((d%60)) s later)"
else
    echo "Alert raised at:        NOT RAISED"
fi
echo "Archiving restored at:  $t_restored_txt"
echo "Queued WAL archived:    $([[ $left == 0 ]] && echo yes || echo NO)"
echo "Add the time the alert arrived in Slack, and the recovery time, to the record."
trap - EXIT INT TERM HUP
[[ -n $t_detect && $rrc == 0 && $left == 0 ]] || exit 1
