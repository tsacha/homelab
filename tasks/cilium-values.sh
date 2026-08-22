#!/usr/bin/env bash
# The effective Cilium values for a cluster, on stdout. `*n` is deep merge, `+`
# is not: both files carry an `ipam:` key and a shallow merge drops `ipam.mode`.
# That shipped once.
set -euo pipefail
cd "$(dirname "$0")/.."
c=${1:?usage: cilium-values.sh <home|gw>}

sops -d "clusters/$c/infra/cilium-values.sops.yaml" |
  yq eval-all 'select(fi == 0).spec.values *n select(fi == 1)' \
    <(yq 'select(.kind == "HelmRelease")' "clusters/$c/infra/cilium.yaml") -
