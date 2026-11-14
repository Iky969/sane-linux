#!/usr/bin/env bash
# Recipe to build busybox base package
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PKG_DIR/../.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

# Find busybox binary
BB_BIN="${BUSYBOX_BIN:-}"
if [ -z "$BB_BIN" ]; then
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
fi

[ -x "$BB_BIN" ] || { printf 'ERROR: BusyBox binary is not executable: %s\n' "$BB_BIN" >&2; exit 1; }

# ELF verification: ensure $BB_BIN is strictly statically linked ELF (no PT_INTERP)
is_static_elf() {
    local bin="$1"
    if command -v readelf >/dev/null 2>&1; then
        readelf -h "$bin" >/dev/null 2>&1 || return 1
        if readelf -l "$bin" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
            return 1
        fi
        return 0
    elif command -v file >/dev/null 2>&1; then
        local f_out
        f_out="$(file -b "$bin" 2>/dev/null || true)"
        if echo "$f_out" | grep -q 'ELF' && echo "$f_out" | grep -q 'statically linked'; then
            return 0
        fi
        return 1
    else
        printf 'ERROR: Neither readelf nor file found to verify static ELF linking\n' >&2
        return 1
    fi
}

if ! is_static_elf "$BB_BIN"; then
    printf 'ERROR: %s is not a statically linked ELF binary (dynamic linking or PT_INTERP detected).\n' "$BB_BIN" >&2
    exit 1
fi

mkdir -p "$OUT_DIR" "$PKG_DIR/x/bin" "$PKG_DIR/x/sbin" "$PKG_DIR/x/usr/share/udhcpc"
[ -f "$PKG_DIR/x/usr/share/udhcpc/default.script" ] && chmod 0755 "$PKG_DIR/x/usr/share/udhcpc/default.script"

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
