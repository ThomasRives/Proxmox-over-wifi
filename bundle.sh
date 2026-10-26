#!/usr/bin/env bash

set -euo pipefail

VERSION="1.0.0"
BUNDLE_DIR="proxmox-over-wifi-${VERSION}"

PACKAGES=(
    wireless-tools
    wpasupplicant
    dnsmasq
)

echo "Creating bundle directory..."
rm -rf "$BUNDLE_DIR"
mkdir -p "${BUNDLE_DIR}/packages"

echo "Refreshing package index..."
apt update

echo "Downloading packages and dependencies..."

apt-get install \
    --download-only \
    --reinstall \
    -o Dir::Cache::archives="$(pwd)/${BUNDLE_DIR}/packages" \
    "${PACKAGES[@]}"

cp install.sh "${BUNDLE_DIR}/"
cp install-offline.sh "${BUNDLE_DIR}/"

tar czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}"

echo
echo "Bundle complete:"
echo "${BUNDLE_DIR}.tar.gz"
