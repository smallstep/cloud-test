#!/usr/bin/env bash
# setup-ssh-identity.sh <aws|gcp|azure> — configure the VM so the ONLY way to log
# in as `operator` is a hardware-attested Smallstep SSH certificate.
#
# Server side (this script, over the admin SSH connection):
#   1. Trust the Smallstep SSH user CA           (sshd TrustedUserCAKeys)
#   2. Create a cert-only `operator` user        (no password, no authorized_keys)
#   3. Map the operator's cert principal → user  (AuthorizedPrincipalsFile)
#
# The admin/provisioning user (ubuntu / azureuser) stays key-based and is NOT
# cert-accessible — so you cannot lock yourself out while setting this up.
#
# Prereqs:
#   export OPERATOR_PRINCIPAL=<the principal in your SSH cert, e.g. you@example.com>
#   export SSH_USER_CA_FILE=<file with the OpenSSH SSH user CA key(s), one per line>
#     Get it on an enrolled machine with:  step ssh config --roots
#     (A team can have more than one SSH user CA — include every CA that signs
#      operator certs; TrustedUserCAKeys takes one key per line.)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

CLOUD="${1:?usage: setup-ssh-identity.sh <aws|gcp|azure>}"
: "${OPERATOR_PRINCIPAL:?export OPERATOR_PRINCIPAL=<the principal in your SSH cert>}"
: "${SSH_USER_CA_FILE:?export SSH_USER_CA_FILE=<file with OpenSSH SSH user CA key(s)>}"
[[ -s "$SSH_USER_CA_FILE" ]] || die "SSH_USER_CA_FILE not found or empty: $SSH_USER_CA_FILE"

IP="$(cloud_output "$CLOUD" public_ip)"
USER="$(cloud_output "$CLOUD" ssh_user)"
VM="$USER@$IP"
wait_for_ssh "$VM"

log "uploading the SSH user CA key(s) → $VM"
scp_admin "$SSH_USER_CA_FILE" "$VM:/tmp/smallstep_ca.pub"

log "configuring sshd (cert trust) + cert-only operator user"
ssh_admin "$VM" "sudo OPERATOR_PRINCIPAL='$OPERATOR_PRINCIPAL' bash -s" <<'REMOTE'
set -euo pipefail

# 1) Trust the Smallstep SSH user CA. Additive — normal key auth is unaffected,
#    so you cannot lock yourself out.
sudo install -m 0644 /tmp/smallstep_ca.pub /etc/ssh/smallstep_ca.pub
rm -f /tmp/smallstep_ca.pub
sudo tee /etc/ssh/sshd_config.d/10-smallstep.conf >/dev/null <<CONF
# Trust hardware-attested Smallstep SSH_USER certs (additive).
TrustedUserCAKeys /etc/ssh/smallstep_ca.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
# Operators whose agent holds many identities trip the default cap of 6.
MaxAuthTries 20
CONF

# 2) Cert-only `operator` user. A historical `operator` *group* (GID 37) may
#    exist, so reuse it (-g) — a bare useradd would fail creating a same-named group.
getent passwd operator || sudo useradd -m -s /bin/bash -g operator operator
echo 'operator ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-operator >/dev/null
sudo chmod 0440 /etc/sudoers.d/90-operator && sudo visudo -cf /etc/sudoers.d/90-operator

# 3) Map the operator's cert principal → the operator login. `operator` has no
#    password and no authorized_keys, so it is reachable ONLY via a valid SSH cert
#    whose principal is listed here.
sudo install -d -m 0755 /etc/ssh/auth_principals
echo "$OPERATOR_PRINCIPAL" | sudo tee /etc/ssh/auth_principals/operator >/dev/null

sudo sshd -t && sudo systemctl reload ssh
echo "OK: sshd trusts the Smallstep SSH user CA; operator maps principal '$OPERATOR_PRINCIPAL'"
REMOTE

log "done. operator@$IP is now reachable ONLY with a valid SSH cert (principal '$OPERATOR_PRINCIPAL')."
log "run: scripts/prove.sh $CLOUD"
