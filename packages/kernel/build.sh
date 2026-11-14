#!/usr/bin/env bash
# Recipe to build kernel base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

CACHE_DIR="$REPO_ROOT/distro/cache"
KERNEL_CACHE="$CACHE_DIR/vmlinuz-virt-v3.20"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/boot" "$PKG_DIR/x/etc" "$CACHE_DIR"

if [ -f "$KERNEL_CACHE" ]; then
    KERNEL_SRC="$KERNEL_CACHE"
elif [ -f "$PKG_DIR/x/boot/vmlinuz-virt" ]; then
    cp "$PKG_DIR/x/boot/vmlinuz-virt" "$KERNEL_CACHE"
    KERNEL_SRC="$KERNEL_CACHE"
else
    printf '==> Downloading Alpine netboot kernel (v3.20)...\n'
    curl -fL -s --retry 3 --connect-timeout 15 -o "$KERNEL_CACHE.part" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/vmlinuz-virt" \
        || { printf 'ERROR: Failed to download Alpine netboot kernel (v3.20)\n' >&2; exit 1; }
    mv "$KERNEL_CACHE.part" "$KERNEL_CACHE"
    KERNEL_SRC="$KERNEL_CACHE"
fi

install -m 0644 "$KERNEL_SRC" "$PKG_DIR/x/boot/vmlinuz-virt"
ln -sf vmlinuz-virt "$PKG_DIR/x/boot/vmlinuz"
ln -sf vmlinuz-virt "$PKG_DIR/x/boot/bzImage"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
