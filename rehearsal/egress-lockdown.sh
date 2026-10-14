#!/usr/bin/env bash
# Host firewall for the TEMPORARY rehearsal application host (crm-rehearsal-app). Never for the production
# application server or the database server.
#
#   sudo OPS_IP=<operator public IPv4> bash rehearsal/egress-lockdown.sh plan     # DEFAULT: checks, prints the exact rules, changes nothing
#   sudo OPS_IP=<operator public IPv4> bash rehearsal/egress-lockdown.sh apply     # typed confirmation, then applies and makes it permanent
#   sudo bash rehearsal/egress-lockdown.sh status                                  # re-checks the loaded rules, shows counters
#   sudo bash rehearsal/egress-lockdown.sh remove                                  # removes only this script's table and unit
#
# Why nftables and not ufw: ufw puts "accept established" rules before its own denies, so a connection that
# was already open when the firewall was switched on (staging downloads, a stray session) would keep working.
# These rules decide by the DIRECTION in which a connection was started:
#   - a packet this host sends is allowed only if it is a REPLY to a connection started from outside
#     (the operator's SSH session) or a new/ongoing connection to the database address and port.
#     A connection this host started earlier to anywhere else is "original direction", so it is dropped
#     even though it is established. No connection-tracking flush is needed.
#   - a packet this host receives is allowed only if it is a reply to what this host started, or a
#     connection from the operator address to the approved port(s).
#   - everything else is logged (rate-limited) and dropped, for IPv4 and IPv6 alike (table family "inet").
#   - the cloud metadata addresses are dropped first, by address, and are never contacted by any test.
# Deliberately NOT allowed: DNS, NTP, HTTP/HTTPS to anywhere, package mirrors. The application reaches the
# database by IP. Any exception needs its own approval first. DHCP lease renewal to the default gateway and
# IPv6 neighbour discovery (link-local only) are allowed so the host keeps its address; they reach no provider.
#
# No safety-net timer is used. A timer that disables the firewall would be a fail-open path, and this host
# holds no data or secrets when the rules are applied. If management access is lost, delete and recreate the
# (empty) host. To avoid that, `apply` refuses unless the current SSH session comes from OPS_IP.
#
# Order: stage the package WITHOUT secrets -> apply this -> verify -> stage secrets. `apply` refuses if the
# secrets file already exists. The rules are loaded atomically, saved to /etc and reloaded at boot by a unit
# that runs before the network comes up; after a reboot, re-run `status` before trusting it.
#
# Environment
#   OPS_IP      operator public IPv4 (required)
#   DB_IP       default 172.26.9.114      DB_PORT   default 5432
#   OPS_PORTS   default 22                comma list of inbound TCP ports allowed from OPS_IP only (e.g. 22,443)
#   GATEWAY     default: the IPv4 default gateway, read from the routing table
#   SECRETS_FILE default /etc/dbs-check/runtime.env (apply refuses if it exists)
#   RULES_FILE / UNIT_FILE / STATE_FILE   where it writes (defaults under /etc)
set -euo pipefail
case $- in *x*|*v*) echo "Refusing to run with shell tracing on." >&2; exit 1 ;; esac

DB_IP=${DB_IP:-172.26.9.114}
DB_PORT=${DB_PORT:-5432}
OPS_PORTS=${OPS_PORTS:-22}
OPS_IP=${OPS_IP:-}
GATEWAY=${GATEWAY:-}
SECRETS_FILE=${SECRETS_FILE:-/etc/dbs-check/runtime.env}
RULES_FILE=${RULES_FILE:-/etc/rehearsal-egress.nft}
UNIT_FILE=${UNIT_FILE:-/etc/systemd/system/rehearsal-egress.service}
STATE_FILE=${STATE_FILE:-/etc/rehearsal-egress.sha256}
TABLE=rehearsal_egress
NFT=${NFT:-nft}
IP=${IP:-ip}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
INSTALL_UNIT=${INSTALL_UNIT:-1}

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
info() { echo "${CYN}$*${RST}"; }; ok() { echo "${GRN}$*${RST}"; }; warn() { echo "${YEL}$*${RST}"; }; err() { echo "${RED}$*${RST}" >&2; }

valid_ipv4() { local o; [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; local IFS=.; for o in $1; do ((10#$o <= 255)) || return 1; done; }

validate() {
    valid_ipv4 "$DB_IP" || { err "DB_IP is not a valid IPv4 address."; exit 1; }
    [[ $DB_PORT =~ ^[0-9]{1,5}$ ]] && ((DB_PORT >= 1 && DB_PORT <= 65535)) || { err "DB_PORT is not a port."; exit 1; }
    [[ $OPS_PORTS =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || { err "OPS_PORTS must be a comma-separated list of ports."; exit 1; }
    local p; IFS=, read -ra _ports <<<"$OPS_PORTS"
    for p in "${_ports[@]}"; do ((p >= 1 && p <= 65535)) || { err "OPS_PORTS contains an invalid port."; exit 1; }; done
    if [[ ${1:-} != status && ${1:-} != remove ]]; then
        valid_ipv4 "$OPS_IP" || { err "Set OPS_IP to the operator's public IPv4 address."; exit 1; }
        case $OPS_IP in 0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|224.*|240.*|255.*) err "OPS_IP $OPS_IP is not a public address. Refusing: it would open access to a private or special range."; exit 1 ;; esac
        [[ $OPS_IP != "$DB_IP" ]] || { err "OPS_IP must not be the database address."; exit 1; }
    fi
}

detect_gateway() {
    if [[ -z $GATEWAY ]]; then
        GATEWAY=$($IP -4 route show default 2>/dev/null | awk '/^default/ {for (i=1;i<NF;i++) if ($i=="via") {print $(i+1); exit}}') || GATEWAY=
    fi
    [[ -z $GATEWAY ]] || valid_ipv4 "$GATEWAY" || { err "GATEWAY '$GATEWAY' is not an IPv4 address."; exit 1; }
}

# The complete rule set. Everything the host may do is on this page.
render_rules() {
    local ports=${OPS_PORTS//,/, } gw=
    [[ -z $GATEWAY ]] || gw=", $GATEWAY"
    cat <<EOF
# Managed by rehearsal/egress-lockdown.sh. Temporary rehearsal host only. Do not edit by hand.
table inet $TABLE
delete table inet $TABLE
table inet $TABLE {
    chain input {
        type filter hook input priority -50; policy drop;
        iif "lo" accept
        ct state invalid drop
        # replies to connections THIS host started (the only one it may start is the database, see output)
        ct direction reply ct state established accept
        meta l4proto { icmp, ipv6-icmp } ct state related accept
        # operator access: new and ongoing connections from the operator address to the approved ports only
        ip saddr $OPS_IP tcp dport { $ports } ct state new,established accept
        # DHCP replies and IPv6 neighbour discovery from the local link
        udp sport 67 udp dport 68 accept
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } ip6 hoplimit 255 accept
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
        # replies to connections started from outside (the operator's session)
        ct direction reply ct state established accept
        meta l4proto { icmp, ipv6-icmp } ct state related accept
        # the ONE connection this host may start: the database
        ip daddr $DB_IP tcp dport $DB_PORT ct state new,established accept
        # DHCP lease renewal (to the broadcast address and the default gateway) and IPv6 neighbour discovery on the link
        udp sport 68 udp dport 67 ip daddr { 255.255.255.255$gw } accept
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit } ip6 daddr { fe80::/10, ff02::/16 } accept
        # everything else, including connections started earlier to anywhere else: logged (rate-limited) and dropped
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
    cat <<EOF
[Unit]
Description=Rehearsal host egress lockdown (temporary host only)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f $RULES_FILE

[Install]
WantedBy=multi-user.target
EOF
}

table_state() { $NFT -s list table inet "$TABLE" 2>/dev/null; }
table_sha() { table_state | sha256sum | cut -d' ' -f1; }

inventory() {
    echo "Existing firewall state on this host (nothing below is changed or removed):"
    echo "  nftables tables: $($NFT list tables 2>/dev/null | tr '\n' ';' | sed 's/;$//' || echo none)"
    if command -v ufw >/dev/null; then echo "  ufw: $(ufw status 2>/dev/null | head -1)"; else echo "  ufw: not installed"; fi
    echo "  existing rules (sha256 of 'nft list ruleset'): $($NFT list ruleset 2>/dev/null | sha256sum | cut -d' ' -f1)"
    echo "  IPv4 default gateway: ${GATEWAY:-none found (DHCP renewal rule will name only the broadcast address)}"
    echo "  IPv6 addresses (global): $($IP -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
    echo "  current SSH client: ${SSH_CONNECTION%% *}"
}

preflight_apply() {
    [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
    if [[ -e $SECRETS_FILE ]]; then
        err "$SECRETS_FILE already exists. Secrets must be staged AFTER the lockdown is applied and verified. Refusing."; exit 1
    fi
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        local client=${SSH_CONNECTION%% *}
        [[ $client == "$OPS_IP" ]] || { err "This SSH session comes from $client, not OPS_IP ($OPS_IP). Applying would lock you out. Refusing."; exit 1; }
    else
        warn "No SSH_CONNECTION found: cannot confirm this session comes from OPS_IP. Confirm you are on the console or the OPS_IP address."
    fi
    command -v "$NFT" >/dev/null || { err "nft is not installed (apt-get install nftables)."; exit 1; }
}

cmd_plan() {
    local tmp; tmp=$(mktemp); render_rules > "$tmp"
    if $NFT -c -f "$tmp"; then ok "Syntax check passed (nft -c): the rule set is valid and was NOT loaded."; else rm -f "$tmp"; err "The generated rule set did not pass nft -c. Nothing was changed."; exit 1; fi
    rm -f "$tmp"
    echo; inventory; echo
    echo "Operator access: $OPS_IP -> TCP $OPS_PORTS    Database: $DB_IP:$DB_PORT    Gateway (DHCP): ${GATEWAY:-none}"
    echo "Rule set that apply would load (and save to $RULES_FILE):"
    render_rules | sed 's/^/    /'
}

cmd_apply() {
    preflight_apply
    cmd_plan
    echo
    warn "There is NO rollback timer. Check OPS_IP ($OPS_IP) is YOUR current address before you continue."
    read -rp "Type LOCKDOWN to apply these rules to this host: " c || c=
    [[ $c == LOCKDOWN ]] || { echo "Cancelled. Nothing changed."; exit 0; }
    ( umask 077; render_rules > "$RULES_FILE" )
    chmod 600 "$RULES_FILE"
    $NFT -c -f "$RULES_FILE" || { err "Saved rules failed the syntax check. Nothing was loaded."; exit 1; }
    $NFT -f "$RULES_FILE"
    table_state | sha256sum | cut -d' ' -f1 > "$STATE_FILE"; chmod 600 "$STATE_FILE"
    if [[ $INSTALL_UNIT == 1 ]]; then
        render_unit > "$UNIT_FILE"; chmod 644 "$UNIT_FILE"
        $SYSTEMCTL daemon-reload
        $SYSTEMCTL enable rehearsal-egress.service >/dev/null 2>&1 || warn "Could not enable rehearsal-egress.service: the rules are loaded now but would NOT survive a reboot."
    fi
    ok "Rules loaded atomically. The loaded rule set is recorded in $STATE_FILE."
    echo "Next: run the verification from rehearsal/egress-plan.md (sink + probe) BEFORE staging any secrets."
}

cmd_status() {
    [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
    local bad=0 st want have
    st=$(table_state) || { err "Table inet $TABLE is NOT loaded: the host is not locked down."; exit 1; }
    for ch in input output forward; do
        grep -A2 "chain $ch {" <<<"$st" | grep -q "policy drop" && echo "PASS  chain $ch: default policy drop" || { echo "FAIL  chain $ch is not default-drop"; bad=1; }
    done
    [[ $(grep -n 'daddr 169.254.169.254' <<<"$st" | head -1 | cut -d: -f1) -lt $(grep -n 'ip daddr .* tcp dport' <<<"$st" | head -1 | cut -d: -f1) ]] \
        && echo "PASS  metadata drop rules come before every accept in output" || { echo "FAIL  metadata drop rules are not ahead of the accepts"; bad=1; }
    grep -q 'ip6 daddr fd00:ec2::254' <<<"$st" && echo "PASS  IPv6 metadata address is dropped" || { echo "FAIL  no IPv6 metadata drop"; bad=1; }
    want=$(cat "$STATE_FILE" 2>/dev/null || echo missing); have=$(table_sha)
    [[ $want == "$have" ]] && echo "PASS  loaded rules match the set recorded at apply time" || { echo "FAIL  loaded rules differ from the recorded set (or the record is missing)"; bad=1; }
    if [[ $INSTALL_UNIT == 1 ]]; then
        $SYSTEMCTL is-enabled rehearsal-egress.service >/dev/null 2>&1 && echo "PASS  rehearsal-egress.service is enabled (rules reload at boot)" || { echo "FAIL  rehearsal-egress.service is not enabled"; bad=1; }
        if $SYSTEMCTL list-units --all --no-legend 'fw-rollback*' 2>/dev/null | grep -q .; then echo "FAIL  a fw-rollback unit exists: remove it, it is a fail-open path"; bad=1; else echo "PASS  no fw-rollback timer or unit exists (there is no fail-open path)"; fi
    fi
    echo; echo "Counters (drops show what was blocked; the evidence is these AND no packets at the sink):"
    $NFT list table inet "$TABLE" | grep -E 'counter|chain' | sed 's/^/  /'
    ((bad == 0)) || { err "Status: NOT as intended."; exit 1; }
    ok "Status: as intended."
}

cmd_remove() {
    [[ $EUID -eq 0 ]] || { err "Run as root."; exit 1; }
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
    case $mode in plan|apply|status|remove) ;; *) echo "Usage: $0 [plan|apply|status|remove]"; exit 1 ;; esac
    validate "$mode"
    detect_gateway
    case $mode in plan) cmd_plan ;; apply) cmd_apply ;; status) cmd_status ;; remove) cmd_remove ;; esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
