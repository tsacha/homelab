#!/usr/bin/env bash
# Render, validate and finalize a cluster's machine config with plain talosctl.
# Replaces talhelper (archived 2026-08-26). Called by `go-task talos:config`.
#
# Usage: talos-render.sh <node> <mode> <endpoint-var> <addr-var>
#   cwd            talos/<cluster>
#   node           hostname of the single node (bl3|gw)
#   mode           talosctl validate mode (metal|cloud)
#   endpoint-var   talenv KEY holding the API endpoint FQDN (KUBE_FQDN|GW_FQDN)
#   addr-var       talenv KEY holding the node address (BL3_ADDR6|GW_ADDR6)
#
# Expects TALOS_VERSION and KUBERNETES_VERSION in the environment (exported by
# tasks/talos.yaml, renovate-tracked). Re-executes itself under
# `sops exec-env talenv.sops.yaml` so no decrypted value ever hits a file
# outside the gitignored clusterconfig/.
set -euo pipefail

if [[ "${1:-}" != "--inner" ]]; then
  exec sops exec-env talenv.sops.yaml "$0 --inner $1 $2 $3 $4"
fi
shift
node=$1 mode=$2 endpoint_var=$3 addr_var=$4

SCHEMATIC_ID=$(<schematic.id)
export SCHEMATIC_ID

# Substitute exactly the ${VARS} that appear in the patches, and refuse to
# render if one of them is not defined — a typo must fail, not pass through.
vars=$(grep -ohE '\$\{[A-Z0-9_]+\}' patches/*.yaml | sort -u)
for v in $vars; do
  name=${v#\$\{}; name=${name%\}}
  [[ -v $name ]] || { echo "talos-render: $name is in a patch but not in talenv/environment" >&2; exit 1; }
done

rendered=clusterconfig/rendered
rm -rf "$rendered"
mkdir -p "$rendered"
patch_args=()
cp_args=()
for f in patches/*.yaml; do
  out="$rendered/$(basename "$f")"
  envsubst "$vars" <"$f" >"$out"
  if [[ $(basename "$f") == controlplane.yaml ]]; then
    cp_args+=(--config-patch-control-plane "@$out")
  else
    patch_args+=(--config-patch "@$out")
  fi
done

talosctl gen config "$CLUSTER_NAME" "https://${!endpoint_var}:6443" \
  --with-secrets <(sops -d talsecret.sops.yaml) \
  --talos-version "$TALOS_VERSION" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --with-docs=false --with-examples=false \
  "${patch_args[@]}" "${cp_args[@]}" \
  --output-types controlplane,talosconfig \
  --output clusterconfig --force

mv clusterconfig/controlplane.yaml "clusterconfig/$node.yaml"
talosctl validate --config "clusterconfig/$node.yaml" --mode "$mode" --strict

addr=${!addr_var}
talosctl --talosconfig clusterconfig/talosconfig config endpoint "$addr"
talosctl --talosconfig clusterconfig/talosconfig config node "$addr"
echo "rendered clusterconfig/$node.yaml, talosconfig -> $node"
