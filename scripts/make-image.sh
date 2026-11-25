#!/usr/bin/env bash
# scripts/make-image.sh -- S.A.N.E Linux Host Image Builder
# Constructs bootable raw GPT disk image (sane.img) with Limine BIOS bootloader,
# dual-partition GPT layout, SPM-installed base packages, and switch_root initramfs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Default configurations
OUTPUT_FILE="${REPO_ROOT}/distro/sane.img"
SIZE_MB=512
PACKAGES_DIR="${REPO_ROOT}/distro/packages"
CACHE_DIR="${REPO_ROOT}/distro/cache"
DISTRO_DIR="${REPO_ROOT}/distro"
ROOTFS="${DISTRO_DIR}/rootfs"

log()  { printf '==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Constructs a bootable S.A.N.E Linux raw GPT disk image.

Options:
  -o, --output <file>     Target disk image path (default: distro/sane.img)
  -s, --size <mb>         Disk image size in megabytes (default: 512)
  -p, --packages <dir>    Directory containing .spm packages (default: distro/packages)
  -h, --help              Show this help message and exit
EOF
}

# Parse options
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)
            [ $# -ge 2 ] || die "Option '$1' requires an argument"
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --output=*)
            OUTPUT_FILE="${1#*=}"
            shift
            ;;
        -s|--size)
            [ $# -ge 2 ] || die "Option '$1' requires an argument"
            SIZE_MB="$2"
            shift 2
            ;;
        --size=*)
            SIZE_MB="${1#*=}"
            shift
            ;;
        -p|--packages)
            [ $# -ge 2 ] || die "Option '$1' requires an argument"
            PACKAGES_DIR="$2"
            shift 2
            ;;
        --packages=*)
            PACKAGES_DIR="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Check root / sudo requirements
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Root privileges or sudo required to manage loop devices and filesystems"
    SUDO="sudo"
fi

# Prerequisite checks
need_tool() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required tool '$cmd' not found on host"
}

need_tool sgdisk
need_tool mkfs.vfat
need_tool losetup
need_tool readelf

MKFS_EXT4=""
if command -v mkfs.ext4 >/dev/null 2>&1; then
    MKFS_EXT4="mkfs.ext4"
elif command -v mke2fs >/dev/null 2>&1; then
    MKFS_EXT4="mke2fs -t ext4"
else
    die "Neither mkfs.ext4 nor mke2fs found on host"
fi

# Find Limine binary
LIMINE_BIN=""
if [ -x "${REPO_ROOT}/distro/cache/limine" ]; then
    LIMINE_BIN="${REPO_ROOT}/distro/cache/limine"
elif [ -x "${REPO_ROOT}/packages/limine-static/x/usr/bin/limine" ]; then
    LIMINE_BIN="${REPO_ROOT}/packages/limine-static/x/usr/bin/limine"
elif command -v limine >/dev/null 2>&1; then
    LIMINE_BIN="$(command -v limine)"
else
    die "Limine bootloader binary not found in cache, packages, or PATH"
fi

# Find limine-bios.sys
LIMINE_BIOS_SYS=""
if [ -f "${REPO_ROOT}/distro/cache/limine-bios.sys" ]; then
    LIMINE_BIOS_SYS="${REPO_ROOT}/distro/cache/limine-bios.sys"
elif [ -f "${REPO_ROOT}/packages/limine-static/x/usr/share/limine/limine-bios.sys" ]; then
    LIMINE_BIOS_SYS="${REPO_ROOT}/packages/limine-static/x/usr/share/limine/limine-bios.sys"
else
    die "limine-bios.sys stage 2 payload not found"
fi

# Find Limine UEFI payloads (BOOTX64.EFI and BOOTIA32.EFI)
LIMINE_BOOTX64_EFI=""
if [ -f "${REPO_ROOT}/distro/cache/BOOTX64.EFI" ]; then
    LIMINE_BOOTX64_EFI="${REPO_ROOT}/distro/cache/BOOTX64.EFI"
elif [ -f "${REPO_ROOT}/packages/limine-static/x/usr/share/limine/BOOTX64.EFI" ]; then
    LIMINE_BOOTX64_EFI="${REPO_ROOT}/packages/limine-static/x/usr/share/limine/BOOTX64.EFI"
else
    die "BOOTX64.EFI UEFI payload not found in cache or packages"
fi

LIMINE_BOOTIA32_EFI=""
if [ -f "${REPO_ROOT}/distro/cache/BOOTIA32.EFI" ]; then
    LIMINE_BOOTIA32_EFI="${REPO_ROOT}/distro/cache/BOOTIA32.EFI"
elif [ -f "${REPO_ROOT}/packages/limine-static/x/usr/share/limine/BOOTIA32.EFI" ]; then
    LIMINE_BOOTIA32_EFI="${REPO_ROOT}/packages/limine-static/x/usr/share/limine/BOOTIA32.EFI"
else
    die "BOOTIA32.EFI UEFI payload not found in cache or packages"
fi

KERNEL_PINNED_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot-3.20.10/vmlinuz-virt"
KERNEL_PINNED_SHA256="be523954ad673a78c9cdfd3d473a8d39609f5901adfcc68402c67dc037a64c7e"
MODLOOP_PINNED_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot-3.20.10/modloop-virt"
MODLOOP_PINNED_SHA256="a6ed1699b1c8c863fe57543263480ee3835c083b8202251d3919d1817a3c5358"
PARTUUID="${PARTUUID:-44444444-4444-4444-8888-888888888888}"
# Validate PARTUUID (S5): it is written into the GPT entry, fstab and the
# kernel command line, so anything but a lowercase UUID must be rejected.
PARTUUID=$(printf '%s' "$PARTUUID" | tr 'A-Z' 'a-z')
if ! printf '%s' "$PARTUUID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    die "invalid PARTUUID format: $PARTUUID"
fi

verify_file_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || true)
    [ "$actual" = "$expected" ]
}

# Find Kernel binary (bzImage / vmlinuz-virt)
KERNEL_BIN=""
if [ -f "${REPO_ROOT}/distro/cache/vmlinuz-virt-v3.20" ] && verify_file_sha256 "${REPO_ROOT}/distro/cache/vmlinuz-virt-v3.20" "$KERNEL_PINNED_SHA256"; then
    KERNEL_BIN="${REPO_ROOT}/distro/cache/vmlinuz-virt-v3.20"
elif [ -f "${REPO_ROOT}/packages/kernel/x/boot/bzImage" ] && verify_file_sha256 "${REPO_ROOT}/packages/kernel/x/boot/bzImage" "$KERNEL_PINNED_SHA256"; then
    KERNEL_BIN="${REPO_ROOT}/packages/kernel/x/boot/bzImage"
    if [ ! -f "${CACHE_DIR}/vmlinuz-virt-v3.20" ] && [ -f "${REPO_ROOT}/packages/kernel/x/boot/vmlinuz-virt" ]; then
        mkdir -p "$CACHE_DIR"
        cp "${REPO_ROOT}/packages/kernel/x/boot/vmlinuz-virt" "${CACHE_DIR}/vmlinuz-virt-v3.20"
    fi
else
    log "Kernel binary not found or checksum mismatch. Downloading Alpine netboot kernel (v3.20 pinned)..."
    mkdir -p "$CACHE_DIR"
    curl -fL -s --retry 3 --connect-timeout 15 -o "${CACHE_DIR}/vmlinuz-virt-v3.20.part" \
        "$KERNEL_PINNED_URL" \
        || die "Failed to download Alpine netboot kernel (v3.20)"
    if ! verify_file_sha256 "${CACHE_DIR}/vmlinuz-virt-v3.20.part" "$KERNEL_PINNED_SHA256"; then
        rm -f "${CACHE_DIR}/vmlinuz-virt-v3.20.part"
        die "SHA256 checksum mismatch for downloaded kernel!"
    fi
    mv "${CACHE_DIR}/vmlinuz-virt-v3.20.part" "${CACHE_DIR}/vmlinuz-virt-v3.20"
    KERNEL_BIN="${CACHE_DIR}/vmlinuz-virt-v3.20"
fi

# Find Static BusyBox binary (for initramfs switch_root)
BUSYBOX_BIN=""
if [ -x "${REPO_ROOT}/distro/rootfs/bin/busybox" ]; then
    BUSYBOX_BIN="${REPO_ROOT}/distro/rootfs/bin/busybox"
elif [ -x "${REPO_ROOT}/packages/busybox/x/bin/busybox" ]; then
    BUSYBOX_BIN="${REPO_ROOT}/packages/busybox/x/bin/busybox"
elif [ -x "/bin/busybox" ]; then
    if readelf -l "/bin/busybox" 2>/dev/null | grep -q "INTERP"; then
        die "Host /bin/busybox fallback is dynamically linked (PT_INTERP detected); static ELF binary required"
    fi
    BUSYBOX_BIN="/bin/busybox"
else
    die "Static BusyBox binary not found for initramfs assembly"
fi

# Strictly verify selected BusyBox binary is a static ELF (no PT_INTERP)
if readelf -l "$BUSYBOX_BIN" 2>/dev/null | grep -q "INTERP"; then
    die "Selected BusyBox binary '$BUSYBOX_BIN' is dynamically linked (PT_INTERP detected); static ELF binary required"
fi

# Ensure kernel storage modules exist in cache
mkdir -p "$CACHE_DIR"
MODLOOP_VIRT="${CACHE_DIR}/modloop-virt"
if [ ! -s "$MODLOOP_VIRT" ] || ! verify_file_sha256 "$MODLOOP_VIRT" "$MODLOOP_PINNED_SHA256"; then
    log "Downloading Alpine modloop-virt for storage drivers (v3.20 pinned)..."
    curl -fL -s --retry 3 --connect-timeout 15 -o "$MODLOOP_VIRT.part" \
        "$MODLOOP_PINNED_URL" \
        || die "Failed to download modloop-virt"
    if ! verify_file_sha256 "$MODLOOP_VIRT.part" "$MODLOOP_PINNED_SHA256"; then
        rm -f "$MODLOOP_VIRT.part"
        die "SHA256 checksum mismatch for downloaded modloop-virt!"
    fi
    mv "$MODLOOP_VIRT.part" "$MODLOOP_VIRT"
fi

MODULES_STAGING="${CACHE_DIR}/storage-modules"
if [ ! -d "$MODULES_STAGING" ] || [ -z "$(find "$MODULES_STAGING" -name "nls_utf8.ko" 2>/dev/null)" ]; then
    log "Extracting storage modules from modloop-virt..."
    mkdir -p "$MODULES_STAGING"
    unsquashfs -f -d "$MODULES_STAGING" "$MODLOOP_VIRT" \
        "modules/*/kernel/drivers/block/virtio_blk.ko" \
        "modules/*/kernel/crypto/crc32c_generic.ko" \
        "modules/*/kernel/arch/x86/crypto/crc32c-intel.ko" \
        "modules/*/kernel/lib/libcrc32c.ko" \
        "modules/*/kernel/lib/crc16.ko" \
        "modules/*/kernel/fs/mbcache.ko" \
        "modules/*/kernel/fs/jbd2/jbd2.ko" \
        "modules/*/kernel/fs/ext4/ext4.ko" \
        "modules/*/kernel/fs/fat/fat.ko" \
        "modules/*/kernel/fs/fat/vfat.ko" \
        "modules/*/kernel/fs/nls/nls_cp437.ko" \
        "modules/*/kernel/fs/nls/nls_iso8859-1.ko" \
        "modules/*/kernel/fs/nls/nls_utf8.ko" >/dev/null
fi

# Verify kernel version matches module vermagic
kver=$(strings "$KERNEL_BIN" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-virt' | head -n1 || true)
sample_mod=$(find "$MODULES_STAGING" -name "*.ko" 2>/dev/null | head -n1 || true)
if [ -n "$kver" ] && [ -n "$sample_mod" ] && command -v modinfo >/dev/null 2>&1; then
    mver=$(modinfo -F vermagic "$sample_mod" 2>/dev/null | awk '{print $1}' || true)
    if [ -n "$mver" ] && [ "$kver" != "$mver" ]; then
        die "Kernel version ($kver) does not match module vermagic ($mver)"
    fi
fi

# Ensure cache is populated before calling packages/build-all.sh
mkdir -p "$CACHE_DIR"
if [ ! -f "${CACHE_DIR}/vmlinuz-virt-v3.20" ] && [ -n "$KERNEL_BIN" ] && [ -f "$KERNEL_BIN" ]; then
    cp "$KERNEL_BIN" "${CACHE_DIR}/vmlinuz-virt-v3.20"
fi

# Ensure base SPM packages exist
if [ ! -d "$PACKAGES_DIR" ] || [ -z "$(ls -A "$PACKAGES_DIR"/*.spm.tar.xz 2>/dev/null)" ]; then
    log "Packages not found in $PACKAGES_DIR. Building base packages..."
    bash "${REPO_ROOT}/packages/build-all.sh" "$PACKAGES_DIR"
fi

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"
OUTPUT_FILE="$(cd "$(dirname "$OUTPUT_FILE")" && pwd -P)/$(basename "$OUTPUT_FILE")"

log "Configuring image generation:"
info "Output file  : $OUTPUT_FILE"
info "Size         : ${SIZE_MB} MB"
info "Limine bin   : $LIMINE_BIN"
info "Kernel bin   : $KERNEL_BIN"
info "BusyBox bin  : $BUSYBOX_BIN"
info "Packages dir : $PACKAGES_DIR"

# Global tracking variables for cleanup trap
LOOP_DEV=""
MNT_DIR=""
INITRAMFS_STAGING=""

cleanup() {
    local rc=$?
    set +e
    if [ -n "$MNT_DIR" ] && [ -d "$MNT_DIR" ]; then
        if mountpoint -q "$MNT_DIR/boot" 2>/dev/null; then
            $SUDO umount "$MNT_DIR/boot" 2>/dev/null || true
        fi
        if mountpoint -q "$MNT_DIR/root" 2>/dev/null; then
            $SUDO umount "$MNT_DIR/root" 2>/dev/null || true
        fi
        if ! mountpoint -q "$MNT_DIR/boot" 2>/dev/null && [ -d "$MNT_DIR/boot" ]; then
            $SUDO rmdir "$MNT_DIR/boot" 2>/dev/null || rmdir "$MNT_DIR/boot" 2>/dev/null || true
        fi
        if ! mountpoint -q "$MNT_DIR/root" 2>/dev/null && [ -d "$MNT_DIR/root" ]; then
            $SUDO rmdir "$MNT_DIR/root" 2>/dev/null || rmdir "$MNT_DIR/root" 2>/dev/null || true
        fi
        if ! mountpoint -q "$MNT_DIR" 2>/dev/null && [ -d "$MNT_DIR" ]; then
            rmdir "$MNT_DIR" 2>/dev/null || true
        fi
    fi
    if [ -n "$INITRAMFS_STAGING" ] && [ -d "$INITRAMFS_STAGING" ]; then
        rm -rf "$INITRAMFS_STAGING" 2>/dev/null || true
    fi
    if [ -n "$LOOP_DEV" ] && [ -b "$LOOP_DEV" ]; then
        $SUDO losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

# Step 1: Create raw image file
log "Step 1/8: Allocating ${SIZE_MB}MB disk image..."
rm -f "$OUTPUT_FILE"
truncate -s "${SIZE_MB}M" "$OUTPUT_FILE"

# Step 2: Create GPT partition table via sgdisk
# Layout:
# - Partition 3: BIOS Boot Partition (type ef02) in sectors 34..2047 (for Limine BIOS stage 2 embedding)
# - Partition 1: 64MB FAT32 EFI System Partition (type ef00, label SANE_BOOT) at sector 2048
# - Partition 2: Remainder ext4 Rootfs (type 8300, label sane_root, PARTUUID=$PARTUUID)
log "Step 2/8: Partitioning image with GUID Partition Table (GPT)..."
sgdisk -Z "$OUTPUT_FILE" >/dev/null
sgdisk -o "$OUTPUT_FILE" >/dev/null

# Embed BIOS boot partition into GPT gap (sectors 34 to 2047)
sgdisk -a 1 -n 3:34:2047 -t 3:ef02 -c 3:bios_boot "$OUTPUT_FILE" >/dev/null

# Partition 1: 64MB ESP / Boot
sgdisk -a 2048 -n 1:2048:+64M -t 1:ef00 -c 1:SANE_BOOT "$OUTPUT_FILE" >/dev/null

# Partition 2: ext4 Rootfs with configured PARTUUID
sgdisk -n 2:0:0 -t 2:8300 -c 2:sane_root -u "2:$PARTUUID" "$OUTPUT_FILE" >/dev/null

# Step 3: Attach loop device
log "Step 3/8: Attaching loop device with partition scanning..."
LOOP_DEV="$($SUDO losetup -Pf --show "$OUTPUT_FILE")"
[ -n "$LOOP_DEV" ] || die "Failed to allocate loop device via losetup"

# Settle partition nodes
for _ in $(seq 1 50); do
    [ -b "${LOOP_DEV}p1" ] && [ -b "${LOOP_DEV}p2" ] && break
    sleep 0.1
done
[ -b "${LOOP_DEV}p1" ] && [ -b "${LOOP_DEV}p2" ] || die "Partition block devices ${LOOP_DEV}p1 / ${LOOP_DEV}p2 did not settle"

# Step 4: Format filesystems
log "Step 4/8: Formatting filesystems (FAT32 on p1, ext4 on p2)..."
$SUDO mkfs.vfat -F 32 -n "SANE_BOOT" "${LOOP_DEV}p1" >/dev/null
$SUDO $MKFS_EXT4 -F -L "sane_root" "${LOOP_DEV}p2" >/dev/null

# Step 5: Mount partitions
log "Step 5/8: Mounting partitions for population..."
MNT_DIR="$(mktemp -d /tmp/sane-img-mnt.XXXXXX)"
mkdir -p "$MNT_DIR/root" "$MNT_DIR/boot"
$SUDO mount "${LOOP_DEV}p2" "$MNT_DIR/root"
$SUDO mount "${LOOP_DEV}p1" "$MNT_DIR/boot"

# Step 6: Populate persistent root filesystem via SPM
log "Step 6/8: Installing S.A.N.E base packages via SPM..."
$SUDO bash "${REPO_ROOT}/scripts/spm" --root "$MNT_DIR/root" init >/dev/null

resolve_package_install_order() {
    local pkg_dir="$1"
    local meta_list
    meta_list="$(mktemp /tmp/sane-pkg-meta.XXXXXX)"
    declare -A seen_pkgs

    for pkg in "$pkg_dir"/*.spm.tar.xz; do
        [ -f "$pkg" ] || continue
        local pkg_manifest pkg_name pkg_deps
        pkg_manifest=$(tar -xJOf "$pkg" ./.META/package 2>/dev/null || tar -xJOf "$pkg" .META/package 2>/dev/null || true)
        pkg_name=$(printf '%s\n' "$pkg_manifest" | grep -E '^[[:space:]]*name=' | head -n1 | cut -d= -f2- | tr -d '\r\n' || true)
        if [ -z "$pkg_name" ]; then
            pkg_name=$(basename "$pkg" | sed -E 's/-[0-9]+(\.[0-9]+)*.*//')
        fi
        if [ -n "${seen_pkgs[$pkg_name]:-}" ]; then
            continue
        fi
        seen_pkgs[$pkg_name]=1

        pkg_deps=$(tar -xJOf "$pkg" ./.META/depends 2>/dev/null || tar -xJOf "$pkg" .META/depends 2>/dev/null || true)
        pkg_deps=$(printf '%s\n' "$pkg_deps" | tr ',\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
        if [ -z "$pkg_deps" ]; then
            pkg_deps=$(printf '%s\n' "$pkg_manifest" | grep -E '^[[:space:]]*dependencies=' | head -n1 | cut -d= -f2- | tr ',\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' || true)
        fi
        printf '%s|%s|%s\n' "$pkg_name" "$pkg" "$pkg_deps" >> "$meta_list"
    done

    local sort_out rc=0
    sort_out=$(LC_ALL=C sort "$meta_list" | awk -F'|' '
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
    ') || rc=$?
    rm -f "$meta_list"
    if [ "$rc" -ne 0 ]; then
        local err_msg
        err_msg=$(printf '%s\n' "$sort_out" | grep '^ERR|' | head -n1 | cut -d'|' -f2- || true)
        die "Package dependency resolution failed: ${err_msg:-exit $rc}"
    fi
    printf '%s\n' "$sort_out"
}

PKG_INSTALL_ORDER=$(resolve_package_install_order "$PACKAGES_DIR")
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    info "Installing package: $(basename "$pkg")"
    $SUDO bash "${REPO_ROOT}/scripts/spm" --root "$MNT_DIR/root" install "$pkg" >/dev/null
done <<EOF
$PKG_INSTALL_ORDER
EOF

# Install kernel modules to rootfs /lib/modules
if [ -d "$ROOTFS/lib/modules" ]; then
    $SUDO mkdir -p "$MNT_DIR/root/lib/modules"
    $SUDO cp -a "$ROOTFS/lib/modules/." "$MNT_DIR/root/lib/modules/"
elif [ -d "$MODULES_STAGING" ]; then
    $SUDO mkdir -p "$MNT_DIR/root/lib/modules"
    $SUDO find "$MODULES_STAGING" -name "*.ko" -exec cp {} "$MNT_DIR/root/lib/modules/" \;
fi

if [ -n "$kver" ] && [ -d "$MNT_DIR/root/lib/modules" ]; then
    $SUDO mkdir -p "$MNT_DIR/root/lib/modules/$kver"
    $SUDO find "$MNT_DIR/root/lib/modules" -maxdepth 1 -name "*.ko" -exec cp -u {} "$MNT_DIR/root/lib/modules/$kver/" \; 2>/dev/null || true
    if command -v depmod >/dev/null 2>&1; then
        $SUDO depmod -b "$MNT_DIR/root" "$kver" 2>/dev/null || true
    elif [ -x "$MNT_DIR/root/bin/busybox" ]; then
        $SUDO chroot "$MNT_DIR/root" /bin/busybox depmod "$kver" 2>/dev/null || true
    fi
fi

# Ensure standard system directories and permissions exist
$SUDO mkdir -p "$MNT_DIR/root"/{boot,proc,sys,dev,run,tmp,root,home,etc}
$SUDO chmod 1777 "$MNT_DIR/root/tmp"

# Configure /etc/fstab
log "Configuring /etc/fstab and /etc/init.conf..."
cat <<EOF | $SUDO tee "$MNT_DIR/root/etc/fstab" >/dev/null
# /etc/fstab: S.A.N.E Linux filesystem table
# Rootfs (PARTUUID=$PARTUUID) is mounted rw by initramfs before switch_root.
# Do not add an active '/' entry here: ninit mounts pseudo-filesystems
# automatically and mount_fstab() detaches recorded entries on shutdown.
EOF

# Install the reliability toolkit used by the reliability boot service.
$SUDO mkdir -p "$MNT_DIR/root/usr/bin"
$SUDO install -m 0755 "$REPO_ROOT/scripts/sane-reliability" "$MNT_DIR/root/usr/bin/sane-reliability"

# Configure /etc/init.conf
cat <<'EOF' | $SUDO tee "$MNT_DIR/root/etc/init.conf" >/dev/null
# /etc/init.conf -- S.A.N.E Linux service supervision
reliability:once:/bin/sh -c '/usr/bin/sane-reliability --root / recover || { echo "reliability: recover failed; boot enters rescue" >&2; exit 1; }':on_fail=rescue:timeout=0
recovery:once:/bin/sh -c 'exec </dev/console >/dev/console 2>&1; /usr/bin/sane-account-recovery':requires=reliability:on_fail=rescue:timeout=0
firstboot:once:/bin/sh -c 'exec </dev/console >/dev/console 2>&1; /usr/bin/sane-firstboot':requires=recovery:on_fail=rescue:timeout=0
network:respawn:/bin/sh -c 'modprobe af_packet 2>/dev/null; modprobe e1000 2>/dev/null; modprobe virtio_net 2>/dev/null; ip link set lo up 2>/dev/null; trap "kill \$! 2>/dev/null; exit 0" TERM INT; while [ ! -d /sys/class/net/eth0 ]; do sleep 5 & wait $!; done; exec sane-net dhcp -f eth0':requires=firstboot
tty1:respawn:/sbin/getty 38400 tty1 linux:requires=firstboot
console:respawn:cttyhack /sbin/getty -L 115200 - vt100:requires=firstboot
EOF

# Configure /etc/hostname
printf 'S.A.N.E\n' | $SUDO tee "$MNT_DIR/root/etc/hostname" >/dev/null
# No base package ships /etc/resolv.conf, so create the default resolver here.
if [ ! -f "$MNT_DIR/root/etc/resolv.conf" ]; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | $SUDO tee "$MNT_DIR/root/etc/resolv.conf" >/dev/null
fi
$SUDO cp "$MNT_DIR/root/etc/resolv.conf" "$MNT_DIR/root/etc/resolv.conf.default"

# Setuid permissions for doas
if [ -f "$MNT_DIR/root/usr/bin/doas" ]; then
    $SUDO chmod 4755 "$MNT_DIR/root/usr/bin/doas"
fi
# Wi-Fi config holds secrets: always root-owned 0600.
if [ -f "$MNT_DIR/root/etc/wpa_supplicant.conf" ]; then
    $SUDO chmod 0600 "$MNT_DIR/root/etc/wpa_supplicant.conf"
fi

# Single source of truth for identity files + account utilities.
$SUDO sh "$REPO_ROOT/scripts/provision-accounts.sh" "$MNT_DIR/root" "$SUDO"

# Configure /etc/issue
cat <<'EOF' | $SUDO tee "$MNT_DIR/root/etc/issue" >/dev/null
Welcome to S.A.N.E Linux (\m) - \l
Kernel \r on an \m (\l)

EOF

# Create /home/sane
$SUDO mkdir -p "$MNT_DIR/root/home/sane"
$SUDO chmod 0750 "$MNT_DIR/root/home/sane"
$SUDO chown 1000:1000 "$MNT_DIR/root/home/sane"

# Configure /etc/profile
cat <<'EOF' | $SUDO tee "$MNT_DIR/root/etc/profile" >/dev/null
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export USER=$(id -un 2>/dev/null || echo "$USER")
export LOGNAME="$USER"
export HOME="/home/$USER"
[ "$USER" = "root" ] && export HOME="/root"
EOF
$SUDO chmod 0644 "$MNT_DIR/root/etc/profile"

# Step 7: Assemble minimal initramfs for switch_root
log "Step 7/8: Assembling minimal switch_root initramfs..."
INITRAMFS_STAGING="$(mktemp -d /tmp/sane-initramfs.XXXXXX)"
mkdir -p "$INITRAMFS_STAGING"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,run,newroot,etc,lib/modules}

install -m 0755 "$BUSYBOX_BIN" "$INITRAMFS_STAGING/bin/busybox"

# Symlink core applets in initramfs
APPLETS=(
    sh ash mount umount mkdir cat sleep echo grep cut ls stat test "["
    switch_root mdev findfs blkid insmod lsmod modprobe hexdump dd mknod awk
)
for applet in "${APPLETS[@]}"; do
    ln -sf /bin/busybox "$INITRAMFS_STAGING/bin/$applet"
    ln -sf /bin/busybox "$INITRAMFS_STAGING/sbin/$applet"
done

# Copy storage drivers to initramfs
if [ -d "$MODULES_STAGING" ]; then
    mkdir -p "$INITRAMFS_STAGING/lib/modules"
    find "$MODULES_STAGING" -name "*.ko" -exec cp {} "$INITRAMFS_STAGING/lib/modules/" \;
fi

# Assemble initramfs /init script adhering to boot-pipeline.md section 3 & distro-image-builder.md
cat <<'EOF' > "$INITRAMFS_STAGING/init"
#!/bin/sh
# /init -- S.A.N.E minimal initramfs entrypoint
set -eu

# 1. Mount essential early pseudo-filesystems
mkdir -p /proc /sys /dev /run /newroot
mount -t proc proc /proc || { echo "ERROR: failed to mount /proc"; exec /bin/sh; }
mount -t sysfs sysfs /sys || { echo "ERROR: failed to mount /sys"; exec /bin/sh; }
mount -t devtmpfs devtmpfs /dev || { echo "ERROR: failed to mount /dev"; exec /bin/sh; }
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run || { echo "ERROR: failed to mount /run"; exec /bin/sh; }

# 2. Load essential storage and filesystem kernel modules
for mod in crc32c_generic crc32c-intel libcrc32c crc16 mbcache jbd2 ext4 virtio_blk nls_cp437 nls_iso8859-1 nls_utf8 fat vfat; do
    if [ -f "/lib/modules/${mod}.ko" ]; then
        insmod "/lib/modules/${mod}.ko" 2>/dev/null || true
    fi
done

# 3. Parse command line for root device
ROOT_DEV="/dev/vda2"
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        root=*) ROOT_DEV="${arg#root=}" ;;
    esac
done

# 4. Resolve device path (supporting PARTUUID, UUID, LABEL, or direct device path)
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

ROOT_DEV="$RESOLVED_DEV"

# 5. Mount target root filesystem
mount -t ext4 -o rw "$ROOT_DEV" /newroot || { echo "ERROR: failed to mount root device $ROOT_DEV"; exec /bin/sh; }

# 6. Move pseudo-filesystems into newroot
mount --move /run /newroot/run || { echo "ERROR: failed to move /run"; exec /bin/sh; }
mount --move /dev /newroot/dev || { echo "ERROR: failed to move /dev"; exec /bin/sh; }
mount --move /sys /newroot/sys || { echo "ERROR: failed to move /sys"; exec /bin/sh; }
mount --move /proc /newroot/proc || { echo "ERROR: failed to move /proc"; exec /bin/sh; }

# 7. Execute switch_root handoff to ninit
echo "switch_root: pivoting to $ROOT_DEV"
exec switch_root /newroot /sbin/init || { echo "ERROR: switch_root failed"; exec /bin/sh; }
EOF
chmod 0755 "$INITRAMFS_STAGING/init"

# Determine portable cpio owner and null flags
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

# Pack initramfs into boot partition
# shellcheck disable=SC2086
( cd "$INITRAMFS_STAGING" && find . -print0 | cpio $CPIO_NULL -o -H newc $CPIO_OWNER | gzip -9 > "$MNT_DIR/boot/initramfs.cpio.gz" )
[ -s "$MNT_DIR/boot/initramfs.cpio.gz" ] || die "Failed to assemble initramfs.cpio.gz"
rm -rf "$INITRAMFS_STAGING"
INITRAMFS_STAGING=""

# Populate boot partition
MNT_BOOT="$MNT_DIR/boot"
$SUDO cp "$KERNEL_BIN" "$MNT_BOOT/bzImage"
$SUDO cp "$LIMINE_BIOS_SYS" "$MNT_BOOT/limine-bios.sys"

# Install UEFI bootloader binaries to ESP standard path
$SUDO mkdir -p "$MNT_BOOT/EFI/BOOT"
$SUDO cp "$LIMINE_BOOTX64_EFI" "$MNT_BOOT/EFI/BOOT/BOOTX64.EFI"
$SUDO cp "$LIMINE_BOOTIA32_EFI" "$MNT_BOOT/EFI/BOOT/BOOTIA32.EFI"

cat <<EOF | $SUDO tee "$MNT_BOOT/limine.conf" >/dev/null
timeout: 0
serial: yes

/S.A.N.E Linux
    protocol: linux
    kernel_path: boot():/bzImage
    module_path: boot():/initramfs.cpio.gz
    cmdline: console=tty0 console=ttyS0 root=PARTUUID=$PARTUUID rootfstype=ext4 rw quiet panic=-1
EOF
$SUDO cp "$MNT_BOOT/limine.conf" "$MNT_BOOT/limine.cfg"
$SUDO cp "$MNT_BOOT/limine.conf" "$MNT_BOOT/EFI/BOOT/limine.conf"
$SUDO cp "$MNT_BOOT/limine.conf" "$MNT_BOOT/EFI/BOOT/limine.cfg"

# Unmount and detach loop device cleanly
log "Step 8/8: Flushing buffers, unmounting and installing Limine bootloader..."
$SUDO sync
$SUDO umount "$MNT_DIR/boot"
$SUDO umount "$MNT_DIR/root"
if ! mountpoint -q "$MNT_DIR/boot" 2>/dev/null && [ -d "$MNT_DIR/boot" ]; then
    $SUDO rmdir "$MNT_DIR/boot" 2>/dev/null || rmdir "$MNT_DIR/boot" 2>/dev/null || true
fi
if ! mountpoint -q "$MNT_DIR/root" 2>/dev/null && [ -d "$MNT_DIR/root" ]; then
    $SUDO rmdir "$MNT_DIR/root" 2>/dev/null || rmdir "$MNT_DIR/root" 2>/dev/null || true
fi
if ! mountpoint -q "$MNT_DIR" 2>/dev/null && [ -d "$MNT_DIR" ]; then
    rmdir "$MNT_DIR" 2>/dev/null || true
fi
MNT_DIR=""

$SUDO losetup -d "$LOOP_DEV"
LOOP_DEV=""

# Deploy Limine BIOS bootloader stage 1 to MBR/GPT
$LIMINE_BIN bios-install "$OUTPUT_FILE" >/dev/null

# Fix permissions so non-root test harness / user can access the disk image
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    REAL_USER="$(stat -c '%U' "$REPO_ROOT" 2>/dev/null || id -u)"
fi
REAL_GROUP="$(id -g "$REAL_USER" 2>/dev/null || stat -c '%G' "$REPO_ROOT" 2>/dev/null || id -g)"
chown "${REAL_USER}:${REAL_GROUP}" "$OUTPUT_FILE" 2>/dev/null || true
chmod 0644 "$OUTPUT_FILE"

log "Image successfully created at $OUTPUT_FILE"
info "Size        : $(du -h "$OUTPUT_FILE" | cut -f1)"
info "SHA256      : $(sha256sum "$OUTPUT_FILE" | cut -d' ' -f1)"
info "Partitions  :"
sgdisk -p "$OUTPUT_FILE" | grep -E "Number|^\s*[1-9]" | sed 's/^/    /'

exit 0
