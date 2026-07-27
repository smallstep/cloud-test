#!/usr/bin/env bash
# provision.sh <aws|gcp|azure> — bring up one secure vTPM VM.
#
#   AWS   → NitroTPM      (Terraform)
#   GCP   → Shielded VM   (Terraform)
#   Azure → Trusted Launch (Bicep via az)
#
# Prereqs (export before running):
#   export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
#   # optional network-layer scoping on top of the SSH-cert gate:
#   export TF_VAR_ssh_ingress_cidr="$(curl -s https://checkip.amazonaws.com)/32"
#   # GCP also needs: export TF_VAR_project_id=<your-project>
#   # Azure uses AZ_RG / AZ_LOCATION (see scripts/lib.sh); pass sshPublicKey below.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

CLOUD="${1:?usage: provision.sh <aws|gcp|azure>}"
: "${TF_VAR_ssh_public_key:?export TF_VAR_ssh_public_key=\"\$(cat ~/.ssh/id_ed25519.pub)\"}"

case "$CLOUD" in
  aws|gcp)
    dir="$(iac_dir "$CLOUD")"
    log "terraform apply → $CLOUD"
    terraform -chdir="$dir" init -input=false >/dev/null
    terraform -chdir="$dir" apply -auto-approve -input=false
    ;;
  azure)
    : "${TF_VAR_ssh_public_key:?}"
    log "az deployment → Azure Trusted Launch (rg=$AZ_RG loc=$AZ_LOCATION)"
    az group create -n "$AZ_RG" -l "$AZ_LOCATION" -o none
    az deployment group create -g "$AZ_RG" -n vtpm-ssh \
      -f "$REPO_ROOT/azure/main.bicep" \
      -p sshPublicKey="$TF_VAR_ssh_public_key" \
         sshIngressCidr="${TF_VAR_ssh_ingress_cidr:-*}" -o none
    ;;
  *) die "unknown cloud '$CLOUD'" ;;
esac

IP="$(cloud_output "$CLOUD" public_ip)"
USER="$(cloud_output "$CLOUD" ssh_user)"
log "provisioned $CLOUD: admin=$USER@$IP"
cat >&2 <<EOF

  Next:
    scripts/enroll-acme-da.sh $CLOUD           # enroll the VM's vTPM into Smallstep (device-attest-01)
    scripts/setup-ssh-identity.sh $CLOUD       # trust the SSH user CA + create the cert-only operator
    scripts/prove.sh $CLOUD                     # prove: SSH with the cert works, without it is refused
EOF
