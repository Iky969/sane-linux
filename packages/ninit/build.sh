#!/usr/bin/env bash
# Recipe to build ninit base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/sbin" "$PKG_DIR/x/usr/bin" "$PKG_DIR/x/usr/share/ninit/services"

# When $REPO_ROOT/ninit.c is present, always compile fresh static binary
if [ -f "$REPO_ROOT/ninit.c" ]; then
    printf '==> Compiling fresh static ninit binary from source...\n'
    gcc -static -O2 -Wall -Wextra -D_GNU_SOURCE "$REPO_ROOT/ninit.c" -o "$REPO_ROOT/ninit"
fi

[ -f "$REPO_ROOT/ninit" ] || { printf 'ERROR: ninit binary not found at %s\n' "$REPO_ROOT/ninit" >&2; exit 1; }

# Install into $PKG_DIR/x/sbin/init
install -m 0755 "$REPO_ROOT/ninit" "$PKG_DIR/x/sbin/init"
chmod 0755 "$PKG_DIR/x/sbin/poweroff" "$PKG_DIR/x/sbin/reboot" "$PKG_DIR/x/sbin/halt"
[ -f "$PKG_DIR/x/usr/bin/sane-ctl" ] && chmod 0755 "$PKG_DIR/x/usr/bin/sane-ctl"
[ -f "$PKG_DIR/x/usr/bin/sane-net" ] && chmod 0755 "$PKG_DIR/x/usr/bin/sane-net"
chmod 0644 "$PKG_DIR/x/usr/share/ninit/services/getty.service"

# Verify static ELF without INTERP or DYNAMIC
command -v readelf >/dev/null 2>&1 || {
    printf 'ERROR: readelf is required for static ELF verification\n' >&2
    exit 1
}
readelf -h "$PKG_DIR/x/sbin/init" >/dev/null 2>&1 || {
    printf 'ERROR: %s is not a valid ELF binary\n' "$PKG_DIR/x/sbin/init" >&2
    exit 1
}
if readelf -lW "$PKG_DIR/x/sbin/init" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
    printf 'ERROR: %s contains dynamic INTERP segment (must be statically linked)\n' "$PKG_DIR/x/sbin/init" >&2
    exit 1
fi
if readelf -lW "$PKG_DIR/x/sbin/init" 2>/dev/null | grep -E -q '[[:space:]]DYNAMIC[[:space:]]'; then
    printf 'ERROR: %s contains DYNAMIC segment (must be statically linked)\n' "$PKG_DIR/x/sbin/init" >&2
    exit 1
fi

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
