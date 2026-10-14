#!/usr/bin/env python3
"""Tiny TCP peer for the firewall tests (run inside Linux network namespaces; synthetic only).
  listen ADDR PORT LOG   accept connections, append every received line to LOG, and push 'P<n>' to the peer every 0.3 s
  connect SRC DST PORT LOG   connect from address SRC to DST:PORT, send 'C<n>' every 0.3 s, append received lines to LOG
Each line written to LOG is one received line, so 'wc -l' shows whether anything is still arriving."""
import socket, sys, threading, time

def pump(conn, log, tag):
    n, nxt = 0, 0.0
    with open(log, "a", buffering=1) as f:
        while True:
            now = time.time()
            if now >= nxt:
                nxt = now + 0.3
                try:
                    conn.settimeout(0.2); conn.sendall(f"{tag}{n}\n".encode()); n += 1
                except OSError:
                    pass
            try:
                conn.settimeout(max(0.05, nxt - time.time()))
                data = conn.recv(4096)
                if not data:
                    time.sleep(0.3); continue
                for line in data.decode(errors="replace").splitlines():
                    f.write(line + "\n")
            except socket.timeout:
                pass
            except OSError:
                time.sleep(0.3)

def main():
    mode = sys.argv[1]
    if mode == "listen":
        addr, port, log = sys.argv[2], int(sys.argv[3]), sys.argv[4]
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((addr, port)); s.listen(8)
        print("listening", addr, port, flush=True)
        while True:
            c, _ = s.accept()
            threading.Thread(target=pump, args=(c, log, "P"), daemon=True).start()
    elif mode == "connect":
        src, dst, port, log = sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
        s = socket.socket(); s.bind((src, 0)); s.connect((dst, port))
        print("connected", src, dst, port, flush=True)
        pump(s, log, "C")

main()
