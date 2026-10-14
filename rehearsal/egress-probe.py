#!/usr/bin/env python3
"""Outbound probe for the egress verification. It only ever contacts the addresses you give it (the test sink
and the database). It resolves no names, contacts no DBS, payment, email, AI, evidence or provider endpoint,
and never the cloud metadata address.

Run it twice, from two hosts:
  1. BASELINE on the control host (crm-rehearsal-pitr-src), proving the sink is reachable at all:
       python3 -I rehearsal/egress-probe.py --expect open --sink4 <SINK_V4> [--sink6 <SINK_V6>]
  2. On the locked-down application host, as the service user (the identity that runs the application):
       sudo -u <SVC_USER> python3 -I rehearsal/egress-probe.py --expect blocked --sink4 <SINK_V4> [--sink6 <SINK_V6>] \\
            --db-ip 172.26.9.114 --db-port 5432

A "blocked" result is only half the evidence. The other half is the firewall's drop counters / log
(egress-lockdown.sh status) AND the sink's own log showing no hit from the application host. A timeout alone
is not proof.
"""
import argparse, errno, socket, sys

PAYLOAD = b"rehearsal-egress-probe (harmless synthetic datagram)\n"
fails = 0


def result(ok, text):
    global fails
    if not ok:
        fails += 1
    print(("PASS  " if ok else "FAIL  ") + text, flush=True)


def tcp(family, addr, port, expect, label):
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(3)
    try:
        s.connect((addr, port))
        connected, why = True, "connected"
    except OSError as e:
        connected, why = False, (errno.errorcode.get(e.errno, "") or str(e)) if e.errno else str(e)
    finally:
        s.close()
    if expect == "open":
        result(connected, f"{label}: connection {'succeeded' if connected else 'FAILED (' + why + ')'}")
    else:
        result(not connected, f"{label}: {'connection SUCCEEDED (it must not)' if connected else 'blocked (' + why + ')'}")


def udp(family, addr, port, expect, label):
    s = socket.socket(family, socket.SOCK_DGRAM)
    s.settimeout(3)
    try:
        s.sendto(PAYLOAD, (addr, port))
        try:
            s.recvfrom(2048)
            replied, why = True, "reply received"
        except socket.timeout:
            replied, why = False, "no reply"
        except OSError as e:
            replied, why = False, errno.errorcode.get(e.errno, str(e))
    except OSError as e:
        replied, why = False, errno.errorcode.get(e.errno, str(e))
    finally:
        s.close()
    if expect == "open":
        result(replied, f"{label}: {why}")
    else:
        result(not replied, f"{label}: {'reply RECEIVED (it must not)' if replied else 'no reply (' + why + '); confirm the sink log shows no datagram'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--expect", choices=["open", "blocked"], required=True)
    ap.add_argument("--sink4", required=True, help="sink IPv4 address")
    ap.add_argument("--sink6", help="sink IPv6 address (omit only if the host has no IPv6 at all)")
    ap.add_argument("--db-ip")
    ap.add_argument("--db-port", type=int, default=5432)
    a = ap.parse_args()
    for ip in (a.sink4, a.db_ip):
        if ip:
            socket.inet_pton(socket.AF_INET, ip)
    if a.sink6:
        socket.inet_pton(socket.AF_INET6, a.sink6)

    print(f"Egress probe, expecting: {a.expect}")
    tcp(socket.AF_INET, a.sink4, 443, a.expect, f"IPv4 tcp {a.sink4}:443")
    tcp(socket.AF_INET, a.sink4, 444, a.expect, f"IPv4 tcp {a.sink4}:444")
    udp(socket.AF_INET, a.sink4, 5353, a.expect, f"IPv4 udp {a.sink4}:5353 (harmless payload)")
    if a.sink6:
        tcp(socket.AF_INET6, a.sink6, 443, a.expect, f"IPv6 tcp [{a.sink6}]:443")
        udp(socket.AF_INET6, a.sink6, 5353, a.expect, f"IPv6 udp [{a.sink6}]:5353 (harmless payload)")
    else:
        print("NOTE  no --sink6 given: IPv6 was not tested. Only acceptable if the host has no IPv6 address at all.")
    if a.db_ip:
        tcp(socket.AF_INET, a.db_ip, a.db_port, "open", f"database {a.db_ip}:{a.db_port} (the one permitted path)")
    print("NOTE  the cloud metadata address is deliberately NOT contacted. Its block is shown by the rule order and counters.")
    if fails:
        print(f"{fails} check(s) did not match the expectation.")
        sys.exit(1)
    print("All checks matched the expectation.")


if __name__ == "__main__":
    main()
