#!/usr/bin/env bash
# Recipe to build disk-tools base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/usr/sbin"

command -v readelf >/dev/null 2>&1 || {
    printf 'ERROR: readelf is required for static ELF verification\n' >&2
    exit 1
}

# Verify required static binaries exist and are strictly statically linked ELF
for bin in sgdisk mke2fs mkfs.fat; do
    bin_path="$PKG_DIR/x/usr/sbin/$bin"
    if [ ! -x "$bin_path" ]; then
        printf 'ERROR: Required disk tool binary missing or not executable: %s\n' "$bin_path" >&2
        exit 1
    fi
    if ! readelf -h "$bin_path" >/dev/null 2>&1; then
        printf 'ERROR: %s is not a valid ELF binary\n' "$bin_path" >&2
        exit 1
    fi
    if readelf -lW "$bin_path" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
        printf 'ERROR: %s contains dynamic INTERP segment (must be statically linked)\n' "$bin_path" >&2
        exit 1
    fi
done

# Ensure symlinks exist
[ -L "$PKG_DIR/x/usr/sbin/mkfs.ext4" ] || ln -sf mke2fs "$PKG_DIR/x/usr/sbin/mkfs.ext4"
[ -L "$PKG_DIR/x/usr/sbin/mkfs.ext2" ] || ln -sf mke2fs "$PKG_DIR/x/usr/sbin/mkfs.ext2"
[ -L "$PKG_DIR/x/usr/sbin/mkfs.vfat" ] || ln -sf mkfs.fat "$PKG_DIR/x/usr/sbin/mkfs.vfat"

chmod 0755 "$PKG_DIR/x/usr/sbin/sgdisk" "$PKG_DIR/x/usr/sbin/mke2fs" "$PKG_DIR/x/usr/sbin/mkfs.fat"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
