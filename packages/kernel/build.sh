#!/usr/bin/env bash
# Recipe to build kernel base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

CACHE_DIR="$REPO_ROOT/distro/cache"
KERNEL_CACHE="$CACHE_DIR/vmlinuz-virt-v3.20"

KERNEL_PINNED_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/vmlinuz-virt"
KERNEL_PINNED_SHA256="be523954ad673a78c9cdfd3d473a8d39609f5901adfcc68402c67dc037a64c7e"

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || true)
    [ "$actual" = "$expected" ]
}

mkdir -p "$OUT_DIR" "$PKG_DIR/x/boot" "$PKG_DIR/x/etc" "$PKG_DIR/x/lib/modules" "$CACHE_DIR"

# Copy storage modules into package payload if available in cache and missing in tree
MODULES_CACHE="$CACHE_DIR/storage-modules"
if [ -d "$MODULES_CACHE" ] && [ -z "$(ls -A "$PKG_DIR/x/lib/modules" 2>/dev/null)" ]; then
    find "$MODULES_CACHE" -name "*.ko" -exec cp {} "$PKG_DIR/x/lib/modules/" \; 2>/dev/null || true
fi

KERNEL_SRC=""
if [ -f "$KERNEL_CACHE" ] && verify_sha256 "$KERNEL_CACHE" "$KERNEL_PINNED_SHA256"; then
    KERNEL_SRC="$KERNEL_CACHE"
elif [ -f "$PKG_DIR/x/boot/vmlinuz-virt" ] && verify_sha256 "$PKG_DIR/x/boot/vmlinuz-virt" "$KERNEL_PINNED_SHA256"; then
    KERNEL_SRC="$PKG_DIR/x/boot/vmlinuz-virt"
    if [ -w "$CACHE_DIR" ]; then
        cp "$KERNEL_SRC" "$KERNEL_CACHE" 2>/dev/null || true
    fi
else
    printf '==> Downloading Alpine netboot kernel (v3.20 pinned)...\n'
    TMP_KERNEL="$(mktemp /tmp/vmlinuz-virt-XXXXXX)"
    curl -fL -s --retry 3 --connect-timeout 15 -o "$TMP_KERNEL" \
        "$KERNEL_PINNED_URL" \
        || { printf 'ERROR: Failed to download Alpine netboot kernel (v3.20)\n' >&2; exit 1; }
    if ! verify_sha256 "$TMP_KERNEL" "$KERNEL_PINNED_SHA256"; then
        printf 'ERROR: SHA256 mismatch for downloaded kernel!\n' >&2
        rm -f "$TMP_KERNEL"
        exit 1
    fi
    if [ -w "$CACHE_DIR" ]; then
        mv "$TMP_KERNEL" "$KERNEL_CACHE" 2>/dev/null || cp "$TMP_KERNEL" "$KERNEL_CACHE" 2>/dev/null || true
    fi
    KERNEL_SRC="$KERNEL_CACHE"
fi

# Verify kernel version matches module tree path
kver=$(strings "$KERNEL_SRC" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-virt' | head -n1 || true)
if [ -d "$PKG_DIR/x/lib/modules" ] && [ -n "$kver" ]; then
    sample_mod=$(find "$PKG_DIR/x/lib/modules" -name "*.ko" 2>/dev/null | head -n1 || true)
    if [ -n "$sample_mod" ] && command -v modinfo >/dev/null 2>&1; then
        mver=$(modinfo -F vermagic "$sample_mod" 2>/dev/null | awk '{print $1}' || true)
        if [ -n "$mver" ] && [ "$kver" != "$mver" ]; then
            printf 'ERROR: Kernel version (%s) does not match module vermagic (%s)!\n' "$kver" "$mver" >&2
            exit 1
        fi
    fi
fi

if [ "$KERNEL_SRC" != "$PKG_DIR/x/boot/vmlinuz-virt" ]; then
    install -m 0644 "$KERNEL_SRC" "$PKG_DIR/x/boot/vmlinuz-virt"
else
    chmod 0644 "$PKG_DIR/x/boot/vmlinuz-virt"
fi
ln -sf vmlinuz-virt "$PKG_DIR/x/boot/vmlinuz"
ln -sf vmlinuz-virt "$PKG_DIR/x/boot/bzImage"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
