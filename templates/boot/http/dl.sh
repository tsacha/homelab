#!/bin/bash

TALOS_VERSION="v1.11.3" # renovate: datasource=github-releases depName=talos packageName=siderolabs/talos
BASE_URL="https://github.com/siderolabs/talos/releases/download/$TALOS_VERSION"
CHECKSUM_URL="$BASE_URL/sha256sum.txt"

# Download checksum file
curl -sSL "$CHECKSUM_URL" -o /tmp/sha256sum.txt

# Declare an associative array of desired files and their target paths
declare -A FILES=(
  ["vmlinuz-amd64"]="/srv/tftp/vmlinuz-x86_64"
  ["initramfs-amd64.xz"]="/srv/tftp/initramfs-x86_64.xz"
  ["vmlinuz-arm64"]="/srv/tftp/vmlinuz-arm64"
  ["initramfs-arm64.xz"]="/srv/tftp/initramfs-arm64.xz"
)

for FILE in "${!FILES[@]}"; do
  DEST="${FILES[$FILE]}"
  EXPECTED_SUM=$(grep "  $FILE$" /tmp/sha256sum.txt | awk '{print $1}')

  if [[ -f "$DEST" ]]; then
    ACTUAL_SUM=$(sha256sum "$DEST" | awk '{print $1}')
    if [[ "$ACTUAL_SUM" == "$EXPECTED_SUM" ]]; then
      echo "$DEST is up to date, skipping download."
      continue
    else
      echo "$DEST exists but checksum mismatch, re-downloading."
    fi
  else
    echo "$DEST does not exist, downloading."
  fi

  curl -sSL "$BASE_URL/$FILE" -o "$DEST"
done
