# Host firewall and egress plan for `crm-rehearsal-app` (review only; nothing has been run on a real host)

Supersedes the earlier ufw-based plan (file hash c2ca…/625bfd52… under 44f60de). It is for the **temporary rehearsal
application host only**, never the production application server or the database server. No secrets in this file.

Executable pieces (all in this repository, reviewed at the revision named in `REVIEW-RESPONSE.md`):

| File | Runs on | Purpose |
| --- | --- | --- |
| `rehearsal/egress-lockdown.sh` | `crm-rehearsal-app` | `plan` (default, changes nothing), `apply`, `status`, `remove` |
| `rehearsal/egress-sink.py` | `crm-rehearsal-pitr-restore` | non-provider sink that logs every hit |
| `rehearsal/egress-probe.py` | control host, then `crm-rehearsal-app` as the service user | outbound attempts to the sink and the database only |
| `rehearsal/verify-session.sh` | `crm-rehearsal-app` | verified-TLS logins as both roles (Gate B) |

## What changed from the first plan, and why

- **nftables instead of ufw.** ufw accepts "established" traffic before its own denies, so a connection already open when the
  firewall is enabled keeps working. The new rules decide by the *direction a connection was started*: this host may send only
  replies to connections started from outside (the operator's SSH) or traffic to `172.26.9.114:5432`. A connection this host
  started earlier to anywhere else is original-direction, so it is dropped even if established. No conntrack flush is needed.
- **No rollback timer.** The old timer disabled the firewall (fail-open). It is gone. `apply` refuses unless the SSH session comes
  from `OPS_IP`; if access is lost anyway, delete and recreate the empty host. `status` fails if any `fw-rollback` unit exists.
- **IPv4 and IPv6 in one table** (`inet`), forwarding dropped, metadata `169.254.169.254` and `fd00:ec2::254` dropped first by
  address. **No test ever contacts a metadata address**: the earlier `curl` is removed. Evidence is rule order plus counters.
- **DHCP renewal and IPv6 neighbour discovery** (link-local only) are allowed so the host keeps its address; the old plan would
  have lost it when the lease expired. They reach no provider.
- Complete evidence: `nft list ruleset` shows every hook (any other firewall tables too), and `apply` prints an inventory first and
  deletes nothing that exists. Nothing is reset.

## Values recorded at provisioning

`OPS_IP` (operator public IPv4), `DB_IP=172.26.9.114`, `DB_PORT=5432`, `SVC_USER` (the application's service identity),
`SINK_V4`/`SINK_V6` (addresses of `crm-rehearsal-pitr-restore`; `SINK_V6` only if it has one), `CONTROL_HOST=crm-rehearsal-pitr-src`.
Cloud (Lightsail) firewall for this host, inbound: remove HTTP 80; SSH 22 (and HTTPS 443 only if used) restricted to `OPS_IP/32`;
no rule for the application port. Prefer IPv4-only networking for the instance.

## Sequence

1. **Stage without secrets.** Install Node, PM2 and dependencies and stage the package; no `runtime.env`, no database password.
2. **Baseline.** On the control host: `python3 -I rehearsal/egress-probe.py --expect open --sink4 <SINK_V4> [--sink6 <SINK_V6>]`,
   with `egress-sink.py` running on the sink. This proves the sink is reachable at all, without opening egress on the application host.
3. **Plan, then apply.** `sudo OPS_IP=<ip> bash rehearsal/egress-lockdown.sh plan` (syntax-checked with `nft -c`, nothing loaded,
   inventory and exact rules printed; send this output for review). Then `apply` (typed `LOCKDOWN`). It refuses if the secrets file
   already exists, if the SSH client is not `OPS_IP`, or if `OPS_IP` is private or special. Rules are loaded atomically and
   saved for boot by `rehearsal-egress.service`.
4. **Verify as the service user, then show the drops.**
   `sudo -u <SVC_USER> python3 -I rehearsal/egress-probe.py --expect blocked --sink4 <SINK_V4> [--sink6 <SINK_V6>] --db-ip 172.26.9.114`
   then `sudo bash rehearsal/egress-lockdown.sh status` (policies, metadata order, no fail-open unit, rules unchanged since apply,
   counters) and `sudo journalctl -k --since "-10 min" | grep REHEARSAL-EGRESS-DROP`. Stop `egress-sink.py` and record its summary:
   **a timeout alone is not a pass; the evidence is the drop counters/log AND no hit from the application host at the sink.**
   Do not resolve or contact DBS, payment, email, AI or evidence endpoints, and do not use public IP-check sites.
5. **Reboot check.** Reboot, then re-run `status` and the probe before trusting persistence.
6. **Only now stage secrets** (`/etc/dbs-check/runtime.env`, mode 0600, readable only by `SVC_USER`), delivered through the agreed
   secure channel. Re-run steps 4 after any restart, after staging, and immediately before Gate B. Any unverified family or path is BLOCKED.
7. **Teardown.** Delete the instance and record it. Revoke the rehearsal database credentials with `dbserver/create-rehearsal-db.sh cleanup`.

## What was actually tested, and what was not

Tested in a sandbox with two Linux network namespaces (IPv4 only, nftables 1.0.9; **IPv6 was only syntax-checked: that kernel has no IPv6**):
baseline all open; then with a long-lived outbound connection, an operator session and a non-operator session already open,
`apply` cut the outbound flow (sink received nothing after), kept the operator session, cut the non-operator session; TCP
443/444 and UDP probes were blocked and the sink saw nothing; the database path stayed open; a metadata analogue address
(inside the namespace only) was never reached and its drop counter rose; `status` passed and failed after a rule was added by hand.

**Not tested:** IPv6 behaviour, the boot-time unit, DHCP renewal on Lightsail, and anything on a real Lightsail host. Those are
checks for the rehearsal itself (steps 4 and 5), and any unverified one counts as BLOCKED.

## What this does not prove

It proves the host cannot start outbound connections except to the database. It says nothing about production, the existing
application server, or DBS connectivity; none of those is tested here.
