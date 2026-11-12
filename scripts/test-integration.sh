#!/bin/sh
# test-integration.sh -- cross-layer integration test: fstab -> real kernel ->
# visible from a service -> QEMU boot ordering.
#
# Why this suite exists: test-config.sh tests the fstab parser in a chroot and
# test-qemu-report.sh tests report() via log fixtures. Neither can catch
# inconsistencies BETWEEN layers — e.g. a correct octal escape in the unit test
# but a mount() failure on the real kernel, or mount options the parser reads
# but that vanish when the rootfs is packed into an initramfs. This suite does
# ONE real QEMU boot with a test fstab + init.conf, then demands the final
# result: the mount really exists in /proc/mounts from the service's point of
# view, and fstab is mounted BEFORE any service starts.
#
# Pemakaian:
#   sudo sh ./scripts/test-integration.sh
#
# Variabel:
#   SECS=40             boot window (TCG without KVM is slow; raise if needed)
#   BUSYBOX_MODE=prebuilt  passed through to build-rootfs.sh (auto|source|prebuilt)
#   DISTRO_DIR, ROOTFS, INITRAMFS, CONSOLE_LOG  as in run-qemu.sh
#
# Requires: same as build-rootfs.sh + run-qemu.sh (qemu-system-x86, cpio,
# static busybox, root for mknod/dev and QEMU TCG).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

DISTRO_DIR=${DISTRO_DIR:-$REPO_ROOT/distro}
CONSOLE_LOG=${CONSOLE_LOG:-$DISTRO_DIR/qemu-console.log}
INITRAMFS=${INITRAMFS:-$DISTRO_DIR/initramfs.cpio.gz}
SECS=${SECS:-40}
BUSYBOX_MODE=${BUSYBOX_MODE:-prebuilt}

log()  { printf '== %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"
$SUDO true 2>/dev/null || die "root or passwordless sudo required (mknod in build-rootfs.sh + QEMU)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# --------------------------------------------------------------- fixture
# Three fstab entries representing three different behaviors:
#   1. a successful mount with a data option (size=1m must reach mount())
#   2. the octal escape \040 in the mountpoint: the unit test proves the parser
#      decodes it; here we prove the kernel really mounts the decoded "a b"
#      directory (PR #3-C1 regression)
#   3. a duplicate mountpoint of entry 1: must be SKIPPED, not mounted twice
#      (PR #3-C2 regression)
cat > "$WORK/fstab" <<'EOF'
tmpfs /mnt/intg tmpfs size=1m 0 0
tmpfs /mnt/a\040b tmpfs defaults 0 0
tmpfs /mnt/intg tmpfs defaults 0 0
EOF

# mountproof: a `once` service that reads /proc/mounts FROM INSIDE the guest.
# If the fstab mount only succeeds in the ninit log but does not enter the
# kernel mount table, INTEGRATION-MOUNT-MISSING is printed. The /proc/mounts
# format escapes spaces literally as \040, so the grep -F here matches the raw
# text, not the decoded directory name.
cat > "$WORK/init.conf" <<'EOF'
mountproof:once:/bin/sh -c 'ok=1; grep -qF " /mnt/intg " /proc/mounts || ok=0; grep -qF " /mnt/a\040b " /proc/mounts || ok=0; [ "$ok" = 1 ] && echo INTEGRATION-MOUNT-VISIBLE || echo INTEGRATION-MOUNT-MISSING'
EOF

# --------------------------------------------------------------- build + boot
log "building ninit"
make -C "$REPO_ROOT" >/dev/null || die "make ninit failed"

log "building rootfs + initramfs with the test fstab & init.conf"
$SUDO env EXTRA_FSTAB="$WORK/fstab" EXTRA_INIT_CONF="$WORK/init.conf" \
BUSYBOX_MODE="$BUSYBOX_MODE" DISTRO_DIR="$DISTRO_DIR" \
	sh "$SCRIPT_DIR/build-rootfs.sh"
[ -s "$INITRAMFS" ] || die "initramfs was not produced"

log "booting QEMU once (SECS=$SECS) — run-qemu.sh's built-in report also judges it"
harness_rc=0
$SUDO env SECS="$SECS" CONSOLE_LOG="$CONSOLE_LOG" sh "$SCRIPT_DIR/run-qemu.sh" || harness_rc=$?
[ -r "$CONSOLE_LOG" ] || die "no readable console at $CONSOLE_LOG"

# --------------------------------------------------------------- checks
fail_count=0
check()  { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [ OK ]   %s\n' "$1"; else printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); fi; }
absent() { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); else printf '  [ OK ]   %s\n' "$1"; fi; }
line_no() { grep -m1 -n "$1" "$CONSOLE_LOG" 2>/dev/null | cut -d: -f1 || true; }

printf '\n== fstab <-> kernel <-> service integration checks ==\n'
check "normal entry mounted with data option (size=1m)" \
	'fstab: mount tmpfs -> /mnt/intg (tmpfs) \[data: size=1m\] ok'
check "octal escape decoded then mounted by the kernel as-is ('/mnt/a b')" \
	'fstab: mount tmpfs -> /mnt/a b (tmpfs)'
check "duplicate entry SKIPPED, not mounted twice" \
	'fstab: tmpfs -> /mnt/intg skipped (duplicate mountpoint'
# Scope mount failures to ONLY the fixture paths: if this suite is later used
# as a host for negative tests (entries that intentionally fail), a mount failure
# on another path must not turn these checks red.
absent "fixture entry /mnt/intg did not fail to mount" 'fstab: mount .* /mnt/intg .* failed'
absent "fixture entry /mnt/a b did not fail to mount"  'fstab: mount .* /mnt/a b .* failed'
check "mountproof service started"          'started mountproof'
check "fstab mount visible from the guest /proc/mounts" 'INTEGRATION-MOUNT-VISIBLE'
absent "no mount missing from the service's point of view" 'INTEGRATION-MOUNT-MISSING'

printf '\n== cross-layer ordering checks ==\n'
# mount_fstab() is run before parse_config()/spawn in ninit's main(); if a
# refactor moves either one, the ordering in this console log is what catches it.
n_first_fstab=$(line_no 'fstab: mount tmpfs -> /mnt/intg (tmpfs)')
n_last_fstab=$(grep -n 'fstab: ' "$CONSOLE_LOG" | tail -n 1 | cut -d: -f1 || true)
n_started=$(line_no 'started mountproof')
n_console=$(line_no 'started console')
n_loop=$(line_no 'main loop ready')
if [ -n "$n_first_fstab" ] && [ -n "$n_started" ] && [ "$n_first_fstab" -lt "$n_started" ]; then
	printf '  [ OK ]   fstab mounted before the mountproof service starts\n'
else
	printf '  [FAIL] fstab mounted AFTER / WITHOUT before the service starts (line %s vs %s)\n' \
		"${n_first_fstab:-?}" "${n_started:-?}"
	fail_count=$((fail_count + 1))
fi
# Note: mount_fstab() runs BEFORE the 'ninit start' banner is printed (the
# banner is written after the log file is opened), so the ordering demanded
# here is fstab < first service < main loop — not fstab after the banner.
if [ -n "$n_last_fstab" ] && [ -n "$n_console" ] && [ "$n_last_fstab" -lt "$n_console" ]; then
	printf '  [ OK ]   ALL fstab lines finish before the first service (console) starts\n'
else
	printf '  [FAIL] fstab lines remain after the first service starts (line %s vs %s)\n' \
		"${n_last_fstab:-?}" "${n_console:-?}"
	fail_count=$((fail_count + 1))
fi
if [ -n "$n_last_fstab" ] && [ -n "$n_loop" ] && [ "$n_last_fstab" -lt "$n_loop" ]; then
	printf '  [ OK ]   fstab finishes before the event loop starts (no mount inside the loop)\n'
else
	printf '  [FAIL] last fstab line (line %s) does not precede main loop ready (line %s)\n' \
		"${n_last_fstab:-?}" "${n_loop:-?}"
	fail_count=$((fail_count + 1))
fi

printf '\n== standard harness checks over the integration log ==\n'
if [ "$harness_rc" = 0 ]; then
	printf '  [ OK ]   run-qemu.sh report() PASSES on the test-fstab boot\n'
else
	printf '  [FAIL] run-qemu.sh report() FAILS (exit %s) — see the output above\n' "$harness_rc"
	fail_count=$((fail_count + 1))
fi

if [ "$fail_count" = 0 ]; then
	printf '\nRESULT: PASS (all integration checks)\n'
else
	printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
	printf '\n-- guest console tail --\n'
	tail -n 20 "$CONSOLE_LOG" | sed 's/^/  | /'
	exit 1
fi
