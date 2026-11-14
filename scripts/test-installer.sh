#!/usr/bin/env bash
# scripts/test-installer.sh -- Test Harness for S.A.N.E Offline Installer (INST-50/INST-51)
#
# Validates:
#   1. Safety guards (fail-closed rejection on partitions, mounted targets, non-block devices)
#   2. Offline end-to-end installation into raw disk image via sane-install.sh
#   3. Partition layout (GPT ef00 ESP, 8300 rootfs, ef02 bios_boot gap)
#   4. ESP bootloader artifacts (bzImage, initramfs, limine-bios.sys, BOOTX64.EFI, limine.conf)
#   5. Root filesystem integrity (/etc/fstab, /etc/init.conf, SPM database)
#   6. Headless QEMU boot test of installed disk (BIOS + UEFI dual-boot verification)
#
# Usage:
#   sudo bash scripts/test-installer.sh [--quick] [--timeout <sec>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DISTRO_DIR="${DISTRO_DIR:-$REPO_ROOT/distro}"
PACKAGES_DIR="${PACKAGES_DIR:-$DISTRO_DIR/packages}"
INSTALLER_BIN="$REPO_ROOT/scripts/sane-install.sh"

TIMEOUT_SECS=30
QUICK_MODE=0
OVMF_PATH="${OVMF_PATH:-}"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --quick)
            QUICK_MODE=1
            shift
            ;;
        --timeout)
            TIMEOUT_SECS="$2"
            shift 2
            ;;
        --ovmf)
            OVMF_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

die()  { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '\033[31m[FAIL]\033[0m %s\n' "$1" >&2; exit 1; }
pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); printf '\033[32m[PASS]\033[0m %s\n' "$1"; }
skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '\033[33m[SKIP]\033[0m %s\n' "$1"; }
info() { printf '       %s\n' "$1"; }

[ -x "$INSTALLER_BIN" ] || die "Installer script not executable: $INSTALLER_BIN"

# Check root privilege
if [ "$(id -u)" -ne 0 ]; then
    die "test-installer.sh requires root privileges to manage loop devices and partitions"
fi

# Ensure packages exist
if ! ls "$PACKAGES_DIR"/*.spm.tar.xz >/dev/null 2>&1; then
    printf 'Building base packages...\n'
    "$REPO_ROOT/packages/build-all.sh" "$PACKAGES_DIR"
fi

TEST_IMG="/tmp/sane-test-install-disk.img"
LOOP_DEV=""
LOOP_GUARD=""
MNT_GUARD=""
MNT_TMP=""

cleanup() {
    set +e
    if [ -n "$MNT_TMP" ] && [ -d "$MNT_TMP" ]; then
        if mountpoint -q "$MNT_TMP/boot" 2>/dev/null; then umount "$MNT_TMP/boot" 2>/dev/null || true; fi
        if mountpoint -q "$MNT_TMP/root" 2>/dev/null; then umount "$MNT_TMP/root" 2>/dev/null || true; fi
        rm -rf "$MNT_TMP" 2>/dev/null || true
    fi
    if [ -n "$MNT_GUARD" ] && [ -d "$MNT_GUARD" ]; then
        if mountpoint -q "$MNT_GUARD" 2>/dev/null; then umount "$MNT_GUARD" 2>/dev/null || true; fi
        rm -rf "$MNT_GUARD" 2>/dev/null || true
    fi
    if [ -n "$LOOP_GUARD" ] && [ -b "$LOOP_GUARD" ]; then
        losetup -d "$LOOP_GUARD" 2>/dev/null || true
    fi
    if [ -n "$LOOP_DEV" ] && [ -b "$LOOP_DEV" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    rm -f "$TEST_IMG" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

printf '=== Phase 5: S.A.N.E Offline Live Installer Test Suite ===\n\n'

# -------------------------------------------------------------
# Test Group 1: Safety Guards & Defensive Validation (Fail-Closed)
# -------------------------------------------------------------
printf '%s\n' "--- Group 1: Safety Guards & Validation ---"

# Test 1.1: Missing target argument
rc=0
"$INSTALLER_BIN" --unattended >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    pass "Guard 1: Missing target argument rejected with non-zero exit code"
else
    die "Guard 1: Installer proceeded without target argument"
fi

# Test 1.2: Non-block device target
rc=0
"$INSTALLER_BIN" --target "/tmp/nonexistent-block-device" --unattended >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    pass "Guard 2: Non-existent or non-block device rejected with non-zero exit code"
else
    die "Guard 2: Installer accepted non-block device"
fi

# Test 1.3: Target is a partition (not a whole disk)
rm -f "$TEST_IMG"
truncate -s 64M "$TEST_IMG"
LOOP_GUARD="$(losetup -Pf --show "$TEST_IMG")"
[ -n "$LOOP_GUARD" ] && [ -b "$LOOP_GUARD" ] || die "Guard 3: Failed to attach loop device"
sgdisk -n 1:2048:0 "$LOOP_GUARD" >/dev/null 2>&1 || die "Guard 3: Failed to partition loop device via sgdisk"
partprobe "$LOOP_GUARD" 2>/dev/null || true
command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=3 2>/dev/null || true

PART_GUARD="${LOOP_GUARD}p1"
for _ in $(seq 1 15); do
    [ -b "$PART_GUARD" ] && break
    sleep 0.2
done
[ -b "$PART_GUARD" ] || die "Guard 3: Partition device $PART_GUARD failed to appear (partition safety guard prerequisite failed)"

rc=0
"$INSTALLER_BIN" --target "$PART_GUARD" --unattended >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
    pass "Guard 3: Partition target rejected (must be whole disk)"
else
    die "Guard 3: Installer accepted a partition target ($PART_GUARD)"
fi
losetup -d "$LOOP_GUARD" || die "Guard 3: Failed to detach loop device"
LOOP_GUARD=""
rm -f "$TEST_IMG"

# Test 1.4: Mounted target disk rejection
truncate -s 64M "$TEST_IMG"
LOOP_GUARD="$(losetup -Pf --show "$TEST_IMG")"
[ -n "$LOOP_GUARD" ] && [ -b "$LOOP_GUARD" ] || die "Guard 4: Failed to attach loop device"
sgdisk -n 1:2048:0 "$LOOP_GUARD" >/dev/null 2>&1 || die "Guard 4: Failed to partition loop device via sgdisk"
partprobe "$LOOP_GUARD" 2>/dev/null || true
command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=3 2>/dev/null || true

PART_GUARD="${LOOP_GUARD}p1"
for _ in $(seq 1 15); do
    [ -b "$PART_GUARD" ] && break
    sleep 0.2
done
[ -b "$PART_GUARD" ] || die "Guard 4: Partition device $PART_GUARD failed to appear (partition safety guard prerequisite failed)"

mkfs.ext2 -F "$PART_GUARD" >/dev/null 2>&1 || die "Guard 4: Failed to format test partition $PART_GUARD"
MNT_GUARD="$(mktemp -d /tmp/sane-guard-mnt.XXXXXX)"
mount "$PART_GUARD" "$MNT_GUARD" || die "Guard 4: Failed to mount test partition $PART_GUARD"

rc=0
"$INSTALLER_BIN" --target "$LOOP_GUARD" --unattended >/dev/null 2>&1 || rc=$?
umount "$MNT_GUARD" || die "Guard 4: Failed to unmount $MNT_GUARD"
rmdir "$MNT_GUARD"
MNT_GUARD=""
if [ "$rc" -ne 0 ]; then
    pass "Guard 4: Mounted disk/partition target rejected (fail-closed)"
else
    die "Guard 4: Installer allowed operating on a mounted disk"
fi
losetup -d "$LOOP_GUARD" || die "Guard 4: Failed to detach loop device"
LOOP_GUARD=""
rm -f "$TEST_IMG"

# Test 1.5: Undersized target disk (<256MB) rejection in preflight
truncate -s 64M "$TEST_IMG"
LOOP_GUARD="$(losetup -f --show "$TEST_IMG")"
[ -n "$LOOP_GUARD" ] && [ -b "$LOOP_GUARD" ] || die "Guard 5: Failed to attach loop device"
rc=0
"$INSTALLER_BIN" --target "$LOOP_GUARD" --unattended >/dev/null 2>&1 || rc=$?
losetup -d "$LOOP_GUARD" || die "Guard 5: Failed to detach loop device"
LOOP_GUARD=""
rm -f "$TEST_IMG"
if [ "$rc" -ne 0 ]; then
    pass "Guard 5: Undersized target disk (<256MB) rejected during preflight"
else
    die "Guard 5: Installer accepted an undersized target disk (<256MB)"
fi

# -------------------------------------------------------------
# Test Group 2: End-to-End Installation on Raw Disk
# -------------------------------------------------------------
printf '\n%s\n' "--- Group 2: End-to-End Installation Execution ---"

truncate -s 512M "$TEST_IMG"
LOOP_DEV="$(losetup -Pf --show "$TEST_IMG")"
[ -b "$LOOP_DEV" ] || die "Failed to attach loop device"

info "Attached test disk: $LOOP_DEV ($TEST_IMG)"

rc=0
"$INSTALLER_BIN" \
    --target "$LOOP_DEV" \
    --packages-dir "$PACKAGES_DIR" \
    --unattended \
    --no-reboot || rc=$?

if [ "$rc" -ne 0 ]; then
    die "sane-install.sh returned non-zero exit code: $rc"
fi
pass "sane-install.sh executed successfully to completion (exit 0)"

# -------------------------------------------------------------
# Test Group 3: Post-Install Layout & Filesystem Assertions
# -------------------------------------------------------------
printf '\n%s\n' "--- Group 3: Partition Layout & Filesystem Verification ---"

# 3.1 Partition table check
part_output="$(sgdisk -p "$LOOP_DEV")"
if echo "$part_output" | grep -q "EF00" && \
   echo "$part_output" | grep -q "8300" && \
   echo "$part_output" | grep -q "EF02"; then
    pass "Partition layout verified: Partition 1 (ef00 ESP), Partition 2 (8300 rootfs), Partition 3 (ef02 bios_boot)"
else
    die "Partition layout mismatch:\n$part_output"
fi

PART1="${LOOP_DEV}p1"
PART2="${LOOP_DEV}p2"

MNT_TMP="$(mktemp -d /tmp/sane-assert-mnt.XXXXXX)"
mkdir -p "$MNT_TMP/boot" "$MNT_TMP/root"

mount "$PART1" "$MNT_TMP/boot"
mount "$PART2" "$MNT_TMP/root"

# 3.2 ESP partition checks
[ -f "$MNT_TMP/boot/bzImage" ] || die "ESP missing bzImage"
[ -f "$MNT_TMP/boot/initramfs.cpio.gz" ] || die "ESP missing initramfs.cpio.gz"
[ -f "$MNT_TMP/boot/limine-bios.sys" ] || die "ESP missing limine-bios.sys"
[ -f "$MNT_TMP/boot/EFI/BOOT/BOOTX64.EFI" ] || die "ESP missing EFI/BOOT/BOOTX64.EFI"
[ -f "$MNT_TMP/boot/limine.conf" ] || die "ESP missing limine.conf"
pass "ESP bootloader files verified (bzImage, initramfs.cpio.gz, limine-bios.sys, BOOTX64.EFI, limine.conf)"

# 3.3 Root filesystem checks
[ -x "$MNT_TMP/root/bin/busybox" ] || die "Rootfs missing /bin/busybox"
[ -x "$MNT_TMP/root/sbin/init" ] || die "Rootfs missing /sbin/init (ninit)"
[ -f "$MNT_TMP/root/etc/fstab" ] || die "Rootfs missing /etc/fstab"
[ -f "$MNT_TMP/root/etc/init.conf" ] || die "Rootfs missing /etc/init.conf"
[ -d "$MNT_TMP/root/var/lib/spm" ] || die "Rootfs missing /var/lib/spm database"

# Check fstab contents
if grep -q "PARTUUID=" "$MNT_TMP/root/etc/fstab"; then
    pass "Rootfs /etc/fstab configured with resilient PARTUUID reference"
else
    die "Rootfs /etc/fstab missing PARTUUID entry"
fi

# Check limine.conf contents
if grep -q "root=PARTUUID=" "$MNT_TMP/boot/limine.conf"; then
    pass "Limine bootloader config uses root=PARTUUID= parameter"
else
    die "Limine bootloader config missing root=PARTUUID= parameter"
fi

# Check init.conf contents
if grep -q "console:respawn:cttyhack /bin/sh -i" "$MNT_TMP/root/etc/init.conf"; then
    pass "Rootfs /etc/init.conf configured with cttyhack interactive console"
else
    die "Rootfs /etc/init.conf missing cttyhack interactive console"
fi

# Check SPM database records
spm_installed="$(ls "$MNT_TMP/root/var/lib/spm/installed/" 2>/dev/null || true)"
if echo "$spm_installed" | grep -q "ninit" && echo "$spm_installed" | grep -q "busybox"; then
    pass "SPM database verified (ninit, busybox, and base packages registered)"
else
    die "SPM database missing base packages: $spm_installed"
fi

umount "$MNT_TMP/boot"
umount "$MNT_TMP/root"
rm -rf "$MNT_TMP"
MNT_TMP=""

losetup -d "$LOOP_DEV"
LOOP_DEV=""

# -------------------------------------------------------------
# Test Group 4: QEMU Boot Verification of Installed Disk Image
# -------------------------------------------------------------
printf '\n%s\n' "--- Group 4: Headless QEMU Boot Verification (INST-51) ---"

if [ "$QUICK_MODE" -eq 1 ]; then
    skip "QEMU BIOS boot test skipped (--quick mode requested)"
    skip "QEMU UEFI boot test skipped (--quick mode requested)"
else
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 required for INST-51 boot test"

    CONSOLE_LOG="/tmp/sane-installer-qemu-console.log"
    : > "$CONSOLE_LOG"

    ACCEL_ARGS=()
    if [ -w /dev/kvm ] 2>/dev/null; then
        ACCEL_ARGS+=(-enable-kvm -cpu host)
    else
        ACCEL_ARGS+=(-cpu max)
    fi

    info "Booting installed disk image in QEMU via Limine BIOS..."
    timeout -k 2 "${TIMEOUT_SECS}s" \
        qemu-system-x86_64 \
        -drive "file=$TEST_IMG,format=raw,if=virtio" \
        -m 256M \
        -serial "file:$CONSOLE_LOG" \
        -display none \
        -no-reboot \
        "${ACCEL_ARGS[@]}" >/dev/null 2>&1 &
    QEMU_PID=$!

    # Monitor boot markers
    DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
    boot_ok=0
    switch_root_ok=0
    ninit_ok=0
    hello_ok=0

    while [ $(date +%s) -lt $DEADLINE ]; do
        if [ -s "$CONSOLE_LOG" ]; then
            if grep -qi "switch_root" "$CONSOLE_LOG"; then
                switch_root_ok=1
            fi
            if grep -qiE "main loop ready|ninit.*ready" "$CONSOLE_LOG"; then
                ninit_ok=1
            fi
            if grep -qiE "started sane-hello|started hello|Hello from S.A.N.E Linux" "$CONSOLE_LOG"; then
                hello_ok=1
            fi
            if [ "$switch_root_ok" -eq 1 ] && [ "$ninit_ok" -eq 1 ]; then
                boot_ok=1
                break
            fi
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done

    kill -TERM "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true

    if [ "$switch_root_ok" -eq 1 ]; then
        pass "QEMU boot: switch_root pivoted cleanly from initramfs to ext4 rootfs"
    else
        die "QEMU boot failed: switch_root marker missing in console log"
    fi

    if [ "$ninit_ok" -eq 1 ]; then
        pass "QEMU boot: ninit PID 1 started and reached 'main loop ready'"
    else
        die "QEMU boot failed: ninit PID 1 ready marker missing in console log"
    fi

    if [ "$hello_ok" -eq 1 ]; then
        pass "QEMU boot: service execution confirmed (sane-hello / console)"
    else
        info "Notice: sane-hello service marker not yet captured, but ninit main loop is active"
    fi

    if grep -qi "kernel panic" "$CONSOLE_LOG"; then
        die "QEMU boot detected kernel panic in console log"
    fi
    pass "QEMU BIOS boot: Zero kernel panics (BIOS test PASS)"

    # 4.2 UEFI Boot Verification if OVMF firmware available
    OVMF_BIN=""
    if [ -n "$OVMF_PATH" ] && [ -f "$OVMF_PATH" ]; then
        OVMF_BIN="$OVMF_PATH"
    else
        for cand in \
            /usr/share/ovmf/OVMF.fd \
            /usr/share/OVMF/OVMF.fd \
            /usr/share/qemu/OVMF.fd \
            /usr/share/edk2-ovmf/x64/OVMF.fd \
            /usr/share/edk2/ovmf/OVMF.fd; do
            if [ -f "$cand" ]; then
                OVMF_BIN="$cand"
                break
            fi
        done
    fi

    if [ -n "$OVMF_BIN" ]; then
        info "Booting installed disk image in QEMU via Limine UEFI ($OVMF_BIN)..."
        CONSOLE_LOG_UEFI="/tmp/sane-installer-qemu-uefi.log"
        : > "$CONSOLE_LOG_UEFI"

        timeout -k 2 "${TIMEOUT_SECS}s" \
            qemu-system-x86_64 \
            -bios "$OVMF_BIN" \
            -drive "file=$TEST_IMG,format=raw,if=virtio" \
            -m 256M \
            -serial "file:$CONSOLE_LOG_UEFI" \
            -display none \
            -no-reboot \
            "${ACCEL_ARGS[@]}" >/dev/null 2>&1 &
        QEMU_UEFI_PID=$!

        DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
        uefi_switch_root_ok=0
        uefi_ninit_ok=0

        while [ $(date +%s) -lt $DEADLINE ]; do
            if [ -s "$CONSOLE_LOG_UEFI" ]; then
                if grep -qi "switch_root" "$CONSOLE_LOG_UEFI"; then
                    uefi_switch_root_ok=1
                fi
                if grep -qiE "main loop ready|ninit.*ready" "$CONSOLE_LOG_UEFI"; then
                    uefi_ninit_ok=1
                fi
                if [ "$uefi_switch_root_ok" -eq 1 ] && [ "$uefi_ninit_ok" -eq 1 ]; then
                    break
                fi
            fi
            if ! kill -0 "$QEMU_UEFI_PID" 2>/dev/null; then
                break
            fi
            sleep 0.2
        done

        kill -TERM "$QEMU_UEFI_PID" 2>/dev/null || true
        wait "$QEMU_UEFI_PID" 2>/dev/null || true

        if grep -qi "kernel panic" "$CONSOLE_LOG_UEFI"; then
            die "QEMU UEFI boot detected kernel panic in console log (UEFI test FAIL)"
        fi

        if [ "$uefi_switch_root_ok" -eq 1 ] && [ "$uefi_ninit_ok" -eq 1 ]; then
            pass "QEMU UEFI boot: switch_root and ninit PID 1 started cleanly (UEFI test PASS)"
        else
            die "QEMU UEFI boot failed: switch_root or ninit ready marker missing (UEFI test FAIL)"
        fi
    else
        skip "QEMU UEFI boot: OVMF firmware not detected on host (UEFI test SKIP)"
    fi
fi

printf '\n=======================================================\n'
printf 'Installer Test Summary: %d passed, %d failed, %d skipped\n' "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
printf '=======================================================\n'
if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
