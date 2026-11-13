#!/bin/sh
# Smoke test for ninit: run it as PID 1 inside a new PID + mount namespace
# with a temporary chroot rootfs, wait for "main loop ready", send SIGTERM,
# then check that shutdown is clean (no respawn after shutdown).
#
# Pemakaian:
#   sudo sh ./scripts/smoke-test.sh      # or: make test
#
# Variabel lingkungan:
#   BIN=./ninit              binary under test
#   BUSYBOX=/bin/busybox     static busybox (apt-get install busybox-static)
#   READY_TIMEOUT=10         max seconds to wait for ninit to be ready
#   LATENCY_LIMIT_MS=5000    max SIGTERM -> exit latency threshold (ms)
#
# Shutdown latency is measured via sync(), which is very volatile on
# VPS/CI (depending on the backend disk load), so the threshold is kept
# loose and can be overridden via the environment.
#
# Note: this script deliberately does NOT use `unshare --mount-proc=<dir>`.
# On some kernels (including certain CI sandboxes) changing mount
# propagation is rejected with EINVAL; the --mount --propagation private +
# manual `mount -t proc` variant has the same effect and is more portable.

set -eu

BIN=${BIN:-}
if [ -z "$BIN" ]; then
	if [ -x "./ninit-test" ]; then
		BIN="./ninit-test"
	else
		BIN="./ninit"
	fi
fi
BUSYBOX=${BUSYBOX:-/bin/busybox}
READY_TIMEOUT=${READY_TIMEOUT:-10}
LATENCY_LIMIT_MS=${LATENCY_LIMIT_MS:-5000}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable (run: make)"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout ps mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required (unshare + chroot)"

ROOT=$(mktemp -d /tmp/ninit-smoke.XXXXXX)
LOG=$(mktemp /tmp/ninit-smoke-log.XXXXXX)
RUN_ID="ninit-smoke-$$-$(date +%s%N 2>/dev/null || date +%s)"
SUITE_CG="/sys/fs/cgroup/$RUN_ID"
if [ -e "$SUITE_CG" ]; then
	fail "cgroup collision: path '$SUITE_CG' already exists before test starts"
fi
$SUDO mkdir "$SUITE_CG" || fail "failed to create isolation root '$SUITE_CG'"
SUITE_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$SUITE_CG" 2>/dev/null || true)
[ -n "$SUITE_CG_DEV_INO" ] || fail "failed to read dev:ino for '$SUITE_CG'"
SUITE_CG_BASE="$SUITE_CG/ninit"

is_test_process() {
	p=$1
	[ -n "$p" ] && [ -d "/proc/$p" ] || return 1
	if [ -n "${SUITE_CG:-}" ] && [ -d "$SUITE_CG" ]; then
		p_cg_path=""
		if [ -r "/proc/$p/cgroup" ]; then
			p_cg_path=$(sed -n 's/^0::\([^[:space:]]*\).*$/\1/p' "/proc/$p/cgroup" 2>/dev/null | head -n 1)
		fi
		[ -n "$p_cg_path" ] || return 1
		case "/sys/fs/cgroup$p_cg_path" in
			"$SUITE_CG"|"$SUITE_CG"/*) ;;
			*) return 1 ;;
		esac
		[ -d "/sys/fs/cgroup$p_cg_path" ] || return 1
	else
		return 1
	fi
	p_root=$($SUDO readlink /proc/"$p"/root 2>/dev/null || true)
	[ -n "$p_root" ] || return 1
	case "$p_root" in
		"$ROOT"|"$ROOT"/*|"$ROOT (deleted)"|"$ROOT/"*) return 0 ;;
	esac
	return 1
}

clean_suite_cgroup() {
	cg_target="${1:-}"
	expected_dev_ino="${2:-}"
	[ -n "$cg_target" ] || return 0
	[ -d "$cg_target" ] || return 0
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

	kill_ok=0
	if [ -f "$cg_target/cgroup.kill" ]; then
		echo 1 | $SUDO tee "$cg_target/cgroup.kill" >/dev/null 2>&1 || true
		waited=0
		while [ "$waited" -lt 20 ]; do
			has_proc=0
			set -f
			for pf in $(find "$cg_target" -type f -name "cgroup.procs" 2>/dev/null); do
				procs=$($SUDO cat "$pf" 2>/dev/null || true)
				for p in $procs; do
					[ -n "$p" ] && { has_proc=1; break; }
				done
				[ "$has_proc" -eq 1 ] && break
			done
			set +f
			[ "$has_proc" -eq 0 ] && { kill_ok=1; break; }
			sleep 0.05
			waited=$((waited + 1))
		done
	fi

	if [ "$kill_ok" -ne 1 ]; then
		set -f
		for pf in $(find "$cg_target" -type f -name "cgroup.procs" 2>/dev/null); do
			procs=$($SUDO cat "$pf" 2>/dev/null || true)
			for p in $procs; do
				if is_test_process "$p"; then
					$SUDO kill -9 "$p" 2>/dev/null || true
				fi
			done
		done
		set +f
	fi

	find "$cg_target" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || {
		sleep 0.1
		find "$cg_target" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
	}

	$SUDO rmdir "$cg_target" 2>/dev/null || {
		sleep 0.1
		$SUDO rmdir "$cg_target" 2>/dev/null || true
	}
}

cleanup() {
	clean_suite_cgroup "${SUITE_CG:-}" "${SUITE_CG_DEV_INO:-}" || printf 'WARN: clean_suite_cgroup failed (status %d), continuing...\n' $? >&2
	# proc lives inside the mount namespace, but clean it up if anything leaks
	$SUDO umount "$ROOT/proc" 2>/dev/null || true
	rm -rf "$ROOT" "$LOG"
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
cp "$BIN" "$ROOT/ninit"
cp "$BUSYBOX" "$ROOT/bin/sh"
printf 'shell:respawn:/bin/sh\n' > "$ROOT/etc/init.conf"

printf '== test rootfs : %s\n' "$ROOT"
printf '== test binary : %s\n' "$BIN"

find_init_pid() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x ninit 2>/dev/null | head -n 1
	else
		ps -eo pid,args 2>/dev/null | awk '$2 == "/ninit" { print $1; exit }'
	fi
}

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT' /ninit" \
		>"$LOG" 2>&1
) &
job=$!

i=0
pid=""
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	pid=$(find_init_pid || true)
	if [ -n "${pid:-}" ] && grep -q 'main loop ready' "$LOG" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done
if [ -z "${pid:-}" ]; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not run within ${READY_TIMEOUT}s"
fi

t0=$(date +%s%N)
$SUDO kill -TERM "$pid" || true
wait "$job" || true
t1=$(date +%s%N)
latency_ms=$(( (t1 - t0) / 1000000 ))

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
check() { if grep -q "$2" "$LOG"; then ok "$1"; else bad "$1"; fi; }

printf '\n== checks ==\n'
check "banner 'ninit start (PID 1)'"          'ninit start (PID 1)'
check "cgroup base path overridden ($SUITE_CG_BASE)" "cgroup: base path overridden: $SUITE_CG_BASE"
check "event loop entered ('main loop ready')"   'main loop ready'
check "service started ('started shell')"  'started shell'
check "SIGTERM handled ('graceful shutdown')" 'graceful shutdown'

after=$(awk '/graceful shutdown/ { f = 1 } f && /started shell/ { c++ } END { print c + 0 }' "$LOG")
if [ "$after" -eq 0 ]; then
	ok "no respawn after shutdown"
else
	bad "$after respawns after shutdown"
fi

if [ "$latency_ms" -lt "$LATENCY_LIMIT_MS" ]; then
	ok "SIGTERM -> exit latency: ${latency_ms}ms"
else
	bad "SIGTERM -> exit latency: ${latency_ms}ms (fast-respawn service must be < ${LATENCY_LIMIT_MS}ms)"
fi

printf '\n== ninit log ==\n'
sed 's/^/  | /' "$LOG"

if [ "$fail_count" -eq 0 ]; then
	printf '\nRESULT: PASS (all checks)\n'
else
	printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
	exit 1
fi
