#!/bin/sh
# test-respawn-cleanup.sh -- T12 (respawn generation counter reset + grandchild
# flush/containment) and T14 (leaf cgroup cleanup hygiene).
#
# Why this suite exists:
#   T12 requires that stopping or disabling a respawning service resets its
#   generation counters (crash_count / respawn_delay) AND that every process
#   still attached to the service cgroup is flushed BEFORE the respawn timer
#   triggers the next generation. Orphaned grandchildren must stay contained
#   inside the ninit cgroup hierarchy and be swept clean.
#   T14 requires the leaf cgroup directory to be deterministically removed
#   after a service stops (rmdir after cgroup.kill, no EBUSY).
#
# The suite is deterministic: no fixed long sleeps. Every wait is a bounded
# poll loop with a counter; the only fractional sleeps are 0.05s ticks inside
# those loops (same convention as scripts/test-cgroup-limits.sh).
#
# Usage:
#   sudo sh ./scripts/test-respawn-cleanup.sh      # or: make test
#
# Environment variables:
#   BIN=./ninit              binary under test
#   BUSYBOX=/bin/busybox     static busybox (apt-get install busybox-static)
#   WAITA / WAITB           observation window per scenario (seconds)
#
# Note: this suite uses unshare with `--mount --propagation private` and a
# manual `mount -t proc` (not `--mount-proc`), consistent with the repo
# convention to avoid EINVAL rejections on certain kernels.

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
WAITA=${WAITA:-10}
WAITB=${WAITB:-8}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable (run: make)"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout grep mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required (unshare + chroot)"

# Safety guard: this suite writes cgroup.kill and rmdir under /sys/fs/cgroup.
# If the host's PID 1 is ninit, this suite would kill the host's init
# (kernel panic). Abort before touching any host cgroup.
pid1_comm=$(cat /proc/1/comm 2>/dev/null || true)
if [ "$pid1_comm" = "ninit" ]; then
	fail "the host's PID 1 is 'ninit' -- this suite is forbidden on a live host (host isolation guard)"
fi

CG_CONTROLLERS="/sys/fs/cgroup/cgroup.controllers"
has_cg2=0
if [ -r "$CG_CONTROLLERS" ]; then has_cg2=1; fi

ROOTS=""
LOGS=""
CG_DYNAMIC=""

# Snapshot the existence of /sys/fs/cgroup/ninit on the host before testing starts
HOST_NINIT_PREEXISTED=0
[ -d /sys/fs/cgroup/ninit ] && HOST_NINIT_PREEXISTED=1

RUN_ID="ninit-respawn-$$-$(date +%s%N 2>/dev/null || date +%s)"
RUN_CG="/sys/fs/cgroup/$RUN_ID"
RUN_CG_BASE="$RUN_CG/ninit"

# Strict mkdir without -p, abort on collision
if [ -e "$RUN_CG" ]; then
	fail "cgroup collision: path '$RUN_CG' already exists before the test starts (abort)"
fi
$SUDO mkdir "$RUN_CG" || fail "failed to create the cgroup isolation root '$RUN_CG'"
RUN_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$RUN_CG" 2>/dev/null || true)
[ -n "$RUN_CG_DEV_INO" ] || fail "failed to read dev:ino for '$RUN_CG'"

# Delegate the controllers used by the services to the test subtree.
for c in memory pids cpu; do
	if grep -qw "$c" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		echo "+$c" | $SUDO tee "$RUN_CG/cgroup.subtree_control" >/dev/null 2>&1 || true
	fi
done
$SUDO mkdir "$RUN_CG_BASE" || fail "failed to create the base cgroup '$RUN_CG_BASE'"
for c in memory pids cpu; do
	if grep -qw "$c" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		echo "+$c" | $SUDO tee "$RUN_CG_BASE/cgroup.subtree_control" >/dev/null 2>&1 || true
	fi
done

INNER=$(mktemp /tmp/ninit-respawn-inner.XXXXXX)

# Depth-first cleanup of the isolation subtree, strictly inside $RUN_CG.
clean_run_cgroup() {
	[ -n "${RUN_CG:-}" ] || return 0
	[ -n "${RUN_CG_DEV_INO:-}" ] || return 0
	[ -d "$RUN_CG" ] || return 0
	if [ -L "$RUN_CG" ]; then
		printf 'SECURITY: %s is a symlink! Cleanup aborted.\n' "$RUN_CG" >&2
		return 1
	fi
	cur_dev_ino=$($SUDO stat -c '%d:%i' "$RUN_CG" 2>/dev/null || true)
	if [ "$cur_dev_ino" != "$RUN_CG_DEV_INO" ]; then
		printf 'SECURITY: dev:ino %s changed (initial: %s, now: %s)! Cleanup aborted.\n' \
			"$RUN_CG" "$RUN_CG_DEV_INO" "$cur_dev_ino" >&2
		return 1
	fi
	if [ -f "$RUN_CG/cgroup.kill" ]; then
		echo 1 | $SUDO tee "$RUN_CG/cgroup.kill" >/dev/null 2>&1 || true
		waited=0
		while [ "$waited" -lt 50 ]; do
			remaining=0
			for pfile in $(find "$RUN_CG" -type f -name cgroup.procs 2>/dev/null); do
				procs=$($SUDO cat "$pfile" 2>/dev/null || true)
				for p in $procs; do
					[ -n "$p" ] && remaining=$((remaining + 1))
				done
			done
			[ "$remaining" -eq 0 ] && break
			sleep 0.05
			waited=$((waited + 1))
		done
	fi
	find "$RUN_CG" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
	$SUDO rmdir "$RUN_CG" 2>/dev/null || true
}

cleanup() {
	clean_run_cgroup || printf 'WARN: clean_run_cgroup failed, continuing with the other resource cleanup...\n' >&2
	for d in ${ROOTS:-}; do
		$SUDO umount -R "$d" 2>/dev/null || $SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d" 2>/dev/null || true
	done
	for f in ${LOGS:-}; do rm -f "$f" 2>/dev/null || true; done
	$SUDO rm -f "$INNER" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fail_count=0
ok()   { printf '  [ OK ]   %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  [SKIP]   %s\n' "$1"; }
check_in()  { if grep -q "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
absent_in() { if grep -q "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi; }

new_root() {
	d=$(mktemp -d /tmp/ninit-respawntest.XXXXXX)
	mkdir -p "$d/proc" "$d/sys" "$d/dev" "$d/run" "$d/tmp" "$d/etc" \
	         "$d/var/log" "$d/bin"
	cp "$BIN" "$d/ninit"
	cp "$BUSYBOX" "$d/bin/sh"
	for a in "$@"; do cp "$BUSYBOX" "$d/bin/$a"; done
	: > "$d/dev/null"
	printf '%s\n' "$d"
}

new_log() { mktemp /tmp/ninit-respawntest-log.XXXXXX; }

boot_guest() {
	root=$1; secs=$2
	cat > "$INNER" <<EOI
#!/bin/sh
mount -t proc proc $root/proc
export NINIT_CGROUP_BASE="$RUN_CG_BASE"
exec chroot $root /ninit
EOI
	$SUDO chmod 755 "$INNER"
	$SUDO sh -c "timeout -s KILL $((secs + 4)) unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh $INNER" || true
}

printf '== test binary : %s\n' "$BIN"

# ------------------------------------------------------------- Scenario A
# T12: respawn flush before the timer + grandchild containment.
# A respawn service forks a grandchild that outlives its leader. The leader
# exits immediately; ninit must flush the cgroup before the respawn timer
# triggers generation 2. Generation 2 asserts that no grandchild survived.
printf '\n== Scenario A: respawn flush before timer + grandchild containment ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "scenario A skipped: cgroup v2 unavailable"
else
	RA=$(new_root sleep grep)
	LA=$(new_log)
	ROOTS="$ROOTS $RA"
	LOGS="$LOGS $LA"

	cat > "$RA/bin/grandparent.sh" << 'EOF'
#!/bin/sh
# Generation 1: fork a grandchild that outlives the leader, then exit at once.
# Generation 2: verify the grandchild from generation 1 was flushed before this
# generation started, then stop the system (poweroff).
if [ ! -f /var/gen1_done ]; then
    touch /var/gen1_done
    /bin/sh -c '/bin/sleep 300 & echo $! > /var/gen1_gc_pid; touch /var/gen1_gc_ready'
    i=0
    while [ ! -f /var/gen1_gc_ready ] && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    exit 0
fi
touch /var/gen2_started

# The recorded grandchild PID must be gone (cgroup.kill swept it).
lingering=0
if [ -f /var/gen1_gc_pid ] && [ -d "/proc/$(cat /var/gen1_gc_pid)" ]; then
    lingering=$((lingering + 1))
fi
# Sweep /proc as well: no process from generation 1 may remain.
for cmd in /proc/[0-9]*/cmdline; do
    [ -f "$cmd" ] || continue
    if grep -q "300" "$cmd" 2>/dev/null; then
        lingering=$((lingering + 1))
    fi
done
echo "LINGERING_GC=$lingering" > /var/respawn_cleanup_audit.txt
echo poweroff > /run/initctl
exit 0
EOF
	chmod 0755 "$RA/bin/grandparent.sh"
	printf 'respawn_svc:respawn:/bin/sh /bin/grandparent.sh\n' > "$RA/etc/init.conf"
	boot_guest "$RA" "$WAITA" >"$LA" 2>&1

	check_in  "generation 1 respawn service ran" "$LA" \
		"started respawn_svc (pid "
	check_in  "respawn was delayed by the timer before the new generation" "$LA" \
		'respawn delayed'
	check_in  "T12: cgroup flushed BEFORE the respawn timer triggered the new generation" "$LA" \
		'respawn_svc: flushing cgroup before respawn'
	if [ -f "$RA/var/gen2_started" ]; then
		ok "generation 2 respawn service started"
	else
		bad "generation 2 respawn service started"
	fi
	check_in  "T12: no orphan grandchild survived into generation 2 (LINGERING_GC=0)" \
		"$RA/var/respawn_cleanup_audit.txt" 'LINGERING_GC=0'
	check_in  "T12: generation counter reset when the service was stopped (shutdown)" "$LA" \
		'respawn_svc: respawn counters reset'
	check_in  "T14: leaf cgroup removed after the service stopped" "$LA" \
		"cgroup: cleaned up 'respawn_svc'"
	absent_in "T14: no leaf cgroup rmdir failure (EBUSY)" "$LA" \
		"Device or resource busy"
	check_in  "event loop stays stable and shutdown is clean" "$LA" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Scenario B
# T12: disabling a respawn service (dependency failure) resets its generation
# counters, so a later start never inherits a stale backoff.
printf '\n== Scenario B: disabled service resets generation counters ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "scenario B skipped: cgroup v2 unavailable"
else
	RB=$(new_root sleep grep false)
	LB=$(new_log)
	ROOTS="$ROOTS $RB"
	LOGS="$LOGS $LB"

	cat > "$RB/bin/stopper.sh" << 'EOF'
#!/bin/sh
# Bounded poll: wait until ninit logs the cancellation of dep_svc, then stop.
i=0
while ! grep -q "dep_svc.*cancelled" /var/log/ninit.log 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
done
echo poweroff > /run/initctl
exit 0
EOF
	chmod 0755 "$RB/bin/stopper.sh"

	cat > "$RB/etc/init.conf" << 'EOF'
broken:once:/bin/false
dep_svc:respawn:/bin/sleep 300:requires=broken
stopper:once:/bin/sh /bin/stopper.sh
EOF
	boot_guest "$RB" "$WAITB" >"$LB" 2>&1

	check_in  "dependency failure detected and the dependent respawn service cancelled" "$LB" \
		"service 'dep_svc' cancelled: dependency 'broken' failed"
	check_in  "T12: generation counter reset when the service was disabled (FAILED)" "$LB" \
		'dep_svc: respawn counters reset'
	check_in  "event loop stays stable and shutdown is clean" "$LB" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Isolation guard
printf '\n== Isolation Guard ==\n'

if [ "$HOST_NINIT_PREEXISTED" -eq 0 ]; then
	if [ -d /sys/fs/cgroup/ninit ]; then
		bad "/sys/fs/cgroup/ninit appeared on the host (isolation broken)"
	else
		ok "host /sys/fs/cgroup/ninit was never created/touched (100% isolation in $RUN_CG)"
	fi
fi

leaked=""
for leaf in respawn_svc dep_svc broken stopper; do
	if [ -d "$RUN_CG_BASE/$leaf" ]; then
		leaked="$leaked $leaf"
	fi
done
if [ -n "$leaked" ]; then
	bad "test-owned cgroup leaf leak:$leaked"
else
	ok "all test leaves in the isolation base are reaped clean"
fi

base_procs=$($SUDO cat "$RUN_CG_BASE/cgroup.procs" 2>/dev/null || true)
if [ -z "$base_procs" ]; then
	ok "no process left in the isolation base cgroup (cgroup.procs empty)"
else
	bad "process left in the isolation base cgroup: $base_procs"
fi

# ------------------------------------------------------------- Summary
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
