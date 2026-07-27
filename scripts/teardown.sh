#!/usr/bin/env bash
# teardown.sh <aws|gcp|azure|all> — destroy the VM(s). Leave nothing running.
#
# AWS also removes the TPM-enabled AMI copy + its EBS snapshot (handled by the
# terraform destroy). Verify the cloud console afterward — a failed teardown is
# the only real cost risk.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

destroy_one() {
  local cloud="$1"
  case "$cloud" in
    aws|gcp)
      log "terraform destroy → $cloud"
      terraform -chdir="$(iac_dir "$cloud")" destroy -auto-approve
      ;;
    azure)
      log "az group delete → $AZ_RG"
      az group delete -n "$AZ_RG" --yes -o none
      ;;
    *) die "unknown cloud '$cloud'" ;;
  esac
  log "$cloud torn down"
}

CLOUD="${1:?usage: teardown.sh <aws|gcp|azure|all>}"
if [[ "$CLOUD" == "all" ]]; then
  for c in aws gcp azure; do destroy_one "$c" || warn "teardown failed for $c — CHECK THE CONSOLE"; done
else
  destroy_one "$CLOUD"
fi
