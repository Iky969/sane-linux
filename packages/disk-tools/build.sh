#!/usr/bin/env bash
# Recipe to build disk-tools base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/usr/sbin"

# Verify required static binaries exist in package payload
for bin in sgdisk mke2fs mkfs.fat; do
    if [ ! -x "$PKG_DIR/x/usr/sbin/$bin" ]; then
        printf 'ERROR: Required disk tool binary missing or not executable: %s\n' "$PKG_DIR/x/usr/sbin/$bin" >&2
        exit 1
    fi
done

# Ensure symlinks exist
[ -L "$PKG_DIR/x/usr/sbin/mkfs.ext4" ] || ln -sf mke2fs "$PKG_DIR/x/usr/sbin/mkfs.ext4"
[ -L "$PKG_DIR/x/usr/sbin/mkfs.ext2" ] || ln -sf mke2fs "$PKG_DIR/x/usr/sbin/mkfs.ext2"
[ -L "$PKG_DIR/x/usr/sbin/mkfs.vfat" ] || ln -sf mkfs.fat "$PKG_DIR/x/usr/sbin/mkfs.vfat"

chmod 0755 "$PKG_DIR/x/usr/sbin/sgdisk" "$PKG_DIR/x/usr/sbin/mke2fs" "$PKG_DIR/x/usr/sbin/mkfs.fat"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
