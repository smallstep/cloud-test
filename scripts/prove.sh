#!/usr/bin/env bash
# prove.sh <aws|gcp|azure> — the whole point: show that `operator` access is
# gated ENTIRELY on a hardware-attested SSH certificate.
#
#   PASS 1 (positive): with the Smallstep SSH agent, `ssh operator@vm` logs in —
#                      no key, no password — and the server logs a cert accept.
#   PASS 2 (negative): with NO agent and NO key, the same login is refused.
#
# The positive test uses your ambient SSH agent, which must be the Smallstep agent
# holding your hardware SSH cert. Point SSH_AUTH_SOCK at it first (see
# docs/ssh-device-identity.md, "Operator setup"):
#   Linux:   export SSH_AUTH_SOCK=/run/ssh-agent.sock
#   macOS:   export SSH_AUTH_SOCK="$HOME/Library/Application Support/Smallstep/step-ssh-agent.sock"
#   Windows: $env:SSH_AUTH_SOCK = '\\.\pipe\step-agent-ssh'   (then run from Git Bash)
# Verify with:  ssh-add -L   (should show a cert whose principal is your identity)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

CLOUD="${1:?usage: prove.sh <aws|gcp|azure>}"
IP="$(cloud_output "$CLOUD" public_ip)"
ADMIN="$(cloud_output "$CLOUD" ssh_user)@$IP"
OP="operator@$IP"

fail=0

echo "── PASS 1 (positive): SSH in as operator using the hardware SSH cert ──" >&2
if who="$(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$OP" whoami 2>/dev/null)" \
     && [[ "$who" == "operator" ]]; then
  echo "  ✅ logged in as '$who' with no key/password (cert presented by the agent)" >&2
else
  echo "  ❌ could not log in with the cert — is SSH_AUTH_SOCK pointed at the Smallstep agent? (ssh-add -L)" >&2
  fail=1
fi

echo "── server-side confirmation: it was a certificate ──" >&2
if line="$(ssh_admin "$ADMIN" "sudo journalctl -u ssh -n 40 --no-pager 2>/dev/null | grep -i 'Accepted publickey for operator' | tail -1")" \
     && [[ -n "$line" ]]; then
  echo "  ${line#* }" | sed 's/^/  /' >&2   # e.g. "Accepted publickey for operator ... ID you@example.com (serial …) CA …"
else
  echo "  (no matching sshd log line found — check 'sudo journalctl -u ssh' on the VM)" >&2
fi

echo "── PASS 2 (negative): SSH in as operator with NO agent and NO key ──" >&2
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=15 \
       -o IdentityAgent=none -o IdentitiesOnly=yes -o PasswordAuthentication=no \
       "$OP" whoami >/dev/null 2>&1; then
  echo "  ❌ SECURITY FAILURE: logged in WITHOUT a cert — the gate is not enforced" >&2
  fail=1
else
  echo "  ✅ refused (Permission denied) — no cert, no access" >&2
fi

echo >&2
if [[ "$fail" -eq 0 ]]; then
  echo "RESULT ($CLOUD): access is gated ENTIRELY on the hardware SSH device identity." >&2
else
  echo "RESULT ($CLOUD): incomplete — see ❌ above." >&2
fi
exit "$fail"
