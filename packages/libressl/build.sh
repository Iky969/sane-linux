#!/usr/bin/env bash
# Recipe to build libressl package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

CACHE_DIR="$REPO_ROOT/distro/cache"
BUILD_ROOT="$REPO_ROOT/distro/build"
TARBALL="$CACHE_DIR/libressl-3.9.2.tar.gz"
URL="https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-3.9.2.tar.gz"
EXPECTED_SHA256="7b031dac64a59eb6ee3304f7ffb75dad33ab8c9d279c847f92c89fb846068f97"

mkdir -p "$OUT_DIR" "$CACHE_DIR" "$BUILD_ROOT"

# 1. Cache source tarball and verify checksum
if [ -f "$TARBALL" ]; then
    actual_sha256="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
    if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
        printf 'Checksum mismatch for %s, re-downloading...\n' "$TARBALL" >&2
        rm -f "$TARBALL"
    fi
fi

if [ ! -f "$TARBALL" ]; then
    printf 'Downloading %s...\n' "$URL"
    curl -fSL --retry 3 --connect-timeout 15 -o "$TARBALL.part" "$URL"
    mv "$TARBALL.part" "$TARBALL"
    actual_sha256="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
    if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
        printf 'ERROR: Checksum mismatch for %s\nExpected: %s\nGot: %s\n' "$TARBALL" "$EXPECTED_SHA256" "$actual_sha256" >&2
        rm -f "$TARBALL"
        exit 1
    fi
fi

# 2. Extract in build scratch directory
SRC_DIR="$BUILD_ROOT/libressl-3.9.2"
if [ ! -f "$SRC_DIR/configure" ]; then
    printf 'Extracting %s...\n' "$TARBALL"
    tar -xzf "$TARBALL" -C "$BUILD_ROOT"
fi

# 3. Configure
cd "$SRC_DIR"
if [ ! -f "Makefile" ]; then
    printf 'Configuring LibreSSL with musl-gcc...\n'
    CC="musl-gcc -static" ./configure --prefix=/usr --disable-shared --enable-static
fi

# 4. Build
printf 'Compiling LibreSSL...\n'
make -j"$(nproc)" LDFLAGS="-all-static"

# 5. Install to package staging payload
rm -rf "$PKG_DIR/x"
make install DESTDIR="$PKG_DIR/x" LDFLAGS="-all-static"

# 6. Clean unnecessary manpages/docs and libtool archive poison
rm -rf "$PKG_DIR/x/usr/share/man"
rmdir "$PKG_DIR/x/usr/share" 2>/dev/null || true
rm -f "$PKG_DIR/x/usr/lib"/*.la 2>/dev/null || true
strip -s "$PKG_DIR/x/usr/bin"/* 2>/dev/null || true
strip --strip-debug "$PKG_DIR/x/usr/lib"/*.a 2>/dev/null || true

# 7. Standardize permissions
chmod -R u+rwX,go+rX "$PKG_DIR/x"

# 8. Package
"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
