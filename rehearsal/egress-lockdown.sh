#!/usr/bin/env bash
# Host firewall for the TEMPORARY rehearsal application host (crm-rehearsal-app). Never for the production
# application server or the database server.
#
#   sudo OPS_IP=<operator public IPv4> bash rehearsal/egress-lockdown.sh plan      # DEFAULT: checks, prints the exact rules, changes nothing
#   sudo OPS_IP=<operator public IPv4> bash rehearsal/egress-lockdown.sh apply     # typed confirmation, then applies and makes it permanent
#   sudo bash rehearsal/egress-lockdown.sh status                                  # re-checks loaded + persisted rules, shows counters and IPv6 posture
#   sudo bash rehearsal/egress-lockdown.sh require                                 # silent gate: exit 0 only if everything status checks passes
#   sudo bash rehearsal/egress-lockdown.sh remove                                  # removes only this script's table and unit (refused with secrets/app present)
#
# Why no 'ct direction' match: a connection that was open BEFORE the rules were loaded has no conntrack entry
# if conntrack was not active; conntrack then adopts it mid-stream and treats whichever side speaks first as
# the 'original' direction. Matching on direction would cut the operator's own session about half the time
# (seen in testing). The rules therefore match on peer address, port and state only.
#
# Why nftables and not ufw: ufw puts "accept established" rules before its own denies, so a connection that
# was already open when the firewall was switched on would keep working. These rules decide by the
# peer and port and the connection state:
#   - this host may SEND only (a) TCP to DB_IP:DB_PORT that it started, and (b) replies to the operator's
#     connections to OPS_PORTS from OPS_IP. A reply on any other pre-existing connection (for example an
#     unapproved inbound connection that was open before the rules were loaded) is dropped, including
#     data that application code or the kernel had already queued for it.
#   - this host may RECEIVE only (a) replies from DB_IP:DB_PORT to its own connections and (b) the operator's
#     connections from OPS_IP to OPS_PORTS.
#   - everything else is logged (rate-limited) and dropped, IPv4 and IPv6 alike (table family "inet").
#   - the cloud metadata addresses are dropped first, by address, and are never contacted by any test.
# Deliberately NOT allowed: DNS, NTP, HTTP/HTTPS to anywhere, package mirrors. The application reaches the
# database by IP.
#
# EXCEPTIONS are additions to the database-only policy and are NOT implied. Each loads ONLY if named in
# APPROVED_EXCEPTIONS (comma list), and only after the client has approved it for this host. Default: none.
#   dhcp          UDP 68<->67 on interface IFACE with DHCP_SERVER (default: the IPv4 default gateway) and the
#                 broadcast address 255.255.255.255, so the lease can be renewed. Without it the host loses its
#                 IPv4 address when the lease expires: record the lease time and keep the host short-lived.
#   nd            IPv6 neighbour discovery on IFACE, link-local only (fe80::/10, ff02::/16), hop limit 255.
#                 Not needed if IPv6 is disabled on the host (preferred).
#   icmp-related  ICMP "destination-unreachable"/"time-exceeded" errors RELATED to the approved flows, with
#                 OPS_IP or DB_IP only (path MTU discovery). IPv6 has no such rule: no IPv6 peer is approved.
#
# No safety-net timer is used. A timer that disables the firewall would be a fail-open path, and this host
# holds no data or secrets when the rules are applied. If management access is lost, delete and recreate the
# (empty) host. To avoid that, `apply` refuses unless the current SSH session comes from OPS_IP.
#
# FAIL CLOSED: if anything after the rules are loaded fails (saving them, the unit, enabling it, checking what
# was saved), `apply` exits non-zero, leaves the rules LOADED, writes no state record, and `status`/`require`
# keep failing until `apply` has completed successfully. Boot: rehearsal-egress.service loads the saved rules
# before the network comes up; the application's own unit must Requires=/After= it and run
# `egress-lockdown.sh require` in ExecStartPre (see egress-plan.md). "Enabled" alone is not proof of boot
# enforcement: the boot and failure behaviour must be demonstrated on the real empty host before secrets.
#
# Order: stage the package WITHOUT secrets -> apply this -> verify -> stage secrets. `apply` and `remove` refuse
# if the secrets file exists or the application is running, so the lockdown can neither be installed late nor
# weakened under a live application.
#
# Environment
#   OPS_IP      operator public IPv4 (required for plan/apply)
#   DB_IP       default 172.26.9.114      DB_PORT   default 5432
#   OPS_PORTS   default 22                comma list of inbound TCP ports allowed from OPS_IP only (e.g. 22,443)
#   APPROVED_EXCEPTIONS   default empty; any of: dhcp,nd,icmp-related
#   IFACE       default: the interface of the IPv4 default route (needed for dhcp/nd)
#   DHCP_SERVER default: the IPv4 default gateway (needed for dhcp)
#   SVC_USER / APP_UNIT   optional: apply and remove refuse while a process runs as SVC_USER or APP_UNIT is active
#   SECRETS_FILE default /etc/dbs-check/runtime.env (apply and remove refuse if it exists)
#   RULES_FILE / UNIT_FILE / STATE_FILE   where it writes (defaults under /etc)
set -euo pipefail
case $- in *x*|*v*) echo "Refusing to run with shell tracing on." >&2; exit 1 ;; esac

DB_IP=${DB_IP:-172.26.9.114}
DB_PORT=${DB_PORT:-5432}
OPS_PORTS=${OPS_PORTS:-22}
OPS_IP=${OPS_IP:-}
APPROVED_EXCEPTIONS=${APPROVED_EXCEPTIONS:-}
IFACE=${IFACE:-}
DHCP_SERVER=${DHCP_SERVER:-}
GATEWAY=
SVC_USER=${SVC_USER:-}
APP_UNIT=${APP_UNIT:-}
SECRETS_FILE=${SECRETS_FILE:-/etc/dbs-check/runtime.env}
RULES_FILE=${RULES_FILE:-/etc/rehearsal-egress.nft}
UNIT_FILE=${UNIT_FILE:-/etc/systemd/system/rehearsal-egress.service}
STATE_FILE=${STATE_FILE:-/etc/rehearsal-egress.state}
TABLE=rehearsal_egress
NFT=${NFT:-nft}
IP=${IP:-ip}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
INSTALL_UNIT=${INSTALL_UNIT:-1}
PROC_SYS=${PROC_SYS:-/proc/sys}
PROC_NET=${PROC_NET:-/proc/net}
QUIET=0

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
info() { echo "${CYN}$*${RST}"; }; ok() { echo "${GRN}$*${RST}"; }; warn() { echo "${YEL}$*${RST}" >&2; }; err() { echo "${RED}$*${RST}" >&2; }
say() { ((QUIET)) || echo "$@"; }

valid_ipv4() { local o; [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; local IFS=.; for o in $1; do ((10#$o <= 255)) || return 1; done; }
has_exc() { [[ ,$APPROVED_EXCEPTIONS, == *,"$1",* ]]; }

validate() {
    local mode=${1:-}
    valid_ipv4 "$DB_IP" || { err "DB_IP is not a valid IPv4 address."; exit 1; }
    [[ $DB_PORT =~ ^[0-9]{1,5}$ ]] && ((DB_PORT >= 1 && DB_PORT <= 65535)) || { err "DB_PORT is not a port."; exit 1; }
    [[ $OPS_PORTS =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || { err "OPS_PORTS must be a comma-separated list of ports."; exit 1; }
    local p e; IFS=, read -ra _ports <<<"$OPS_PORTS"
    for p in "${_ports[@]}"; do ((p >= 1 && p <= 65535)) || { err "OPS_PORTS contains an invalid port."; exit 1; }; done
    if [[ -n $APPROVED_EXCEPTIONS ]]; then
        IFS=, read -ra _exc <<<"$APPROVED_EXCEPTIONS"
        for e in "${_exc[@]}"; do case $e in dhcp|nd|icmp-related) ;; *) err "Unknown exception '$e'. Allowed: dhcp, nd, icmp-related."; exit 1 ;; esac; done
    fi
    if [[ $mode == plan || $mode == apply ]]; then
        valid_ipv4 "$OPS_IP" || { err "Set OPS_IP to the operator's public IPv4 address."; exit 1; }
        case $OPS_IP in 0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|224.*|240.*|255.*) err "OPS_IP $OPS_IP is not a public address. Refusing: it would open access to a private or special range."; exit 1 ;; esac
        [[ $OPS_IP != "$DB_IP" ]] || { err "OPS_IP must not be the database address."; exit 1; }
    fi
}

# Interface and gateway are read from the routing table; the checks are explicit (a failed command is not "none found").
detect_network() {
    local out
    if [[ -z $GATEWAY || -z $IFACE ]]; then
        if out=$($IP -4 route show default 2>/dev/null); then
            [[ -n $GATEWAY ]] || GATEWAY=$(awk '/^default/ {for (i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}' <<<"$out")
            [[ -n $IFACE ]] || IFACE=$(awk '/^default/ {for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$out")
        fi
    fi
    [[ -z $GATEWAY ]] || valid_ipv4 "$GATEWAY" || { err "Default gateway '$GATEWAY' is not an IPv4 address."; exit 1; }
    [[ -z $IFACE || $IFACE =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || { err "IFACE '$IFACE' is not a valid interface name."; exit 1; }
    [[ -n $DHCP_SERVER ]] || DHCP_SERVER=$GATEWAY
    [[ -z $DHCP_SERVER ]] || valid_ipv4 "$DHCP_SERVER" || { err "DHCP_SERVER '$DHCP_SERVER' is not an IPv4 address."; exit 1; }
}

need_net_for_exceptions() {
    if has_exc dhcp; then
        [[ -n $IFACE ]] || { err "Exception 'dhcp' needs IFACE (no default route found: set IFACE=)."; exit 1; }
        [[ -n $DHCP_SERVER ]] || { err "Exception 'dhcp' needs DHCP_SERVER (no default gateway found: set DHCP_SERVER=)."; exit 1; }
    fi
    if has_exc nd; then [[ -n $IFACE ]] || { err "Exception 'nd' needs IFACE (set IFACE=)."; exit 1; }; fi
    return 0
}

# The complete rule set. Everything the host may do is on this page.
render_rules() {
    local ports=${OPS_PORTS//,/, }
    cat <<EOF
# Managed by rehearsal/egress-lockdown.sh. Temporary rehearsal host only. Do not edit by hand.
# approved exceptions: ${APPROVED_EXCEPTIONS:-none}
table inet $TABLE
delete table inet $TABLE
table inet $TABLE {
    chain input {
        type filter hook input priority -50; policy drop;
        iif "lo" accept
        ct state invalid drop
        # replies from the database to connections THIS host started
        ip saddr $DB_IP tcp sport $DB_PORT ct state established accept
        # the operator: OPS_IP to the approved ports only (NEW only from outside; no ct direction is used, see the header)
        ip saddr $OPS_IP tcp dport { $ports } ct state new,established accept
EOF
    if has_exc icmp-related; then cat <<EOF
        # EXCEPTION icmp-related: error messages about approved flows, from the approved peers only
        ip saddr { $OPS_IP, $DB_IP } icmp type { destination-unreachable, time-exceeded } ct state related accept
EOF
    fi
    if has_exc dhcp; then cat <<EOF
        # EXCEPTION dhcp: replies from the DHCP server on the primary interface
        iifname "$IFACE" ip saddr $DHCP_SERVER udp sport 67 udp dport 68 accept
EOF
    fi
    if has_exc nd; then cat <<EOF
        # EXCEPTION nd: IPv6 neighbour discovery from the local link
        iifname "$IFACE" ip6 saddr fe80::/10 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } ip6 hoplimit 255 accept
EOF
    fi
    cat <<EOF
        limit rate 6/minute burst 10 packets log prefix "REHEARSAL-IN-DROP " counter
        counter
    }
    chain output {
        type filter hook output priority -50; policy drop;
        # cloud metadata: dropped first, by address (IPv4 and IPv6). No test ever contacts these addresses.
        ip daddr 169.254.169.254 counter drop
        ip6 daddr fd00:ec2::254 counter drop
        oif "lo" accept
        ct state invalid drop
        # the ONE connection this host may start: the database
        ip daddr $DB_IP tcp dport $DB_PORT ct state new,established accept
        # replies to the operator's connections, from the approved ports only (nothing else, whatever its state)
        ip daddr $OPS_IP tcp sport { $ports } ct state established accept
EOF
    if has_exc icmp-related; then cat <<EOF
        # EXCEPTION icmp-related
        ip daddr { $OPS_IP, $DB_IP } icmp type { destination-unreachable, time-exceeded } ct state related accept
EOF
    fi
    if has_exc dhcp; then cat <<EOF
        # EXCEPTION dhcp: renewal (unicast to the server) and rebind (broadcast) on the primary interface
        oifname "$IFACE" udp sport 68 udp dport 67 ip daddr { $DHCP_SERVER, 255.255.255.255 } accept
EOF
    fi
    if has_exc nd; then cat <<EOF
        # EXCEPTION nd
        oifname "$IFACE" icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } ip6 daddr { fe80::/10, ff02::/16 } accept
EOF
    fi
    cat <<EOF
        # everything else, including replies on connections that were open before these rules: logged (rate-limited) and dropped
        limit rate 6/minute burst 10 packets log prefix "REHEARSAL-EGRESS-DROP " counter
        counter
    }
    chain forward {
        type filter hook forward priority -50; policy drop;
    }
}
EOF
}

render_unit() {
    local nftbin; nftbin=$(command -v "$NFT" || echo "$NFT")
    cat <<EOF
[Unit]
Description=Rehearsal host egress lockdown (temporary host only)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$nftbin -f $RULES_FILE
ExecStartPost=$nftbin list table inet $TABLE

[Install]
WantedBy=multi-user.target
EOF
}

table_state() { $NFT -s list table inet "$TABLE"; }
table_sha() { local t; t=$(table_state 2>/dev/null) || return 1; sha256sum <<<"$t" | cut -d' ' -f1; }
file_sha() { sha256sum < "$1" | cut -d' ' -f1; }

ipv6_posture() {
    local a d v any_dis=1 enabled_scope=
    echo "IPv6 posture (read from the kernel, not assumed):"
    for d in all default ${IFACE:+$IFACE}; do
        v=$(cat "$PROC_SYS/net/ipv6/conf/$d/disable_ipv6" 2>/dev/null || echo unreadable)
        echo "  net.ipv6.conf.$d.disable_ipv6 = $v"
        [[ $v == 1 ]] || any_dis=0
    done
    a=$(awk '$6 != "lo" {n++; print "    " $6 " " $1 " scope=" $4} END {if (!n) print "    (none outside loopback)"}' "$PROC_NET/if_inet6" 2>/dev/null || echo "    (cannot read if_inet6)")
    echo "  IPv6 addresses outside loopback (all scopes):"; echo "$a"
    echo "  IPv6 routes: $($IP -6 route show 2>/dev/null | tr '\n' ';' || true)"
    if ((any_dis)) && [[ $a == *"(none outside loopback)"* ]]; then
        IPV6_STATE=disabled; echo "  => IPv6 is DISABLED on this host (sysctl + no addresses)."
    else
        IPV6_STATE=enabled; echo "  => IPv6 is NOT demonstrably disabled: the probe must be run with --sink6 (including TCP 443 and 444) and the result recorded."
    fi
}

inventory() {
    echo "Existing firewall state on this host (nothing below is changed or removed):"
    echo "  nftables tables: $($NFT list tables 2>/dev/null | tr '\n' ';' | sed 's/;$//' || echo none)"
    if command -v ufw >/dev/null; then echo "  ufw: $(ufw status 2>/dev/null | head -1)"; else echo "  ufw: not installed"; fi
    echo "  existing rules (sha256 of 'nft list ruleset'): $($NFT list ruleset 2>/dev/null | sha256sum | cut -d' ' -f1)"
    echo "  IPv4 default gateway: ${GATEWAY:-none found}   interface: ${IFACE:-none found}   DHCP server used if 'dhcp' is approved: ${DHCP_SERVER:-none}"
    echo "  current SSH client: ${SSH_CONNECTION%% *}"
    ipv6_posture
}

app_active() { # prints a reason and returns 0 if the application looks active or secrets are staged
    local why=
    [[ ! -e $SECRETS_FILE ]] || why="the secrets file $SECRETS_FILE exists"
    if [[ -z $why && -n $SVC_USER ]]; then
        if id "$SVC_USER" >/dev/null 2>&1 && pgrep -u "$SVC_USER" >/dev/null 2>&1; then why="a process is running as $SVC_USER"; fi
    fi
    if [[ -z $why && -n $APP_UNIT ]]; then
        if $SYSTEMCTL is-active --quiet "$APP_UNIT" 2>/dev/null; then why="$APP_UNIT is active"; fi
    fi
    [[ -n $why ]] || return 1
    echo "$why"
}

preflight_apply() {
    [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
    local why
    if why=$(app_active); then err "Refusing: $why. The lockdown is applied (or changed) only on an empty host, before any secrets or application."; exit 1; fi
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        local client=${SSH_CONNECTION%% *}
        [[ $client == "$OPS_IP" ]] || { err "This SSH session comes from $client, not OPS_IP ($OPS_IP). Applying would lock you out. Refusing."; exit 1; }
    else
        warn "No SSH_CONNECTION found: cannot confirm this session comes from OPS_IP. Confirm you are on the console or the OPS_IP address."
    fi
    command -v "$NFT" >/dev/null || { err "nft is not installed (apt-get install nftables)."; exit 1; }
}

print_exceptions() {
    echo "Exceptions requiring explicit client approval (approved here: ${APPROVED_EXCEPTIONS:-none}):"
    echo "  dhcp          $(has_exc dhcp && echo "LOADED: UDP 68<->67 on $IFACE with $DHCP_SERVER and 255.255.255.255" || echo "not loaded: the IPv4 lease cannot be renewed; record the lease time and keep the host short-lived")"
    echo "  nd            $(has_exc nd && echo "LOADED: IPv6 neighbour discovery on $IFACE, link-local only" || echo "not loaded: IPv6 cannot work on the link (fine if IPv6 is disabled)")"
    echo "  icmp-related  $(has_exc icmp-related && echo "LOADED: ICMP unreachable/time-exceeded related to flows with $OPS_IP and $DB_IP only" || echo "not loaded: path-MTU errors for approved flows are dropped")"
}

cmd_plan() {
    local tmp; tmp=$(mktemp); render_rules > "$tmp"
    if $NFT -c -f "$tmp"; then ok "Syntax check passed (nft -c): the rule set is valid and was NOT loaded."; else rm -f "$tmp"; err "The generated rule set did not pass nft -c. Nothing was changed."; exit 1; fi
    rm -f "$tmp"
    echo; inventory; echo
    echo "Operator access: $OPS_IP -> TCP $OPS_PORTS    Database: $DB_IP:$DB_PORT"
    print_exceptions; echo
    echo "Rule set that apply would load (and save to $RULES_FILE):"
    render_rules | sed 's/^/    /'
}

# Everything below runs AFTER the rules are loaded. Any failure leaves them loaded (fail closed), writes no state
# record, and exits non-zero.
persist_fail() { err "$1"; err "The rules REMAIN LOADED (fail closed) but persistence is NOT established and no state record was written: status and require will fail. Fix the cause and run apply again, or delete and recreate this empty host."; exit 1; }

cmd_apply() {
    preflight_apply
    cmd_plan
    echo
    warn "There is NO rollback timer. Check OPS_IP ($OPS_IP) is YOUR current address before you continue."
    read -rp "Type LOCKDOWN to apply these rules to this host: " c || c=
    [[ $c == LOCKDOWN ]] || { echo "Cancelled. Nothing changed."; exit 0; }
    local want have
    want=$(mktemp); render_rules > "$want"
    rm -f "$STATE_FILE"       # any earlier success record is void from here on
    ( umask 077; cp "$want" "$RULES_FILE" ) || { rm -f "$want"; err "Could not write $RULES_FILE. Nothing was loaded."; exit 1; }
    chmod 600 "$RULES_FILE"
    cmp -s "$want" "$RULES_FILE" || { rm -f "$want"; err "The saved rules differ from the generated rules. Nothing was loaded."; exit 1; }
    $NFT -c -f "$RULES_FILE" || { rm -f "$want"; err "Saved rules failed the syntax check. Nothing was loaded."; exit 1; }
    rm -f "$want"
    $NFT -f "$RULES_FILE" || persist_fail "Loading the rules failed."
    have=$(table_sha) || persist_fail "The table is not visible after loading."
    local unit_sha=none
    if [[ $INSTALL_UNIT == 1 ]]; then
        local u; u=$(mktemp); render_unit > "$u"
        ( umask 022; cp "$u" "$UNIT_FILE" ) || { rm -f "$u"; persist_fail "Could not write $UNIT_FILE."; }
        chmod 644 "$UNIT_FILE"
        cmp -s "$u" "$UNIT_FILE" || { rm -f "$u"; persist_fail "The saved unit differs from the generated unit."; }
        rm -f "$u"
        $SYSTEMCTL daemon-reload || persist_fail "systemctl daemon-reload failed."
        $SYSTEMCTL enable rehearsal-egress.service >/dev/null || persist_fail "systemctl enable failed: the rules would NOT survive a reboot."
        [[ $($SYSTEMCTL is-enabled rehearsal-egress.service) == enabled ]] || persist_fail "rehearsal-egress.service is not reported as 'enabled'."
        unit_sha=$(file_sha "$UNIT_FILE")
    fi
    ( umask 077; printf 'table %s\nrules %s\nunit %s\nexceptions %s\n' "$have" "$(file_sha "$RULES_FILE")" "$unit_sha" "${APPROVED_EXCEPTIONS:-none}" > "$STATE_FILE" ) \
        || persist_fail "Could not write the state record $STATE_FILE."
    chmod 600 "$STATE_FILE"
    ok "Rules loaded atomically, saved, checked against what was generated, and recorded in $STATE_FILE."
    echo "Persistence is configured, NOT proven: the boot and failure behaviour must be demonstrated on this host (egress-plan.md, step 5) before secrets."
    echo "Next: run the verification from rehearsal/egress-plan.md (sink + probe) BEFORE staging any secrets."
}

# check_all: prints PASS/FAIL lines unless QUIET; sets BAD. Every system call's status is checked.
check_all() {
    BAD=0
    local st want key val line out rc
    st=$(table_state 2>&1) || { say "FAIL  table inet $TABLE is NOT loaded or cannot be read: the host is not locked down"; BAD=1; return; }
    local ch
    for ch in input output forward; do
        if grep -A2 "chain $ch {" <<<"$st" | grep -q "policy drop"; then say "PASS  chain $ch: default policy drop"; else say "FAIL  chain $ch is not default-drop"; BAD=1; fi
    done
    local m a
    m=$(grep -n 'daddr 169.254.169.254' <<<"$st" | head -1 | cut -d: -f1 || true)
    a=$(grep -n 'accept' <<<"$(sed -n '/chain output/,/chain forward/p' <<<"$st")" | head -1 | cut -d: -f1 || true)
    if [[ -n $m ]] && grep -q 'ip6 daddr fd00:ec2::254' <<<"$st"; then say "PASS  both metadata drop rules are present"; else say "FAIL  a metadata drop rule is missing"; BAD=1; fi
    if [[ -n $m && -n $a ]] && (( $(grep -n 'daddr 169.254.169.254' <<<"$(sed -n '/chain output/,/chain forward/p' <<<"$st")" | head -1 | cut -d: -f1) < a )); then say "PASS  metadata drops come before every accept in output"; else say "FAIL  metadata drops are not ahead of the accepts"; BAD=1; fi
    # persisted state must exist and agree with what is loaded and what is on disk
    if [[ -r $STATE_FILE ]]; then
        local s_table s_rules s_unit
        s_table=$(awk '$1=="table"{print $2}' "$STATE_FILE"); s_rules=$(awk '$1=="rules"{print $2}' "$STATE_FILE"); s_unit=$(awk '$1=="unit"{print $2}' "$STATE_FILE")
        [[ $(table_sha) == "$s_table" ]] && say "PASS  loaded rules match the set recorded when apply completed" || { say "FAIL  loaded rules differ from the recorded set"; BAD=1; }
        if [[ -r $RULES_FILE && $(file_sha "$RULES_FILE") == "$s_rules" ]]; then say "PASS  saved rules file ($RULES_FILE) is unchanged since apply"; else say "FAIL  saved rules file is missing or changed since apply"; BAD=1; fi
        if [[ $INSTALL_UNIT == 1 ]]; then
            if [[ -r $UNIT_FILE && $(file_sha "$UNIT_FILE") == "$s_unit" ]]; then say "PASS  unit file is unchanged since apply"; else say "FAIL  unit file is missing or changed since apply"; BAD=1; fi
        fi
    else
        say "FAIL  no state record ($STATE_FILE): apply has not completed successfully on this host"; BAD=1
    fi
    if [[ $INSTALL_UNIT == 1 ]]; then
        out=$($SYSTEMCTL is-enabled rehearsal-egress.service 2>&1) || true
        [[ $out == enabled ]] && say "PASS  rehearsal-egress.service is enabled (rules reload at boot; boot ordering still to be demonstrated)" || { say "FAIL  rehearsal-egress.service is not enabled ($out)"; BAD=1; }
        # legacy fail-open timers: the inventory itself must succeed, then nothing may match
        local inv_ok=1 legacy=
        for line in "list-units --all --no-legend --plain" "list-timers --all --no-legend --plain" "list-unit-files --no-legend --plain"; do
            if out=$($SYSTEMCTL $line 2>&1); then legacy+=$(grep -iE 'fw-rollback|rollback' <<<"$out" || true); else inv_ok=0; say "FAIL  systemctl $line failed: the legacy-timer inventory is not confirmed"; BAD=1; fi
        done
        if ((inv_ok)); then
            if [[ -n $legacy ]]; then say "FAIL  a rollback unit/timer exists (a fail-open path): remove it. Found: $(tr '\n' ';' <<<"$legacy")"; BAD=1; else say "PASS  no rollback/fw-rollback unit, unit file or timer exists (inventory succeeded)"; fi
        fi
        if command -v atq >/dev/null; then
            if out=$(atq 2>&1); then [[ -z $out ]] && say "PASS  no 'at' jobs are queued" || { say "FAIL  'at' jobs are queued: $(tr '\n' ';' <<<"$out")"; BAD=1; }; else say "FAIL  atq failed: scheduled jobs not confirmed"; BAD=1; fi
        fi
    fi
    return 0
}

cmd_status() {
    [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
    check_all
    echo; ipv6_posture
    echo; echo "Counters (drops show what was blocked; the evidence is these AND no packets at the sink):"
    $NFT list table inet "$TABLE" | grep -E 'counter|chain' | sed 's/^/  /' || true
    ((BAD == 0)) || { err "Status: NOT as intended."; exit 1; }
    ok "Status: as intended."
}

# Silent gate for the application's start procedure (ExecStartPre). Exit 0 only if every status check passes.
cmd_require() {
    [[ $EUID -eq 0 ]] || exit 1
    QUIET=1; check_all
    ((BAD == 0)) || { err "egress-lockdown require: the host is NOT locked down as approved. Not starting."; exit 1; }
}

cmd_remove() {
    [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
    local why
    if why=$(app_active); then err "Refusing to remove the lockdown: $why. Never weaken it under a live application or staged secrets: delete the host instead."; exit 1; fi
    warn "This removes ONLY table inet $TABLE and its unit. The host will no longer be locked down."
    read -rp "Type REMOVE to continue: " c || c=
    [[ $c == REMOVE ]] || { echo "Cancelled."; exit 0; }
    $NFT delete table inet "$TABLE" 2>/dev/null || true
    if [[ $INSTALL_UNIT == 1 ]]; then $SYSTEMCTL disable rehearsal-egress.service >/dev/null 2>&1 || true; rm -f "$UNIT_FILE"; $SYSTEMCTL daemon-reload; fi
    rm -f "$RULES_FILE" "$STATE_FILE"
    ok "Removed."
}

main() {
    local mode=${1:-plan}
    case $mode in plan|apply|status|require|remove) ;; *) echo "Usage: $0 [plan|apply|status|require|remove]"; exit 1 ;; esac
    validate "$mode"
    detect_network
    [[ $mode == plan || $mode == apply ]] && need_net_for_exceptions
    case $mode in plan) cmd_plan ;; apply) cmd_apply ;; status) cmd_status ;; require) cmd_require ;; remove) cmd_remove ;; esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
