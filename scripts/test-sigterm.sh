#!/bin/sh
# SIGTERM test: proves that SIGTERM from init is really FORWARDED to the service
# process, so the service can close itself cleanly through its own trap (exit 0)
# instead of being forcibly killed by SIGKILL after the grace window expires.
#
# Why this test exists: a fork() child once inherited PID 1's signal mask
# (main() blocks SIGTERM/SIGCHLD/SIGINT/SIGUSR1/SIGUSR2 for ppoll). While that
# mask is installed in the child, the service never receives SIGTERM -> its trap
# does not run -> shutdown_all() waits 5 seconds and then uses SIGKILL.
# This test fails if that regression returns.
#
# Scenario 3 locks in the SANE-01 audit: a service leader that obeys SIGTERM and
# exits first must NOT make init think the whole group is already dead. A child
# in the group that ignores SIGTERM must still be waited for until the grace
# window expires, then killed with SIGKILL via the pgid init stored.
#
# Scenario 4 locks in the final-SIGKILL path fix: a grace loop that stops probing
# at the first live service leaves a stale pgid on the following service, and an
# unchecked SIGKILL can land on a process group whose number the kernel has
# already recycled. A service whose group is proven empty is now skipped (only
# cgroup.kill); a service whose group is alive is still killed.
#
# Pemakaian:
#   sudo sh ./scripts/test-sigterm.sh      # or: make test
#
# Variabel lingkungan:
#   BIN=./ninit              binary under test
#   BUSYBOX=/bin/busybox     static busybox (apt-get install busybox-static)
#   READY_TIMEOUT=10         max seconds to wait for ninit to be ready
#   ACK_TIMEOUT=12           max seconds to wait for the service to close itself
#
# Note: this script deliberately does NOT use `unshare --mount-proc=<dir>`; on
# some kernels mount propagation changes are rejected with EINVAL, so the
# --mount --propagation private + manual `mount -t proc` variant is used
# (same as scripts/smoke-test.sh).

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
ACK_TIMEOUT=${ACK_TIMEOUT:-12}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable (run: make)"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout ps mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required (unshare + chroot)"

ROOTS=""
LOGS=""
init_pid=""
init_pid2=""
init_pid3=""
init_pid4=""

RUN_ID="ninit-sigterm-$$-$(date +%s%N 2>/dev/null || date +%s)"
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
	clean_suite_cgroup "${SUITE_CG:-}" "${SUITE_CG_DEV_INO:-}" || printf 'WARN: clean_suite_cgroup failed (status %d), continuing...\n' $? >&2
	[ -n "${init_pid:-}" ] && $SUDO kill -KILL "$init_pid" 2>/dev/null || true
	[ -n "${init_pid2:-}" ] && $SUDO kill -KILL "$init_pid2" 2>/dev/null || true
	[ -n "${init_pid3:-}" ] && $SUDO kill -KILL "$init_pid3" 2>/dev/null || true
	[ -n "${init_pid4:-}" ] && $SUDO kill -KILL "$init_pid4" 2>/dev/null || true
	for d in ${ROOTS:-}; do
		$SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d"
	done
	for f in ${LOGS:-}; do rm -f "$f"; done
}
trap cleanup EXIT INT TERM

ROOT=$(mktemp -d /tmp/ninit-sigterm.XXXXXX)
LOG=$(mktemp /tmp/ninit-sigterm-log.XXXXXX)
ROOTS="$ROOTS $ROOT"
LOGS="$LOGS $LOG"

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
cp "$BIN" "$ROOT/ninit"
cp "$BUSYBOX" "$ROOT/bin/sh"

# Test service: its only job is to close itself cleanly when it receives
# SIGTERM. The "bye!" string below is what this test checks.
cat > "$ROOT/sigterm-service.sh" <<'EOSVC'
#!/bin/sh
trap 'echo "Received SIGTERM, bye!"; exit 0' TERM
echo "sigterm-service: waiting for SIGTERM (pid $$)"
while true; do sleep 1; done
EOSVC
chmod 0755 "$ROOT/sigterm-service.sh"
printf 'sigterm-test:once:/sigterm-service.sh\n' > "$ROOT/etc/init.conf"

printf '== test rootfs : %s\n' "$ROOT"
printf '== test binary : %s\n' "$BIN"

find_init_pid() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x ninit 2>/dev/null | head -n 1
	else
		ps -eo pid,args 2>/dev/null | awk '$2 == "/ninit" { print $1; exit }'
	fi
}

find_service_pid() {
	ps -eo pid,args 2>/dev/null | awk '/sigterm-service\.sh/ && !/awk/ { print $1; exit }'
}

synblk_has_term() {
	# Argument: contents of /proc/<pid>/status. Print 1 when the SIGTERM bit (0x4000) is set.
	sigblk=$(printf '%s\n' "$1" | awk '/^SigBlk/ { print $2; exit }')
	[ -n "${sigblk:-}" ] || { echo 0; return; }
	low=$(printf '%s' "$sigblk" | cut -c9-16)
	case "$low" in *[!0-9a-fA-F]*|'') echo 0; return;; esac
	echo $(( (0x$low & 0x4000) != 0 ))
}

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT' /ninit" \
		>"$LOG" 2>&1
) &
job=$!

i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	init_pid=$(find_init_pid || true)
	if [ -n "${init_pid:-}" ] && grep -q 'main loop ready' "$LOG" 2>/dev/null \
	   && grep -q 'waiting for SIGTERM' "$LOG" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done
if [ -z "${init_pid:-}" ]; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not run within ${READY_TIMEOUT}s"
fi

# Service process signal mask: SIGTERM must NOT be blocked here.
service_pid=$(find_service_pid || true)
mask_checked=0
if [ -n "${service_pid:-}" ]; then
	mask_checked=1
	service_blocked=$(synblk_has_term "$(cat "/proc/$service_pid/status" 2>/dev/null || echo '')")
fi

t0=$(date +%s%N)
$SUDO kill -TERM "$init_pid" || true

# Wait until the service has closed itself (the exit status line appears in the log).
ack_ms=""
i=0
while [ "$i" -lt $((ACK_TIMEOUT * 20)) ]; do
	if grep -q 'sigterm-test (pid .*) exit status=' "$LOG" 2>/dev/null; then
		ack_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
		break
	fi
	sleep 0.05
	i=$((i + 1))
done

# Give the namespace process a chance to stop on its own (reboot() in the PID
# namespace kills everything in it); the rest is cleaned up by the trap.
i=0
while [ "$i" -lt 60 ]; do
	kill -0 "$job" 2>/dev/null || break
	sleep 0.1
	i=$((i + 1))
done

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
check() { if grep -q "$2" "$LOG"; then ok "$1"; else bad "$1"; fi; }

printf '\n== checks ==\n'
check "cgroup base path overridden ($SUITE_CG_BASE)" "cgroup: base path overridden: $SUITE_CG_BASE"
check "test service running ('waiting for SIGTERM')" 'waiting for SIGTERM'

if [ "$mask_checked" -eq 1 ]; then
	if [ "$service_blocked" -eq 0 ]; then
		ok "SIGTERM not blocked in the service process (SigBlk clean)"
	else
		bad "SIGTERM IS BLOCKED in the service process (the inherited PID 1 mask was not cleared)"
	fi
else
	printf '  [SKIP]   service signal mask not checked (service pid not found)\n'
fi

check "service receives SIGTERM ('bye!' from the trap)" 'Received SIGTERM, bye!'
if grep -qE 'sigterm-test \(pid [0-9]+\) exit status=0x0' "$LOG"; then
	ok "service exits by itself through the trap (exit status=0x0)"
else
	bad "service did not exit with status 0x0"
fi

if grep -q 'exit status=0x9' "$LOG"; then
	bad "service forcibly killed with SIGKILL (exit status=0x9)"
else
	ok "service not forcibly killed with SIGKILL"
fi

if grep -q 'Device or resource busy' "$LOG"; then
	bad "shutdown failed with EBUSY (open file descriptor on rootfs)"
else
	ok "shutdown remount does not fail with EBUSY (log fd closed cleanly)"
fi

if [ -n "$ack_ms" ] && [ "$ack_ms" -lt 4000 ]; then
	ok "service shutdown before the grace window: ${ack_ms}ms (grace = 5000ms)"
elif [ -n "$ack_ms" ]; then
	bad "service only closed itself after ${ack_ms}ms (approaching/exceeding the 5000ms grace window)"
else
	bad "service never closed itself within ${ACK_TIMEOUT}s"
fi

printf '\n== ninit log ==\n'
sed 's/^/  | /' "$LOG"

# -------------------------------------------------------------- Scenario 2
printf '\n== Scenario 2: shutdown pipeline (kill(-pid)) ==\n'
ROOT2=$(mktemp -d /tmp/ninit-sigterm-pipe.XXXXXX)
LOG2=$(mktemp /tmp/ninit-sigterm-pipe-log.XXXXXX)
ROOTS="$ROOTS $ROOT2"
LOGS="$LOGS $LOG2"

mkdir -p "$ROOT2/proc" "$ROOT2/sys" "$ROOT2/dev" "$ROOT2/run" "$ROOT2/tmp" \
         "$ROOT2/etc" "$ROOT2/var/log" "$ROOT2/bin"
cp "$BIN" "$ROOT2/ninit"
cp "$BUSYBOX" "$ROOT2/bin/sh"
cp "$BUSYBOX" "$ROOT2/bin/sleep"

printf 'pipe-svc:once:/bin/sh -c "/bin/sleep 50 | /bin/sleep 50"\n' > "$ROOT2/etc/init.conf"

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT2/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT2' /ninit" \
		>"$LOG2" 2>&1
) &
job2=$!

i=0
init_pid2=""
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	init_pid2=$(find_init_pid || true)
	if [ -n "${init_pid2:-}" ] && grep -q 'main loop ready' "$LOG2" 2>/dev/null \
	   && grep -q 'started pipe-svc' "$LOG2" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done

if [ -z "${init_pid2:-}" ]; then
	sed 's/^/  | /' "$LOG2"
	fail "ninit scenario 2 did not run within ${READY_TIMEOUT}s"
fi

# Pause so both sleep processes in the pipeline are ready
sleep 0.5

# Make sure the sleep processes are alive before shutdown
pipe_procs_before=$(ps -eo args 2>/dev/null | grep '/bin/sleep 50' | grep -v grep | wc -l || true)
if [ "$pipe_procs_before" -ge 2 ]; then
	ok "pipeline processes running ($pipe_procs_before active sleep processes)"
else
	bad "pipeline processes not active before shutdown (found $pipe_procs_before sleep processes)"
fi

# Send SIGTERM to init
$SUDO kill -TERM "$init_pid2" || true

i=0
while [ "$i" -lt 60 ]; do
	kill -0 "$job2" 2>/dev/null || break
	sleep 0.1
	i=$((i + 1))
done
wait "$job2" 2>/dev/null || true

# Verify no sleep 50 process is left behind
pipe_procs_after=$(ps -eo args 2>/dev/null | grep '/bin/sleep 50' | grep -v grep | wc -l || true)
if [ "$pipe_procs_after" -eq 0 ]; then
	ok "all processes in the pipeline are dead after shutdown (group kill -pid)"
else
	bad "$pipe_procs_after pipeline processes left behind after shutdown"
fi

printf '\n== ninit log scenario 2 ==\n'
sed 's/^/  | /' "$LOG2"

# -------------------------------------------------------------- Scenario 3
printf '\n== Scenario 3: stubborn child in a process group (SANE-01 audit) ==\n'
ROOT3=$(mktemp -d /tmp/ninit-sigterm-stubborn.XXXXXX)
LOG3=$(mktemp /tmp/ninit-sigterm-stubborn-log.XXXXXX)
ROOTS="$ROOTS $ROOT3"
LOGS="$LOGS $LOG3"

mkdir -p "$ROOT3/proc" "$ROOT3/sys" "$ROOT3/dev" "$ROOT3/run" "$ROOT3/tmp" \
         "$ROOT3/etc" "$ROOT3/var/log" "$ROOT3/bin"
cp "$BIN" "$ROOT3/ninit"
cp "$BUSYBOX" "$ROOT3/bin/sh"
cp "$BUSYBOX" "$ROOT3/bin/sleep"

# The leader obeys SIGTERM and exits 0, but first spawns a child in the same
# process group that IGNORES SIGTERM (sleep 47). The old init was fooled:
# leader dies -> pid is zeroed -> shutdown thinks the service is already dead
# -> the group escapes SIGKILL and only dies through namespace teardown. The
# /dev/null placeholder is a plain file: ash opens /dev/null for the background
# job's stdin, and the test rootfs really has no device node (the harness avoids
# mknod). An empty file is enough — what matters is that open() succeeds; the
# stubborn child never reads stdin.
: > "$ROOT3/dev/null"
cat > "$ROOT3/stubborn-service.sh" <<'EOSVC'
#!/bin/sh
( trap '' TERM; exec sleep 47 ) &
echo $! > /var/stubborn.pid
echo "stubborn-service: leader running (pid $$), stubborn child sleep 47"
trap 'echo "leader received SIGTERM, bye!"; exit 0' TERM
while true; do sleep 1; done
EOSVC
chmod 0755 "$ROOT3/stubborn-service.sh"
printf 'stubborn-svc:once:/stubborn-service.sh\n' > "$ROOT3/etc/init.conf"

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT3/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT3' /ninit" \
		>"$LOG3" 2>&1
) &
job3=$!

i=0
init_pid3=""
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	init_pid3=$(find_init_pid || true)
	if [ -n "${init_pid3:-}" ] && grep -q 'main loop ready' "$LOG3" 2>/dev/null \
	   && grep -q 'started stubborn-svc' "$LOG3" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done

if [ -z "${init_pid3:-}" ]; then
	sed 's/^/  | /' "$LOG3"
	fail "ninit scenario 3 did not run within ${READY_TIMEOUT}s"
fi

sleep 0.5

# Track the stubborn child through its own PID instead of scanning `ps`
# globally (a global scan depends on other processes on the test machine). The
# service writes its namespace pid to /var/stubborn.pid (NOT /tmp or /run: both
# are overwritten with tmpfs by ninit inside the namespace, so they are not
# visible from the host); map it to the host pid through the NSpid field in
# /proc/<pid>/status (the last field = the pid in the innermost namespace; the
# NF >= 3 requirement rules out host-level processes whose pid number happens
# to match).
child_ns_pid=""
host_pid_of_ns() {
	for d in /proc/[0-9]*; do
		ns=$(awk '/^NSpid:/ { if (NF >= 3) print $NF }' "$d/status" 2>/dev/null || true)
		if [ -n "${ns:-}" ] && [ "$ns" = "$1" ]; then
			printf '%s\n' "${d#/proc/}"
			return 0
		fi
	done
	return 0
}
stubborn_alive() {
	[ -n "${child_ns_pid:-}" ] || return 1
	hp=$(host_pid_of_ns "$child_ns_pid")
	[ -n "${hp:-}" ] && kill -0 "$hp" 2>/dev/null
}

i=0
while [ "$i" -lt 25 ]; do
	if [ -s "$ROOT3/var/stubborn.pid" ]; then
		child_ns_pid=$(cat "$ROOT3/var/stubborn.pid")
	fi
	if stubborn_alive; then break; fi
	sleep 0.2
	i=$((i + 1))
done

if stubborn_alive; then
	ok "stubborn child running before shutdown (namespace pid $child_ns_pid mapped to host)"
else
	bad "stubborn child not active before shutdown (namespace pid: '${child_ns_pid:-?}')"
fi

t0=$(date +%s)
$SUDO kill -TERM "$init_pid3" || true

# Wait for the leader to exit through its trap (exit status is logged).
i=0
while [ "$i" -lt $((ACK_TIMEOUT * 20)) ]; do
	grep -q 'stubborn-svc (pid .*) exit status=' "$LOG3" 2>/dev/null && break
	sleep 0.05
	i=$((i + 1))
done

# 2 seconds after the leader dies, the stubborn child must STILL be alive: the
# correct init still waits for its group (grace), rather than rebooting immediately.
sleep 2
if stubborn_alive; then stubborn_mid=1; else stubborn_mid=0; fi

i=0
while [ "$i" -lt 150 ]; do
	kill -0 "$job3" 2>/dev/null || break
	sleep 0.1
	i=$((i + 1))
done
wait "$job3" 2>/dev/null || true
shutdown_secs=$(( $(date +%s) - t0 ))

if stubborn_alive; then stubborn_after=1; else stubborn_after=0; fi

if grep -q 'leader received SIGTERM, bye!' "$LOG3"; then
	ok "leader exits by itself through the SIGTERM trap"
else
	bad "leader did not run the SIGTERM trap"
fi

if grep -qE 'stubborn-svc \(pid [0-9]+\) exit status=0x0' "$LOG3"; then
	ok "leader exit status=0x0 (graceful)"
else
	bad "leader did not exit with status 0x0"
fi

if [ "$stubborn_mid" -ge 1 ]; then
	ok "stubborn child still alive 2 seconds after the leader dies (init waits for the group, not fooled)"
else
	bad "stubborn child already gone 2 seconds after the leader dies (init fooled: the group escaped grace+SIGKILL)"
fi

if [ "$shutdown_secs" -ge 4 ]; then
	ok "shutdown waits the full grace window for the stubborn group: ${shutdown_secs}s (grace = 5s)"
else
	bad "shutdown finished in only ${shutdown_secs}s (the grace window was not used for the stubborn group)"
fi

if [ "$stubborn_after" -eq 0 ]; then
	ok "stubborn child is dead after shutdown (namespace pid $child_ns_pid no longer mapped)"
else
	bad "stubborn child still alive after shutdown (namespace pid $child_ns_pid)"
fi

printf '\n== ninit log scenario 3 ==\n'
sed 's/^/  | /' "$LOG3"

# -------------------------------------------------------------- Scenario 4
printf '\n== Scenario 4: re-probe before the final SIGKILL (stale group) ==\n'
ROOT4=$(mktemp -d /tmp/ninit-sigterm-stalepgid.XXXXXX)
LOG4=$(mktemp /tmp/ninit-sigterm-stalepgid-log.XXXXXX)
ROOTS="$ROOTS $ROOT4"
LOGS="$LOGS $LOG4"

mkdir -p "$ROOT4/proc" "$ROOT4/sys" "$ROOT4/dev" "$ROOT4/run" "$ROOT4/tmp" \
         "$ROOT4/etc" "$ROOT4/var/log" "$ROOT4/bin"
cp "$BIN" "$ROOT4/ninit"
cp "$BUSYBOX" "$ROOT4/bin/sh"
cp "$BUSYBOX" "$ROOT4/bin/sleep"
: > "$ROOT4/dev/null"

# Two services, and their order matters:
#   astall (index 0) = respawn that IGNORES SIGTERM -> the grace window is
#           guaranteed to expire with one service still alive.
#   zdead  (index 1) = once that finishes by itself long before shutdown ->
#           the pid is already 0 but the pgid is still stored (deliberately,
#           SANE-01 audit), and its group is already empty.
# The old grace loop used `break` as soon as it found the first live service, so
# zdead was never probed on the last pass: that stale pgid was then used for
# kill(-pgid, SIGKILL) without a check. Process group numbers can be recycled by
# the kernel, and the signal could land on a process group owned by someone else.
# Now every service is probed and every SIGKILL is preceded by
# service_still_alive(), so zdead is recorded as
# "process group already dead, SIGKILL skipped".
printf 'astall:respawn:trap "" TERM; exec /bin/sleep 60\nzdead:once:/bin/sleep 1\n' \
	> "$ROOT4/etc/init.conf"

(
	$SUDO timeout -k 5 40 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT4/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT4' /ninit" \
		>"$LOG4" 2>&1
) &
job4=$!

i=0
init_pid4=""
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	init_pid4=$(find_init_pid || true)
	if [ -n "${init_pid4:-}" ] && grep -q 'main loop ready' "$LOG4" 2>/dev/null \
	   && grep -q 'started astall' "$LOG4" 2>/dev/null \
	   && grep -q 'started zdead' "$LOG4" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done

if [ -z "${init_pid4:-}" ]; then
	sed 's/^/  | /' "$LOG4"
	fail "ninit scenario 4 did not run within ${READY_TIMEOUT}s"
fi

# Give zdead time to finish and let reap normalize its pid (the pgid is deliberately left behind).
sleep 2
if ! grep -qE 'zdead \(pid [0-9]+\) exit status=0x0' "$LOG4"; then
	sed 's/^/  | /' "$LOG4"
	fail "zdead did not finish first as this test assumes"
fi

t0=$(date +%s)
$SUDO kill -TERM "$init_pid4" || true

i=0
while [ "$i" -lt 200 ]; do
	kill -0 "$job4" 2>/dev/null || break
	sleep 0.1
	i=$((i + 1))
done
wait "$job4" 2>/dev/null || true
shutdown4_secs=$(( $(date +%s) - t0 ))

check4() { if grep -q "$2" "$LOG4"; then ok "$1"; else bad "$1"; fi; }
absent4() { if grep -q "$2" "$LOG4"; then bad "$1"; else ok "$1"; fi; }

check4  "zdead probed and SIGKILL skipped (stale pgid not used)" \
	'zdead: process group already dead, SIGKILL skipped'
absent4 "astall NOT considered a dead group (its group is still alive)" \
	'astall: process group already dead'
# There is no third assertion here. The "astall (pid N) exit status=0x9"
# line is not printed because shutdown_all() calls reboot() as soon as SIGKILL
# is sent — the namespace dies before ninit gets to reap. Marking the cgroup as
# freed cannot be used either: cleanup_cgroup() only prints when rmdir()
# succeeds, and rmdir of a group whose members were just killed returning EBUSY
# depends on scheduling. The two checks above already separate both branches
# (group alive -> SIGKILL, group empty -> skipped) and that is the part that
# was regressed.
if [ "$shutdown4_secs" -ge 4 ]; then
	ok "grace window still fully used for the stubborn service: ${shutdown4_secs}s"
else
	bad "shutdown finished in ${shutdown4_secs}s (grace window not honored)"
fi

printf '\n== ninit log scenario 4 ==\n'
sed 's/^/  | /' "$LOG4"

if [ "$fail_count" -eq 0 ]; then
	printf '\nRESULT: PASS (all checks)\n'
else
	printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
	exit 1
fi
