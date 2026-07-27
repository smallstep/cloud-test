#!/usr/bin/env bash
# enroll-acme-da.sh <aws|gcp|azure> — enroll the VM's vTPM into Smallstep via
# ACME device-attest-01, using the official step-agent (no custom client code).
#
# The agent proves possession of the VM's Endorsement Key (EK) to the Smallstep
# CA, which issues a leaf whose private key is generated in and never leaves the
# vTPM (TPM-resident). This is what makes the VM a "secure", hardware-attested
# device identity.
#
# Prereqs:
#   export STEP_TEAM=<your-team-slug>
#   export STEP_CA_FINGERPRINT=<your-Agents-CA-fingerprint>
#   The device's EK must be a registered/approved identity in your Smallstep
#   inventory (acme-da only issues to a registered EK). This script reads + prints
#   the EK identifier in-guest (`step-agent tpm --fingerprint`) so you know exactly
#   what to register. See docs/acme-da.md.
#
#   STEP_AGENT_VERSION (optional): apt version suffix for step-agent. Defaults to
#   "=0.67.3-1" — 0.68.0 has a TPM AK-attestation regression that 404s on GCP/Azure
#   device-attest-01. Set STEP_AGENT_VERSION= (empty) for latest once it's fixed.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

CLOUD="${1:?usage: enroll-acme-da.sh <aws|gcp|azure>}"
: "${STEP_TEAM:?export STEP_TEAM=<your-team-slug>}"
: "${STEP_CA_FINGERPRINT:?export STEP_CA_FINGERPRINT=<your-Agents-CA-fingerprint>}"

IP="$(cloud_output "$CLOUD" public_ip)"
USER="$(cloud_output "$CLOUD" ssh_user)"
VM="$USER@$IP"
wait_for_ssh "$VM"

# Pinned step-agent apt version (see header). Default "=0.67.3-1"; STEP_AGENT_VERSION=
# (empty) installs latest.
STEP_AGENT_PIN="${STEP_AGENT_VERSION-=0.67.3-1}"

log "installing official step-cli + step-agent${STEP_AGENT_PIN} on $VM and enrolling (device-attest-01)"
ssh_admin "$VM" "sudo bash -s" <<REMOTE
set -euo pipefail
# Official Smallstep apt repo — no custom client code.
if ! command -v step-agent >/dev/null 2>&1; then
  curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg \
    | sudo tee /etc/apt/trusted.gpg.d/smallstep.asc >/dev/null
  echo 'deb https://packages.smallstep.com/stable/debian debs main' \
    | sudo tee /etc/apt/sources.list.d/smallstep.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq --allow-downgrades step-cli "step-agent${STEP_AGENT_PIN}"
fi

# The agent config is just the team + the Agents-CA fingerprint. TPM /
# device-attest-01 support is built into step-agent.
sudo install -d -m 0755 /etc/step-agent
sudo tee /etc/step-agent/agent.yaml >/dev/null <<YAML
team: ${STEP_TEAM}
fingerprint: ${STEP_CA_FINGERPRINT}
YAML

sudo systemctl enable --now step-agent
REMOTE

# Read the device's EK identifier in-guest from the vTPM — uniform across clouds,
# no control-plane API needed. Register/approve this in your Smallstep inventory if
# it isn't already; acme-da only issues to a registered EK. See docs/acme-da.md.
EK_ID="$(ssh_admin "$VM" "sudo step-agent tpm --fingerprint 2>/dev/null" | tr -d '\r' | grep -m1 '^urn:ek:' || true)"
[[ -n "$EK_ID" ]] && log "device EK identifier: $EK_ID"

log "waiting for the device certificate to be issued (register/approve the device if pending)…"
cert=/var/lib/step-agent/certificates/device/service.crt
for i in $(seq 1 30); do
  if ssh_admin "$VM" "sudo test -s $cert"; then
    log "device certificate issued — inspecting:"
    ssh_admin "$VM" "sudo step certificate inspect $cert --short 2>/dev/null || sudo step certificate inspect $cert" \
      | sed 's/^/    /' >&2
    log "the private key is TPM-resident (no usable key material on disk):"
    ssh_admin "$VM" "sudo ls -l /var/lib/step-agent/certificates/device/service.key 2>/dev/null || echo 'service.key: absent — the private key lives in the vTPM'" | sed 's/^/    /' >&2
    exit 0
  fi
  sleep 10
done
warn "no device cert yet after ~5 min. The device is likely pending approval in your"
warn "Smallstep inventory — approve it, then re-run this script (install is idempotent)."
exit 1
