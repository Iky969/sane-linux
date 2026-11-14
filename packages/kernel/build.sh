#!/usr/bin/env bash
# Recipe to build kernel base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/boot" "$PKG_DIR/x/etc"

KERNEL_SRC="$REPO_ROOT/distro/cache/vmlinuz-virt-v3.20"
if [ ! -f "$KERNEL_SRC" ]; then
    printf 'ERROR: Kernel bzImage missing at %s\n' "$KERNEL_SRC" >&2
    exit 1
fi

install -m 0644 "$KERNEL_SRC" "$PKG_DIR/x/boot/vmlinuz-virt"
ln -sf vmlinuz-virt "$PKG_DIR/x/boot/vmlinuz"
ln -sf vmlinuz-virt "$PKG_DIR/x/boot/bzImage"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
