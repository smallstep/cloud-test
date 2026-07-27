#!/usr/bin/env bash
# lib.sh — shared helpers for the SSH device-identity demo scripts.
# Sourced by provision.sh / enroll-acme-da.sh / setup-ssh-identity.sh / prove.sh / teardown.sh.
set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Azure resource group / location (Bicep is deployed at RG scope).
AZ_RG="${AZ_RG:-vtpm-ssh-rg}"
AZ_LOCATION="${AZ_LOCATION:-eastus2}"

# Resolve the IaC directory + provisioner for a cloud.
iac_dir() {
  case "$1" in
    aws)   printf '%s/terraform/aws' "$REPO_ROOT" ;;
    gcp)   printf '%s/terraform/gcp' "$REPO_ROOT" ;;
    azure) printf '%s/azure' "$REPO_ROOT" ;;
    *)     die "unknown cloud '$1' (expected: aws | gcp | azure)" ;;
  esac
}

# Echo a named provisioner output (public_ip, instance_id, ssh_user, ...).
cloud_output() {
  local cloud="$1" key="$2"
  case "$cloud" in
    aws|gcp) terraform -chdir="$(iac_dir "$cloud")" output -raw "$key" ;;
    azure)   az deployment group show -g "$AZ_RG" -n vtpm-ssh \
               --query "properties.outputs.${key}.value" -o tsv ;;
  esac
}

# ---- SSH host-key policy ---------------------------------------------------
# These demo VMs are ephemeral and their host keys rotate on recreate, so we do
# NOT pin a persistent known_hosts. Default is TOFU accept-new into a per-run
# known_hosts (a mid-run change is still refused). INSECURE_SSH=1 disables it.
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-${TMPDIR:-/tmp}/vtpm-ssh-known-hosts.$$}"
if [[ "${INSECURE_SSH:-0}" == "1" ]]; then
  SSH_OPTS=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null )
else
  SSH_OPTS=( -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" )
fi

# Run a command on the VM as the admin (provisioning) user, applying host-key
# policy. Admin auth uses the provisioning KEY, not an SSH agent — set
# ADMIN_SSH_KEY to point at it (default ~/.ssh/id_ed25519, else ~/.ssh/id_rsa).
# IdentityAgent=none is deliberate: on Windows the Smallstep agent is a named pipe
# that Git Bash's ssh can't consume, and admin access shouldn't depend on it anyway.
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"
if [[ -z "$ADMIN_SSH_KEY" ]]; then
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [[ -f "$k" ]] && { ADMIN_SSH_KEY="$k"; break; }
  done
fi
ssh_admin() {
  local user_host="$1"; shift
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=15 -o IdentityAgent=none -o IdentitiesOnly=yes \
      ${ADMIN_SSH_KEY:+-i "$ADMIN_SSH_KEY"} "$user_host" "$@"
}

# scp using the same admin-key policy.
scp_admin() {
  scp "${SSH_OPTS[@]}" -o IdentityAgent=none -o IdentitiesOnly=yes \
      ${ADMIN_SSH_KEY:+-i "$ADMIN_SSH_KEY"} "$@"
}

# Wait until SSH answers (post boot).
wait_for_ssh() {
  local user_host="$1" tries="${2:-40}"
  for ((i = 1; i <= tries; i++)); do
    if ssh_admin "$user_host" true 2>/dev/null; then log "ssh up: $user_host"; return 0; fi
    sleep 10
  done
  die "ssh never came up: $user_host"
}
