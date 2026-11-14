#!/usr/bin/env bash
# Recipe to build ninit base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/sbin" "$PKG_DIR/x/usr/bin" "$PKG_DIR/x/usr/share/ninit/services"

# Ensure ninit binary is built and static
if [ ! -x "$REPO_ROOT/ninit" ]; then
    printf '==> Building static ninit binary...\n'
    (cd "$REPO_ROOT" && gcc -static -O2 -Wall -Wextra -D_GNU_SOURCE ninit.c -o ninit)
fi

install -m 0755 "$REPO_ROOT/ninit" "$PKG_DIR/x/sbin/init"
chmod 0755 "$PKG_DIR/x/sbin/poweroff" "$PKG_DIR/x/sbin/reboot" "$PKG_DIR/x/sbin/halt"
[ -f "$PKG_DIR/x/usr/bin/sane-ctl" ] && chmod 0755 "$PKG_DIR/x/usr/bin/sane-ctl"
[ -f "$PKG_DIR/x/usr/bin/sane-net" ] && chmod 0755 "$PKG_DIR/x/usr/bin/sane-net"
chmod 0644 "$PKG_DIR/x/usr/share/ninit/services/getty.service"

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
