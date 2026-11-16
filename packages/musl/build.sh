#!/usr/bin/env bash
# Recipe to build musl base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR"

# Clean and recreate staging payload
rm -rf "$PKG_DIR/x"
mkdir -p "$PKG_DIR/x/usr/include" "$PKG_DIR/x/usr/lib" "$PKG_DIR/x/lib"

# 1. Copy musl headers
if [ -d "/usr/include/x86_64-linux-musl" ]; then
    cp -a /usr/include/x86_64-linux-musl/* "$PKG_DIR/x/usr/include/"
else
    printf 'ERROR: /usr/include/x86_64-linux-musl not found\n' >&2
    exit 1
fi

# 2. Copy static libraries and runtime objects (libc.a, crt1.o, crti.o, crtn.o, etc.)
if [ -d "/usr/lib/x86_64-linux-musl" ]; then
    cp -a /usr/lib/x86_64-linux-musl/* "$PKG_DIR/x/usr/lib/"
else
    printf 'ERROR: /usr/lib/x86_64-linux-musl not found\n' >&2
    exit 1
fi

# 3. Copy dynamic linker if present
if [ -f "/usr/lib/x86_64-linux-musl/libc.so" ]; then
    cp -L "/usr/lib/x86_64-linux-musl/libc.so" "$PKG_DIR/x/lib/ld-musl-x86_64.so.1"
    chmod 0755 "$PKG_DIR/x/lib/ld-musl-x86_64.so.1"
elif [ -e "/lib/ld-musl-x86_64.so.1" ]; then
    cp -L "/lib/ld-musl-x86_64.so.1" "$PKG_DIR/x/lib/ld-musl-x86_64.so.1"
    chmod 0755 "$PKG_DIR/x/lib/ld-musl-x86_64.so.1"
fi

# Standardize permissions
chmod -R u+rwX,go+rX "$PKG_DIR/x"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
