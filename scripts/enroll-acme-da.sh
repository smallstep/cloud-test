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
#   The device's EK must be an approved identity in your Smallstep inventory. The
#   agent presents the EK on first contact; approve the device (dashboard/API), or
#   pre-register it as urn:ek:sha256:base64(sha256(DER EKpub)). See docs/acme-da.md.
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

# Print the device's EK identifier so you can register/approve it in the Smallstep
# inventory — the acme-da flow only issues to a registered EK. The identifier is
# urn:ek:sha256:base64(sha256(DER EKpub)).
print_ek_hint() {
  case "$1" in
    aws)
      local iid ek; iid="$(cloud_output aws instance_id 2>/dev/null)"
      ek="$(aws ec2 get-instance-tpm-ek-pub --instance-id "$iid" --key-type rsa-2048 \
              --key-format der --query KeyValue --output text 2>/dev/null \
            | base64 -d 2>/dev/null | openssl dgst -sha256 -binary | openssl base64)"
      [[ -n "$ek" ]] && log "device EK identifier: urn:ek:sha256:$ek" ;;
    gcp)
      log "GCP EK: gcloud compute instances get-shielded-identity <name> --zone <zone> --format json → hash the EKpub DER" ;;
    azure)
      log "Azure EK: no control-plane API — read the EK in-guest from the vTPM" ;;
  esac
  log "If this device is not yet approved in your Smallstep inventory, register that identifier first (see docs/acme-da.md)."
}
print_ek_hint "$CLOUD"

log "installing official step-cli + step-agent on $VM and enrolling (device-attest-01)"
ssh_admin "$VM" "sudo bash -s" <<REMOTE
set -euo pipefail
# Official Smallstep apt repo — no custom client code.
if ! command -v step-agent >/dev/null 2>&1; then
  curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg \
    | sudo tee /etc/apt/trusted.gpg.d/smallstep.asc >/dev/null
  echo 'deb https://packages.smallstep.com/stable/debian debs main' \
    | sudo tee /etc/apt/sources.list.d/smallstep.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq step-cli step-agent
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

log "waiting for the device certificate to be issued (approve the device in inventory if it is pending)…"
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
