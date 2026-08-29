#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in $(git ls-files '*.sops.yaml' '*.sops.rsc' | grep -v '^\.sops\.yaml$'); do
  [ "$(sops filestatus "$f" | yq -r .encrypted)" = true ] || fail "$f is not encrypted"
done

plaintext=$(git ls-files -c -o --exclude-standard |
  grep -vE '\.sops\.(ya?ml|rsc)$' |
  grep -vE '\.md$|talconfig\.schema\.json$|/templates/')

leak=$(echo "$plaintext" | xargs grep -nIiE \
  'BEGIN [A-Z ]*PRIVATE KEY|(key|token|password|secret)[A-Za-z0-9_.-]*:[[:space:]]*"?[A-Za-z0-9+/]{24,}={0,2}"?[[:space:]]*$' \
  2>/dev/null | grep -viE 'publickey|pubkey' || true)
[ -z "$leak" ] || fail "credential-shaped literal in a plaintext file:
$leak"

for f in $plaintext; do
  case "$f" in *.yaml | *.yml) ;; *) continue ;; esac
  grep -q '^kind: Secret' "$f" 2>/dev/null || continue
  yq -e 'select(.kind == "Secret") | (.data // .stringData // {}) | to_entries |
         map(select(.value | tostring | test("^[A-Za-z0-9+/]{24,}={0,2}$"))) |
         length > 0' "$f" >/dev/null 2>&1 &&
    fail "$f: plaintext Secret with literal key material"
done

ADDR_RE='([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]+)?|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(/[0-9]+)?|([0-9a-f]{2}:){5}[0-9a-f]{2}|enp[0-9]+s[0-9]+|\b(ata|nvme|usb)-[A-Za-z0-9_]{6,}'
GENERIC='(::1|fe80::1|::/0|0\.0\.0\.0/0|127\.0\.0\.1|::)'

addrs=$(git ls-files '*.md' | xargs grep -noE "$ADDR_RE" 2>/dev/null |
  grep -vwE "$GENERIC" || true)
[ -z "$addrs" ] || fail "address literal in a doc — name the talenv key instead:
$addrs"

for f in $(git ls-files '*.sops.yaml' '*.sops.rsc' | grep -v '^\.sops\.yaml$'); do
  c=$(grep -nE '^[[:space:]]*#|[[:space:]]#' "$f" | grep -oE "$ADDR_RE" |
    grep -vwE "$GENERIC" || true)
  [ -z "$c" ] || fail "$f: identifying value in a comment — sops leaves comments in cleartext:
$(echo "$c" | sed 's/^/  /')"
done

docs=$(git ls-files '*.md')
: >"$tmp/encvals"
for f in $(git ls-files '*.sops.yaml' | grep -v '^\.sops\.yaml$'); do
  sops -d "$f" 2>/dev/null | yq -r '.. | select(tag == "!!str") | .' 2>/dev/null |
    awk 'length($0) >= 8' | sort -u | while IFS= read -r v; do
    grep -Fq -- "$v" "$f" || echo "$v" # partly-encrypted files: keep the ciphertext only
  done
done | sort -u >"$tmp/encvals"

while IFS= read -r v; do
  grep -Fq -- "$v" $docs 2>/dev/null || continue
  grep -Fq -- "$v" $plaintext 2>/dev/null && continue # also plaintext: published on purpose
  fail "a doc repeats a value that only exists encrypted: '$v'
$(grep -Fn -- "$v" $docs | sed 's/^/  /')"
done <"$tmp/encvals"

domain=$(sops -d secrets/inventory.sops.yaml | yq -r .network.fqdn |
  awk -F. 'NF >= 2 { print $(NF-1) "." $NF }')
[ -n "$domain" ] || fail "cannot read the domain from secrets/inventory.sops.yaml"
readable=$(git ls-files -c -o --exclude-standard | grep -vE '\.sops\.(ya?ml|rsc)$')
names=$(echo "$readable" | xargs grep -nIF -- "$domain" 2>/dev/null || true)
[ -z "$names" ] || fail "a DNS name in a file that is not encrypted — name the talenv key instead:
$(echo "$names" | sed 's/^/  /')"

echo "secrets ok"
