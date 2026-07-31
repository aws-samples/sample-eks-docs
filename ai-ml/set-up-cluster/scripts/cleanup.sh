#!/bin/bash
#
# Usage: ./cleanup.sh [--auto-approve]
# Run from terraform/auto-mode/ or terraform/karpenter/.

set -euo pipefail

log() { printf '\n==> %s\n' "$*"; }

[[ -f main.tf && -f eks.tf ]] || {
  echo "Run this from terraform/auto-mode/ or terraform/karpenter/" >&2
  exit 1
}

destroy_args=()
[[ "${1:-}" == "--auto-approve" ]] && destroy_args=(-input=false -auto-approve)

log "Draining cluster (PDBs, NodeClaims, NodePools, EC2NodeClasses)"
kubectl delete pdb -A --all 2>/dev/null || true
kubectl delete nodeclaim --all --wait=true --timeout=900s 2>/dev/null || true
kubectl delete nodepool --all --wait=true --timeout=120s 2>/dev/null || true
kubectl delete ec2nodeclass --all --wait=true --timeout=120s 2>/dev/null || true

log "Running terraform destroy"
terraform destroy "${destroy_args[@]+"${destroy_args[@]}"}"

log "Cleanup complete"
