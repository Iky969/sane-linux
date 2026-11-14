#!/usr/bin/env bash
# Recipe to build busybox base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR" "$PKG_DIR/x/bin" "$PKG_DIR/x/sbin"

# Find busybox binary
BB_BIN=""
if [ -x "$REPO_ROOT/distro/rootfs/bin/busybox" ]; then
    BB_BIN="$REPO_ROOT/distro/rootfs/bin/busybox"
elif [ -x "$REPO_ROOT/distro/build/busybox-1.36.1/busybox" ]; then
    BB_BIN="$REPO_ROOT/distro/build/busybox-1.36.1/busybox"
elif [ -x "/bin/busybox" ]; then
    BB_BIN="/bin/busybox"
else
    printf 'ERROR: No static busybox binary found. Run make rootfs first.\n' >&2
    exit 1
fi

install -m 0755 "$BB_BIN" "$PKG_DIR/x/bin/busybox"

# Core /bin applets
BIN_APPLETS=(
    ash cat chmod chown cp cut date dd df dirname dmesg du echo env expr
    false find grep head hostname id kill ln ls mkdir mknod more mount mv
    od printf ps pwd readlink realpath rm rmdir sed seq sh sleep sort stat
    sync tail tar tee touch tr true umount uname uniq wc wget xargs
)

for applet in "${BIN_APPLETS[@]}"; do
    ln -sf /bin/busybox "$PKG_DIR/x/bin/$applet"
done

# Core /sbin applets
SBIN_APPLETS=(
    fdisk getty ifconfig ip login mdev mkswap modprobe insmod lsmod
    route switch_root sysctl udhcpc
)

for applet in "${SBIN_APPLETS[@]}"; do
    ln -sf /bin/busybox "$PKG_DIR/x/sbin/$applet"
done

"$REPO_ROOT/scripts/build-package.sh" --source "$PKG_DIR" --output "$OUT_DIR" --base
