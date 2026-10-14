#!/usr/bin/env bash
# Small helpers for the rehearsal scripts (create-rehearsal-db.sh, verify-roles.sh). Sourced, not run.
#
# This file replaces the repository's general-purpose lib.sh for these scripts, so the whole of what
# they depend on is this one short file: no nginx, certbot or account-management code is loaded, and
# nothing here runs at source time other than defining functions and constants.
#
# No secrets are handled or stored here.

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
info() { echo "${CYN}$*${RST}"; }
ok()   { echo "${GRN}$*${RST}"; }
warn() { echo "${YEL}$*${RST}"; }
err()  { echo "${RED}$*${RST}" >&2; }

# Shell tracing would print variable values (including generated passwords) to the terminal or a
# captured log. Refuse before anything is generated. SHELLOPTS=xtrace and `bash -x` both set $-.
refuse_tracing() {
    case $- in
        *x*|*v*) err "Refusing to run with shell tracing (xtrace/verbose) on: it would print secrets."; exit 1 ;;
    esac
    [[ -z ${BASH_XTRACEFD:-} ]] || { err "Refusing to run with BASH_XTRACEFD set."; exit 1; }
}

# Database/role names: lowercase letters, digits and underscore only, starting with a letter. This is
# also what makes it safe to place a validated name inside a SQL identifier or literal.
valid_dbname() { [[ $1 =~ ^[a-z][a-z0-9_]{0,30}$ ]]; }

valid_ipv4() {
    local o
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for o in $1; do ((10#$o <= 255)) || return 1; done
}

is_private_ipv4() {
    local a b
    IFS=. read -r a b _ <<<"$1"
    a=$((10#$a)); b=$((10#$b))
    ((a == 10)) || ((a == 172 && b >= 16 && b <= 31)) || ((a == 192 && b == 168))
}

# A bounded positive integer: bounded_int VALUE MIN MAX
bounded_int() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= $2 && 10#$1 <= $3)); }

# 32 random letters and digits (about 190 bits). Letters and digits only.
# (`|| true`: head closing the pipe makes tr exit with SIGPIPE, which `set -o pipefail` would treat as failure.)
random_password() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true; }

# Turns a password (read from STDIN, so it never appears in a process argument list) into a
# PostgreSQL SCRAM-SHA-256 verifier, the same format the server stores. The server is given only
# this verifier, never the plain password, so the password cannot appear in a CREATE ROLE statement,
# an error message that quotes it, a statement log or a pg_stat_statements row.
scram_verifier() {
    python3 -I -c '
import base64, hashlib, hmac, os, sys
pw = sys.stdin.buffer.read()
if not pw or not pw.isalnum():
    sys.exit("password must be non-empty letters and digits")
salt, rounds = os.urandom(16), 4096
salted = hashlib.pbkdf2_hmac("sha256", pw, salt, rounds)
client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
stored_key = hashlib.sha256(client_key).digest()
server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
b = lambda x: base64.b64encode(x).decode()
print("SCRAM-SHA-256$%d:%s$%s:%s" % (rounds, b(salt), b(stored_key), b(server_key)))
'
}
