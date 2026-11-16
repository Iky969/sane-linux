#!/usr/bin/env bash
# Recipe to build curl package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

CACHE_DIR="$REPO_ROOT/distro/cache"
BUILD_ROOT="$REPO_ROOT/distro/build"
TARBALL="$CACHE_DIR/curl-8.11.0.tar.xz"
URL="https://curl.se/download/curl-8.11.0.tar.xz"
EXPECTED_SHA256="db59cf0d671ca6e7f5c2c5ec177084a33a79e04c97e71cf183a5cdea235054eb"

mkdir -p "$OUT_DIR"

if [ -x "$PKG_DIR/x/usr/bin/curl" ] && [ "${REBUILD:-0}" != "1" ]; then
    printf 'Using prebuilt curl payload in %s/x\n' "$PKG_DIR"
    if ! command -v readelf >/dev/null 2>&1; then
        printf 'ERROR: readelf is required for static ELF verification\n' >&2
        exit 1
    fi
    if ! readelf -h "$PKG_DIR/x/usr/bin/curl" >/dev/null 2>&1; then
        printf 'ERROR: %s is not a valid ELF binary\n' "$PKG_DIR/x/usr/bin/curl" >&2
        exit 1
    fi
    if readelf -lW "$PKG_DIR/x/usr/bin/curl" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
        printf 'ERROR: %s contains dynamic INTERP segment (must be statically linked)\n' "$PKG_DIR/x/usr/bin/curl" >&2
        exit 1
    fi
    chmod -R u+rwX,go+rX "$PKG_DIR/x"
    "$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR" "$BUILD_ROOT"

# 1. Ensure libressl is built first
LIBRESSL_PREFIX="$REPO_ROOT/packages/libressl/x/usr"
if [ ! -d "$LIBRESSL_PREFIX" ] || [ ! -f "$LIBRESSL_PREFIX/lib/libssl.a" ]; then
    printf 'Building libressl dependency first...\n'
    "$REPO_ROOT/packages/libressl/build.sh" "$OUT_DIR"
fi

[ -f "$LIBRESSL_PREFIX/lib/libssl.a" ] || {
    printf 'ERROR: LibreSSL static library not found at %s/lib/libssl.a\n' "$LIBRESSL_PREFIX" >&2
    exit 1
}

# 2. Cache source tarball and verify checksum
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

# 3. Extract in build scratch directory
SRC_DIR="$BUILD_ROOT/curl-8.11.0"
if [ ! -f "$SRC_DIR/configure" ]; then
    printf 'Extracting %s...\n' "$TARBALL"
    tar -xJf "$TARBALL" -C "$BUILD_ROOT"
fi

# 4. Configure
cd "$SRC_DIR"
if [ ! -f "Makefile" ]; then
    printf 'Configuring curl with musl-gcc and LibreSSL...\n'
    CC="musl-gcc -static" LDFLAGS="-static" ./configure \
        --prefix=/usr \
        --disable-shared \
        --enable-static \
        --with-openssl="$LIBRESSL_PREFIX" \
        --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
        --disable-ldap \
        --disable-sspi \
        --disable-manual \
        --disable-libcurl-option \
        --disable-docs \
        --without-libpsl
fi

# 5. Compile curl binary
printf 'Compiling curl...\n'
make -j"$(nproc)" LDFLAGS="-static -all-static -L$LIBRESSL_PREFIX/lib"

# 6. Install into $PKG_DIR/x/usr/bin/curl
rm -rf "$PKG_DIR/x"
mkdir -p "$PKG_DIR/x/usr/bin"
install -m 0755 src/curl "$PKG_DIR/x/usr/bin/curl"
strip "$PKG_DIR/x/usr/bin/curl" 2>/dev/null || true

# 7. Verify static ELF without dynamic INTERP
if ! command -v readelf >/dev/null 2>&1; then
    printf 'ERROR: readelf is required for static ELF verification\n' >&2
    exit 1
fi

if ! readelf -h "$PKG_DIR/x/usr/bin/curl" >/dev/null 2>&1; then
    printf 'ERROR: %s is not a valid ELF binary\n' "$PKG_DIR/x/usr/bin/curl" >&2
    exit 1
fi

if readelf -lW "$PKG_DIR/x/usr/bin/curl" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
    printf 'ERROR: %s contains dynamic INTERP segment (must be statically linked)\n' "$PKG_DIR/x/usr/bin/curl" >&2
    exit 1
fi

# Standardize permissions
chmod -R u+rwX,go+rX "$PKG_DIR/x"

# 8. Package
"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
