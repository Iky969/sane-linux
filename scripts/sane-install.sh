#!/bin/sh
# scripts/sane-install.sh -- Guest Offline Live Installer for S.A.N.E Linux
#
# Partitions a target disk with GPT, formats filesystems (FAT32 ESP + ext4 rootfs),
# installs base packages via SPM, configures the system, and installs the Limine bootloader.
#
# Adheres to fail-closed security, zero-bloat, POSIX sh (BusyBox ash compatible),
# and anti-EXDEV cross-device mount sequencing.
#
# Usage:
#   sane-install.sh --target /dev/vda [OPTIONS]
#
# Options:
#   -t, --target <dev>       Target block device (e.g. /dev/vda, /dev/sda, /dev/loop0)
#   -p, --packages-dir <dir> Directory containing .spm.tar.xz packages (auto-detected if omitted)
#   -y, --yes, --unattended  Non-interactive mode (no confirmation prompt)
#   --partuuid <uuid>        PARTUUID for root partition (default: 44444444-4444-4444-8888-888888888888)
#   --initramfs <path>       Pre-built initramfs.cpio.gz path (auto-assembled if omitted)
#   --kernel <path>          Pre-built kernel bzImage path (auto-detected from packages/rootfs if omitted)
#   --no-reboot              Do not reboot or poweroff when done (default)
#   --reboot                 Reboot immediately after successful installation
#   --poweroff               Power off immediately after successful installation
#   -h, --help               Show this help message

set -eu

log()  { printf '==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf 'WARNING: %s\n' "$1" >&2; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

TARGET=""
PACKAGES_DIR=""
UNATTENDED=0
PARTUUID_ARG=""
PARTUUID=""
INITRAMFS_ARG=""
KERNEL_ARG=""
POST_ACTION="none"

while [ $# -gt 0 ]; do
    case "$1" in
        -t|--target)
            [ $# -ge 2 ] || die "Missing argument for $1"
            TARGET="$2"
            shift 2
            ;;
        -p|--packages-dir)
            [ $# -ge 2 ] || die "Missing argument for $1"
            PACKAGES_DIR="$2"
            shift 2
            ;;
        -y|--yes|--unattended)
            UNATTENDED=1
            shift
            ;;
        --partuuid)
            [ $# -ge 2 ] || die "Missing argument for $1"
            PARTUUID_ARG="$2"
            shift 2
            ;;
        --initramfs)
            [ $# -ge 2 ] || die "Missing argument for $1"
            INITRAMFS_ARG="$2"
            shift 2
            ;;
        --kernel)
            [ $# -ge 2 ] || die "Missing argument for $1"
            KERNEL_ARG="$2"
            shift 2
            ;;
        --no-reboot)
            POST_ACTION="none"
            shift
            ;;
        --reboot)
            POST_ACTION="reboot"
            shift
            ;;
        --poweroff)
            POST_ACTION="poweroff"
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: sane-install.sh --target <block_device> [OPTIONS]

Options:
  -t, --target <dev>       Target block device (e.g. /dev/vda, /dev/sda, /dev/loop0)
  -p, --packages-dir <dir> Directory containing .spm.tar.xz packages
  -y, --yes, --unattended  Non-interactive mode (proceed without confirmation)
  --partuuid <uuid>        PARTUUID for root partition (default: 44444444-4444-4444-8888-888888888888)
  --initramfs <path>       Pre-built initramfs.cpio.gz path
  --kernel <path>          Pre-built kernel bzImage path
  --no-reboot              Do not reboot or poweroff when done (default)
  --reboot                 Reboot immediately after successful installation
  --poweroff               Power off immediately after successful installation
  -h, --help               Show this help message
EOF
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Generate unique PARTUUID if not supplied
if [ -n "$PARTUUID_ARG" ]; then
    PARTUUID="$PARTUUID_ARG"
else
    if [ -f /proc/sys/kernel/random/uuid ]; then
        PARTUUID=$(cat /proc/sys/kernel/random/uuid | tr 'A-Z' 'a-z')
    elif command -v uuidgen >/dev/null 2>&1; then
        PARTUUID=$(uuidgen | tr 'A-Z' 'a-z')
    else
        PARTUUID=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | hexdump -e '16/1 "%02x"' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
    fi
fi

# Validate PARTUUID (S5): it is written unquoted into fstab and the kernel
# command line, so anything but a lowercase UUID must be rejected here.
PARTUUID=$(printf '%s' "$PARTUUID" | tr 'A-Z' 'a-z')
if ! printf '%s' "$PARTUUID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    die "invalid PARTUUID format: $PARTUUID"
fi

# Root check
if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
    die "sane-install must be run as root (UID 0)"
fi

# Tool lookup helper
find_tool() {
    name="$1"
    shift
    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    return 1
}

# CDPATH= is an intentional env-prefix: it stops CDPATH from redirecting cd.
# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# CDPATH= is an intentional env-prefix: it stops CDPATH from redirecting cd.
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)

# Resolve required tooling
SGDISK_BIN=$(find_tool sgdisk /usr/sbin/sgdisk /sbin/sgdisk /usr/bin/sgdisk /bin/sgdisk || true)
[ -n "$SGDISK_BIN" ] || die "sgdisk not found; install disk-tools package or gdisk"

MKFS_EXT4_BIN=$(find_tool mkfs.ext4 /usr/sbin/mkfs.ext4 /sbin/mkfs.ext4 /usr/sbin/mke2fs /sbin/mke2fs /usr/bin/mkfs.ext4 || true)
[ -n "$MKFS_EXT4_BIN" ] || die "mkfs.ext4 / mke2fs not found; install disk-tools package or e2fsprogs"

MKFS_VFAT_BIN=$(find_tool mkfs.vfat /usr/sbin/mkfs.vfat /sbin/mkfs.vfat /usr/sbin/mkfs.fat /sbin/mkfs.fat /usr/bin/mkfs.vfat || true)
[ -n "$MKFS_VFAT_BIN" ] || die "mkfs.vfat / mkfs.fat not found; install disk-tools package or dosfstools"

LIMINE_BIN=$(find_tool limine /usr/bin/limine /usr/sbin/limine "$REPO_ROOT/packages/limine-static/x/usr/bin/limine" || true)
[ -n "$LIMINE_BIN" ] || die "limine not found; install limine-static package"

SPM_BIN=$(find_tool spm /usr/bin/spm "$SCRIPT_DIR/spm" "$REPO_ROOT/scripts/spm" || true)
[ -n "$SPM_BIN" ] || die "spm package manager not found"

# Target device verification
[ -n "$TARGET" ] || die "No target device specified. Use --target /dev/vda"
TARGET_CANON=$(readlink -f "$TARGET" 2>/dev/null || true)
[ -n "$TARGET_CANON" ] && [ -b "$TARGET_CANON" ] || die "Target '$TARGET' is not a valid block device"
TARGET="$TARGET_CANON"

TGT_BASE=$(basename "$TARGET")

# Guard: Ensure target is a whole disk, not a partition
if [ -f "/sys/class/block/$TGT_BASE/partition" ]; then
    die "Target '$TARGET' is a partition, not a whole disk (expected e.g. /dev/vda, not /dev/vda1)"
fi
if [ -d /sys/block ] && [ ! -d "/sys/block/$TGT_BASE" ]; then
    die "Target '$TARGET' is not a whole-disk block device"
fi

# Guard: Fail-closed if target or any of its partitions have active device holders (e.g. dm/LVM/MD)
for hdir in "/sys/block/$TGT_BASE/holders" "/sys/block/$TGT_BASE"/*/holders; do
    [ -d "$hdir" ] || continue
    if find "$hdir" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
        die "Target '$TARGET' (or one of its partitions) has active device holders ($hdir)"
    fi
done

# Collect major:minor IDs of the target disk and all of its partitions so
# aliases such as /dev/root or symlinks cannot bypass mount/swap checks.
TGT_DEV_IDS=""
for devfile in "/sys/block/$TGT_BASE/dev" "/sys/block/$TGT_BASE"/*/dev; do
    [ -r "$devfile" ] || continue
    _devid=$(cat "$devfile" 2>/dev/null || true)
    [ -n "$_devid" ] && TGT_DEV_IDS="$TGT_DEV_IDS $_devid"
done

matches_target_dev() {
    _cand="$1"
    [ -n "$_cand" ] || return 1
    case "$_cand" in
        "$TARGET") return 0 ;;
        "$TARGET"*)
            _suf=${_cand#"$TARGET"}
            case "$TARGET" in
                *[0-9])
                    case "$_suf" in p[0-9]*) _suf=${_suf#p} ;; *) return 1 ;; esac
                    ;;
            esac
            case "$_suf" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
            ;;
    esac
    return 1
}

dev_matches_target() {
    _raw="$1"
    matches_target_dev "$_raw" && return 0
    case "$_raw" in
        /*)
            _canon=$(readlink -f "$_raw" 2>/dev/null || printf '%s' "$_raw")
            matches_target_dev "$_canon" && return 0
            if [ -b "$_canon" ]; then
                _hex_mm=$(stat -c '%t %T' "$_canon" 2>/dev/null || true)
                if [ -n "$_hex_mm" ]; then
                    _hmaj=${_hex_mm%% *}
                    _hmin=${_hex_mm##* }
                    _dec_mm="$((0x$_hmaj)):$((0x$_hmin))"
                    for _tid in $TGT_DEV_IDS; do
                        [ "$_dec_mm" = "$_tid" ] && return 0
                    done
                fi
            fi
            ;;
    esac
    return 1
}

# Guard: Fail-closed if target or any of its partitions are active in /proc/mounts
if [ -r /proc/mounts ]; then
    for _mdev in $(awk '{print $1}' /proc/mounts 2>/dev/null || true); do
        if dev_matches_target "$_mdev"; then
            die "Target '$TARGET' (or one of its partitions: $_mdev) is currently mounted in /proc/mounts"
        fi
    done
fi

# Guard: Fail-closed if target or any of its partitions are active in /proc/swaps
if [ -r /proc/swaps ]; then
    for _sdev in $(awk 'NR > 1 {print $1}' /proc/swaps 2>/dev/null || true); do
        if dev_matches_target "$_sdev"; then
            die "Target '$TARGET' (or one of its partitions: $_sdev) is currently active in /proc/swaps"
        fi
    done
fi

# Guard: Check read-only bit
if [ -f "/sys/class/block/$TGT_BASE/ro" ] && [ "$(cat "/sys/class/block/$TGT_BASE/ro" 2>/dev/null || echo 0)" = "1" ]; then
    die "Target '$TARGET' is marked read-only"
fi
if [ -f "/sys/block/$TGT_BASE/ro" ] && [ "$(cat "/sys/block/$TGT_BASE/ro" 2>/dev/null || echo 0)" = "1" ]; then
    die "Target '$TARGET' is marked read-only"
fi

# Resolve partition naming
case "$TARGET" in
    *[0-9])
        PART1="${TARGET}p1"
        PART2="${TARGET}p2"
        PART3="${TARGET}p3"
        ;;
    *)
        PART1="${TARGET}1"
        PART2="${TARGET}2"
        PART3="${TARGET}3"
        ;;
esac

# Resolve packages directory
if [ -z "$PACKAGES_DIR" ]; then
    for candidate_dir in \
        /media/packages \
        /mnt/packages \
        /distro/packages \
        "$REPO_ROOT/distro/packages" \
        /usr/share/sane-install/packages; do
        if [ -d "$candidate_dir" ] && ls "$candidate_dir"/*.spm.tar.xz >/dev/null 2>&1; then
            PACKAGES_DIR="$candidate_dir"
            break
        fi
    done
fi

[ -n "$PACKAGES_DIR" ] && [ -d "$PACKAGES_DIR" ] || die "Packages directory not found. Use --packages-dir <path>"

# Preflight Check 1: Minimum target disk capacity check (minimum 256MB)
tgt_bytes=0
if [ -f "/sys/class/block/$TGT_BASE/size" ]; then
    tgt_sectors=$(cat "/sys/class/block/$TGT_BASE/size" 2>/dev/null || echo 0)
    case "$tgt_sectors" in ''|*[!0-9]*) tgt_sectors=0 ;; esac
    tgt_bytes=$((tgt_sectors * 512))
fi
if [ "$tgt_bytes" -le 0 ] && command -v blockdev >/dev/null 2>&1; then
    tgt_bytes=$(blockdev --getsize64 "$TARGET" 2>/dev/null || echo 0)
    case "$tgt_bytes" in ''|*[!0-9]*) tgt_bytes=0 ;; esac
fi
MIN_DISK_BYTES=268435456  # 256MB
if [ "$tgt_bytes" -le 0 ] || [ "$tgt_bytes" -lt "$MIN_DISK_BYTES" ]; then
    die "Target disk $TARGET size is invalid or too small ($((tgt_bytes / 1024 / 1024))MB). Minimum required: 256MB ($MIN_DISK_BYTES bytes)"
fi

# Preflight Check 2: Required base packages existence and archive integrity
REQUIRED_PKGS="busybox ninit kernel limine-static disk-tools"
for req in $REQUIRED_PKGS; do
    pkg_file=$(ls "$PACKAGES_DIR"/$req-*.spm.tar.xz 2>/dev/null | head -n1 || true)
    [ -n "$pkg_file" ] && [ -f "$pkg_file" ] || die "Preflight: Required package '$req' not found in $PACKAGES_DIR"
    tar -tJf "$pkg_file" >/dev/null 2>&1 || die "Preflight: Package '$pkg_file' archive is corrupt"
done

# Preflight Check 3: Kernel payload availability
PREFLIGHT_KERNEL=""
if [ -n "$KERNEL_ARG" ] && [ -f "$KERNEL_ARG" ]; then
    PREFLIGHT_KERNEL="$KERNEL_ARG"
elif [ -f "/boot/bzImage" ]; then
    PREFLIGHT_KERNEL="/boot/bzImage"
elif [ -f "$REPO_ROOT/distro/cache/vmlinuz-virt-v3.20" ]; then
    PREFLIGHT_KERNEL="$REPO_ROOT/distro/cache/vmlinuz-virt-v3.20"
elif [ -f "$REPO_ROOT/distro/cache/vmlinuz-virt" ]; then
    PREFLIGHT_KERNEL="$REPO_ROOT/distro/cache/vmlinuz-virt"
elif [ -f "$REPO_ROOT/packages/kernel/x/boot/vmlinuz-virt" ]; then
    PREFLIGHT_KERNEL="$REPO_ROOT/packages/kernel/x/boot/vmlinuz-virt"
else
    kpkg=$(ls "$PACKAGES_DIR"/kernel-*.spm.tar.xz 2>/dev/null | head -n1 || true)
    if [ -n "$kpkg" ] && [ -f "$kpkg" ]; then
        if tar -tf "$kpkg" 2>/dev/null | grep -qE "x/boot/(bzImage|vmlinuz)"; then
            PREFLIGHT_KERNEL="package:$kpkg"
        fi
    fi
fi
[ -n "$PREFLIGHT_KERNEL" ] || die "Preflight: Kernel bzImage payload not found"

# Preflight Check 4: BusyBox binary availability for initramfs
PREFLIGHT_BB=""
if [ -x "/bin/busybox" ]; then
    PREFLIGHT_BB="/bin/busybox"
elif [ -x "$REPO_ROOT/distro/rootfs/bin/busybox" ]; then
    PREFLIGHT_BB="$REPO_ROOT/distro/rootfs/bin/busybox"
elif [ -x "$REPO_ROOT/packages/busybox/x/bin/busybox" ]; then
    PREFLIGHT_BB="$REPO_ROOT/packages/busybox/x/bin/busybox"
else
    bbpkg=$(ls "$PACKAGES_DIR"/busybox-*.spm.tar.xz 2>/dev/null | head -n1 || true)
    if [ -n "$bbpkg" ] && [ -f "$bbpkg" ]; then
        if tar -tf "$bbpkg" 2>/dev/null | grep -qE "x/bin/busybox"; then
            PREFLIGHT_BB="package:$bbpkg"
        fi
    fi
fi
[ -n "$PREFLIGHT_BB" ] || die "Preflight: BusyBox payload not found for initramfs generation"

# Preflight Check 5: Limine BIOS and mandatory UEFI BOOTX64.EFI payload availability
PREFLIGHT_LIMINE_SHARE=""
for cand in \
    /usr/share/limine \
    "$REPO_ROOT/packages/limine-static/x/usr/share/limine" \
    "$REPO_ROOT/distro/cache/limine" \
    "$REPO_ROOT/distro/cache"; do
    if [ -f "$cand/limine-bios.sys" ] && [ -f "$cand/BOOTX64.EFI" ]; then
        PREFLIGHT_LIMINE_SHARE="$cand"
        break
    fi
done
if [ -z "$PREFLIGHT_LIMINE_SHARE" ]; then
    lpkg=$(ls "$PACKAGES_DIR"/limine-static-*.spm.tar.xz 2>/dev/null | head -n1 || true)
    if [ -n "$lpkg" ] && [ -f "$lpkg" ]; then
        if tar -tf "$lpkg" 2>/dev/null | grep -q "limine-bios.sys" && tar -tf "$lpkg" 2>/dev/null | grep -q "BOOTX64.EFI"; then
            PREFLIGHT_LIMINE_SHARE="package:$lpkg"
        fi
    fi
fi
[ -n "$PREFLIGHT_LIMINE_SHARE" ] || die "Preflight: Mandatory Limine payloads (limine-bios.sys and BOOTX64.EFI) not found"

is_mounted() {
    _mnt="$1"
    [ -n "$_mnt" ] || return 1
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$_mnt" 2>/dev/null && return 0
    fi
    awk -v m="$_mnt" '$2 == m { found = 1; exit } END { exit !found }' /proc/mounts 2>/dev/null
}

# Track staging directories and temp files for clean exit / failure cleanup
CLEANUP_MOUNTS=""
CLEANUP_DIRS=""
CLEANUP_FILES=""
cleanup() {
    set +e
    if [ -n "$CLEANUP_MOUNTS" ]; then
        for mnt in $CLEANUP_MOUNTS; do
            if is_mounted "$mnt"; then
                umount -f "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
            fi
            if ! is_mounted "$mnt" && [ -d "$mnt" ]; then
                rmdir "$mnt" 2>/dev/null || true
            fi
        done
    fi
    if [ -n "$CLEANUP_DIRS" ]; then
        for d in $CLEANUP_DIRS; do
            [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
        done
    fi
    if [ -n "$CLEANUP_FILES" ]; then
        for f in $CLEANUP_FILES; do
            [ -e "$f" ] && rm -f "$f" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT INT TERM

log "S.A.N.E Linux Offline Installer"
info "Target Device : $TARGET"
info "ESP Partition : $PART1 (FAT32, 64MB, ef00)"
info "Root Partition: $PART2 (ext4, sane_root, PARTUUID=$PARTUUID)"
info "BIOS Gap Part : $PART3 (ef02, bios_boot, 1MB)"
info "Packages Dir  : $PACKAGES_DIR"

if [ "$UNATTENDED" -ne 1 ]; then
    printf '\nWARNING: All existing data on %s will be permanently erased!\n' "$TARGET"
    printf 'Do you want to continue? [y/N]: '
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) printf 'Installation aborted by user.\n'; exit 0 ;;
    esac
fi

# Step 1: Partitioning target disk with GPT
log "Step 1/6: Partitioning $TARGET with GUID Partition Table (GPT)..."
"$SGDISK_BIN" -Z "$TARGET" >/dev/null
"$SGDISK_BIN" -o "$TARGET" >/dev/null

# BIOS Boot Partition in GPT gap (sectors 34..2047, ef02)
"$SGDISK_BIN" -a 1 -n 3:34:2047 -t 3:ef02 -c 3:bios_boot "$TARGET" >/dev/null

# ESP / Boot (64MB FAT32, ef00)
"$SGDISK_BIN" -a 2048 -n 1:2048:+64M -t 1:ef00 -c 1:SANE_BOOT "$TARGET" >/dev/null

# Root Partition (ext4, 8300, remainder of disk)
"$SGDISK_BIN" -n 2:0:0 -t 2:8300 -c 2:sane_root -u "2:$PARTUUID" "$TARGET" >/dev/null

# Re-read partition table and wait for device nodes
blockdev --rereadpt "$TARGET" 2>/dev/null || partprobe "$TARGET" 2>/dev/null || true
COUNT=0
while [ $COUNT -lt 50 ]; do
    if [ -b "$PART1" ] && [ -b "$PART2" ]; then
        break
    fi
    sleep 0.1
    COUNT=$((COUNT + 1))
done
[ -b "$PART1" ] && [ -b "$PART2" ] || die "Partition block devices $PART1 and $PART2 failed to settle"

# Step 2: Formatting filesystems
log "Step 2/6: Formatting filesystems..."
info "Formatting FAT32 EFI System Partition ($PART1)..."
"$MKFS_VFAT_BIN" -F 32 -n "SANE_BOOT" "$PART1" >/dev/null

info "Formatting ext4 root filesystem ($PART2)..."
case "$MKFS_EXT4_BIN" in
    *mke2fs)
        "$MKFS_EXT4_BIN" -t ext4 -F -L "sane_root" "$PART2" >/dev/null
        ;;
    *)
        "$MKFS_EXT4_BIN" -F -L "sane_root" "$PART2" >/dev/null
        ;;
esac

# Step 3: Installing base packages via SPM (Anti-EXDEV: mount rootfs only)
log "Step 3/6: Installing base packages via SPM..."
TARGET_ROOT="$(mktemp -d /tmp/sane-target-root.XXXXXX)"
CLEANUP_MOUNTS="$TARGET_ROOT $CLEANUP_MOUNTS"

mount "$PART2" "$TARGET_ROOT"
"$SPM_BIN" --root "$TARGET_ROOT" init >/dev/null

# Topologically sort .spm.tar.xz packages via .META/depends (fallback: dependencies=).
PKG_META_TMP=$(mktemp /tmp/sane-pkg-meta.XXXXXX)
PKG_ORDER_TMP=$(mktemp /tmp/sane-pkg-order.XXXXXX)
CLEANUP_FILES="$PKG_META_TMP $PKG_ORDER_TMP $CLEANUP_FILES"
INSTALLED_PKGS=""
is_pkg_seen() {
    _pname="$1"
    for _inst in $INSTALLED_PKGS; do
        if [ "$_inst" = "$_pname" ]; then
            return 0
        fi
    done
    return 1
}

for pkg in "$PACKAGES_DIR"/*.spm.tar.xz; do
    [ -f "$pkg" ] || continue
    fname=$(basename "$pkg")
    pkg_manifest=$(tar -xJOf "$pkg" ./.META/package 2>/dev/null || tar -xJOf "$pkg" .META/package 2>/dev/null || true)
    pkg_name=$(printf '%s\n' "$pkg_manifest" | grep -E '^[[:space:]]*name=' | head -n1 | cut -d= -f2- | tr -d '\r\n' || true)
    if [ -z "$pkg_name" ]; then
        pkg_name=$(printf '%s' "$fname" | sed -E 's/-[0-9]+(\.[0-9]+)*.*//')
    fi
    if is_pkg_seen "$pkg_name"; then
        continue
    fi
    INSTALLED_PKGS="$INSTALLED_PKGS $pkg_name"
    pkg_deps=$(tar -xJOf "$pkg" ./.META/depends 2>/dev/null || tar -xJOf "$pkg" .META/depends 2>/dev/null || true)
    pkg_deps=$(printf '%s\n' "$pkg_deps" | tr ',\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    if [ -z "$pkg_deps" ]; then
        pkg_deps=$(printf '%s\n' "$pkg_manifest" | grep -E '^[[:space:]]*dependencies=' | head -n1 | cut -d= -f2- | tr ',\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' || true)
    fi
    printf '%s|%s|%s\n' "$pkg_name" "$pkg" "$pkg_deps" >> "$PKG_META_TMP"
done

_sort_rc=0
LC_ALL=C sort "$PKG_META_TMP" | awk -F'|' '
    BEGIN { n = 0 }
    {
        name = $1; path = $2; deps_str = $3
        n++
        pkgs[n] = name
        paths[name] = path
        present[name] = 1
        dc = split(deps_str, darr, /[[:space:]]+/)
        dep_cnt[name] = 0
        for (i = 1; i <= dc; i++) {
            if (darr[i] != "") {
                dep_cnt[name]++
                dep[name, dep_cnt[name]] = darr[i]
            }
        }
    }
    END {
        for (i = 1; i <= n; i++) {
            p = pkgs[i]
            for (j = 1; j <= dep_cnt[p]; j++) {
                d = dep[p, j]
                if (!(d in present)) {
                    printf "ERR|missing dependency %s required by %s\n", d, p
                    exit 2
                }
            }
        }
        emitted = 0
        while (emitted < n) {
            progressed = 0
            for (i = 1; i <= n; i++) {
                p = pkgs[i]
                if (done[p]) continue
                ready = 1
                for (j = 1; j <= dep_cnt[p]; j++) {
                    d = dep[p, j]
                    if (!done[d]) { ready = 0; break }
                }
                if (ready) {
                    done[p] = 1
                    emitted++
                    order[emitted] = paths[p]
                    progressed = 1
                    break
                }
            }
            if (!progressed) {
                cyc = ""
                for (i = 1; i <= n; i++) {
                    if (!done[pkgs[i]]) {
                        cyc = (cyc == "" ? pkgs[i] : cyc ", " pkgs[i])
                    }
                }
                printf "ERR|dependency cycle among: %s\n", cyc
                exit 3
            }
        }
        for (i = 1; i <= emitted; i++) {
            print order[i]
        }
    }
' > "$PKG_ORDER_TMP" || _sort_rc=$?
rm -f "$PKG_META_TMP"
if [ "$_sort_rc" -ne 0 ]; then
    _err=$(grep '^ERR|' "$PKG_ORDER_TMP" | head -n1 | cut -d'|' -f2- || true)
    rm -f "$PKG_ORDER_TMP"
    die "Package dependency resolution failed: ${_err:-exit $_sort_rc}"
fi

while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    fname=$(basename "$pkg")
    info "Installing: $fname"
    "$SPM_BIN" --root "$TARGET_ROOT" install "$pkg" >/dev/null
done < "$PKG_ORDER_TMP"
rm -f "$PKG_ORDER_TMP"

# Ensure standard system directories and permissions exist
mkdir -p "$TARGET_ROOT/boot" "$TARGET_ROOT/proc" "$TARGET_ROOT/sys" "$TARGET_ROOT/dev" \
         "$TARGET_ROOT/run" "$TARGET_ROOT/tmp" "$TARGET_ROOT/root" "$TARGET_ROOT/home" "$TARGET_ROOT/etc"
chmod 1777 "$TARGET_ROOT/tmp"

# Step 4: Configuring system files
log "Step 4/6: Configuring system (/etc/fstab, /etc/init.conf, /etc/hostname)..."

cat <<EOF > "$TARGET_ROOT/etc/fstab"
# /etc/fstab: S.A.N.E Linux filesystem table
# Rootfs (PARTUUID=$PARTUUID) is mounted rw by initramfs before switch_root.
# Do not add an active '/' entry here: ninit mounts pseudo-filesystems
# automatically and mount_fstab() detaches recorded entries on shutdown.
EOF

cat <<'EOF' > "$TARGET_ROOT/etc/init.conf"
# /etc/init.conf -- S.A.N.E Linux service supervision
reliability:once:/bin/sh -c '/usr/bin/sane-reliability --root / recover || { echo "reliability: recover failed; boot enters rescue" >&2; exit 1; }':on_fail=rescue:timeout=0
recovery:once:/bin/sh -c 'exec </dev/console >/dev/console 2>&1; /usr/bin/sane-account-recovery':requires=reliability:on_fail=rescue:timeout=0
firstboot:once:/bin/sh -c 'exec </dev/console >/dev/console 2>&1; /usr/bin/sane-firstboot':requires=recovery:on_fail=rescue:timeout=0
network:respawn:/bin/sh -c 'modprobe af_packet 2>/dev/null; modprobe e1000 2>/dev/null; modprobe virtio_net 2>/dev/null; ip link set lo up 2>/dev/null; trap "kill \$! 2>/dev/null; exit 0" TERM INT; while [ ! -d /sys/class/net/eth0 ]; do sleep 5 & wait $!; done; exec sane-net dhcp -f eth0':requires=firstboot
tty1:respawn:/sbin/getty 38400 tty1 linux:requires=firstboot
console:respawn:cttyhack /sbin/getty -L 115200 - vt100:requires=firstboot
EOF

printf 'S.A.N.E\n' > "$TARGET_ROOT/etc/hostname"
# No base package ships /etc/resolv.conf, so create the default resolver here.
if [ ! -f "$TARGET_ROOT/etc/resolv.conf" ]; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$TARGET_ROOT/etc/resolv.conf"
fi
cp "$TARGET_ROOT/etc/resolv.conf" "$TARGET_ROOT/etc/resolv.conf.default"

if [ -f "$TARGET_ROOT/usr/bin/doas" ]; then
    chmod 4755 "$TARGET_ROOT/usr/bin/doas"
fi
# Wi-Fi config holds secrets: always root-owned 0600.
if [ -f "$TARGET_ROOT/etc/wpa_supplicant.conf" ]; then
    chmod 0600 "$TARGET_ROOT/etc/wpa_supplicant.conf"
fi

# Install the reliability toolkit used by the reliability boot service.
RELIABILITY_BIN=$(find_tool sane-reliability "$SCRIPT_DIR/sane-reliability" \
    "$REPO_ROOT/scripts/sane-reliability" /usr/bin/sane-reliability /usr/share/sane-install/sane-reliability || true)
[ -n "$RELIABILITY_BIN" ] || die "sane-reliability not found"
mkdir -p "$TARGET_ROOT/usr/bin"
install -m 0755 "$RELIABILITY_BIN" "$TARGET_ROOT/usr/bin/sane-reliability"

# Single source of truth for identity files + account utilities.
PROVISION_BIN=$(find_tool provision-accounts.sh "$SCRIPT_DIR/provision-accounts.sh" \
    "$REPO_ROOT/scripts/provision-accounts.sh" /usr/share/sane-install/provision-accounts.sh || true)
[ -n "$PROVISION_BIN" ] || die "provision-accounts.sh not found"
if [ "${SANE_WEAK_DEFAULT_CREDS:-0}" = "1" ]; then
    export SANE_WEAK_DEFAULT_CREDS=1
fi
if [ -n "${SANE_TEST_CREDS_FILE:-}" ]; then
    export SANE_TEST_CREDS_FILE
fi
sh "$PROVISION_BIN" "$TARGET_ROOT"

cat <<'EOF' > "$TARGET_ROOT/etc/issue"
Welcome to S.A.N.E Linux (\m) - \l
Kernel \r on an \m (\l)

EOF

mkdir -p "$TARGET_ROOT/home/sane"
chmod 0750 "$TARGET_ROOT/home/sane"
chown 1000:1000 "$TARGET_ROOT/home/sane" 2>/dev/null || true

cat <<'EOF' > "$TARGET_ROOT/etc/profile"
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export USER=$(id -un 2>/dev/null || echo "$USER")
export LOGNAME="$USER"
export HOME="/home/$USER"
[ "$USER" = "root" ] && export HOME="/root"
EOF
chmod 0644 "$TARGET_ROOT/etc/profile"

# Resolve Kernel bzImage before setting up module directory so --kernel is honored
KERNEL_SRC=""
if [ -n "$KERNEL_ARG" ] && [ -f "$KERNEL_ARG" ]; then
    KERNEL_SRC="$KERNEL_ARG"
elif [ -f "$TARGET_ROOT/boot/bzImage" ]; then
    KERNEL_SRC="$TARGET_ROOT/boot/bzImage"
elif [ -f "$TARGET_ROOT/boot/vmlinuz-virt" ]; then
    KERNEL_SRC="$TARGET_ROOT/boot/vmlinuz-virt"
elif [ -f "/boot/bzImage" ]; then
    KERNEL_SRC="/boot/bzImage"
elif [ -f "$REPO_ROOT/distro/cache/vmlinuz-virt" ]; then
    KERNEL_SRC="$REPO_ROOT/distro/cache/vmlinuz-virt"
elif [ -f "$REPO_ROOT/packages/kernel/x/boot/vmlinuz-virt" ]; then
    KERNEL_SRC="$REPO_ROOT/packages/kernel/x/boot/vmlinuz-virt"
fi
[ -n "$KERNEL_SRC" ] && [ -f "$KERNEL_SRC" ] || die "Kernel bzImage not found"

# Setup kernel module directory for modprobe
kver_inst=$(strings "$KERNEL_SRC" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-virt' | head -n1 || true)
[ -n "$kver_inst" ] || kver_inst="6.6.134-0-virt"
if [ -d "$TARGET_ROOT/lib/modules" ]; then
    mkdir -p "$TARGET_ROOT/lib/modules/$kver_inst"
    find "$TARGET_ROOT/lib/modules" -maxdepth 1 -name "*.ko" -exec cp -u {} "$TARGET_ROOT/lib/modules/$kver_inst/" \; 2>/dev/null || true
    if command -v depmod >/dev/null 2>&1; then
        depmod -b "$TARGET_ROOT" "$kver_inst" 2>/dev/null || true
    elif [ -x "$TARGET_ROOT/bin/busybox" ]; then
        chroot "$TARGET_ROOT" /bin/busybox depmod "$kver_inst" 2>/dev/null || true
    fi
fi

# Step 5: Populating boot partition (ESP) with kernel, initramfs, and Limine
log "Step 5/6: Populating ESP and bootloader files..."
TARGET_BOOT="$(mktemp -d /tmp/sane-target-boot.XXXXXX)"
CLEANUP_MOUNTS="$TARGET_BOOT $CLEANUP_MOUNTS"

mount "$PART1" "$TARGET_BOOT"

# 5.1 Kernel bzImage
cp "$KERNEL_SRC" "$TARGET_BOOT/bzImage"
info "Copied kernel: $KERNEL_SRC -> $TARGET_BOOT/bzImage"

# 5.2 Initramfs
INITRAMFS_SRC=""
if [ -n "$INITRAMFS_ARG" ] && [ -f "$INITRAMFS_ARG" ]; then
    INITRAMFS_SRC="$INITRAMFS_ARG"
elif [ -f "/boot/initramfs.cpio.gz" ] && [ ! -f "/boot/bzImage" ]; then
    INITRAMFS_SRC="/boot/initramfs.cpio.gz"
fi

if [ -n "$INITRAMFS_SRC" ] && [ -f "$INITRAMFS_SRC" ]; then
    cp "$INITRAMFS_SRC" "$TARGET_BOOT/initramfs.cpio.gz"
    info "Copied initramfs: $INITRAMFS_SRC -> $TARGET_BOOT/initramfs.cpio.gz"
else
    # Assemble minimal switch_root initramfs on the fly
    info "Assembling minimal switch_root initramfs..."
    IR_TMP="$(mktemp -d /tmp/sane-ir-gen.XXXXXX)"
    CLEANUP_DIRS="$IR_TMP $CLEANUP_DIRS"
    mkdir -p "$IR_TMP/bin" "$IR_TMP/sbin" "$IR_TMP/proc" "$IR_TMP/sys" "$IR_TMP/dev" "$IR_TMP/run" "$IR_TMP/newroot" "$IR_TMP/etc" "$IR_TMP/lib/modules"
    
    BB_SRC=""
    if [ -x "$TARGET_ROOT/bin/busybox" ]; then
        BB_SRC="$TARGET_ROOT/bin/busybox"
    elif [ -x "/bin/busybox" ]; then
        BB_SRC="/bin/busybox"
    fi
    [ -n "$BB_SRC" ] || die "BusyBox binary not found for initramfs generation"
    cp "$BB_SRC" "$IR_TMP/bin/busybox"
    chmod 0755 "$IR_TMP/bin/busybox"

    for app in sh ash mount umount mkdir cat sleep echo grep cut ls stat test "[" switch_root mdev findfs blkid insmod hexdump dd mknod awk; do
        ln -sf /bin/busybox "$IR_TMP/bin/$app"
        ln -sf /bin/busybox "$IR_TMP/sbin/$app"
    done

    # Copy storage kernel modules if available
    if [ -d "$TARGET_ROOT/lib/modules" ]; then
        find "$TARGET_ROOT/lib/modules" -name "*.ko*" -exec cp {} "$IR_TMP/lib/modules/" \; 2>/dev/null || true
    fi
    if [ -d "$REPO_ROOT/distro/cache/storage-modules" ]; then
        find "$REPO_ROOT/distro/cache/storage-modules" -name "*.ko*" -exec cp {} "$IR_TMP/lib/modules/" \; 2>/dev/null || true
    fi

    cat <<'EOF' > "$IR_TMP/init"
#!/bin/sh
set -eu
mkdir -p /proc /sys /dev /run /newroot
mount -t proc proc /proc || { echo "ERROR: failed to mount /proc"; exec /bin/sh; }
mount -t sysfs sysfs /sys || { echo "ERROR: failed to mount /sys"; exec /bin/sh; }
mount -t devtmpfs devtmpfs /dev || { echo "ERROR: failed to mount /dev"; exec /bin/sh; }
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run || { echo "ERROR: failed to mount /run"; exec /bin/sh; }

for mod in crc32c_generic crc32c-intel libcrc32c crc16 mbcache jbd2 ext4 virtio_blk nls_cp437 nls_iso8859-1 nls_utf8 fat vfat; do
    if [ -f "/lib/modules/${mod}.ko" ]; then
        insmod "/lib/modules/${mod}.ko" 2>/dev/null || true
    fi
done

ROOT_DEV="/dev/vda2"
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        root=*) ROOT_DEV="${arg#root=}" ;;
    esac
done

RESOLVED_DEV=""
COUNT=0
while [ -z "$RESOLVED_DEV" ] && [ $COUNT -lt 50 ]; do
    if [ -b "$ROOT_DEV" ]; then
        RESOLVED_DEV="$ROOT_DEV"
        break
    fi
    case "$ROOT_DEV" in
        PARTUUID=*)
            target_uuid="${ROOT_DEV#PARTUUID=}"
            # Method 1: Kernel sysfs uevent (for kernels exporting PARTUUID directly)
            for uevent in /sys/class/block/*/uevent; do
                [ -f "$uevent" ] || continue
                if grep -qi "^PARTUUID=$target_uuid" "$uevent" 2>/dev/null; then
                    devname=$(grep '^DEVNAME=' "$uevent" | cut -d= -f2)
                    maj=$(grep '^MAJOR=' "$uevent" | cut -d= -f2)
                    min=$(grep '^MINOR=' "$uevent" | cut -d= -f2)
                    [ -n "$devname" ] || continue
                    [ -b "/dev/$devname" ] || mknod "/dev/$devname" b "$maj" "$min" 2>/dev/null || true
                    if [ -b "/dev/$devname" ]; then
                        RESOLVED_DEV="/dev/$devname"
                        break
                    fi
                fi
            done
            # Method 2: Direct GPT partition table inspection on parent block device
            if [ -z "$RESOLVED_DEV" ] && command -v hexdump >/dev/null 2>&1 && command -v dd >/dev/null 2>&1; then
                for duevent in /sys/class/block/*/uevent; do
                    [ -f "$duevent" ] || continue
                    if grep -q '^DEVTYPE=disk' "$duevent" 2>/dev/null; then
                        dname=$(grep '^DEVNAME=' "$duevent" | cut -d= -f2 || true)
                        dmaj=$(grep '^MAJOR=' "$duevent" | cut -d= -f2 || true)
                        dmin=$(grep '^MINOR=' "$duevent" | cut -d= -f2 || true)
                        [ -n "$dname" ] || continue
                        [ -b "/dev/$dname" ] || mknod "/dev/$dname" b "$dmaj" "$dmin" 2>/dev/null || true
                        [ -b "/dev/$dname" ] || continue
                        for puevent in /sys/class/block/*/uevent; do
                            [ -f "$puevent" ] || continue
                            if grep -q '^DEVTYPE=partition' "$puevent" 2>/dev/null; then
                                pname=$(grep '^DEVNAME=' "$puevent" | cut -d= -f2 || true)
                                pnum=$(grep '^PARTN=' "$puevent" | cut -d= -f2 || true)
                                pmaj=$(grep '^MAJOR=' "$puevent" | cut -d= -f2 || true)
                                pmin=$(grep '^MINOR=' "$puevent" | cut -d= -f2 || true)
                                [ -n "$pname" ] || continue
                                [ ! -d "/sys/block/$dname" ] || [ -d "/sys/block/$dname/$pname" ] || continue
                                case "$dname" in
                                    *[0-9])
                                        case "$pname" in "${dname}"p[0-9]*) ;; *) continue ;; esac
                                        psuf=${pname#"${dname}p"}
                                        ;;
                                    *)
                                        case "$pname" in "${dname}"[0-9]*) ;; *) continue ;; esac
                                        psuf=${pname#"$dname"}
                                        ;;
                                esac
                                case "$psuf" in ''|*[!0-9]*) continue ;; esac
                                case "$pnum" in ''|*[!0-9]*) pnum="" ;; esac
                                if [ -n "$pnum" ]; then
                                    sk=$(( 1024 + (pnum - 1) * 128 + 16 ))
                                    raw_hex=$(dd if="/dev/$dname" bs=1 skip=$sk count=16 2>/dev/null | hexdump -e '16/1 "%02x "' || true)
                                    if [ -n "$raw_hex" ]; then
                                        calc_uuid=$(echo "$raw_hex" | awk '{print $4$3$2$1"-"$6$5"-"$8$7"-"$9$10"-"$11$12$13$14$15$16}')
                                        if [ -n "$calc_uuid" ] && echo "$calc_uuid" | grep -qi "^${target_uuid}$"; then
                                            [ -b "/dev/$pname" ] || mknod "/dev/$pname" b "$pmaj" "$pmin" 2>/dev/null || true
                                            if [ -b "/dev/$pname" ]; then
                                                RESOLVED_DEV="/dev/$pname"
                                                break 2
                                            fi
                                        fi
                                    fi
                                fi
                            fi
                        done
                    fi
                done
            fi
            ;;
        LABEL=*)
            if command -v findfs >/dev/null 2>&1; then
                dev=$(findfs "$ROOT_DEV" 2>/dev/null || true)
                [ -b "$dev" ] && RESOLVED_DEV="$dev" && break
            fi
            ;;
        UUID=*)
            if command -v findfs >/dev/null 2>&1; then
                dev=$(findfs "$ROOT_DEV" 2>/dev/null || true)
                [ -b "$dev" ] && RESOLVED_DEV="$dev" && break
            fi
            ;;
    esac
    [ -n "$RESOLVED_DEV" ] && break
    sleep 0.1
    COUNT=$((COUNT + 1))
done

if [ -z "$RESOLVED_DEV" ] || [ ! -b "$RESOLVED_DEV" ]; then
    echo "ERROR: Root device $ROOT_DEV not found after timeout!"
    exec /bin/sh
fi

mount -t ext4 -o rw "$RESOLVED_DEV" /newroot || { echo "ERROR: failed to mount root device $RESOLVED_DEV"; exec /bin/sh; }
mount --move /run /newroot/run || { echo "ERROR: failed to move /run"; exec /bin/sh; }
mount --move /dev /newroot/dev || { echo "ERROR: failed to move /dev"; exec /bin/sh; }
mount --move /sys /newroot/sys || { echo "ERROR: failed to move /sys"; exec /bin/sh; }
mount --move /proc /newroot/proc || { echo "ERROR: failed to move /proc"; exec /bin/sh; }

echo "switch_root: pivoting to $RESOLVED_DEV"
exec switch_root /newroot /sbin/init || { echo "ERROR: switch_root failed"; exec /bin/sh; }
EOF
    chmod 0755 "$IR_TMP/init"

    CPIO_OWNER=""
    if cpio --help 2>&1 | grep -q -- '--owner'; then
        CPIO_OWNER="--owner=+0:+0"
    elif cpio --help 2>&1 | grep -q -- '-R'; then
        CPIO_OWNER="-R 0:0"
    fi

    CPIO_NULL="-0"
    if cpio --help 2>&1 | grep -q -- '--null'; then
        CPIO_NULL="--null"
    elif cpio --help 2>&1 | grep -q -- '-0'; then
        CPIO_NULL="-0"
    fi

    IR_CPIO="$TARGET_BOOT/initramfs.cpio.$$"
    IR_GZ="$TARGET_BOOT/initramfs.cpio.gz.tmp.$$"
    IR_LIST=$(mktemp /tmp/sane-ir-list.XXXXXX)
    CLEANUP_FILES="$IR_CPIO $IR_GZ $IR_LIST $CLEANUP_FILES"
    if ! (
        cd "$IR_TMP" &&
        set -- "$CPIO_NULL" -o -H newc &&
        case "$CPIO_OWNER" in
            --owner=*) set -- "$@" "$CPIO_OWNER" ;;
            "-R 0:0") set -- "$@" -R 0:0 ;;
        esac &&
        find . -print0 > "$IR_LIST" &&
        cpio "$@" < "$IR_LIST" > "$IR_CPIO"
    ); then
        rm -f "$IR_LIST" "$IR_CPIO" "$IR_GZ"
        die "Failed to pack initramfs cpio archive"
    fi
    rm -f "$IR_LIST"
    [ -s "$IR_CPIO" ] || { rm -f "$IR_CPIO" "$IR_GZ"; die "Initramfs cpio archive is empty"; }
    if ! gzip -9 < "$IR_CPIO" > "$IR_GZ" || ! gzip -t "$IR_GZ"; then
        rm -f "$IR_CPIO" "$IR_GZ"
        die "Failed to compress initramfs cpio archive"
    fi
    rm -f "$IR_CPIO"
    mv -f "$IR_GZ" "$TARGET_BOOT/initramfs.cpio.gz" || { rm -f "$IR_GZ"; die "Failed to install initramfs"; }
    rm -rf "$IR_TMP"
    info "Assembled initramfs -> $TARGET_BOOT/initramfs.cpio.gz"
fi

# 5.3 Limine BIOS & UEFI payloads
LIMINE_SHARE=""
for cand in \
    "$TARGET_ROOT/usr/share/limine" \
    /usr/share/limine \
    "$REPO_ROOT/packages/limine-static/x/usr/share/limine"; do
    if [ -f "$cand/limine-bios.sys" ]; then
        LIMINE_SHARE="$cand"
        break
    fi
done

[ -n "$LIMINE_SHARE" ] || die "Limine bootloader payload directory not found"

cp "$LIMINE_SHARE/limine-bios.sys" "$TARGET_BOOT/limine-bios.sys"
mkdir -p "$TARGET_BOOT/EFI/BOOT"

# Strictly enforce mandatory UEFI payload
[ -f "$LIMINE_SHARE/BOOTX64.EFI" ] || die "Mandatory UEFI payload BOOTX64.EFI missing in $LIMINE_SHARE"
cp "$LIMINE_SHARE/BOOTX64.EFI" "$TARGET_BOOT/EFI/BOOT/BOOTX64.EFI"
info "Installed UEFI payload: $TARGET_BOOT/EFI/BOOT/BOOTX64.EFI"

if [ -f "$LIMINE_SHARE/BOOTIA32.EFI" ]; then
    cp "$LIMINE_SHARE/BOOTIA32.EFI" "$TARGET_BOOT/EFI/BOOT/BOOTIA32.EFI"
fi

cat <<EOF > "$TARGET_BOOT/limine.conf"
timeout: 0
serial: yes

/S.A.N.E Linux
    protocol: linux
    kernel_path: boot():/bzImage
    module_path: boot():/initramfs.cpio.gz
    cmdline: console=tty0 console=ttyS0 root=PARTUUID=$PARTUUID rootfstype=ext4 rw quiet panic=-1
EOF

cp "$TARGET_BOOT/limine.conf" "$TARGET_BOOT/limine.cfg"
cp "$TARGET_BOOT/limine.conf" "$TARGET_BOOT/EFI/BOOT/limine.conf"
cp "$TARGET_BOOT/limine.conf" "$TARGET_BOOT/EFI/BOOT/limine.cfg"

# Step 6: Unmount filesystems & install Limine bootloader to MBR/GPT
log "Step 6/6: Installing Limine bootloader to MBR/GPT ($TARGET)..."
sync
if is_mounted "$TARGET_BOOT"; then
    umount "$TARGET_BOOT" || die "Failed to unmount ESP $TARGET_BOOT cleanly"
fi
if [ -d "$TARGET_BOOT" ]; then
    rmdir "$TARGET_BOOT" 2>/dev/null || true
fi
if is_mounted "$TARGET_ROOT"; then
    umount "$TARGET_ROOT" || die "Failed to unmount root $TARGET_ROOT cleanly"
fi
if [ -d "$TARGET_ROOT" ]; then
    rmdir "$TARGET_ROOT" 2>/dev/null || true
fi
CLEANUP_MOUNTS=""

"$LIMINE_BIN" bios-install "$TARGET" >/dev/null
sync

log "Installation completed successfully on $TARGET!"
info "Bootloader : Limine BIOS (MBR/GPT) & UEFI (x86_64)"
info "Rootfs UUID: PARTUUID=$PARTUUID"

case "$POST_ACTION" in
    reboot)
        log "Rebooting system..."
        reboot -f 2>/dev/null || reboot 2>/dev/null || true
        ;;
    poweroff)
        log "Powering off system..."
        poweroff -f 2>/dev/null || poweroff 2>/dev/null || true
        ;;
    *)
        info "Run 'reboot' to boot into your new S.A.N.E Linux installation."
        ;;
esac

exit 0
