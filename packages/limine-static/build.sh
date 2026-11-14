#!/usr/bin/env bash
# Recipe to build limine-static base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"
CACHE_DIR="$REPO_ROOT/distro/cache"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/usr/share/limine" "$PKG_DIR/x/usr/bin" "$CACHE_DIR"

# Ensure limine binaries exist in cache, fetching if needed
if [ ! -f "$CACHE_DIR/limine-bios.sys" ] || [ ! -f "$CACHE_DIR/limine-uefi-cd.bin" ] || [ ! -x "$CACHE_DIR/limine" ]; then
    printf '==> Downloading and preparing limine static binaries...\n'
    TMP_LIMINE="$(mktemp -d /tmp/limine-fetch-XXXXXX)"
    curl -sL "https://github.com/Limine-Bootloader/Limine/releases/download/v12.9.6/limine-binary.tar.xz" | tar -xJ -C "$TMP_LIMINE"
    cp "$TMP_LIMINE/limine-binary/limine-bios.sys" "$CACHE_DIR/"
    cp "$TMP_LIMINE/limine-binary/limine-uefi-cd.bin" "$CACHE_DIR/"
    (cd "$TMP_LIMINE/limine-binary" && gcc -O2 -static -fpie -Wl,-z,now limine.c -o "$CACHE_DIR/limine")
    strip "$CACHE_DIR/limine"
    rm -rf "$TMP_LIMINE"
fi

install -m 0644 "$CACHE_DIR/limine-bios.sys" "$PKG_DIR/x/usr/share/limine/limine-bios.sys"
install -m 0644 "$CACHE_DIR/limine-uefi-cd.bin" "$PKG_DIR/x/usr/share/limine/limine-uefi-cd.bin"
install -m 0755 "$CACHE_DIR/limine" "$PKG_DIR/x/usr/bin/limine"

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
