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
# tasks/talos.yaml, renovate-tracked).
set -euo pipefail

rendered=clusterconfig/rendered

render_patches() {
  local vars name f out
  vars=$(grep -ohE '\$\{[A-Z0-9_]+\}' patches/*.yaml | sort -u)

  # A typo in a patch must fail the render, not pass through as literal text.
  for name in $(tr -d '${}' <<<"$vars"); do
    [[ -v $name ]] || {
      echo "talos-render: $name is in a patch but not in talenv/environment" >&2
      exit 1
    }
  done

  rm -rf "$rendered"
  mkdir -p "$rendered"
  for f in patches/*.yaml; do
    out="$rendered/$(basename "$f")"
    envsubst "$vars" <"$f" >"$out"
    patch_args+=(--config-patch "@$out")
  done
}

generate_config() {
  talosctl gen config "$CLUSTER_NAME" "https://${!endpoint_var}:6443" \
    --with-secrets <(sops -d talsecret.sops.yaml) \
    --talos-version "$TALOS_VERSION" \
    --kubernetes-version "$KUBERNETES_VERSION" \
    --with-docs=false --with-examples=false \
    "${patch_args[@]}" \
    --output-types controlplane,talosconfig \
    --output clusterconfig --force
  mv clusterconfig/controlplane.yaml "clusterconfig/$node.yaml"
}

validate_config() {
  talosctl validate --config "clusterconfig/$node.yaml" --mode "$mode" --strict
}

point_talosconfig_at_node() {
  local addr=${!addr_var}
  talosctl --talosconfig clusterconfig/talosconfig config endpoint "$addr"
  talosctl --talosconfig clusterconfig/talosconfig config node "$addr"
}

# Re-exec under sops so no decrypted talenv value ever hits a file outside
# the gitignored clusterconfig/.
if [[ "${1:-}" != "--inner" ]]; then
  exec sops exec-env talenv.sops.yaml "$0 --inner $1 $2 $3 $4"
fi
shift
node=$1 mode=$2 endpoint_var=$3 addr_var=$4

SCHEMATIC_ID=$(<schematic.id)
export SCHEMATIC_ID
patch_args=()

render_patches
generate_config
validate_config
point_talosconfig_at_node
echo "rendered clusterconfig/$node.yaml, talosconfig -> $node"
