#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
c=${1:?usage: cilium-values.sh <home|gw>}

sops -d "clusters/$c/infra/cilium-values.sops.yaml" |
  yq eval-all 'select(fi == 0).spec.values *n select(fi == 1)' \
    <(yq 'select(.kind == "HelmRelease")' "clusters/$c/infra/cilium.yaml") -
