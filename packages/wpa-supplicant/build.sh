#!/usr/bin/env bash
# Recipe to build the S.A.N.E wpa_supplicant package (static musl + LibreSSL).
# Fail-closed: pinned tarball + SHA256, static ELF verification, deterministic pack.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

CACHE_DIR="$REPO_ROOT/distro/cache"
BUILD_ROOT="$REPO_ROOT/distro/build"
TARBALL="$CACHE_DIR/wpa_supplicant-2.10.tar.gz"
URL="https://w1.fi/releases/wpa_supplicant-2.10.tar.gz"
EXPECTED_SHA256="20df7ae5154b3830355f8ab4269123a87affdea59fe74fe9292a91d0d7e17b2f"
SRC_DIR="$BUILD_ROOT/wpa_supplicant-2.10"
UAPI_DIR="$BUILD_ROOT/wpa-uapi-include"
LIBRESSL_PREFIX="$REPO_ROOT/packages/libressl/x/usr"
CONF="$PKG_DIR/x/etc/wpa_supplicant.conf"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# Static ELF guard shared by the prebuilt fast path and the fresh-build path.
verify_static_elf() {
    local bin="$1"
    command -v readelf >/dev/null 2>&1 || die "readelf is required for static ELF verification"
    [ -x "$bin" ] || die "missing executable payload: $bin"
    readelf -h "$bin" >/dev/null 2>&1 || die "$bin is not a valid ELF binary"
    if readelf -lW "$bin" 2>/dev/null | grep -E -q 'PT_INTERP|[[:space:]]INTERP[[:space:]]'; then
        die "$bin contains a dynamic INTERP segment (must be statically linked)"
    fi
    if readelf -lW "$bin" 2>/dev/null | grep -E -q '[[:space:]]DYNAMIC[[:space:]]'; then
        die "$bin contains a DYNAMIC segment (must be statically linked)"
    fi
}

# Fast path: reuse an already-staged payload, but still verify it and re-pack
# deterministically. REBUILD=1 forces a full source build.
if [ -x "$PKG_DIR/x/usr/bin/wpa_supplicant" ] && \
   [ -x "$PKG_DIR/x/usr/bin/wpa_cli" ] && [ -f "$CONF" ] && \
   [ "${REBUILD:-0}" != "1" ]; then
    printf 'Using prebuilt wpa_supplicant payload in %s/x\n' "$PKG_DIR"
    verify_static_elf "$PKG_DIR/x/usr/bin/wpa_supplicant"
    verify_static_elf "$PKG_DIR/x/usr/bin/wpa_cli"
    chmod 0755 "$PKG_DIR/x/usr/bin/wpa_supplicant" "$PKG_DIR/x/usr/bin/wpa_cli"
    chmod 0600 "$CONF"
    SOURCE_DATE_EPOCH=0 "$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR" "$BUILD_ROOT"

# 0. Toolchain and build-host prerequisites (fail closed, never fake a binary).
command -v musl-gcc >/dev/null 2>&1 || die "musl-gcc not found (install the musl toolchain); refusing to build a non-static binary"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
command -v curl >/dev/null 2>&1 || die "curl is required to fetch the pinned source"
command -v make >/dev/null 2>&1 || die "make is required"
command -v strip >/dev/null 2>&1 || die "strip is required"
command -v gcc >/dev/null 2>&1 || die "gcc is required to locate the host UAPI asm headers"

# 1. LibreSSL dependency: static libs + headers must exist before compiling.
if [ ! -f "$LIBRESSL_PREFIX/lib/libssl.a" ] || [ ! -f "$LIBRESSL_PREFIX/lib/libcrypto.a" ] || \
   [ ! -f "$LIBRESSL_PREFIX/include/openssl/ssl.h" ]; then
    printf 'Building libressl dependency first...\n'
    "$REPO_ROOT/packages/libressl/build.sh" "$OUT_DIR"
fi
[ -f "$LIBRESSL_PREFIX/lib/libssl.a" ] || die "LibreSSL static library not found at $LIBRESSL_PREFIX/lib/libssl.a"
[ -f "$LIBRESSL_PREFIX/lib/libcrypto.a" ] || die "LibreSSL static library not found at $LIBRESSL_PREFIX/lib/libcrypto.a"
[ -f "$LIBRESSL_PREFIX/include/openssl/ssl.h" ] || die "LibreSSL headers not found at $LIBRESSL_PREFIX/include/openssl/ssl.h"

# 2. Isolated Linux UAPI headers for CONFIG_DRIVER_WEXT. We copy only linux/,
#    asm/, asm-generic/ into a private include dir so <linux/wireless.h> resolves
#    there while userspace headers still come from musl (never /usr/include).
ASM_SRC=""
for candidate in "/usr/include/$(gcc -dumpmachine)/asm" "/usr/include/asm"; do
    [ -d "$candidate" ] && { ASM_SRC="$candidate"; break; }
done
[ -d /usr/include/linux ] || die "/usr/include/linux UAPI headers not found (install linux-libc-dev)"
[ -d /usr/include/asm-generic ] || die "/usr/include/asm-generic UAPI headers not found"
[ -n "$ASM_SRC" ] || die "host asm/ UAPI headers not found; cannot build the WEXT driver"
rm -rf "$UAPI_DIR"
mkdir -p "$UAPI_DIR"
cp -aL /usr/include/linux "$UAPI_DIR/linux"
cp -aL /usr/include/asm-generic "$UAPI_DIR/asm-generic"
cp -aL "$ASM_SRC" "$UAPI_DIR/asm"

# 3. Download and verify the pinned source tarball.
if [ -f "$TARBALL" ]; then
    actual_sha256="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
    if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
        printf 'Checksum mismatch for %s, re-downloading...\n' "$TARBALL" >&2
        rm -f "$TARBALL"
    fi
fi
if [ ! -f "$TARBALL" ]; then
    printf 'Downloading %s...\n' "$URL"
    curl -fSL --retry 3 --connect-timeout 15 -o "$TARBALL.part" "$URL" || die "failed to download $URL"
    mv "$TARBALL.part" "$TARBALL"
    actual_sha256="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
    if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
        printf 'ERROR: Checksum mismatch for %s\nExpected: %s\nGot: %s\n' \
            "$TARBALL" "$EXPECTED_SHA256" "$actual_sha256" >&2
        rm -f "$TARBALL"
        exit 1
    fi
fi

# 4. Extract into build scratch directory.
if [ ! -f "$SRC_DIR/wpa_supplicant/Makefile" ]; then
    printf 'Extracting %s...\n' "$TARBALL"
    rm -rf "$SRC_DIR"
    tar -xzf "$TARBALL" -C "$BUILD_ROOT"
fi
[ -f "$SRC_DIR/wpa_supplicant/Makefile" ] || die "source tree incomplete at $SRC_DIR"

# 5. Deterministic build configuration: musl + repo LibreSSL, WEXT driver only.
#    CFLAGS/LIBS are set here (not on the make command line) so the upstream
#    Makefile's own CFLAGS += rules remain in effect.
cd "$SRC_DIR/wpa_supplicant"
cat > .config <<EOF
CC=musl-gcc -static
CFLAGS += -O2 -static -I$UAPI_DIR -I$LIBRESSL_PREFIX/include
LDFLAGS += -static -L$LIBRESSL_PREFIX/lib
LIBS += -L$LIBRESSL_PREFIX/lib

CONFIG_NO_GITVER=y
CONFIG_TLS=openssl
CONFIG_TLSV12=y
CONFIG_DRIVER_WEXT=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_EAP_MD5=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_TLS=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TTLS=y
CONFIG_EAP_GTC=y
CONFIG_EAP_PSK=y
CONFIG_IEEE80211N=y
CONFIG_IEEE80211AC=y
EOF

# 6. Compile wpa_supplicant and wpa_cli.
printf 'Compiling wpa_supplicant (static musl + LibreSSL)...\n'
make -j"$(nproc)" wpa_supplicant wpa_cli

# 7. Install binaries. Do NOT wipe the whole x/ tree: the tracked, documented
#    etc/wpa_supplicant.conf template lives there.
mkdir -p "$PKG_DIR/x/usr/bin" "$PKG_DIR/x/etc"
install -m 0755 wpa_supplicant "$PKG_DIR/x/usr/bin/wpa_supplicant"
install -m 0755 wpa_cli "$PKG_DIR/x/usr/bin/wpa_cli"
strip "$PKG_DIR/x/usr/bin/wpa_supplicant" "$PKG_DIR/x/usr/bin/wpa_cli" 2>/dev/null || true
[ -f "$CONF" ] || die "documented config template is missing at $CONF"
chmod 0600 "$CONF"

# 8. Verify static ELF with no PT_INTERP for both payload binaries.
verify_static_elf "$PKG_DIR/x/usr/bin/wpa_supplicant"
verify_static_elf "$PKG_DIR/x/usr/bin/wpa_cli"

chmod 0755 "$PKG_DIR/x/usr/bin/wpa_supplicant" "$PKG_DIR/x/usr/bin/wpa_cli"
chmod 0600 "$CONF"

# 9. Deterministic package (build-package.sh regenerates .META/files and sha256).
SOURCE_DATE_EPOCH=0 "$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR"
