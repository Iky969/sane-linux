#!/usr/bin/env bash
# Recipe to build sane-hello package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR"
chmod 0755 "$PKG_DIR/x/usr/bin/sane-hello"
chmod 0644 "$PKG_DIR/x/usr/share/ninit/services/sane-hello.service"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
