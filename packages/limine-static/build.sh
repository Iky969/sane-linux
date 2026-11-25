#!/usr/bin/env bash
# Recipe to build limine-static base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"
CACHE_DIR="$REPO_ROOT/distro/cache"
LIMINE_VERSION="12.9.6"
LIMINE_URL="https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VERSION}/limine-binary.tar.xz"
EXPECTED_SHA256="939f670e0831cc940453fd3a0ddfb2b324c0b4e3c5d0e741c190aa0d13df0103"
TARBALL="$CACHE_DIR/limine-binary-v${LIMINE_VERSION}.tar.xz"
TMP_LIMINE=""

cleanup() {
    if [ -n "$TMP_LIMINE" ] && [ -d "$TMP_LIMINE" ]; then
        rm -rf "$TMP_LIMINE"
    fi
}
trap cleanup EXIT

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

verify_static_elf() {
    local bin="$1"
    command -v readelf >/dev/null 2>&1 || die "readelf is required for static ELF verification"
    [ -x "$bin" ] || die "missing executable payload: $bin"
    readelf -h "$bin" >/dev/null 2>&1 || die "$bin is not a valid ELF binary"
    if readelf -lW "$bin" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
        die "$bin contains dynamic INTERP segment (must be statically linked)"
    fi
    if readelf -lW "$bin" 2>/dev/null | grep -E -q '[[:space:]]DYNAMIC[[:space:]]'; then
        die "$bin contains DYNAMIC segment (must be statically linked)"
    fi
}

mkdir -p "$OUT_DIR" "$PKG_DIR/x/usr/share/limine" "$PKG_DIR/x/usr/bin" "$CACHE_DIR"

# Ensure limine binaries exist in package tree or cache
if [ "${REBUILD:-0}" != "1" ] && \
   [ -f "$PKG_DIR/x/usr/share/limine/limine-bios.sys" ] && \
   [ -f "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin" ] && \
   [ -f "$PKG_DIR/x/usr/share/limine/BOOTX64.EFI" ] && \
   [ -f "$PKG_DIR/x/usr/share/limine/BOOTIA32.EFI" ] && \
   [ -x "$PKG_DIR/x/usr/bin/limine" ]; then
    verify_static_elf "$PKG_DIR/x/usr/bin/limine"
    # Already present in package tree; populate cache if writable
    if [ -w "$CACHE_DIR" ]; then
        cp -u "$PKG_DIR/x/usr/share/limine/limine-bios.sys" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/share/limine/BOOTX64.EFI" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/share/limine/BOOTIA32.EFI" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/bin/limine" "$CACHE_DIR/" 2>/dev/null || true
    fi
elif [ "${REBUILD:-0}" = "1" ] || [ ! -f "$CACHE_DIR/limine-bios.sys" ] || [ ! -f "$CACHE_DIR/limine-uefi-cd.bin" ] || [ ! -x "$CACHE_DIR/limine" ] || [ ! -f "$CACHE_DIR/BOOTX64.EFI" ] || [ ! -f "$CACHE_DIR/BOOTIA32.EFI" ]; then
    printf '==> Downloading and preparing limine static binaries (v%s)...\n' "$LIMINE_VERSION"
    TMP_LIMINE="$(mktemp -d /tmp/limine-fetch-XXXXXX)"
    local_tar="$TARBALL"
    if [ ! -w "$CACHE_DIR" ] && [ ! -f "$local_tar" ]; then
        local_tar="$TMP_LIMINE/limine-binary.tar.xz"
    fi
    if [ -f "$local_tar" ]; then
        actual_sha256="$(sha256sum "$local_tar" | cut -d' ' -f1)"
        if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
            printf 'Checksum mismatch for %s, re-downloading...\n' "$local_tar" >&2
            rm -f "$local_tar"
        fi
    fi
    if [ ! -f "$local_tar" ]; then
        curl -fSL --retry 3 --connect-timeout 15 -o "${local_tar}.part" "$LIMINE_URL" \
            || die "Failed to download $LIMINE_URL"
        mv -f "${local_tar}.part" "$local_tar"
        actual_sha256="$(sha256sum "$local_tar" | cut -d' ' -f1)"
        if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
            rm -f "$local_tar"
            die "Checksum mismatch for $local_tar (expected $EXPECTED_SHA256, got $actual_sha256)"
        fi
    fi
    tar -xJf "$local_tar" -C "$TMP_LIMINE"
    (cd "$TMP_LIMINE/limine-binary" && gcc -O2 -static -fpie -Wl,-z,now limine.c -o limine)
    strip "$TMP_LIMINE/limine-binary/limine"
    verify_static_elf "$TMP_LIMINE/limine-binary/limine"

    install -m 0644 "$TMP_LIMINE/limine-binary/limine-bios.sys" "$PKG_DIR/x/usr/share/limine/limine-bios.sys"
    install -m 0644 "$TMP_LIMINE/limine-binary/limine-uefi-cd.bin" "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin"
    install -m 0644 "$TMP_LIMINE/limine-binary/BOOTX64.EFI" "$PKG_DIR/x/usr/share/limine/BOOTX64.EFI"
    install -m 0644 "$TMP_LIMINE/limine-binary/BOOTIA32.EFI" "$PKG_DIR/x/usr/share/limine/BOOTIA32.EFI"
    install -m 0755 "$TMP_LIMINE/limine-binary/limine" "$PKG_DIR/x/usr/bin/limine"

    if [ -w "$CACHE_DIR" ]; then
        cp "$TMP_LIMINE/limine-binary/limine-bios.sys" "$CACHE_DIR/" 2>/dev/null || true
        cp "$TMP_LIMINE/limine-binary/limine-uefi-cd.bin" "$CACHE_DIR/" 2>/dev/null || true
        cp "$TMP_LIMINE/limine-binary/BOOTX64.EFI" "$CACHE_DIR/" 2>/dev/null || true
        cp "$TMP_LIMINE/limine-binary/BOOTIA32.EFI" "$CACHE_DIR/" 2>/dev/null || true
        cp "$TMP_LIMINE/limine-binary/limine" "$CACHE_DIR/" 2>/dev/null || true
    fi
else
    verify_static_elf "$CACHE_DIR/limine"
    install -m 0644 "$CACHE_DIR/limine-bios.sys" "$PKG_DIR/x/usr/share/limine/limine-bios.sys"
    install -m 0644 "$CACHE_DIR/limine-uefi-cd.bin" "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin"
    install -m 0644 "$CACHE_DIR/BOOTX64.EFI" "$PKG_DIR/x/usr/share/limine/BOOTX64.EFI"
    install -m 0644 "$CACHE_DIR/BOOTIA32.EFI" "$PKG_DIR/x/usr/share/limine/BOOTIA32.EFI"
    install -m 0755 "$CACHE_DIR/limine" "$PKG_DIR/x/usr/bin/limine"
fi

verify_static_elf "$PKG_DIR/x/usr/bin/limine"

cat > "$PKG_DIR/x/usr/bin/limine-deploy" <<'EOF'
#!/bin/sh
# Deploy Limine bootloader to MBR/GPT disk device
if [ -x /usr/bin/limine ]; then
    exec /usr/bin/limine bios-install "$@"
elif [ -x "$(dirname "$0")/limine" ]; then
    exec "$(dirname "$0")/limine" bios-install "$@"
else
    echo "ERROR: limine binary not found" >&2
    exit 1
fi
EOF
chmod 0755 "$PKG_DIR/x/usr/bin/limine-deploy"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
