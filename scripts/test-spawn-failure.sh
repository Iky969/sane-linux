#!/bin/sh
# test-spawn-failure.sh -- spawn() failure paths: fork() fails, a dependency
# fails, and an unmet dependency via the respawn path.
#
# Why this suite exists: an external audit of main (af3388f) claimed that a
# fork() failure locks PID 1 in a do-while without ever returning to
# ppoll(). That claim did not hold when tested: spawn_service() already
# sets last_start BEFORE fork(), so the RESPAWN_DELAY window lets the
# loop exit and the event loop keeps running. Re-testing the same path
# found two other real defects:
#
#   1. respawn_services() does not read dependencies at all. A service that was
#      already "cancelled" because its once dependency failed is still revived
#      forever -- the cancellation message is just log decoration, and the
#      `requires=` ordering promise is violated through the respawn path.
#   2. A once service whose fork() fails never has a retry path
#      (respawn_services only handles svc->respawn) and never reaches a
#      terminal state: it stays in SVC_STATE_STOPPED forever while its
#      dependency waits without any message.
#
# Scenarios 1 and 2 lock in fix (1) and run in any environment like similar
# suites. Scenario 3 locks in fix (2) by forcing fork() to return EAGAIN via the
# cgroup v2 `pids` controller (root is immune to RLIMIT_NPROC, so pids.max=1
# is the only deterministic way); this scenario is skipped with a note if the pids
# controller is not delegated.
# Scenario 4 tests the crash-loop limit on a respawn service cancelling its
# (transitive) dependent services.
# Scenario 5 tests enforcement of the :timeout= limit on a once service, which
# is SIGKILLed and cancels its dependent services.
#
# Pemakaian:
#   sudo sh ./scripts/test-spawn-failure.sh      # or: make test
#
# Variabel lingkungan:
#   BIN=./ninit              binary under test
#   BUSYBOX=/bin/busybox     static busybox (apt-get install busybox-static)
#   WAIT1/WAIT2/WAIT3        observation window per scenario (seconds)
#
# Note: like smoke-test.sh, this script uses `--mount --propagation
# private` + a manual `mount -t proc` instead of `unshare --mount-proc`,
# because some kernels reject mount propagation changes with EINVAL.

set -eu

BIN=${BIN:-./ninit}
BUSYBOX=${BUSYBOX:-/bin/busybox}
WAIT1=${WAIT1:-6}
WAIT2=${WAIT2:-6}
WAIT3=${WAIT3:-10}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable (run: make)"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout grep mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required (unshare + chroot)"

RUN_ID="ninit-spawnfail-$$-$(date +%s%N 2>/dev/null || date +%s)"
SUITE_CG="/sys/fs/cgroup/$RUN_ID"
SUITE_CG_BASE="$SUITE_CG/ninit"
if [ -e "$SUITE_CG" ]; then
	fail "cgroup collision: path '$SUITE_CG' already exists before test starts"
fi
$SUDO mkdir "$SUITE_CG" || fail "failed to create isolation root '$SUITE_CG'"
SUITE_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$SUITE_CG" 2>/dev/null || true)
[ -n "$SUITE_CG_DEV_INO" ] || fail "failed to read dev:ino for '$SUITE_CG'"

SCENARIO3_CG="/sys/fs/cgroup/ninit-spawnfail-limit-$$-$(date +%s%N 2>/dev/null || date +%s)"
SCENARIO3_CG_DEV_INO=""

ROOTS=""
LOGS=""
HELPERS=""
INNER=$(mktemp /tmp/ninit-spawnfail-inner.XXXXXX)

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
			"$SUITE_CG"|"$SUITE_CG"/*|"${SCENARIO3_CG:-}"|"${SCENARIO3_CG:-}"/*) ;;
			*) return 1 ;;
		esac
		[ -d "/sys/fs/cgroup$p_cg_path" ] || return 1
	else
		return 1
	fi
	p_root=$($SUDO readlink /proc/"$p"/root 2>/dev/null || true)
	[ -n "$p_root" ] || return 1
	for r in ${ROOTS:-}; do
		case "$p_root" in
			"$r"|"$r"/*|"$r (deleted)"|"$r/"*) return 0 ;;
		esac
	done
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

clean_suite_leaves() {
	[ -n "${SUITE_CG:-}" ] && [ -d "$SUITE_CG" ] || return 0
	find "$SUITE_CG" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
}

cleanup() {
	clean_suite_cgroup "${SCENARIO3_CG:-}" "${SCENARIO3_CG_DEV_INO:-}" || printf 'WARN: clean SCENARIO3_CG failed\n' >&2
	clean_suite_cgroup "${SUITE_CG:-}" "${SUITE_CG_DEV_INO:-}" || printf 'WARN: clean_suite_cgroup failed (status %d), continuing...\n' $? >&2
	for d in ${ROOTS:-}; do
		$SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d"
	done
	for f in ${LOGS:-}; do rm -f "$f"; done
	for h in ${HELPERS:-}; do rm -f "$h"; done
	$SUDO rm -f "$INNER" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fail_count=0
ok()   { printf '  [ OK ]   %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  [SKIP]   %s\n' "$1"; }
check_in()  { if grep -q "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
absent_in() { if grep -q "$3" "$2"; then bad "$1"; else ok "$1"; fi; }

# New test rootfs; extra arguments are the busybox applets required.
# The caller MUST record the result in ROOTS: this function runs through
# command substitution (a subshell), so accumulation inside the function
# would never be visible to the cleanup trap in the parent process.
new_root() {
	d=$(mktemp -d /tmp/ninit-spawnfail.XXXXXX)
	mkdir -p "$d/proc" "$d/sys" "$d/dev" "$d/run" "$d/tmp" "$d/etc" \
	         "$d/var/log" "$d/bin"
	cp "$BIN" "$d/ninit"
	cp "$BUSYBOX" "$d/bin/sh"
	for a in "$@"; do cp "$BUSYBOX" "$d/bin/$a"; done
	# /dev/null is a plain file: ninit opens /dev/null for the child's stdin,
	# and this harness deliberately avoids mknod.
	: > "$d/dev/null"
	printf '%s\n' "$d"
}

new_log() {
	mktemp /tmp/ninit-spawnfail-log.XXXXXX
}

# Boot ninit as PID 1 inside a pid+mount namespace for ~$2 seconds.
# If $3 is a cgroup path, the process that is about to become ninit moves
# itself into that cgroup BEFORE exec -- so the pids.max slot is already
# taken when ninit tries to fork() a service child, and that fork() fails
# with EAGAIN.
boot_guest() {
	root=$1; secs=$2; cg=${3:-}
	if [ -n "$cg" ]; then
		move="echo \$\$ > $cg/cgroup.procs;"
	else
		move=""
	fi
	cat > "$INNER" <<EOI
#!/bin/sh
mount -t proc proc $root/proc
export NINIT_CGROUP_BASE="$SUITE_CG_BASE"
$move
exec chroot $root /ninit
EOI
	$SUDO chmod 755 "$INNER"
	$SUDO sh -c "timeout -s KILL $((secs + 3)) unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh $INNER" || true
	clean_suite_leaves
}

printf '== test binary : %s\n' "$BIN"

# ------------------------------------------------------------- Scenario 1
# A once dependency FAILS -> the respawn service must be cancelled and must
# never be started. Regression locked in: the old respawn path ignored
# dependencies, so "cancelled" was followed by repeated "started app".
printf '\n== Scenario 1: dependency fails, respawn service must not be respawned ==\n'
R1=$(new_root)
L1=$(new_log)
ROOTS="$ROOTS $R1"
LOGS="$LOGS $L1"
printf 'boot:once:exit 3\napp:respawn:exit 0:requires=boot\n' > "$R1/etc/init.conf"
boot_guest "$R1" "$WAIT1" "" >"$L1" 2>&1
check_in  "cgroup base path overridden ($SUITE_CG_BASE)" "$L1" \
	"cgroup: base path overridden: $SUITE_CG_BASE"
check_in  "boot ran then failed (exit status=0x300)" "$L1" \
	'boot (pid .* exit status=0x300'
check_in  "app cancelled because the dependency failed" "$L1" \
	"service 'app' cancelled: dependency 'boot' failed"
absent_in "app was NEVER started after cancellation" "$L1" 'started app'

# ------------------------------------------------------------- Scenario 2
# A once dependency is STILL RUNNING -> the respawn service must not start
# first. Ordering evidence comes from /var/order, written by the service from
# inside the guest (/var, not /tmp: ninit overwrites /tmp and /run with tmpfs
# inside the namespace, so they are not visible from the host).
#
# The `ping` service is deliberately included: without it, the old event loop
# would block in ppoll with no timeout until `slow` finishes, so the wrong
# respawn path would never be exercised and the test would be empty. The
# SIGCHLD from ping, which exits immediately, forces the loop to run again
# WHILE slow is still sleeping -- exactly when the old respawn path makes the
# wrong decision.
printf '\n== Scenario 2: dependency not finished, respawn must not go first ==\n'
R2=$(new_root sleep)
L2=$(new_log)
ROOTS="$ROOTS $R2"
LOGS="$LOGS $L2"
printf 'ping:once:echo PING-DONE >> /var/order\nslow:once:/bin/sleep 4; echo SLOW-DONE >> /var/order\napp:respawn:echo APP-START >> /var/order:requires=slow\n' \
	> "$R2/etc/init.conf"
boot_guest "$R2" "$WAIT2" "" >"$L2" 2>&1
check_in "ping started" "$L2" 'started ping'
check_in "slow started" "$L2" 'started slow'
check_in "app started"  "$L2" 'started app'
n_slow=$(grep -n -m1 'SLOW-DONE'  "$R2/var/order" 2>/dev/null | cut -d: -f1 || true)
n_app=$(grep -n -m1 'APP-START'  "$R2/var/order" 2>/dev/null | cut -d: -f1 || true)
if [ -z "${n_slow:-}" ] || [ -z "${n_app:-}" ]; then
	bad "/var/order lacks SLOW-DONE and APP-START (slow=${n_slow:-?} app=${n_app:-?})"
elif [ "$n_slow" -lt "$n_app" ]; then
	ok "app writes only AFTER the once dependency finishes (SLOW-DONE line $n_slow < APP-START line $n_app)"
else
	bad "app precedes its once dependency (SLOW-DONE line $n_slow, APP-START line $n_app)"
fi

# ------------------------------------------------------------- Scenario 3
# fork() keeps failing (EAGAIN) on a once service -> attempts are limited,
# then the state becomes terminal FAILED, then its dependency is cancelled.
# If the do-while were truly locked as the audit suspected, 'main loop ready'
# would never be printed.
printf '\n== Scenario 3: fork() failure on a once service (pids.max=1) ==\n'
pids_ok=0
if [ -r /sys/fs/cgroup/cgroup.controllers ] \
   && $SUDO grep -qw pids /sys/fs/cgroup/cgroup.controllers 2>/dev/null \
   && $SUDO mkdir "$SCENARIO3_CG" 2>/dev/null; then
	SCENARIO3_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$SCENARIO3_CG" 2>/dev/null || true)
	if [ -e "$SCENARIO3_CG/pids.max" ] && printf '1\n' | $SUDO tee "$SCENARIO3_CG/pids.max" >/dev/null; then
		pids_ok=1
	fi
fi

if [ "$pids_ok" -ne 1 ]; then
	skip "scenario 3 skipped: cgroup v2 + pids controller unavailable/undelegated"
else
	R3=$(new_root)
	L3=$(new_log)
	ROOTS="$ROOTS $R3"
	LOGS="$LOGS $L3"
	printf 'boot:once:exit 0\napp:respawn:exit 0:requires=boot\n' > "$R3/etc/init.conf"
	boot_guest "$R3" "$WAIT3" "$SCENARIO3_CG" >"$L3" 2>&1

	check_in  "event loop still entered (no busy-loop)" "$L3" 'main loop ready'
	check_in  "fork() failure logged for boot" "$L3" \
		'fork boot: Resource temporarily unavailable'
	check_in  "attempts limited then boot marked failed" "$L3" \
		'attempts, service marked failed'
	check_in  "dependent cancelled cleanly" "$L3" \
		"service 'app' cancelled: dependency 'boot' failed"
	absent_in "boot never spawned successfully" "$L3" 'started boot'
	absent_in "app not attempted before the dependency reached a terminal state" "$L3" 'fork app'
	nfork=$(grep -c 'fork boot' "$L3" 2>/dev/null || true)
	if [ "${nfork:-0}" -le 3 ]; then
		ok "boot fork() attempts limited: $nfork (max 3, no busy-loop)"
	else
		bad "boot fork() attempts unbounded: $nfork lines (suspected busy-loop)"
	fi
fi

# ------------------------------------------------------------- Scenario 4
# A respawn service that crash-loops until FAILED cancels all of its
# (transitive) dependent services (instead of hanging in STOPPED forever).
# The ninit binary is compiled with the override limits -DCRASH_LIMIT=2
# -DBACKOFF_MAX=1 so the crash-loop is detected quickly (<3 seconds) without
# waiting for the 60s interval.
printf '\n== Scenario 4: respawn service crash-loop cancels dependent services ==\n'
BIN_FAST=$(mktemp /tmp/ninit-fast-bin.XXXXXX)
HELPERS="$HELPERS $BIN_FAST"
# -DNINIT_TESTING is mandatory: this binary is booted with NINIT_CGROUP_BASE, and
# without the define the guest would fall back to the host's /sys/fs/cgroup/ninit
# (isolation lost + host hierarchy polluted).
gcc -static -O2 -Wall -DCRASH_LIMIT=2 -DBACKOFF_MAX=1 -DNINIT_TESTING ./ninit.c -o "$BIN_FAST"

R4=$(new_root sleep)
L4=$(new_log)
ROOTS="$ROOTS $R4"
LOGS="$LOGS $L4"

# Replace the guest ninit binary with the fast-crash one
cp "$BIN_FAST" "$R4/ninit"

cat > "$R4/etc/init.conf" << 'EOF'
slow:once:/bin/sleep 2
crasher:respawn:exit 1
dep:once:echo DEP_STARTED > /var/dep.txt:requires=crasher,slow
stopper:once:/bin/sh -c "/bin/sleep 4 && echo poweroff > /run/initctl"
EOF

boot_guest "$R4" 6 "" >"$L4" 2>&1

check_in  "crasher detected crash-loop and marked failed" "$L4" \
	'crasher: crash-loop detected'
check_in  "dependent cancelled because the respawn dependency failed" "$L4" \
	"service 'dep' cancelled: dependency 'crasher' failed"
absent_in "dependent never ran" "$L4" 'started dep'

# ------------------------------------------------------------- Scenario 5
# A once service with a :timeout=2 limit that sleeps past the time limit is
# SIGKILLed and all of its dependents are cancelled transitively.
printf '\n== Scenario 5: once service with :timeout=2 killed & dependents cancelled ==\n'
R5=$(new_root sleep)
L5=$(new_log)
ROOTS="$ROOTS $R5"
LOGS="$LOGS $L5"

cat > "$R5/etc/init.conf" << 'EOF'
hanger:once:/bin/sleep 20:timeout=2
dep:once:echo DEP_STARTED > /var/dep.txt:requires=hanger
stopper:once:/bin/sh -c "/bin/sleep 4 && echo poweroff > /run/initctl"
EOF

boot_guest "$R5" 6 "" >"$L5" 2>&1

check_in  "hanger killed because of the 2-second timeout limit" "$L5" \
	'hanger: once service exceeded 2 seconds timeout, marked failed'
check_in  "hanger forcibly killed by a signal (exit status=0x9)" "$L5" \
	'hanger (pid .* exit status=0x9'
check_in  "dependent cancelled when the once service timed out" "$L5" \
	"service 'dep' cancelled: dependency 'hanger' failed"
absent_in "hanger did not finish successfully" "$L5" 'hanger (pid .* exit status=0x0'
absent_in "dependent never ran" "$L5" 'started dep'

if [ "$fail_count" -eq 0 ]; then
	printf '\nRESULT: PASS (all checks)\n'
else
	printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
	for l in ${LOGS:-}; do
		printf '\n-- tail of log %s --\n' "$l"
		tail -n 15 "$l" | sed 's/^/  | /'
	done
	exit 1
fi
