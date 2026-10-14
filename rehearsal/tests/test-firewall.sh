#!/usr/bin/env bash
# Regression tests for rehearsal/egress-lockdown.sh and egress-probe.py (finding F5) in Linux network namespaces on the machine
# running the test (IPv4 only if the kernel has no IPv6). Nothing outside the namespaces is touched. Run as root.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd); R=$REPO/rehearsal
PASSN=0; FAILN=0
check() { if [[ $2 == 0 ]]; then PASSN=$((PASSN+1)); echo "  ok    $1"; else FAILN=$((FAILN+1)); echo "  FAIL  $1"; fi; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }
T=$(mktemp -d /run/fwtest.XXXXXX); STUB=$T/stub; mkdir -p "$STUB"
HOSTNS=rapp; NETNS=rnet
APP=198.51.100.1; OPS=198.51.100.10; DB=198.51.100.20; SINK=198.51.100.30; OTHER=198.51.100.40; DHCPS=198.51.100.50
cleanup() { for p in $(cat "$T"/pids 2>/dev/null); do kill "$p" 2>/dev/null; done; ip netns del $HOSTNS 2>/dev/null; ip netns del $NETNS 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
ip netns add $HOSTNS; ip netns add $NETNS
ip link add vA type veth peer name vB; ip link set vA netns $HOSTNS; ip link set vB netns $NETNS
H() { ip netns exec $HOSTNS "$@"; }; N() { ip netns exec $NETNS "$@"; }
H ip addr add $APP/24 dev vA; H ip link set vA up; H ip link set lo up
N ip link set vB up; N ip link set lo up; for a in $OPS $DB $SINK $OTHER $DHCPS; do N ip addr add $a/24 dev vB; done
H ip route add default via $OPS dev vA
bg() { "$@" >>"$T/bg.log" 2>&1 & echo $! >>"$T/pids"; }
HAS6=$(H sh -c '[ -e /proc/net/if_inet6 ] && echo yes || echo no')

# fake systemctl: behaviour controlled by files in $STUB
cat >"$T/systemctl" <<'SC'
#!/usr/bin/env bash
S=$STUB_DIR
case $1 in
  daemon-reload) [[ -e $S/daemon_fail ]] && exit 1; exit 0 ;;
  enable) [[ -e $S/enable_fail ]] && { echo "Failed to enable" >&2; exit 1; }; touch "$S/enabled"; exit 0 ;;
  is-enabled) if [[ -e $S/enabled ]]; then echo enabled; exit 0; else echo disabled; exit 1; fi ;;
  is-active) [[ -e $S/app_active ]] && exit 0; exit 3 ;;
  list-units|list-timers|list-unit-files) [[ -e $S/list_fail ]] && { echo "Failed to connect to bus" >&2; exit 1; }; cat "$S/legacy" 2>/dev/null; exit 0 ;;
  disable) rm -f "$S/enabled"; exit 0 ;;
esac
exit 0
SC
chmod +x "$T/systemctl"
export STUB_DIR=$STUB
ENVV=(OPS_IP=$OPS DB_IP=$DB SSH_CONNECTION="$OPS 5555 $APP 22" SYSTEMCTL=$T/systemctl RULES_FILE=$T/rules.nft UNIT_FILE=$T/unit.service STATE_FILE=$T/state SECRETS_FILE=$T/runtime.env)
LK() { H env "${ENVV[@]}" "$@" bash "$R/egress-lockdown.sh"; }   # LK [extra env...]   (mode as following args handled by callers)
lk() { local mode=$1; shift; H env "${ENVV[@]}" "$@" bash "$R/egress-lockdown.sh" "$mode"; }
cnt() { wc -l <"$1" 2>/dev/null || echo 0; }
grow() { local a b; a=$(cnt "$1"); sleep "${2:-2}"; b=$(cnt "$1"); echo $((b - a)); }

echo "== setup: peers and long-lived connections BEFORE the lockdown"
bg ip netns exec $NETNS python3 -I "$R/tests/netns_peer.py" listen $SINK 8443 "$T/sink8443.log"
bg ip netns exec $NETNS python3 -I "$R/tests/netns_peer.py" listen $DB 5432 "$T/db.log"
bg ip netns exec $NETNS python3 -I "$R/egress-sink.py" --no-ipv6 --bind4 $SINK
bg ip netns exec $HOSTNS python3 -I "$R/tests/netns_peer.py" listen $APP 22 "$T/app22.log"
bg ip netns exec $HOSTNS python3 -I "$R/tests/netns_peer.py" listen $APP 2222 "$T/app2222.log"
sleep 1
bg ip netns exec $HOSTNS python3 -I "$R/tests/netns_peer.py" connect $APP $SINK 8443 "$T/appout.log"     # app-started, unapproved destination
bg ip netns exec $HOSTNS python3 -I "$R/tests/netns_peer.py" connect $APP $DB 5432 "$T/appdb.log"       # app-started, approved database
bg ip netns exec $NETNS python3 -I "$R/tests/netns_peer.py" connect $OPS $APP 22 "$T/ops.log"           # operator session
bg ip netns exec $NETNS python3 -I "$R/tests/netns_peer.py" connect $OTHER $APP 2222 "$T/other.log"     # unapproved inbound session
sleep 2
check "before: operator session carries data both ways" $([[ $(cnt $T/ops.log) -gt 3 && $(cnt $T/app22.log) -gt 3 ]]; echo $?)
check "before: unapproved inbound session receives pushed data" $([[ $(cnt $T/other.log) -gt 3 ]]; echo $?)
check "before: app-started outbound connection reaches the sink" $([[ $(cnt $T/sink8443.log) -gt 3 ]]; echo $?)

echo "== plan changes nothing and shows scope"
lk plan >"$T/plan.txt" 2>&1; check "plan exits 0" $?; check "no table loaded by plan" $([[ -z $(H nft list tables) ]]; echo $?)
check "plan lists exceptions as not loaded by default" $(grep -q 'not loaded: the IPv4 lease cannot be renewed' "$T/plan.txt"; echo $?)
check "plan reports the IPv6 posture" $(grep -q 'IPv6 posture' "$T/plan.txt"; echo $?)
check "rules: no unconditional established-reply accept in either chain" $(! grep -E '^\s+ct direction reply ct state established accept' "$T/plan.txt"; echo $?)
check "rules: no DHCP/ND/ICMP rule by default" $(! grep -E 'udp dport 67|nd-neighbor|icmp type' "$T/plan.txt"; echo $?)
lk plan APPROVED_EXCEPTIONS=dhcp,nd,icmp-related IFACE=vA DHCP_SERVER=$DHCPS >"$T/plan2.txt" 2>&1; check "plan with all three exceptions passes nft -c" $?
check "exception rules name interface vA, server and peers" $(grep -q 'oifname "vA" udp sport 68 udp dport 67 ip daddr { '$DHCPS', 255.255.255.255 }' "$T/plan2.txt" && grep -q 'icmp type { destination-unreachable, time-exceeded }' "$T/plan2.txt"; echo $?)
lk plan APPROVED_EXCEPTIONS=bogus >/dev/null 2>&1; check "unknown exception name refused" $(( $? == 0 ))

echo "== apply that fails to enable persistence fails closed"
touch $STUB/enable_fail
lk apply <<<"LOCKDOWN" >"$T/apply1.txt" 2>&1; RC=$?
check "apply exits non-zero" $((RC == 0)); check "  says the rules remain loaded and persistence is NOT established" $(grep -q 'REMAIN LOADED' "$T/apply1.txt"; echo $?)
check "  rules ARE loaded (fail closed)" $(H nft list table inet rehearsal_egress >/dev/null 2>&1; echo $?)
check "  no state record written" $([[ ! -e $T/state ]]; echo $?)
lk status >"$T/st1.txt" 2>&1; check "  status fails" $(( $? == 0 )); lk require >/dev/null 2>&1; check "  require fails" $(( $? == 0 ))
echo "== a clean apply, then status and require pass"
rm -f $STUB/enable_fail
lk apply <<<"LOCKDOWN" >"$T/apply2.txt" 2>&1; check "apply exits 0" $?
check "state record, rules file and unit file exist" $([[ -s $T/state && -s $T/rules.nft && -s $T/unit.service ]]; echo $?)
check "rules file is mode 600, state is mode 600" $([[ $(stat -c %a $T/rules.nft) == 600 && $(stat -c %a $T/state) == 600 ]]; echo $?)
lk status >"$T/st2.txt" 2>&1; check "status passes" $?; lk require >/dev/null 2>&1; check "require passes (silent)" $?

echo "== connections that were open before the lockdown"
sleep 1
S1=$(cnt $T/ops.log); A1=$(cnt $T/app22.log); sleep 2
echo "    (ops.log $S1 -> $(cnt $T/ops.log), app22.log $A1 -> $(cnt $T/app22.log))"; check "operator session still works both ways" $([[ $(cnt $T/ops.log) -gt $S1 && $(cnt $T/app22.log) -gt $A1 ]]; echo $?)
O1=$(cnt $T/other.log); K1=$(cnt $T/sink8443.log); D1=$(cnt $T/appdb.log); DB1=$(cnt $T/db.log); sleep 3
check "UNAPPROVED inbound session receives nothing more (no replies/queued pushes leak)" $([[ $(cnt $T/other.log) == "$O1" ]]; echo $?)
check "app-started connection to the sink delivers nothing more" $([[ $(cnt $T/sink8443.log) == "$K1" ]]; echo $?)
echo "    (appdb.log $D1 -> $(cnt $T/appdb.log), db.log $DB1 -> $(cnt $T/db.log))"; check "app-started connection to the database continues both ways" $([[ $(cnt $T/appdb.log) -gt $D1 && $(cnt $T/db.log) -gt $DB1 ]]; echo $?)
check "output drop counter rose (the blocked pushes were counted)" $(H nft list chain inet rehearsal_egress output | awk '/REHEARSAL-EGRESS-DROP/ {for(i=1;i<=NF;i++) if($i=="packets"){ if ($(i+1)>0) f=1 }} END{exit !f}'; echo $?)

echo "== probes (as blocked) and drops"
H python3 -I "$R/egress-probe.py" --expect blocked --sink4 $SINK --db-ip $DB >"$T/probe.txt" 2>&1; RC=$?
check "probe: all outbound blocked, database reachable" $RC
check "probe covers tcp 443, tcp 444 and udp 5353 (IPv4)" $([[ $(grep -c 'IPv4' "$T/probe.txt") -ge 3 ]]; echo $?)
check "probe covers IPv6 tcp 444 or states IPv6 state" $(grep -qE 'IPv6 tcp .*:444|IPv6 state' "$T/probe.txt"; echo $?)
sleep 1; check "the sink logged no hit from the app host" $(! grep -q "HIT .* from $APP" "$T/bg.log"; echo $?)
N python3 -I -c "
import socket
s=socket.socket(); s.settimeout(2)
try: s.connect(('$APP',2223)); print('connected')
except Exception as e: print('blocked')" | grep -q blocked; check "a NEW inbound connection from the unapproved peer is dropped" $?

echo "== probe: IPv6 state is evidence, not an assumption (F5)"
python3 -I - "$R/egress-probe.py" <<'PY'
import importlib.util, os, sys, tempfile
spec = importlib.util.spec_from_file_location("probe", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def mk(all_, default, inet6):
    d = tempfile.mkdtemp(); os.makedirs(d + "/sys/net/ipv6/conf/all"); os.makedirs(d + "/sys/net/ipv6/conf/default"); os.makedirs(d + "/net")
    open(d + "/sys/net/ipv6/conf/all/disable_ipv6", "w").write(all_ + "\n"); open(d + "/sys/net/ipv6/conf/default/disable_ipv6", "w").write(default + "\n")
    if inet6 is not None: open(d + "/net/if_inet6", "w").write(inet6)
    return d + "/sys", d + "/net"
LL = "fe800000000000000000000000000001 02 40 20 80 eth0\n"; LO = "00000000000000000000000000000001 01 80 10 80 lo\n"
cases = [("disabled by sysctl, nothing but lo", mk("1", "1", LO), True),
         ("kernel without IPv6", mk("1", "1", None), True),
         ("enabled, link-local only (no global address)", mk("0", "0", LL + LO), False),
         ("sysctl all=1 but default=0", mk("1", "0", LO), False),
         ("disabled but an address remains", mk("1", "1", LL), False)]
bad = 0
for name, (ps, pn), want in cases:
    got = m.ipv6_state(ps, pn)[0]; ok = got == want; bad += not ok
    print(("  ok    " if ok else "  FAIL  ") + "probe IPv6 state: " + name)
sys.exit(bad)
PY
RC=$?; PASSN=$((PASSN+5-RC)); FAILN=$((FAILN+RC))

echo "== tampering is detected"
cp $T/rules.nft $T/rules.bak; echo "# edited" >>$T/rules.nft; lk status >/dev/null 2>&1; check "edited rules file: status fails" $(( $? == 0 )); lk require >/dev/null 2>&1; check "edited rules file: require fails" $(( $? == 0 )); cp $T/rules.bak $T/rules.nft
cp $T/unit.service $T/unit.bak; echo "# edited" >>$T/unit.service; lk require >/dev/null 2>&1; check "edited unit file: require fails" $(( $? == 0 )); cp $T/unit.bak $T/unit.service
H nft add rule inet rehearsal_egress output ip daddr 198.51.100.99 accept; lk require >/dev/null 2>&1; check "rule added by hand: require fails" $(( $? == 0 ))
lk apply <<<"LOCKDOWN" >/dev/null 2>&1; lk require >/dev/null 2>&1; check "re-apply restores a passing state" $?
rm -f $STUB/enabled; lk require >/dev/null 2>&1; check "unit not enabled: require fails" $(( $? == 0 )); touch $STUB/enabled
echo "== legacy timer inventory"
echo "fw-rollback.timer loaded active waiting" >$STUB/legacy; lk status >"$T/st3.txt" 2>&1; check "fw-rollback timer present: status FAILS" $(( $? == 0 )); check "  and names it" $(grep -q 'fw-rollback' "$T/st3.txt"; echo $?); rm -f $STUB/legacy
touch $STUB/list_fail; lk status >"$T/st4.txt" 2>&1; check "systemctl inventory command fails: status FAILS (was a false PASS)" $(( $? == 0 )); check "  and says the inventory is not confirmed" $(grep -q 'not confirmed' "$T/st4.txt"; echo $?); lk require >/dev/null 2>&1; check "  require fails too" $(( $? == 0 )); rm -f $STUB/list_fail
lk require >/dev/null 2>&1; check "back to passing once the inventory works" $?

echo "== cannot be weakened or re-applied under secrets or a running app"
: >$T/runtime.env
lk remove <<<"REMOVE" >"$T/rm1.txt" 2>&1; check "remove refused with the secrets file present" $(( $? == 0 )); check "  table still loaded" $(H nft list table inet rehearsal_egress >/dev/null 2>&1; echo $?)
lk apply <<<"LOCKDOWN" >/dev/null 2>&1; check "apply refused with the secrets file present" $(( $? == 0 ))
rm -f $T/runtime.env; touch $STUB/app_active
lk remove APP_UNIT=dbs-check.service <<<"REMOVE" >"$T/rm2.txt" 2>&1; check "remove refused while the app unit is active" $(( $? == 0 )); rm -f $STUB/app_active
sleep 60 & SP=$!; ( exec -a x sleep 60 ) & 
id nobody >/dev/null 2>&1 && { H runuser -u nobody -- sleep 30 & sleep 0.5; lk remove SVC_USER=nobody <<<"REMOVE" >/dev/null 2>&1; check "remove refused while a process runs as SVC_USER" $(( $? == 0 )); pkill -u nobody sleep 2>/dev/null; }
kill $SP 2>/dev/null
lk remove <<<"REMOVE" >/dev/null 2>&1; check "remove works on the empty host" $?; check "  table gone and files removed" $([[ -z $(H nft list tables) && ! -e $T/state && ! -e $T/rules.nft ]]; echo $?)

echo "== exceptions load only when approved, scoped to the interface and peers"
lk apply APPROVED_EXCEPTIONS=dhcp,icmp-related IFACE=vA DHCP_SERVER=$DHCPS <<<"LOCKDOWN" >/dev/null 2>&1; check "apply with dhcp,icmp-related" $?
RS=$(H nft list table inet rehearsal_egress)
check "DHCP rule is bound to vA and the named server" $(grep -q "oifname \"vA\" udp sport 68 udp dport 67 ip daddr { $DHCPS, 255.255.255.255 }" <<<"$RS"; echo $?)
check "no ND rule (not approved)" $(! grep -q nd-neighbor <<<"$RS"; echo $?)
lk require >/dev/null 2>&1; check "require passes with exceptions loaded" $?
summary() { echo; echo "RESULT: $PASSN passed, $FAILN failed"; ((FAILN == 0)); }
echo "kernel IPv6 available in this test environment: $HAS6 (IPv6 rules are syntax-checked by nft -c; behaviour needs the real host)"
summary
