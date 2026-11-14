#!/usr/bin/env bash
# Recipe to build limine-static base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"
CACHE_DIR="$REPO_ROOT/distro/cache"
LIMINE_VERSION="12.9.6"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/usr/share/limine" "$PKG_DIR/x/usr/bin" "$CACHE_DIR"

# Ensure limine binaries exist in package tree or cache
if [ -f "$PKG_DIR/x/usr/share/limine/limine-bios.sys" ] && \
   [ -f "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin" ] && \
   [ -f "$PKG_DIR/x/usr/share/limine/BOOTX64.EFI" ] && \
   [ -f "$PKG_DIR/x/usr/share/limine/BOOTIA32.EFI" ] && \
   [ -x "$PKG_DIR/x/usr/bin/limine" ]; then
    # Already present in package tree; populate cache if writable
    if [ -w "$CACHE_DIR" ]; then
        cp -u "$PKG_DIR/x/usr/share/limine/limine-bios.sys" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/share/limine/BOOTX64.EFI" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/share/limine/BOOTIA32.EFI" "$CACHE_DIR/" 2>/dev/null || true
        cp -u "$PKG_DIR/x/usr/bin/limine" "$CACHE_DIR/" 2>/dev/null || true
    fi
elif [ ! -f "$CACHE_DIR/limine-bios.sys" ] || [ ! -f "$CACHE_DIR/limine-uefi-cd.bin" ] || [ ! -x "$CACHE_DIR/limine" ] || [ ! -f "$CACHE_DIR/BOOTX64.EFI" ] || [ ! -f "$CACHE_DIR/BOOTIA32.EFI" ]; then
    printf '==> Downloading and preparing limine static binaries (v%s)...\n' "$LIMINE_VERSION"
    TMP_LIMINE="$(mktemp -d /tmp/limine-fetch-XXXXXX)"
    curl -sL "https://github.com/Limine-Bootloader/Limine/releases/download/v${LIMINE_VERSION}/limine-binary.tar.xz" | tar -xJ -C "$TMP_LIMINE"
    (cd "$TMP_LIMINE/limine-binary" && gcc -O2 -static -fpie -Wl,-z,now limine.c -o limine)
    strip "$TMP_LIMINE/limine-binary/limine"
    
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
    rm -rf "$TMP_LIMINE"
else
    install -m 0644 "$CACHE_DIR/limine-bios.sys" "$PKG_DIR/x/usr/share/limine/limine-bios.sys"
    install -m 0644 "$CACHE_DIR/limine-uefi-cd.bin" "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin"
    install -m 0644 "$CACHE_DIR/BOOTX64.EFI" "$PKG_DIR/x/usr/share/limine/BOOTX64.EFI"
    install -m 0644 "$CACHE_DIR/BOOTIA32.EFI" "$PKG_DIR/x/usr/share/limine/BOOTIA32.EFI"
    install -m 0755 "$CACHE_DIR/limine" "$PKG_DIR/x/usr/bin/limine"
fi

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
