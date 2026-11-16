#!/usr/bin/env bash
# Recipe to build doas package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

CACHE_DIR="$REPO_ROOT/distro/cache"
BUILD_ROOT="$REPO_ROOT/distro/build"
TARBALL="$CACHE_DIR/opendoas-6.8.2.tar.gz"
URL="https://github.com/Duncaen/OpenDoas/releases/download/v6.8.2/opendoas-6.8.2.tar.gz"
EXPECTED_SHA256="28dca29adec5f4336465812d9e2243f599e62a78903de71c24f0cd6fe667edac"

mkdir -p "$OUT_DIR"

if [ -x "$PKG_DIR/x/usr/bin/doas" ] && [ -f "$PKG_DIR/x/etc/doas.conf" ] && [ "${REBUILD:-0}" != "1" ]; then
    printf 'Using prebuilt doas payload in %s/x\n' "$PKG_DIR"
    if ! command -v readelf >/dev/null 2>&1; then
        printf 'ERROR: readelf is required for static ELF verification\n' >&2
        exit 1
    fi
    if ! readelf -h "$PKG_DIR/x/usr/bin/doas" >/dev/null 2>&1; then
        printf 'ERROR: %s is not a valid ELF binary\n' "$PKG_DIR/x/usr/bin/doas" >&2
        exit 1
    fi
    if readelf -lW "$PKG_DIR/x/usr/bin/doas" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
        printf 'ERROR: %s contains dynamic INTERP segment (must be statically linked)\n' "$PKG_DIR/x/usr/bin/doas" >&2
        exit 1
    fi
    chmod 0600 "$PKG_DIR/x/etc/doas.conf"
    chmod 0755 "$PKG_DIR/x/usr/bin/doas"
    "$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR" "$BUILD_ROOT"

# 1. Download and verify source tarball
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

# 2. Extract into build scratch directory
SRC_DIR="$BUILD_ROOT/opendoas-6.8.2"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
tar -xzf "$TARBALL" -C "$BUILD_ROOT"

cd "$SRC_DIR"

# 3. musl has crypt in libc.a. Create an empty stub libcrypt.a so -lcrypt links cleanly
ar cr "$BUILD_ROOT/libcrypt.a"

# 4. Configure
CC="musl-gcc -static" LDFLAGS="-static" ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --enable-static \
    --without-pam \
    --with-timestamp

# 5. Compile
make -j"$(nproc)" CC="musl-gcc -static" LDLIBS="-L$BUILD_ROOT -lcrypt"

# 6. Install into $PKG_DIR/x
rm -rf "$PKG_DIR/x"
mkdir -p "$PKG_DIR/x/usr/bin" "$PKG_DIR/x/etc"
install -m 0755 doas "$PKG_DIR/x/usr/bin/doas"
strip "$PKG_DIR/x/usr/bin/doas" 2>/dev/null || true

# 7. Default config
cat > "$PKG_DIR/x/etc/doas.conf" <<'EOF'
permit persist :wheel
EOF
chmod 0600 "$PKG_DIR/x/etc/doas.conf"

# 8. Verify static ELF without dynamic INTERP
if ! command -v readelf >/dev/null 2>&1; then
    printf 'ERROR: readelf is required for static ELF verification\n' >&2
    exit 1
fi

if ! readelf -h "$PKG_DIR/x/usr/bin/doas" >/dev/null 2>&1; then
    printf 'ERROR: %s is not a valid ELF binary\n' "$PKG_DIR/x/usr/bin/doas" >&2
    exit 1
fi

if readelf -lW "$PKG_DIR/x/usr/bin/doas" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
    printf 'ERROR: %s contains dynamic INTERP segment (must be statically linked)\n' "$PKG_DIR/x/usr/bin/doas" >&2
    exit 1
fi

# Clean docs/man to keep package lean (not installed into payload)
# SPM anti-setuid invariant: binary payload must be 0755; setuid 4755 is set during rootfs/image assembly.
chmod 0755 "$PKG_DIR/x/usr/bin/doas"

# 9. Package
"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
