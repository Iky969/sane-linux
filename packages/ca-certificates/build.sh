#!/usr/bin/env bash
# Recipe to build ca-certificates package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR"

# Clean and recreate staging payload
rm -rf "$PKG_DIR/x"
mkdir -p "$PKG_DIR/x/etc/ssl/certs"

if [ -f "/etc/ssl/certs/ca-certificates.crt" ]; then
    cp -a /etc/ssl/certs/ca-certificates.crt "$PKG_DIR/x/etc/ssl/certs/ca-certificates.crt"
else
    printf 'ERROR: /etc/ssl/certs/ca-certificates.crt not found\n' >&2
    exit 1
fi

# Create relative symlink: cert.pem -> certs/ca-certificates.crt
ln -sf certs/ca-certificates.crt "$PKG_DIR/x/etc/ssl/cert.pem"

# Standardize permissions
chmod -R u+rwX,go+rX "$PKG_DIR/x"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
