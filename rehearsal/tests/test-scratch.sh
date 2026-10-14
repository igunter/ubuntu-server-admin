#!/usr/bin/env bash
# Regression tests for rehearsal/scratch/scratch-pitr.sh (findings F2 and F3). No AWS, apt or PostgreSQL is used: every
# system call is replaced by a recording fake, and all secrets are fictional sentinel strings. Run as root.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); SC=$REPO/rehearsal/scratch/scratch-pitr.sh
PASSN=0; FAILN=0
check() { if [[ $2 == 0 ]]; then PASSN=$((PASSN+1)); echo "  ok    $1"; else FAILN=$((FAILN+1)); echo "  FAIL  $1"; fi; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
T=$(mktemp -d /run/scratchtest.XXXXXX); trap 'rm -rf "$T"' EXIT
KEY=AKIASENTINEL0000TEST; SEC=SentinelSecretKey0123456789abcdefgh; PASS=SentinelPassphrase0123456789abcdef   # fictional
SEC_DIR=$T/sec; mkdir -p "$SEC_DIR" "$T/etc/pgbackrest"; chmod 700 "$SEC_DIR"
mkid() { # mkid ROLE HOSTNAME [BUCKET]
    printf 'ROLE=%s\nHOSTNAME=%s\nMACHINE_ID=%s\nBUCKET=%s\nREGION=eu-west-2\nPG_MAJOR=16\nDATA_DIR=/var/lib/postgresql/16/main\nSTANZA=main\n' "$1" "$2" "machine-1234" "${3:-dbs-check-crm-rehearsal-backups}" >"$T/identity"; chmod 600 "$T/identity"; }
mksec() { printf 'S3_KEY=%s\nS3_SECRET=%s\nPASSPHRASE=%s\n' "$KEY" "$SEC" "$PASS" >"$SEC_DIR/$1"; chmod 600 "$SEC_DIR/$1"; }
# drive: runs main in a subshell with fakes. Extra shell code in $EXTRA is evaluated after the fakes (to inject state).
drive() { # drive SUBCOMMAND [stdin]
    : >"$T/calls"; : >"$T/out"
    ( . "$SC"
      IDENTITY=$T/identity SECRET_DIR=$SEC_DIR CONF=$T/etc/pgbackrest/pgbackrest.conf ALERT_ENV=$T/etc/pgbackrest/alert.env CRON_FILE=$T/cron OUT=$T/restore-test.txt
      ROOT_PREFIX=$T/root SPOOL_DIR=$T/spool LOG_DIR=$T/log PREPARE_WAIT=0
      FAKE_HOST=${FAKE_HOST:-crm-rehearsal-pitr-src}; FAKE_MID=${FAKE_MID:-machine-1234}; FAKE_IPS=${FAKE_IPS:-"2: eth0    inet 172.26.5.7/20 brd x"}
      FAKE_ACTIVE=${FAKE_ACTIVE:-0}; FAKE_ARCH=${FAKE_ARCH:-off}; FAKE_LISTEN=${FAKE_LISTEN:-localhost}; FAKE_HBA=${FAKE_HBA:-0}; FAKE_DBS=${FAKE_DBS:-postgres}; FAKE_DATADIR=${FAKE_DATADIR:-/var/lib/postgresql/16/main}
      g_hostname() { echo "$FAKE_HOST"; }; g_machine_id() { echo "$FAKE_MID"; }; g_ipv4() { echo "$FAKE_IPS"; }
      g_active_state() { case "$FAKE_ACTIVE" in 1) echo "0 active" ;; 0) echo "3 inactive" ;; failed) echo "3 failed" ;; missing) echo "4 unknown" ;; *) echo "$FAKE_ACTIVE" ;; esac; }
      g_pg() { echo "pg $*" >>"$T/calls"; case "$*" in
          *"SHOW archive_mode"*) [[ $FAKE_ARCH == FAIL ]] && return 1; echo "$FAKE_ARCH" ;;
          *"SHOW data_directory"*) echo "$FAKE_DATADIR" ;; *"FROM pg_database WHERE NOT"*) echo "$FAKE_DBS" ;;
          *"SHOW listen_addresses"*) echo "$FAKE_LISTEN" ;; *"pg_hba_file_rules"*) echo "$FAKE_HBA" ;;
          *"pg_is_in_recovery"*) echo f ;; *"FROM pg_database WHERE datname"*) echo 1 ;; *) echo ok ;; esac; }
      g_apt() { echo "apt $*" >>"$T/calls"; [[ -z ${DRIFT_AFTER_APT:-} ]] || FAKE_HOST=${DRIFT_AFTER_APT}; }
      g_pgbackrest() { echo "pgbackrest $*" >>"$T/calls"; if [[ $* == *restore && -n ${RESTORE_AUTO:-} ]]; then mkdir -p "$T/root$ID_DATA_DIR"; printf '%s\n' "$RESTORE_AUTO" > "$T/root$ID_DATA_DIR/postgresql.auto.conf"; fi; return 0; }
      g_systemctl() { echo "systemctl $*" >>"$T/calls"; }
      createdb() { :; }; runuser() { echo "runuser $*" >>"$T/calls"; }
      install() { command install "$@" 2>/dev/null || true; }
      sleep() { :; }
      ID_DATA_DIR_OVERRIDE=1
      eval "${EXTRA:-}"
      main "$@" ) <<<"${2:-}" >"$T/out" 2>&1; RC=$?; strip <"$T/out" >"$T/out.txt"
}
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
calls_n() { grep -cE "^(apt|pgbackrest|systemctl|pg -c ALTER|runuser)" "$T/calls" || true; }
no_secrets() { ! grep -qE "$KEY|$SEC|$PASS" "$T/out" "$T/calls" 2>/dev/null; }
reset() { rm -f "$T/etc/pgbackrest/"* "$T/cron" "$T/auto.conf" "$T/restore-test.txt"; mkid source crm-rehearsal-pitr-src; mksec scratch-pitr-rw.env; unset FAKE_HOST FAKE_MID FAKE_IPS FAKE_ACTIVE FAKE_ARCH FAKE_LISTEN FAKE_HBA FAKE_DBS FAKE_DATADIR DRIFT_AFTER_APT RESTORE_AUTO EXTRA TARGET; }
refused() { # refused "label" : the last drive must have failed the guard and called nothing
    check "$1" $([[ $RC != 0 ]] && grep -q 'GUARD FAILED' "$T/out.txt" && [[ $(calls_n) == 0 ]]; echo $?); }
SI=$'SCRATCH-SOURCE\n'

echo "== happy path: source-install"
reset; drive source-install "$SI"
check "exit 0" $RC
check "apt, conf, ALTER SYSTEM x4, restart, stanza-create, check, full backup — in that order" $([[ $(grep -E '^(apt install|pg -c ALTER|systemctl restart|pgbackrest)' "$T/calls" | sed -E 's/ .*//;' | tr '\n' ' ') == "apt pg pg pg pg systemctl pgbackrest pgbackrest pgbackrest " ]]; echo $?)
check "conf names only the scratch bucket, mode 600, postgres-owned" $([[ $(sed -n 's/^repo1-s3-bucket=//p' $T/etc/pgbackrest/pgbackrest.conf) == dbs-check-crm-rehearsal-backups && $(stat -c %a $T/etc/pgbackrest/pgbackrest.conf) == 600 && $(stat -c %U $T/etc/pgbackrest/pgbackrest.conf) == postgres ]]; echo $?)
check "the pgBackRest commands carry no secret (config file only)" $(no_secrets; echo $?)
check "no secret or passphrase was printed to the terminal (sentinel scan)" $(! grep -qE "$KEY|$SEC|$PASS" "$T/out"; echo $?)
check "no cron file, monitor or alert env was created" $([[ ! -e $T/cron && ! -e $T/etc/pgbackrest/alert.env ]]; echo $?)
check "the old live-capable scripts are not invoked" $(! grep -qE 'install-backup\.sh|restore-test(-prepare)?\.sh' <(grep -vE '^\s*#' "$SC"); echo $?)
check "no prompt generates or prints a passphrase" $(! grep -qiE 'generate a random passphrase|random_string' "$SC"; echo $?)

echo "== guard refusals: nothing is called (source-install)"
for case in \
  "wrong hostname|FAKE_HOST=crm-other" \
  "machine-id differs (identity copied from elsewhere)|FAKE_MID=machine-9999" \
  "protected live address present|FAKE_IPS='2: eth0 inet 172.26.9.114/20 brd x'" \
  "protected app address present|FAKE_IPS='2: eth0 inet 172.26.0.238/20 brd x'" \
  "protected fixed outbound address present|FAKE_IPS='2: eth0 inet 18.169.221.228/20 brd x'" \
  "PING_URL set (even empty) in the environment|EXTRA='export PING_URL='" \
  "ARCHIVE_PING_URL set in the environment|EXTRA='export ARCHIVE_PING_URL=https://x.invalid/abc'" \
  "alert.env defines a ping URL|EXTRA='echo \"PING_URL=x\" > \$ALERT_ENV'" \
  "cron file from the live installer exists|EXTRA='touch \$CRON_FILE'" \
  "existing conf names the live bucket|EXTRA='printf \"repo1-s3-bucket=dbs-check-crm-backups\n\" > \$CONF; chmod 600 \$CONF'" \
  "existing conf has a second, different bucket|EXTRA='printf \"repo1-s3-bucket=dbs-check-crm-rehearsal-backups\nrepo2-s3-bucket=other\n\" > \$CONF; chmod 600 \$CONF'" \
  "existing conf is mode 644|EXTRA='printf \"repo1-s3-bucket=dbs-check-crm-rehearsal-backups\n\" > \$CONF; chmod 644 \$CONF'" \
  "running server: archive_mode query FAILS (was treated as not-live)|FAKE_ACTIVE=1 FAKE_ARCH=FAIL" \
  "source with archive_mode=always|FAKE_ACTIVE=1 FAKE_ARCH=always" \
  "source listens beyond localhost|FAKE_ACTIVE=1 FAKE_LISTEN='*'" \
  "source has a remote pg_hba rule (HBA is inspected)|FAKE_ACTIVE=1 FAKE_HBA=2" \
  "cluster holds dbscheckcrm|FAKE_ACTIVE=1 FAKE_DBS=\$'postgres\ndbscheckcrm'" \
  "running cluster's data directory differs from the identity|FAKE_ACTIVE=1 FAKE_DATADIR=/srv/pg"; do
    reset; label=${case%%|*}; assign=${case#*|}
    ( eval "export $assign" 2>/dev/null; true ) >/dev/null 2>&1
    # apply the assignment as environment for drive
    eval "$assign" 2>/dev/null; drive source-install "$SI"
    refused "$label"; unset FAKE_HOST FAKE_MID FAKE_IPS FAKE_ACTIVE FAKE_ARCH FAKE_LISTEN FAKE_HBA FAKE_DBS FAKE_DATADIR EXTRA
done
echo "== an inspection failure of is-active is not 'PostgreSQL is not running' (review 2cc127a)"
for st in "1 Failed to connect to bus: Permission denied" "1 Access denied" "255 Transport endpoint is not connected" "0 activating" "3 deactivating" "3 " "0 inactive" "error"; do
    reset; FAKE_ACTIVE=$st drive source-install "$SI"; refused "source: is-active answered '$st'"
    reset; mkid restore crm-rehearsal-pitr-restore; mksec scratch-pitr-ro.env; FAKE_HOST=crm-rehearsal-pitr-restore FAKE_ACTIVE=$st TARGET='2026-10-16 15:05:30.123456+01' drive restore $'RESTORE-TEST\n'; refused "restore: is-active answered '$st'"
done
reset; drive check; check "documented 'inactive' (3) is accepted as not running" $RC
reset; FAKE_ACTIVE=failed drive check; check "documented 'failed' (3) is accepted as not running" $RC
reset; FAKE_ACTIVE=missing drive check; check "'unknown' (no such unit, 4) is accepted as not running" $RC
reset; FAKE_ACTIVE=1 drive check; check "'active' leads to the running-server checks, which pass for a clean source" $RC
reset; FAKE_ACTIVE=1 FAKE_ARCH=always drive check; check "'active' with archive_mode=always is still refused" $((RC == 0))
echo "== the real g_active_state wrapper reports exit status and output (stub systemctl on PATH)"
mkdir -p "$T/bin"; cat >"$T/bin/systemctl" <<'SC'
#!/usr/bin/env bash
case ${STUB_MODE:-} in active) echo active; exit 0 ;; inactive) echo inactive; exit 3 ;; denied) echo "Failed to connect to system scope bus: Permission denied" >&2; exit 1 ;; esac
SC
chmod +x "$T/bin/systemctl"
for m in "active|0 active" "inactive|3 inactive" "denied|1 Failed to connect to system scope bus: Permission denied"; do
    got=$( . "$SC"; PATH=$T/bin:$PATH STUB_MODE=${m%%|*} g_active_state ); check "wrapper for '${m%%|*}' returns '${m#*|}'" $([[ $got == "${m#*|}" ]]; echo $?)
done
echo "== identity file refusals"
reset; mkid source crm-rehearsal-pitr-src dbs-check-crm-backups; drive source-install "$SI"; refused "identity names the LIVE bucket"
reset; chmod 644 "$T/identity"; drive source-install "$SI"; refused "identity file mode 0644"
reset; rm -f "$T/identity"; drive source-install "$SI"; refused "identity file missing"
reset; echo "EXTRA=1" >>"$T/identity"; drive source-install "$SI"; refused "identity file with an unknown key"
reset; mkid restore crm-rehearsal-pitr-restore; drive source-install "$SI"; refused "identity role is restore but the step is source"
reset; sed -i 's/^REGION=.*/REGION=us-east-1/' "$T/identity"; drive source-install "$SI"; refused "identity region not eu-west-2"
echo "== bucket/region are never taken from the environment"
reset; BUCKET=dbs-check-crm-backups REGION=us-east-1 drive source-install "$SI"
check "BUCKET=live in the environment is ignored; conf still names the scratch bucket" $([[ $RC == 0 && $(sed -n 's/^repo1-s3-bucket=//p' $T/etc/pgbackrest/pgbackrest.conf) == dbs-check-crm-rehearsal-backups && $(sed -n 's/^repo1-s3-region=//p' $T/etc/pgbackrest/pgbackrest.conf) == eu-west-2 ]]; echo $?)

echo "== credentials file restrictions"
reset; chmod 644 "$SEC_DIR/scratch-pitr-rw.env"; drive source-install "$SI"; check "mode 0644 refused, nothing called" $([[ $RC != 0 && $(calls_n) == 0 ]]; echo $?)
reset; echo 'PING_URL=https://hc.invalid/x' >>"$SEC_DIR/scratch-pitr-rw.env"; drive source-install "$SI"; check "a ping URL line in the credentials file refused" $([[ $RC != 0 && $(calls_n) == 0 ]]; echo $?)
reset; printf 'S3_KEY=%s\nS3_SECRET=%s\nPASSPHRASE=short\n' "$KEY" "$SEC" >"$SEC_DIR/scratch-pitr-rw.env"; chmod 600 "$SEC_DIR/scratch-pitr-rw.env"; drive source-install "$SI"; check "passphrase under 24 characters refused" $([[ $RC != 0 && $(calls_n) == 0 ]]; echo $?)
reset; rm "$SEC_DIR/scratch-pitr-rw.env"; ln -s /etc/hostname "$SEC_DIR/scratch-pitr-rw.env"; drive source-install "$SI"; check "symlinked credentials file refused" $([[ $RC != 0 && $(calls_n) == 0 ]]; echo $?); rm -f "$SEC_DIR/scratch-pitr-rw.env"
reset; printf 'S3_KEY=%s\nS3_SECRET=$(touch %s/pwned)\nPASSPHRASE=%s\n' "$KEY" "$T" "$PASS" >"$SEC_DIR/scratch-pitr-rw.env"; chmod 600 "$SEC_DIR/scratch-pitr-rw.env"; drive source-install "$SI"
check "shell syntax in a value is refused and never executed" $([[ $RC != 0 && ! -e $T/pwned ]]; echo $?)
reset; chmod 755 "$SEC_DIR"; drive source-install "$SI"; check "secret directory mode 0755 refused" $([[ $RC != 0 && $(calls_n) == 0 ]]; echo $?); chmod 700 "$SEC_DIR"

echo "== the guard is re-run before each step (drift mid-run)"
reset; DRIFT_AFTER_APT=crm-prod drive source-install "$SI"
check "hostname changes after the package step: run stops" $([[ $RC != 0 ]] && grep -q "GUARD FAILED before 'writing" "$T/out.txt"; echo $?)
check "  conf was NOT written and no WAL/restart/backup call followed" $([[ ! -e $T/etc/pgbackrest/pgbackrest.conf ]] && ! grep -qE '^(pg -c ALTER|systemctl restart|pgbackrest)' "$T/calls"; echo $?)
reset; EXTRA='g_systemctl() { echo "systemctl $*" >>"$T/calls"; touch "$CRON_FILE"; }' drive source-install "$SI"
check "cron file appears after the restart: stanza-create/backup NOT run" $([[ $RC != 0 ]] && ! grep -qE '^pgbackrest' "$T/calls"; echo $?)

echo "== confirmation is typed"
reset; drive source-install "no"; check "wrong confirmation: nothing called" $([[ $RC == 0 && $(calls_n) == 0 ]] && grep -q Cancelled "$T/out.txt"; echo $?)

echo "== restore host"
rreset() { reset; rm -rf "$T/root"; mkid restore crm-rehearsal-pitr-restore; mksec scratch-pitr-ro.env; export FAKE_HOST=crm-rehearsal-pitr-restore TARGET='2026-10-16 15:05:30.123456+01'; }
RS=$'RESTORE-TEST\n'
rreset; RESTORE_AUTO="archive_mode = 'off'" drive restore "$RS"
check "restored settings say archive_mode off: cluster started, exit 0" $([[ $RC == 0 ]] && grep -q '^systemctl start' "$T/calls"; echo $?)
check "restore used --archive-mode=off and the read-only credentials; no secret in any argument or output" $(grep -q -- '--archive-mode=off restore' "$T/calls" && no_secrets; echo $?)
check "listen_addresses forced to localhost in the restored settings" $(grep -q "^listen_addresses = 'localhost'" "$T/root/var/lib/postgresql/16/main/postgresql.auto.conf"; echo $?)
rreset; RESTORE_AUTO="archive_mode = 'on'" drive restore "$RS"
check "restored settings say archive_mode on: cluster NOT started" $([[ $RC != 0 ]] && grep -q 'NOT starting the restored cluster' "$T/out.txt" && ! grep -q '^systemctl start' "$T/calls"; echo $?)
rreset; RESTORE_AUTO=$'archive_mode = \'off\'\narchive_mode = \'always\'' drive restore "$RS"
check "the LAST archive_mode line wins (off then always): NOT started" $([[ $RC != 0 ]] && ! grep -q '^systemctl start' "$T/calls"; echo $?)
rreset; drive restore "$RS"
check "restored settings absent/unset: NOT started" $([[ $RC != 0 ]] && ! grep -q '^systemctl start' "$T/calls"; echo $?)
rreset; FAKE_ACTIVE=1 FAKE_ARCH=on drive restore "$RS"; refused "restore host with archive_mode=on refused before anything"
rreset; FAKE_ACTIVE=1 FAKE_ARCH=FAIL drive restore "$RS"; refused "restore host: archive_mode query failure refused"
rreset; TARGET=yesterday drive restore "$RS"; check "invalid restore time refused, nothing called" $([[ $RC != 0 && $(calls_n) == 0 ]]; echo $?)
rreset; mksec scratch-pitr-rw.env; rm -f "$SEC_DIR/scratch-pitr-ro.env"; drive restore "$RS"; check "restore does not fall back to the read-write credentials" $([[ $RC != 0 && $(calls_n) == 0 ]]; echo $?)
rreset; RESTORE_AUTO="archive_mode = 'off'" EXTRA='g_systemctl() { echo "systemctl $*" >>"$T/calls"; [[ $1 == start ]] && FAKE_HOST=crm-other; return 0; }' drive restore "$RS"
check "guard re-run before and after start: drift after start flagged" $([[ $RC != 0 ]] && grep -q "GUARD FAILED before 'final check'" "$T/out.txt"; echo $?)
unset TARGET FAKE_HOST

echo "== tracing is refused before any secret is read"
reset; bash -x "$SC" check >"$T/out" 2>&1; check "bash -x refused" $(grep -q 'Refusing to run with shell tracing' "$T/out"; echo $?); check "  and printed no sentinel" $(no_secrets; echo $?)
reset; env SHELLOPTS=xtrace bash "$SC" check >"$T/out" 2>&1; check "SHELLOPTS=xtrace refused" $(grep -q 'Refusing to run with shell tracing' "$T/out"; echo $?)
echo; echo "RESULT: $PASSN passed, $FAILN failed"; ((FAILN == 0))
