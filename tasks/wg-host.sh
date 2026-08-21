#!/usr/bin/env bash
set -euo pipefail

gw="$(yq -r '.gw.fqdn' .private/inventory.yaml)"
secrets="$(sops -d clusters/gw/vars/app/cluster-secrets.sops.yaml)"
v() { yq -r ".stringData.$1" <<<"$secrets"; }

# No Endpoint: the router (dynamic IP) initiates, the host learns it from the handshake.
conf="[Interface]
Address = $(v WG_ADDRESS)
ListenPort = 51820
PrivateKey = $(v WG_PRIVATEKEY)
MTU = 1392

[Peer]
PublicKey = $(v WG_PUBLICKEY)
AllowedIPs = $(v WG_ALLOWED_IPS6), $(v WG_ALLOWED_IPS4)"

printf '%s\n' "$conf" | ssh -l root "$gw" '
set -eu
command -v wg-quick >/dev/null || {
  apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -qy wireguard-tools >/dev/null
}
umask 077
mkdir -p /etc/wireguard
cat >/etc/wireguard/wg0.next
if cmp -s /etc/wireguard/wg0.next /etc/wireguard/wg0.conf; then
  rm /etc/wireguard/wg0.next
  systemctl enable --now wg-quick@wg0
else
  mv /etc/wireguard/wg0.next /etc/wireguard/wg0.conf
  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0
fi
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  hs=$(wg show wg0 latest-handshakes | awk "{print \$2}")
  [ "${hs:-0}" -gt 0 ] && break
  sleep 5
done
wg show wg0'

ssh -l root "$gw" "ping -c1 -W2 $(v WG_HEALTHCHECK)"
