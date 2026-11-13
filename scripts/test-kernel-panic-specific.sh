#!/bin/sh
# test-kernel-panic-specific.sh -- Dedicated validation suite for Kernel Panic scenarios
# Tests:
# 1. Deliberate Kernel Panic Induction 1 (PID 1 premature exit via rdinit=/bin/false):
#    Proves that Linux kernel panics with "Attempted to kill init!" and terminates QEMU via panic=-1.
# 2. Deliberate Kernel Panic Induction 2 (No working init found via rdinit=/missing):
#    Proves that Linux kernel panics when rootfs/initramfs init is missing and halts via panic=-1.
# 3. Rescue Mode Defense against Kernel Panic in ninit:
#    Proves that ninit catches fatal dependency cycles / syntax errors without exiting,
#    entering rescue mode (/bin/sh) to prevent kernel panic.
# 4. Production QEMU Boot Verification:
#    Boots the production sane-linux image in QEMU, asserts clean arrival at "main loop ready",
#    and verifies complete absence of "Kernel panic".

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DISTRO_DIR="$REPO_ROOT/distro"
INITRAMFS="$DISTRO_DIR/initramfs.cpio.gz"
PANIC_LOG1="/tmp/qemu-panic-exit.log"
PANIC_LOG2="/tmp/qemu-panic-missing.log"
PROD_LOG="/tmp/qemu-prod-panic-check.log"
PASS=0; FAIL=0

pass() { printf '  [ OK ]   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

KERNEL=${KERNEL:-}
KERNEL_MODE=${KERNEL_MODE:-auto}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.20}
ALPINE_FLAVOR=${ALPINE_FLAVOR:-virt}
CACHE_DIR="$DISTRO_DIR/cache"

host_kernel() {
	hk=/boot/vmlinuz-$(uname -r)
	[ -r "$hk" ] && { printf '%s' "$hk"; return 0; }
	return 1
}

# Resolve a bootable kernel: explicit $KERNEL, then the host kernel, then an
# Alpine vmlinuz-virt download (same strategy as scripts/run-qemu.sh) so the
# suite also runs on CI runners where /boot is empty.
if [ -n "$KERNEL" ]; then
	[ -r "$KERNEL" ] || { echo "FAIL: kernel '$KERNEL' is not readable"; exit 1; }
elif [ "$KERNEL_MODE" = "host" ]; then
	KERNEL=$(host_kernel) || { echo "FAIL: /boot/vmlinuz-$(uname -r) not found (use KERNEL_MODE=alpine)"; exit 1; }
else
	if ! KERNEL=$(host_kernel); then
		KERNEL="$CACHE_DIR/vmlinuz-$ALPINE_FLAVOR-$ALPINE_BRANCH"
		if [ ! -s "$KERNEL" ]; then
			echo "== downloading Alpine kernel ($ALPINE_BRANCH, $ALPINE_FLAVOR)"
			mkdir -p "$CACHE_DIR"
			curl -fL --retry 3 --connect-timeout 15 -o "$KERNEL.part" \
				"https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/x86_64/netboot/vmlinuz-$ALPINE_FLAVOR" \
				|| { echo "SKIP: kernel download failed (no network?)"; exit 77; }
			mv "$KERNEL.part" "$KERNEL"
		fi
		[ "$(wc -c < "$KERNEL")" -gt 500000 ] || { echo "FAIL: downloaded kernel is too small"; exit 1; }
	fi
fi
[ -f "$KERNEL" ] || { echo "SKIP: no guest kernel found"; exit 77; }
[ -f "$INITRAMFS" ] || { echo "SKIP: no initramfs at $INITRAMFS (run: make rootfs)"; exit 77; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "SKIP: qemu-system-x86_64 not found"; exit 77; }

printf '=== SPECIFIC KERNEL PANIC TEST SUITE ===\n'
printf 'Kernel   : %s\n' "$KERNEL"
printf 'Initramfs: %s\n\n' "$INITRAMFS"

# --------------------------------------------------------------------------
# Test 1: Real Kernel Panic Induction - PID 1 exits (rdinit=/bin/false)
# --------------------------------------------------------------------------
printf '== Test 1: Deliberate Panic Induction: PID 1 Exits (rdinit=/bin/false) ==\n'
rm -f "$PANIC_LOG1"
timeout --kill-after=5 15 qemu-system-x86_64 \
	-nodefaults -display none \
	-serial file:"$PANIC_LOG1" \
	-m 256 -no-reboot -cpu max \
	-kernel "$KERNEL" \
	-initrd "$INITRAMFS" \
	-append "console=ttyS0 rdinit=/bin/false init=/bin/false panic=-1 loglevel=7" \
	>/dev/null 2>&1 || true

if [ -f "$PANIC_LOG1" ]; then
	if grep -q "Kernel panic" "$PANIC_LOG1"; then
		pass "real kernel panic emitted on PID 1 exit"
	else
		fail "panic1-presence" "no 'Kernel panic' found in $PANIC_LOG1"
	fi

	if grep -q "Attempted to kill init! exitcode=" "$PANIC_LOG1"; then
		pass "panic reason correctly identified: 'Attempted to kill init!'"
	else
		fail "panic1-reason" "missing 'Attempted to kill init' signature"
	fi

	PANIC_LINE=$(grep "Kernel panic" "$PANIC_LOG1" | head -n 1)
	printf '     Captured Trace: %s\n' "$PANIC_LINE"
else
	fail "panic1-exec" "log file $PANIC_LOG1 not created"
fi

# --------------------------------------------------------------------------
# Test 2: Real Kernel Panic Induction - Missing Init Binary
# --------------------------------------------------------------------------
printf '\n== Test 2: Deliberate Panic Induction: Missing Init Binary ==\n'
rm -f "$PANIC_LOG2"
timeout --kill-after=5 15 qemu-system-x86_64 \
	-nodefaults -display none \
	-serial file:"$PANIC_LOG2" \
	-m 256 -no-reboot -cpu max \
	-kernel "$KERNEL" \
	-initrd "$INITRAMFS" \
	-append "console=ttyS0 rdinit=/nonexistent_init init=/nonexistent_init panic=-1 loglevel=7" \
	>/dev/null 2>&1 || true

if [ -f "$PANIC_LOG2" ]; then
	if grep -q "Kernel panic" "$PANIC_LOG2"; then
		pass "real kernel panic emitted on missing init binary"
	else
		fail "panic2-presence" "no 'Kernel panic' found in $PANIC_LOG2"
	fi

	PANIC_LINE2=$(grep "Kernel panic" "$PANIC_LOG2" | head -n 1)
	printf '     Captured Trace: %s\n' "$PANIC_LINE2"
else
	fail "panic2-exec" "log file $PANIC_LOG2 not created"
fi

# --------------------------------------------------------------------------
# Test 3: Anti-Panic Rescue Mode Defense in ninit
# --------------------------------------------------------------------------
printf '\n== Test 3: Rescue Mode Defense (Fatal Dependency Cycle -> Shell, No Panic) ==\n'
ROOT=$(mktemp -d /tmp/ninit-panic-test.XXXXXX)
LOG="/tmp/ninit-panic-test.log"
trap 'rm -rf "$ROOT" "$LOG" "$PANIC_LOG1" "$PANIC_LOG2" "$PROD_LOG"' EXIT INT TERM

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
cp "$REPO_ROOT/ninit" "$ROOT/ninit"
cp /bin/busybox "$ROOT/bin/sh"
# Malformed cyclic dependency
printf 'svc_alpha:once:echo a:requires=svc_beta\nsvc_beta:once:echo b:requires=svc_alpha\n' > "$ROOT/etc/init.conf"

(
	sudo timeout -k 2 5 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT/proc' && exec chroot '$ROOT' /ninit" \
		>"$LOG" 2>&1
) || true

if grep -q "Entering rescue mode (shell)" "$LOG"; then
	pass "fatal dependency cycle caught and redirected to rescue shell"
else
	fail "rescue-mode-trigger" "ninit did not enter rescue mode"
fi

if grep -q "FATAL: CYCLE DETECTED" "$LOG"; then
	pass "cycle reported unambiguously as FATAL"
else
	fail "cycle-fatal-log" "missing FATAL: CYCLE DETECTED in log"
fi

if ! grep -q "Kernel panic" "$LOG"; then
	pass "zero kernel panic during fatal config handling"
else
	fail "unwanted-panic" "kernel panic appeared in user-space log"
fi

# --------------------------------------------------------------------------
# Test 4: Live Production Boot in QEMU (Zero Panic Assertion)
# --------------------------------------------------------------------------
printf '\n== Test 4: Live Production Sane-Linux QEMU Boot (Absence of Panic) ==\n'
rm -f "$PROD_LOG"
: > "$PROD_LOG"
timeout -k 2 10 qemu-system-x86_64 \
	-nodefaults -display none \
	-serial file:"$PROD_LOG" \
	-m 256 -no-reboot -cpu max \
	-kernel "$KERNEL" \
	-initrd "$INITRAMFS" \
	-append "console=ttyS0 rdinit=/sbin/init init=/sbin/init panic=-1 loglevel=7" \
	>/dev/null 2>&1 &
QEMU_PID=$!

for i in $(seq 1 120); do
	if grep -q "main loop ready" "$PROD_LOG" 2>/dev/null; then
		break
	fi
	if ! kill -0 "$QEMU_PID" 2>/dev/null; then
		break
	fi
	sleep 0.05
done
kill -TERM "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

if [ -f "$PROD_LOG" ]; then
	if grep -q "ninit start (PID 1)" "$PROD_LOG"; then
		pass "production ninit started successfully as PID 1"
	else
		fail "prod-boot-start" "ninit banner not found in $PROD_LOG"
	fi

	if grep -q "main loop ready" "$PROD_LOG"; then
		pass "main loop reached successfully"
	else
		fail "prod-boot-ready" "main loop ready not found in $PROD_LOG"
	fi

	if ! grep -q "Kernel panic" "$PROD_LOG"; then
		pass "zero kernel panic in production boot log"
	else
		fail "prod-kernel-panic" "unexpected kernel panic in production boot log"
	fi
else
	fail "prod-log-presence" "production console log $PROD_LOG missing"
fi

printf '\n=== FINAL RESULT: %d PASS, %d FAIL ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
