#!/usr/bin/env bash
# Runs every regression suite and prints a transcript. Needs root, PostgreSQL 16 server binaries (/usr/lib/postgresql/16/bin),
# openssl, nftables and iproute2. Everything runs against throwaway clusters and network namespaces on THIS machine; it never
# contacts a real server, AWS, or any provider.   sudo bash rehearsal/tests/run-all.sh | tee rehearsal/tests/TRANSCRIPT.txt
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
echo "Regression run $(date -u +%Y-%m-%dT%H:%M:%SZ)  commit-base: $(git -C ../.. rev-parse HEAD 2>/dev/null || echo unknown)  dirty-files: $(git -C ../.. status --porcelain 2>/dev/null | wc -l)"
echo "bash $BASH_VERSION; $(nft --version 2>&1 | head -1); $(/usr/lib/postgresql/16/bin/postgres --version)"
bad=0
for t in test-provisioning.sh test-verifier.sh test-firewall.sh test-scratch.sh; do
    echo; echo "################ $t"; HOST_IP=172.26.5.5 bash "./$t" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true
    r=${PIPESTATUS[0]}; echo "exit status of $t: $r"; ((r == 0)) || bad=1
done
echo; ((bad == 0)) && echo "ALL SUITES PASSED" || echo "SOME SUITE FAILED"
exit $bad
