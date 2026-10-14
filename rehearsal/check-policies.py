#!/usr/bin/env python3
"""Offline check of the scratch-bucket policy files in rehearsal/policies/. It makes NO AWS call and contacts no
bucket (live or scratch): it only reads the JSON files and tests them against the rules below.

    python3 -I rehearsal/check-policies.py [policies-dir]

Rules: the read-write and read-only IAM policies may only Allow actions on the scratch bucket; both carry an
explicit Deny on the live bucket; the read-only policy has no write or delete action; no wildcard actions or
resources and no NotAction/NotResource in an Allow; the bucket policy denies non-TLS requests for the bucket and
its objects; the lifecycle expires current objects within 7 days and aborts incomplete multipart uploads.
This is a static review aid. The effective permissions of the real IAM users still have to be inspected
(attached policies, boundaries, bucket policy, principals) after they are created.
"""
import json, os, sys
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "policies")
SC, LIVE = "arn:aws:s3:::dbs-check-crm-rehearsal-backups", "arn:aws:s3:::dbs-check-crm-backups"
WRITE = {"s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectAcl", "s3:PutBucketPolicy",
         "s3:PutBucketAcl", "s3:DeleteBucket", "s3:PutLifecycleConfiguration", "s3:PutEncryptionConfiguration"}
RW_OK = {"s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"}
RO_OK = {"s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject"}
bad = 0
def lst(x): return x if isinstance(x, list) else [x]
def res(ok, text):
    global bad
    bad += (not ok); print(("PASS  " if ok else "FAIL  ") + text)
def load(n): return json.load(open(os.path.join(D, n + ".json")))

for name, allowed in (("iam-rw", RW_OK), ("iam-ro", RO_OK)):
    p = load(name); st = p["Statement"]
    allows = [s for s in st if s["Effect"] == "Allow"]
    acts = {a for s in allows for a in lst(s["Action"])}
    ress = [r for s in allows for r in lst(s["Resource"])]
    res(all("NotAction" not in s and "NotResource" not in s for s in st), f"{name}: no NotAction/NotResource")
    res(acts <= allowed, f"{name}: Allow actions are only {sorted(allowed)} (found {sorted(acts)})")
    res(all("*" not in a.split(":")[-1] for a in acts) and "*" not in ress, f"{name}: no wildcard action or bare '*' resource")
    res(all(r == SC or r == SC + "/*" for r in ress), f"{name}: every Allow resource is the scratch bucket or its objects")
    res(not any(LIVE in r for r in ress), f"{name}: no Allow mentions the live bucket")
    den = [s for s in st if s["Effect"] == "Deny" and "s3:*" in lst(s["Action"]) and {LIVE, LIVE + "/*"} <= set(lst(s["Resource"]))]
    res(bool(den), f"{name}: explicit Deny s3:* on the live bucket and its objects")
    if name == "iam-ro": res(not (acts & WRITE), "iam-ro: no write, delete or administrative action")
bp = load("bucket-policy")["Statement"]
res(any(s["Effect"] == "Deny" and s.get("Condition", {}).get("Bool", {}).get("aws:SecureTransport") == "false"
        and {SC, SC + "/*"} <= set(lst(s["Resource"])) for s in bp), "bucket-policy: denies non-TLS requests to the bucket and its objects")
lc = load("lifecycle")["Rules"]
res(any(r["Status"] == "Enabled" and r.get("Expiration", {}).get("Days", 99) <= 7 for r in lc), "lifecycle: current objects expire within 7 days")
res(any("AbortIncompleteMultipartUpload" in r for r in lc), "lifecycle: incomplete multipart uploads are aborted")
res(any("NoncurrentVersionExpiration" in r for r in lc), "lifecycle: noncurrent versions expire (in case versioning is ever on)")
print(f"{bad} check(s) FAILED" if bad else "All checks passed"); sys.exit(1 if bad else 0)
