#!/usr/bin/env bash
# Generic talosctl front: resolves the cluster (tasks/talos-cluster.sh),
# points --talosconfig and --nodes at it, passes everything else through.
#   tasks/talosctl.sh health
#   CLUSTER=gw tasks/talosctl.sh dashboard
set -euo pipefail
cd "$(dirname "$0")/.."

cluster=$(tasks/talos-cluster.sh)
case "$cluster" in
  gw) addr_var=GW_ADDR6 ;;
  *)  addr_var=BL3_ADDR6 ;;
esac
addr=$(sops -d "talos/$cluster/talenv.sops.yaml" | yq -r ".$addr_var")

exec talosctl \
  --talosconfig "talos/$cluster/clusterconfig/talosconfig" \
  --nodes "$addr" --endpoints "$addr" \
  "$@"
