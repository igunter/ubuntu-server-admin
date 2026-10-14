# Host firewall and egress plan for `crm-rehearsal-app` (review only; nothing has been run on a real host)

Revision after the review of 4d94396 (finding F5). Supersedes the earlier ufw-based plan and the 4d94396 version of this file. It is
for the **temporary rehearsal application host only**, never the production application server or the database server. No secrets
in this file.

| File | Runs on | Purpose |
| --- | --- | --- |
| `rehearsal/egress-lockdown.sh` | `crm-rehearsal-app` | `plan` (default, changes nothing), `apply`, `status`, `require`, `remove` |
| `rehearsal/egress-sink.py` | `crm-rehearsal-pitr-restore` | non-provider sink that logs every hit |
| `rehearsal/egress-probe.py` | control host, then `crm-rehearsal-app` as the service user | outbound attempts to the sink and the database only |
| `rehearsal/verify-session.sh` | `crm-rehearsal-app` | verified-TLS logins as both roles (Gate B) |

## The policy, exactly

Default drop in input, output and forward (IPv4 and IPv6, one `inet` table, priority -50). Metadata addresses `169.254.169.254` and
`fd00:ec2::254` are dropped first by address and never contacted. Then **only**:

| Direction | Allowed | Notes |
| --- | --- | --- |
| output | TCP to `DB_IP:DB_PORT` (state new, established) | the one connection this host may start |
| output | TCP **from** `OPS_PORTS` **to** `OPS_IP` (state established) | replies to the operator only |
| input | TCP from `DB_IP:DB_PORT` (established) | replies from the database |
| input | TCP from `OPS_IP` to `OPS_PORTS` (new, established) | operator access only |

**Changed from 4d94396:** output no longer accepts every established reply. A connection that was already open before the rules
loaded (for example an unapproved inbound session that has server data queued) gets no output at all, because its peer is not
`OPS_IP` on an approved port. Tested.

**No `ct direction` match (found by testing, now removed).** A connection that predates conntrack is adopted mid-stream, and
whichever side speaks first is recorded as the original direction. Matching on direction therefore cut the operator's own session in
roughly one run in four. The rules match on peer address, port and state only. The 4d94396 rules had the same weakness.

### Exceptions: additions to the database-only policy, not implied by anything above

Each loads **only** if named in `APPROVED_EXCEPTIONS`, and only after the client has approved it for this host. Default: none. `plan`
prints which are loaded.

| Exception | Rules | Without it |
| --- | --- | --- |
| `dhcp` | UDP 68→67 out on `IFACE` to `DHCP_SERVER` and 255.255.255.255; UDP 67→68 in on `IFACE` from `DHCP_SERVER` only | the IPv4 lease cannot be renewed; record the lease time and keep the host short-lived |
| `nd` | IPv6 neighbour discovery on `IFACE`, link-local only (`fe80::/10`, `ff02::/16`), hop limit 255 | IPv6 cannot work on the link (fine if IPv6 is disabled, which is preferred) |
| `icmp-related` | ICMP destination-unreachable / time-exceeded, **related** to flows, with `OPS_IP` or `DB_IP` only | path-MTU errors for approved flows are dropped |

`IFACE` and `DHCP_SERVER` default to the IPv4 default route's interface and gateway. **The client must confirm both values from the
plan output** before approving `dhcp`; the gateway is assumed to be the DHCP server, which is not guaranteed.

## Fail closed, persistence and application start

- Any failure after the rules load (saving, comparing the saved file with the generated one, writing or enabling the unit, checking
  `is-enabled` returns exactly `enabled`, writing the state record) makes `apply` **exit non-zero, leave the rules loaded, and write no
  state record**. `status` and `require` then fail until `apply` has completed.
- The state record holds hashes of the loaded table, the saved rules file and the unit file; `status` fails if any differs
  (so a hand-edited rules file, unit or live rule is caught), if the unit is not enabled, or if the legacy-timer inventory cannot be taken.
- **Legacy timers:** `status` lists units, timers and unit files through `systemctl`, checking each command's exit status. A failing
  `systemctl` is a FAIL (not a PASS); any `fw-rollback`/rollback unit, timer or unit file is a FAIL; queued `at` jobs are a FAIL.
- **No weakening under a live app:** `apply` (including re-apply) and `remove` refuse if the secrets file exists, a process runs as
  `SVC_USER`, or `APP_UNIT` is active. There is no override: delete and recreate the host instead.
- **Application start gate.** The application's own systemd unit must contain
  `Requires=rehearsal-egress.service`, `After=rehearsal-egress.service` and
  `ExecStartPre=/usr/bin/env bash /path/to/rehearsal/egress-lockdown.sh require`. `require` is silent and exits 0 only if every
  `status` check passes. That unit is the application owner's and is **not** supplied or tested here; Gate B must see it.
- "Enabled" is not proof of boot enforcement. Boot ordering (`Before=network-pre.target`) and the failure case (rules file broken
  or `nft` failing: the unit fails, the application unit does not start) must be **demonstrated on the real empty host** (step 5).

## IPv6 posture and probe coverage

`plan` and `status` print, from the kernel: `disable_ipv6` for `all`, `default` and the interface, every IPv6 address outside loopback
(all scopes), and the IPv6 routes. IPv6 counts as disabled only if the sysctls are 1 **and** no non-loopback address exists.
`egress-probe.py` now covers IPv4 and IPv6 TCP 443 and **444** and UDP 5353 when `--sink6` is given. Without `--sink6`, `--expect
blocked` **fails** unless IPv6 is demonstrably disabled by that same test: "no global address" is not accepted. Preferred: disable
IPv6 on the instance and give no `--sink6`; otherwise give the sink's IPv6 address and approve `nd`.

## Values recorded at provisioning

`OPS_IP`, `DB_IP=172.26.9.114`, `DB_PORT=5432`, `OPS_PORTS`, `APPROVED_EXCEPTIONS`, `IFACE`, `DHCP_SERVER`, `SVC_USER`, `APP_UNIT`,
`SINK_V4`/`SINK_V6`, `CONTROL_HOST=crm-rehearsal-pitr-src`. Cloud (Lightsail) firewall for this host, inbound: remove HTTP 80; SSH 22
(and HTTPS 443 only if used) restricted to `OPS_IP/32`; no rule for the application port.

## Sequence

1. **Stage without secrets.** Node, PM2, dependencies, package; no `runtime.env`, no database password.
2. **Baseline** on the control host: `python3 -I rehearsal/egress-probe.py --expect open --sink4 <SINK_V4> [--sink6 <SINK_V6>]`, with `egress-sink.py` on the sink.
3. **Plan, then apply.** `sudo OPS_IP=<ip> [APPROVED_EXCEPTIONS=...] bash rehearsal/egress-lockdown.sh plan` (checked with `nft -c`, nothing loaded, rules, exceptions and IPv6 posture printed: send for review). Then `apply` (typed `LOCKDOWN`).
4. **Verify as the service user, then show the drops.** `sudo -u <SVC_USER> python3 -I rehearsal/egress-probe.py --expect blocked --sink4 <SINK_V4> [--sink6 <SINK_V6>] --db-ip 172.26.9.114`, then `sudo bash rehearsal/egress-lockdown.sh status`, then `sudo journalctl -k --since "-10 min" | grep REHEARSAL-EGRESS-DROP`. Stop the sink and record its summary. **A timeout alone is not a pass; the evidence is the drop counters/log AND no hit from the application host at the sink.** Do not resolve or contact DBS, payment, email, AI or evidence endpoints, and do not use public IP-check sites.
5. **Boot and failure evidence (real host, before secrets).** Reboot, then `status` and the probe. Then, on the still-empty host: break `RULES_FILE` deliberately, reboot, and show that `rehearsal-egress.service` fails and the host is not left open (the table either loaded or the network does not come up with an open policy); restore it. Record both transcripts. Show DHCP renewal if `dhcp` is approved (lease time and a renewal in the journal). Record the IPv6 posture output. Any of these missing is BLOCKED.
6. **Only now stage secrets** (`/etc/dbs-check/runtime.env`, mode 0600, readable only by `SVC_USER`) through the agreed secure channel. Re-run step 4 after any restart, after staging, and immediately before Gate B.
7. **Teardown.** Delete the instance and record it. Revoke the rehearsal database credentials with `dbserver/create-rehearsal-db.sh cleanup`.

## What was actually tested, and what was not

`rehearsal/tests/test-firewall.sh` (61 checks, run repeatedly; transcript in `rehearsal/tests/TRANSCRIPT.txt`), in two Linux network
namespaces, IPv4 only (**the sandbox kernel has no IPv6; IPv6 rules were only syntax-checked with `nft -c`**), with a stub in place
of `systemctl`:

- connections open **before** the lockdown: the operator session continued both ways; an unapproved inbound session received nothing
  more (its queued pushes were dropped and counted); an application-started connection to a non-database address delivered nothing
  more; the database connection continued both ways;
- probes blocked with nothing at the sink; a new inbound connection from an unapproved peer dropped;
- `apply` with persistence failing (`enable` fails): exit non-zero, rules loaded, no state record, `status` and `require` fail; a clean
  apply then passes both;
- tampering (rules file, unit file, a rule added by hand, unit not enabled) detected by `require`;
- a `fw-rollback` timer, a failing `systemctl` inventory: `status` fails (the latter was a false PASS before);
- `remove` and re-`apply` refused with the secrets file present, with the app unit active, with a process running as `SVC_USER`;
- DHCP and related-ICMP rules render scoped to the interface, server and peers only when approved; ND absent unless approved;
- the probe's IPv6 verdict logic against five synthetic `/proc` layouts.

**Not tested, and only obtainable on the real empty host:** IPv6 behaviour, the boot-time unit and its failure behaviour, DHCP renewal,
the application's own unit, and anything on Lightsail. Any unverified item counts as BLOCKED.

## What this does not prove

It proves the host cannot start outbound connections except to the database. It says nothing about production, the existing
application server, or DBS connectivity; none of those is tested here.
