#!/usr/bin/env bash
# Writes rehearsal/MANIFEST.sha256: the SHA-256 of every file the rehearsal depends on, from the current checkout.
# Verify a delivered copy with:  (cd <repo root> && sha256sum -c rehearsal/MANIFEST.sha256)
# The manifest's own hash, and the full 40-character commit ID, must be sent to the reviewer by a DIFFERENT channel
# from the files, or it is not independent delivery.
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
files=(
  lib.sh
  dbserver/rehearsal-common.sh dbserver/create-rehearsal-db.sh dbserver/verify-roles.sh
  dbserver/install-backup.sh dbserver/restore-test-prepare.sh dbserver/restore-test.sh
  rehearsal/egress-lockdown.sh rehearsal/egress-sink.py rehearsal/egress-probe.py rehearsal/verify-session.sh
  rehearsal/scratch-preflight.sh rehearsal/check-policies.py rehearsal/make-manifest.sh
  rehearsal/egress-plan.md rehearsal/scratch-storage.md rehearsal/REVIEW-RESPONSE.md
  rehearsal/policies/iam-rw.json rehearsal/policies/iam-ro.json rehearsal/policies/bucket-policy.json rehearsal/policies/lifecycle.json
)
sha256sum "${files[@]}" > rehearsal/MANIFEST.sha256
wc -l < rehearsal/MANIFEST.sha256
