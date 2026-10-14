# Host firewall and egress plan for `crm-rehearsal-app` (review only; nothing has been run)

This is the target-specific, reviewable rule plan that the isolation procedure asks for. It is for the **temporary
rehearsal application host only**, never for the production application server or the database server. No
commands here have been executed. Values in `<angle brackets>` are recorded at provisioning, before use.

No secrets in this file.

## Why host rules

Lightsail's firewall controls **inbound** traffic only, so outbound deny-by-default has to be enforced on the host
itself (`ufw`, IPv4 and IPv6). The rehearsal host has no static IP, so it has no route to the address allowlisted for
DBS, and it receives no DBS, email, payment, evidence, MySQL or AI credentials.

## Values to record at provisioning

| Name | Value |
| --- | --- |
| `OPS_IP` | Ian's public IPv4 address for SSH (and HTTPS, if used) |
| `DB_IP`, `DB_PORT` | `172.26.9.114`, `5432` |
| `SVC_USER` | the service identity that runs the application |
| `SINK_V4`, `SINK_V6` | addresses of `crm-rehearsal-pitr-restore`, used as the non-provider test sink (`SINK_V6` only if the host has one) |
| `CONTROL_HOST` | `crm-rehearsal-pitr-src`, used to prove the sink is reachable (so the application host never has to open general egress) |
| `IFACE` | the host's network interface |

## Cloud (Lightsail) firewall, inbound, for this host

- Remove the default HTTP (80) rule. Keep SSH (22) restricted to `OPS_IP/32`. Add HTTPS (443) only if used, also restricted to `OPS_IP/32`.
- No rule for the application port 5000: it is reachable only from the local reverse proxy.
- Prefer IPv4-only networking for the instance. If it has an IPv6 address, record it; the rules below cover both families either way.

## Sequence

### 1. Stage with network, without secrets

Install Node 22, build tools, PM2 and Chromium dependencies, and run `npm ci --omit=dev`, with **no** `runtime.env`,
no database password and no application secrets on the host yet. Stage the package without starting it.

### 2. Record the baseline (sanitised output)

```
ip -br addr
ip -4 route; ip -6 route
sysctl net.ipv6.conf.all.disable_ipv6
resolvectl status | head -20
sudo ufw status verbose
```

### 3. Lock down, with an automatic safety net

The safety net disables the firewall after 10 minutes if the operator is locked out. It is cancelled in step 5. The
host holds no secrets or data at this point.

```
sudo systemd-run --unit=fw-rollback --on-active=10m /usr/sbin/ufw --force disable
sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default deny outgoing
sudo ufw default deny routed
sudo ufw logging low
sudo ufw allow in on <IFACE> from <OPS_IP> to any port 22 proto tcp
sudo ufw allow out to 172.26.9.114 port 5432 proto tcp
sudo ufw insert 1 deny out to 169.254.169.254
sudo ufw --force enable
```

Deliberately **not** allowed: DNS, NTP, HTTP/HTTPS to anywhere, package mirrors, the cloud metadata address. The
application connects to the database by IP, so no name lookup is needed. Established SSH replies are allowed by
`ufw`'s connection tracking, so the current session survives. Any exception (for example NTP) needs a specific approval first.

### 4. Verify, under the service identity, and record the output

Prove the policy:

```
sudo ufw status verbose                 # Default: deny (incoming), deny (outgoing), deny (routed)
sudo iptables -S | head -20
sudo ip6tables -S | head -20
```

Prove nothing leaves, to the controlled **sink**, never to any provider. On `crm-rehearsal-pitr-restore`, start listeners on
TCP 443, TCP 444 and a UDP port and watch for packets (for example `sudo tcpdump -ni any host <app host private IP>`).
Prove the sink is reachable at all from `CONTROL_HOST` first (baseline), never by opening egress on the application host.
Then, on `crm-rehearsal-app`:

```
sudo -u <SVC_USER> nc -vz -w 3 <SINK_V4> 443        # must fail
sudo -u <SVC_USER> nc -vz -w 3 <SINK_V4> 444        # must fail
sudo -u <SVC_USER> nc -u -w 3 <SINK_V4> 5353 </dev/null   # must show no reply; sink must see no packet
sudo -u <SVC_USER> nc -6 -vz -w 3 <SINK_V6> 443     # IPv6: must fail, or "Network is unreachable" if IPv6 is off
sudo -u <SVC_USER> curl -sS --max-time 3 http://169.254.169.254/   # metadata: must fail
sudo journalctl -k --since "-10 min" | grep 'UFW BLOCK'            # blocked packets, with destination and port
```

A timeout alone is not a pass: the evidence is the matching `UFW BLOCK` entries **and** no packets at the sink. Do not
resolve or connect to DBS, payment, email, AI or evidence endpoints to prove blocking, and do not use public IP-check sites.

Prove the one permitted path (TCP only here; the verified-TLS test is a separate Gate B check with the real Node client):

```
sudo -u <SVC_USER> nc -vz -w 3 172.26.9.114 5432   # must connect
```

### 5. Cancel the safety net, then confirm

```
sudo systemctl stop fw-rollback.timer fw-rollback.service
systemctl list-timers | grep fw-rollback || echo "no rollback timer pending"
sudo ufw status verbose
```

The timer must be gone and `ufw` must still be active.

### 6. Only now stage secrets

Create `/etc/dbs-check/runtime.env` (mode 0600, readable only by `SVC_USER`) and add the database credentials, delivered
through the agreed secure channel. Re-run step 4 after any restart, after staging and again immediately before Gate B.
Any unverified family or path counts as BLOCKED, not safe.

### 7. Teardown

Delete the instance and record the deletion. The host holds only synthetic data and test credentials; revoke the
rehearsal database passwords with `dbserver/create-rehearsal-db.sh cleanup` on the database server.

## What this does not prove

It proves the host cannot start outbound connections except to the database. It does not prove anything about
production, the existing application server, or DBS connectivity; none of those is tested here.
