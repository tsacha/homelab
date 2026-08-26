#!/usr/bin/env bash
# Resolve which cluster a talos command targets: $CLUSTER wins, then the
# kubectl context matched against the inventory fqdns; anything else refuses
# rather than silently targeting home.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "${CLUSTER:-}" ]]; then
  echo "$CLUSTER"
  exit 0
fi

ctx=$(kubectl config current-context 2>/dev/null | sed 's/.*@//') || true
case "$ctx" in
  "$(yq -r '.gw.fqdn|sub("\\.";"-")' .private/inventory.yaml)") echo gw ;;
  "$(yq -r '.network.fqdn|sub("\\.";"-")' .private/inventory.yaml)") echo home ;;
  *)
    echo "talos: kubectl context '$ctx' is neither cluster — pass CLUSTER=home|gw" >&2
    exit 1
    ;;
esac
