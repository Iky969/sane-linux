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
BIN=${BIN:-$REPO_ROOT/ninit-test}
BUSYBOX=${BUSYBOX:-/bin/busybox}
PASS=0; FAIL=0

pass() { printf '  [ OK ]   %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

KERNEL=${KERNEL:-}
KERNEL_MODE=${KERNEL_MODE:-auto}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.20}
ALPINE_FLAVOR=${ALPINE_FLAVOR:-virt}
ALPINE_RELEASE=${ALPINE_RELEASE:-3.20.10}
KERNEL_PINNED_SHA256="be523954ad673a78c9cdfd3d473a8d39609f5901adfcc68402c67dc037a64c7e"
if [ "${KERNEL_SHA256+set}" != "set" ]; then
	if [ "$ALPINE_BRANCH" = "v3.20" ] && [ "$ALPINE_FLAVOR" = "virt" ] && [ "$ALPINE_RELEASE" = "3.20.10" ]; then
		KERNEL_SHA256="$KERNEL_PINNED_SHA256"
	else
		KERNEL_SHA256=""
	fi
fi
CACHE_DIR="$DISTRO_DIR/cache"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

WORKDIR=$(mktemp -d /tmp/ninit-panic-suite.XXXXXX)
PANIC_LOG1="$WORKDIR/qemu-panic-exit.log"
PANIC_LOG2="$WORKDIR/qemu-panic-missing.log"
PROD_LOG="$WORKDIR/qemu-prod-panic-check.log"
LOG="$WORKDIR/ninit-panic-test.log"
ROOT="$WORKDIR/rootfs"
SUITE_CG=""
SUITE_CG_DEV_INO=""
SUITE_CG_BASE=""

clean_suite_cgroup() {
	cg_target="${1:-}"
	expected_dev_ino="${2:-}"
	[ -n "$cg_target" ] && [ -d "$cg_target" ] || return 0
	if [ -L "$cg_target" ]; then
		printf 'SECURITY: %s is a symlink, cleanup aborted!\n' "$cg_target" >&2
		return 1
	fi
	if [ -n "$expected_dev_ino" ]; then
		cur_ino=$($SUDO stat -c '%d:%i' "$cg_target" 2>/dev/null || true)
		if [ "$cur_ino" != "$expected_dev_ino" ]; then
			printf 'SECURITY: %s dev:ino changed (expected %s, got %s)!\n' "$cg_target" "$expected_dev_ino" "$cur_ino" >&2
			return 1
		fi
	fi
	if [ -f "$cg_target/cgroup.kill" ]; then
		echo 1 | $SUDO tee "$cg_target/cgroup.kill" >/dev/null 2>&1 || true
		waited=0
		while [ "$waited" -lt 20 ]; do
			has_proc=0
			set -f
			for pf in $(find "$cg_target" -type f -name "cgroup.procs" 2>/dev/null); do
				[ -n "$($SUDO cat "$pf" 2>/dev/null || true)" ] && { has_proc=1; break; }
			done
			set +f
			[ "$has_proc" -eq 0 ] && break
			sleep 0.05
			waited=$((waited + 1))
		done
	fi
	find "$cg_target" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
	$SUDO rmdir "$cg_target" 2>/dev/null || true
}

cleanup() {
	clean_suite_cgroup "${SUITE_CG:-}" "${SUITE_CG_DEV_INO:-}" || true
	$SUDO umount "$ROOT/proc" 2>/dev/null || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

host_kernel() {
	hk=/boot/vmlinuz-$(uname -r)
	[ -r "$hk" ] && { printf '%s' "$hk"; return 0; }
	return 1
}

# Resolve a bootable kernel: explicit $KERNEL, then the host kernel, then an
# Alpine vmlinuz-virt download (pinned SHA-256, same strategy as scripts/run-qemu.sh)
# so the suite also runs on CI runners where /boot is empty.
if [ -n "$KERNEL" ]; then
	[ -r "$KERNEL" ] || { echo "FAIL: kernel '$KERNEL' is not readable"; exit 1; }
elif [ "$KERNEL_MODE" = "host" ]; then
	KERNEL=$(host_kernel) || { echo "FAIL: /boot/vmlinuz-$(uname -r) not found (use KERNEL_MODE=alpine)"; exit 1; }
else
	if ! KERNEL=$(host_kernel); then
		if ! printf '%s' "$KERNEL_SHA256" | grep -qE '^[0-9a-fA-F]{64}$'; then
			echo "FAIL: KERNEL_SHA256 must be a 64-digit hex checksum for Alpine download" >&2
			exit 1
		fi
		[ -n "$ALPINE_RELEASE" ] || { echo "FAIL: ALPINE_RELEASE must not be empty" >&2; exit 1; }
		expected_sha=$(printf '%s' "$KERNEL_SHA256" | tr 'A-F' 'a-f')
		KERNEL="$CACHE_DIR/vmlinuz-$ALPINE_FLAVOR-$ALPINE_BRANCH"
		if [ ! -s "$KERNEL" ]; then
			echo "== downloading Alpine kernel ($ALPINE_BRANCH/$ALPINE_RELEASE, $ALPINE_FLAVOR)"
			mkdir -p "$CACHE_DIR"
			curl -fL --retry 3 --connect-timeout 15 -o "$KERNEL.part" \
				"https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/x86_64/netboot-$ALPINE_RELEASE/vmlinuz-$ALPINE_FLAVOR" \
				|| { rm -f "$KERNEL.part"; echo "SKIP: kernel download failed (no network?)"; exit 77; }
			actual_sha=$(sha256sum "$KERNEL.part" | cut -d' ' -f1 | tr 'A-F' 'a-f')
			if [ "$actual_sha" != "$expected_sha" ]; then
				rm -f "$KERNEL.part"
				echo "FAIL: downloaded kernel SHA-256 mismatch (expected $expected_sha, got $actual_sha)" >&2
				exit 1
			fi
			mv "$KERNEL.part" "$KERNEL"
		fi
		[ "$(wc -c < "$KERNEL")" -gt 500000 ] || { echo "FAIL: downloaded kernel is too small"; exit 1; }
		cached_sha=$(sha256sum "$KERNEL" | cut -d' ' -f1 | tr 'A-F' 'a-f')
		if [ "$cached_sha" != "$expected_sha" ]; then
			echo "FAIL: cached kernel '$KERNEL' SHA-256 mismatch (expected $expected_sha, got $cached_sha)" >&2
			exit 1
		fi
	fi
fi
[ -f "$KERNEL" ] || { echo "SKIP: no guest kernel found"; exit 77; }
[ -f "$INITRAMFS" ] || { echo "SKIP: no initramfs at $INITRAMFS (run: make rootfs)"; exit 77; }
[ -x "$BIN" ] || { echo "FAIL: test binary '$BIN' missing/not executable (run: make ninit-test)"; exit 1; }
[ -f "$BUSYBOX" ] || { echo "FAIL: static busybox missing at '$BUSYBOX'"; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "SKIP: qemu-system-x86_64 not found"; exit 77; }
$SUDO true 2>/dev/null || { echo "SKIP: root or passwordless sudo required for unshare/chroot"; exit 77; }

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
HOST_NINIT_PREEXISTED=0
[ -d /sys/fs/cgroup/ninit ] && HOST_NINIT_PREEXISTED=1
RUN_ID="ninit-panic-$$-$(date +%s%N 2>/dev/null || date +%s)"
SUITE_CG="/sys/fs/cgroup/$RUN_ID"
[ -e "$SUITE_CG" ] && { echo "FAIL: cgroup collision '$SUITE_CG'" >&2; exit 1; }
$SUDO mkdir "$SUITE_CG" || { echo "FAIL: failed to create isolation root '$SUITE_CG'" >&2; exit 1; }
SUITE_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$SUITE_CG" 2>/dev/null || true)
[ -n "$SUITE_CG_DEV_INO" ] || { echo "FAIL: failed to read dev:ino for '$SUITE_CG'" >&2; exit 1; }
SUITE_CG_BASE="$SUITE_CG/ninit"
$SUDO mkdir -p "$SUITE_CG/init"

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
cp "$BIN" "$ROOT/ninit"
cp "$BUSYBOX" "$ROOT/bin/sh"
# Malformed cyclic dependency
printf 'svc_alpha:once:echo a:requires=svc_beta\nsvc_beta:once:echo b:requires=svc_alpha\n' > "$ROOT/etc/init.conf"

rc=0
$SUDO timeout -k 2 5 unshare --pid --fork --kill-child=SIGKILL \
	--mount --propagation private \
	sh -c "echo \$\$ > '$SUITE_CG/init/cgroup.procs' 2>/dev/null || true; mount -t proc proc '$ROOT/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT' /ninit" \
	>"$LOG" 2>&1 || rc=$?

if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
	pass "isolated rescue execution exited cleanly under timeout/shutdown (rc=$rc)"
else
	fail "rescue-exec" "unshare/ninit exited with unexpected code rc=$rc"
fi

if grep -q "cgroup: base path overridden: $SUITE_CG_BASE" "$LOG"; then
	pass "cgroup base path overridden ($SUITE_CG_BASE)"
else
	fail "cgroup-isolation" "missing cgroup base path override in log (is BIN=./ninit-test?)"
fi

if [ "$HOST_NINIT_PREEXISTED" -eq 0 ]; then
	if [ -d /sys/fs/cgroup/ninit ]; then
		fail "host-cgroup-leak" "/sys/fs/cgroup/ninit appeared on the host"
	else
		pass "host /sys/fs/cgroup/ninit untouched (isolated in $SUITE_CG)"
	fi
fi

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
