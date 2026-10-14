#!/usr/bin/env python3
"""Non-provider test sink for the egress verification. Run on crm-rehearsal-pitr-restore (never on the
application host). It listens on harmless ports and LOGS every connection or datagram it receives, with the
source address, so "nothing arrived" can be shown from this side as well as from the firewall counters.

    sudo python3 -I rehearsal/egress-sink.py                      # TCP 443 and 444, UDP 5353, IPv4 and IPv6
    sudo python3 -I rehearsal/egress-sink.py --tcp 443 --udp 5353 --bind4 10.0.0.5 --no-ipv6

It reads nothing it receives (TCP connections are accepted and closed; UDP datagrams are echoed back only so a
baseline from the control host can show the path is open). It contacts nobody and resolves no names.
Stop with Ctrl-C: it prints a summary of the hits per port and source.
"""
import argparse, collections, datetime, selectors, socket, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tcp", type=int, action="append", help="TCP port to listen on (repeatable; default 443 and 444)")
    ap.add_argument("--udp", type=int, action="append", help="UDP port to listen on (repeatable; default 5353)")
    ap.add_argument("--bind4", default="0.0.0.0")
    ap.add_argument("--bind6", default="::")
    ap.add_argument("--no-ipv6", action="store_true")
    a = ap.parse_args()
    tcp_ports = a.tcp or [443, 444]
    udp_ports = a.udp or [5353]

    sel = selectors.DefaultSelector()
    hits = collections.Counter()

    def listen(family, kind, addr, port):
        s = socket.socket(family, kind)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.bind((addr, port))
        if kind == socket.SOCK_STREAM:
            s.listen(16)
        s.setblocking(False)
        sel.register(s, selectors.EVENT_READ, (kind, port))
        fam = "v6" if family == socket.AF_INET6 else "v4"
        print(f"listening {fam} {'tcp' if kind == socket.SOCK_STREAM else 'udp'} {addr}:{port}", flush=True)

    families = [(socket.AF_INET, a.bind4)] + ([] if a.no_ipv6 else [(socket.AF_INET6, a.bind6)])
    for fam, addr in families:
        for p in tcp_ports:
            try:
                listen(fam, socket.SOCK_STREAM, addr, p)
            except OSError as e:
                print(f"cannot listen {addr}:{p}/tcp: {e}", file=sys.stderr)
        for p in udp_ports:
            try:
                listen(fam, socket.SOCK_DGRAM, addr, p)
            except OSError as e:
                print(f"cannot listen {addr}:{p}/udp: {e}", file=sys.stderr)
    if not sel.get_map():
        sys.exit("nothing to listen on")

    try:
        while True:
            for key, _ in sel.select():
                kind, port = key.data
                now = datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S.%f")[:-3]
                if kind == socket.SOCK_STREAM:
                    conn, src = key.fileobj.accept()
                    conn.close()
                    proto = "tcp"
                else:
                    data, src = key.fileobj.recvfrom(2048)
                    try:
                        key.fileobj.sendto(b"sink-reply\n", src)
                    except OSError:
                        pass
                    proto = "udp"
                hits[(proto, port, src[0])] += 1
                print(f"{now}Z HIT {proto}/{port} from {src[0]}", flush=True)
    except KeyboardInterrupt:
        pass
    print("\nSummary of everything received (empty means nothing arrived):")
    if not hits:
        print("  (no hits)")
    for (proto, port, src), n in sorted(hits.items()):
        print(f"  {proto}/{port} from {src}: {n}")


if __name__ == "__main__":
    main()
