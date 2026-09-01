#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} != --inner ]]; then
  printf -v command '%q ' "$0" --inner "$@"
  exec sops exec-env talenv.sops.yaml "$command"
fi

shift
node=$1
mode=$2
endpoint_var=$3
addr_var=$4

SCHEMATIC_ID=$(<schematic.id)
export SCHEMATIC_ID

vars=$(grep -ohE '\$\{[A-Z0-9_]+\}' patches/*.yaml | sort -u)
for name in $(tr -d '${}' <<<"$vars"); do
  [[ -v $name ]] || {
    echo "talos: missing $name" >&2
    exit 1
  }
done

mkdir -p clusterconfig
{
  for patch in patches/*.yaml; do
    printf '%s\n' '---'
    cat "$patch"
  done
} | envsubst "$vars" >clusterconfig/patches.yaml

talosctl gen config "$CLUSTER_NAME" "https://${!endpoint_var}:6443" \
  --with-secrets <(sops -d talsecret.sops.yaml) \
  --talos-version "$TALOS_VERSION" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --with-docs=false --with-examples=false \
  --config-patch @clusterconfig/patches.yaml \
  --output-types controlplane,talosconfig \
  --output clusterconfig --force
mv clusterconfig/controlplane.yaml "clusterconfig/$node.yaml"
talosctl validate --config "clusterconfig/$node.yaml" --mode "$mode" --strict

addr=${!addr_var}
talosctl --talosconfig clusterconfig/talosconfig config endpoint "$addr"
talosctl --talosconfig clusterconfig/talosconfig config node "$addr"
echo "rendered clusterconfig/$node.yaml"
