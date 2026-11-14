#!/bin/sh
# Configuration + initctl IPC test: locks in three reliability fixes.
#
#   1a. topological `:requires=` order is correct for a diamond shape (a needs b,c ;
#       b needs c -> order c, b, a).
#   1b. a dense configuration of exactly 64 services (root needs all of s2..s64,
#       s63 needs two siblings) completes without a stack overflow.
#       Old regression: services still "pending" on the stack were pushed again and
#       again, so stack_top passed MAX_SERVICES -> stack-buffer-overflow in
#       sort_services() (proven with AddressSanitizer on the old version).
#   2.  a missing dependency (web:requires=db) -> "FATAL: Dependency ... not
#       found" + SUPERVISED rescue shell, NOT a half-finished boot. PID 1 stays
#       alive and the shell is its child (T15).
#   3a. two commands in one write to /run/initctl (poweroff + reboot):
#       only the first line is executed.
#   3b. an unknown command on the first line (status + poweroff): the command on
#       the second line is NOT lost without a trace (old parsing regression).
#   4a. an unreadable config -> a real SUPERVISED rescue shell (old regression:
#       only logged, then init "successfully" booted with zero services).
#       Same for a config that parses but registers zero services (T16).
#   4b. a dependency cycle -> rescue shell, and that shell inherits an EMPTY
#       signal mask so SIGINT (Ctrl+C) works (old regression: PID 1's ppoll mask
#       leaked into the emergency shell).
#   4c. the rescue shell exits (exit/Ctrl-D/EOF) -> PID 1 SURVIVES, records the
#       exit and respawns the shell. Any execl-based rescue dies here and the
#       kernel panics with "Attempted to kill init!" (T15).
#
# Pemakaian:
#   sudo sh ./scripts/test-config.sh      # or: make test
#
# Variabel lingkungan:
#   BIN=./ninit              binary under test
#   BUSYBOX=/bin/busybox     static busybox (apt-get install busybox-static)
#   READY_TIMEOUT=10         max seconds to wait for ninit to be ready/reactive
#
# Note: same as scripts/smoke-test.sh, this script deliberately does NOT use
# `unshare --mount-proc=<dir>` (some kernels reject mount propagation changes
# with EINVAL). Scenarios that need a LIVE rescue shell to inspect (2, 4a, 4b)
# provide a fifo stdin held open by `sleep`, because with /dev/null the shell
# hits EOF at once. That immediate-exit path is itself covered: scenario 4c runs
# with /dev/null and asserts PID 1 survives the exit and respawns the shell -
# supervision means an exiting shell can no longer hang or kill CI.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

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

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
check() { if grep -q "$2" "$LOG"; then ok "$1"; else bad "$1"; fi; }
check_absent() { if grep -q "$2" "$LOG"; then bad "$1"; else ok "$1"; fi; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable (run: make)"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout ps mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required (unshare + chroot)"

ROOTS=""
LOGS=""
JOB=""
INIT_PID=""
HOLDER=""
INIT_STDIN=/dev/null

RUN_ID="ninit-config-$$-$(date +%s%N 2>/dev/null || date +%s)"
SUITE_CG="/sys/fs/cgroup/$RUN_ID"
SUITE_CG_BASE="$SUITE_CG/ninit"
if [ -e "$SUITE_CG" ]; then
	fail "cgroup collision: path '$SUITE_CG' already exists before test starts"
fi
$SUDO mkdir "$SUITE_CG" || fail "failed to create isolation root '$SUITE_CG'"
SUITE_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$SUITE_CG" 2>/dev/null || true)
[ -n "$SUITE_CG_DEV_INO" ] || fail "failed to read dev:ino for '$SUITE_CG'"

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
	[ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null || true
	[ -n "${INIT_PID:-}" ] && $SUDO kill -KILL "$INIT_PID" 2>/dev/null || true
	for d in ${ROOTS:-}; do
		$SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d"
	done
	for f in ${LOGS:-}; do rm -f "$f"; done
}
trap cleanup EXIT INT TERM

# Prepare a separate test rootfs for each scenario ($1 = test name/tag).
start_root() {
	ROOT=$(mktemp -d "/tmp/ninit-$1.XXXXXX")
	chmod 0755 "$ROOT"
	LOG=$(mktemp "/tmp/ninit-$1-log.XXXXXX")
	ROOTS="$ROOTS $ROOT"
	LOGS="$LOGS $LOG"
	mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
	         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
	cp "$BIN" "$ROOT/ninit"
	cp "$BUSYBOX" "$ROOT/bin/sh"
}

# Run ninit as PID 1 inside a new PID + mount namespace.
run_init() {
	(
		$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
			--mount --propagation private ${TEST_UNSHARE_OPTS:-} \
			sh -c "umask ${TEST_UMASK:-0022}; mount -t proc proc '$ROOT/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT' /ninit ${INIT_ARGS:-}" \
			>"$LOG" 2>&1 <"$INIT_STDIN"
	) &
	JOB=$!
	INIT_PID=""
}

find_init_pid() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x ninit 2>/dev/null | head -n 1
	else
		ps -eo pid,args 2>/dev/null | awk '$2 == "/ninit" { print $1; exit }'
	fi
}

# Wait until the pattern appears in the log. 0 = found, 1 = timeout.
wait_for() {
	i=0
	while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
		if grep -q "$1" "$LOG" 2>/dev/null; then return 0; fi
		sleep 0.2
		i=$((i + 1))
	done
	return 1
}

stop_init() {
	if [ -n "${INIT_PID:-}" ]; then $SUDO kill -KILL "$INIT_PID" 2>/dev/null || true; fi
	wait "$JOB" 2>/dev/null || true
	INIT_PID=""
	clean_suite_leaves
}

# --- supervised rescue helpers (T15) -----------------------------------------
# Find the rescue SHELL: a process whose root filesystem is $ROOT and whose
# argv[0] is "sh". With supervised rescue, PID 1 keeps running /ninit and the
# shell is its child; the init pid is excluded explicitly so this can never
# return PID 1 itself. (Under the old execl() implementation PID 1 *was* the
# shell, which is exactly the behaviour this test now rejects.)
find_rescue_pid() {
	for s in /proc/[0-9]*/status; do
		p=${s#/proc/}; p=${p%/status}
		r=$(readlink "/proc/$p/root" 2>/dev/null) || continue
		[ "$r" = "$ROOT" ] || continue
		[ "$p" = "${INIT_PID:-}" ] && continue
		c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
		[ "$c" = "sh " ] || continue
		printf '%s\n' "$p"; return 0
	done
	return 1
}

# Assert supervised rescue: PID 1 alive AND the shell is its child. An exited
# PID 1 panics the kernel ("Attempted to kill init!"), so "PID 1 still alive"
# is the core promise of T15. $1 = scenario tag used in the messages.
assert_supervised_rescue() {
	tag=$1

	# Resolve PID 1 here (bounded poll), never before the guest has booted:
	# ninit only exists a moment after run_init returns.
	if [ -z "${INIT_PID:-}" ]; then
		j=0
		while [ "$j" -lt 50 ]; do
			init_pid=$(find_init_pid || true)
			[ -n "${init_pid:-}" ] && break
			sleep 0.1
			j=$((j + 1))
		done
		INIT_PID="${init_pid:-}"
	fi

	rescue_pid=""
	i=0
	while [ "$i" -lt 50 ]; do
		rescue_pid=$(find_rescue_pid || true)
		[ -n "$rescue_pid" ] && break
		sleep 0.1
		i=$((i + 1))
	done

	if [ -n "${INIT_PID:-}" ] && kill -0 "$INIT_PID" 2>/dev/null; then
		ok "$tag: PID 1 (ninit) is STILL ALIVE in rescue mode (no execl replacement)"
	else
		bad "$tag: PID 1 is gone after entering rescue mode (kernel panic risk)"
	fi

	if [ -z "$rescue_pid" ]; then
		bad "$tag: supervised rescue shell not found (no forked /bin/sh child)"
		return 0
	fi
	ok "$tag: rescue shell child is running (pid $rescue_pid)"

	ppid=$(awk '/^PPid:/ { print $2; exit }' "/proc/$rescue_pid/status" 2>/dev/null || true)
	if [ -n "${INIT_PID:-}" ] && [ "$ppid" = "$INIT_PID" ]; then
		ok "$tag: rescue shell is a CHILD of PID 1 (PPid=$ppid), PID 1 supervises it"
	else
		bad "$tag: rescue shell PPid=$ppid (expected PID 1 = ${INIT_PID:-?})"
	fi
}

printf '== test binary : %s\n' "$BIN"
printf '== busybox    : %s\n' "$BUSYBOX"

# -------------------------------------------------------------- scenario 1a
printf '\n== 1a. dependency order: diamond shape ==\n'
start_root topo
LOG1="$LOG"
cat > "$ROOT/etc/init.conf" <<'EOCFG'
# diamond shape -> two services need the same service (not a cycle)
a:once:echo svc-a:requires=b,c
b:once:echo svc-b:requires=c
c:once:echo svc-c
EOCFG

run_init
if ! wait_for 'ninit: started a (pid'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not finish running the diamond services within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "cgroup base path overridden ($SUITE_CG_BASE)" "cgroup: base path overridden: $SUITE_CG_BASE"
check "event loop running ('main loop ready')" 'main loop ready'
check "dependency-ordered service ran ('started a')" 'ninit: started a (pid'
check "service without dependencies runs first ('started c')" 'ninit: started c (pid'
check_absent "diamond not misjudged as a cycle" 'CYCLE DETECTED'

# Spawn order must follow the topological order: c -> b -> a.
order=$(sed -n 's/.*ninit: started \([abc]\) (pid.*/\1/p' "$LOG" | tr -d '\n')
if [ "$order" = "cba" ]; then
	ok "topological order correct: c -> b -> a (got: $order)"
else
	bad "topological order wrong (expected cba, got: '$order')"
fi

# A once service must really finish (exit status) before its dependency runs
seq_c_exit=$(grep -nE 'ninit: c \(pid [0-9]+\) exit status=0x0' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_b_start=$(grep -nE 'ninit: started b \(pid' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_b_exit=$(grep -nE 'ninit: b \(pid [0-9]+\) exit status=0x0' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_a_start=$(grep -nE 'ninit: started a \(pid' "$LOG" | head -n 1 | cut -d: -f1 || true)

if [ -n "$seq_c_exit" ] && [ -n "$seq_b_start" ] && [ "$seq_c_exit" -lt "$seq_b_start" ] && \
   [ -n "$seq_b_exit" ] && [ -n "$seq_a_start" ] && [ "$seq_b_exit" -lt "$seq_a_start" ]; then
	ok "once service finishes before its dependency runs (c exit -> b start -> b exit -> a start)"
else
	bad "once service did not wait for completion before the dependency ran (c_exit=$seq_c_exit b_start=$seq_b_start b_exit=$seq_b_exit a_start=$seq_a_start)"
fi

# -------------------------------------------------------------- scenario 1b
printf '\n== 1b. dense configuration of 64 services (stack overflow regression) ==\n'
start_root dense
LOG2="$LOG"
{
	printf '# root needs all of s2..s64 (63 dependencies) and s63 needs two siblings\n'
	printf 'root:once:::requires='
	i=2; sep=""
	while [ "$i" -le 64 ]; do
		printf '%s%s' "$sep" "s$i"
		sep=","
		i=$((i + 1))
	done
	printf '\n'
	printf 's63:once:::requires=s62,s61\n'
	i=2
	while [ "$i" -le 64 ]; do
		if [ "$i" -ne 63 ]; then printf 's%d:once::\n' "$i"; fi
		i=$((i + 1))
	done
} > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'ninit: started root (pid'; then
	sed 's/^/  | /' "$LOG" | grep -vE 'started s[0-9]+ \(pid'
	fail "ninit did not finish spawning the dense configuration within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

dense_started=$(grep -cE 'ninit: started (s[0-9]+|root) \(pid' "$LOG" || true)
if [ "$dense_started" -eq 64 ]; then
	ok "dense configuration: 64/64 services ran without a stack overflow"
else
	bad "dense configuration: only $dense_started/64 services ran"
fi
check "cgroup base path overridden ($SUITE_CG_BASE)" "cgroup: base path overridden: $SUITE_CG_BASE"
check "event loop running ('main loop ready')" 'main loop ready'
check_absent "no FATAL (stack overflow/cycle) on a valid configuration" 'FATAL'

# --------------------------------------------------------------- scenario 2
printf '\n== 2. missing dependency -> supervised rescue shell ==\n'
start_root missing
LOG3="$LOG"
printf 'web:once:echo web:requires=db\n' > "$ROOT/etc/init.conf"

# A held-open stdin keeps the emergency shell alive long enough to inspect it.
# (With /dev/null the shell hits EOF instantly and is respawned - that path is
# scenario 4c.)
mkfifo "$ROOT/rescue.stdin"
sleep 15 > "$ROOT/rescue.stdin" &
HOLDER=$!
INIT_STDIN="$ROOT/rescue.stdin"

run_init
if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "ninit did not report rescue mode for the missing dependency"
fi

check "missing dependency reported as FATAL" "FATAL: Dependency 'db' for 'web' not found"
check "init enters rescue mode (shell)" 'Entering rescue mode (shell)'
check_absent "boot not continued (no 'main loop ready')" 'main loop ready'
check_absent "problematic service not run" 'ninit: started web'

# T15: PID 1 supervises the shell instead of being replaced by it.
assert_supervised_rescue "2"

INIT_STDIN=/dev/null
kill "$HOLDER" 2>/dev/null || true
HOLDER=""
stop_init

# --------------------------------------------------------------- scenario 3
# $1 = test tag, $2 = printf payload the service sends to /run/initctl
#      (e.g. 'poweroff\nreboot\n')
run_cmdtest() {
	start_root "$1"
	cat > "$ROOT/send-cmd.sh" <<EOSVC
#!/bin/sh
sleep 1
printf '$2' > /run/initctl
EOSVC
	chmod 0755 "$ROOT/send-cmd.sh"
	printf 'sender:once:/send-cmd.sh\n' > "$ROOT/etc/init.conf"

	run_init
	init_pid=$(find_init_pid || true)
	INIT_PID="${init_pid:-}"
	if ! wait_for 'graceful shutdown'; then
		sed 's/^/  | /' "$LOG"
		bad "$1: ninit did not react to the command in /run/initctl"
	fi
	stop_init
}

printf '\n== 3a. two commands in one write: poweroff + reboot ==\n'
run_cmdtest ipc 'poweroff\nreboot\n'
LOG4="$LOG"
check "first line executed" "initctl cmd: 'poweroff'"
check_absent "second line not executed (poweroff turns the system off)" "initctl cmd: 'reboot'"
check "shutdown from /run/initctl ran cleanly" 'graceful shutdown'

printf '\n== 3b. unknown command on the first line: status + poweroff ==\n'
run_cmdtest ipc2 'status\npoweroff\n'
LOG5="$LOG"
check "unknown line still logged" "initctl cmd: 'status'"
check "command on the second line NOT lost" "initctl cmd: 'poweroff'"
check "command on the second line really executed" 'graceful shutdown'

# --------------------------------------------------------------- scenario 4a
# parse_config() fails (file missing) MUST enter the rescue shell, not continue
# booting with zero services and then claim "main loop ready".
printf '\n== 4a. unreadable config -> supervised rescue shell ==\n'
start_root badconf
LOG6="$LOG"
# deliberately do not create /etc/init.conf
INIT_ARGS=/etc/init.conf.missing
mkfifo "$ROOT/rescue.stdin"
sleep 15 > "$ROOT/rescue.stdin" &
HOLDER=$!
INIT_STDIN="$ROOT/rescue.stdin"
run_init
INIT_ARGS=""
if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "an unreadable config did not trigger rescue mode"
fi

check "config failure reported" 'Config failed to read/parse!'
check "init enters rescue mode (shell)" 'Entering rescue mode (shell)'
check_absent "boot not continued (no 'main loop ready')" 'main loop ready'

# T15: PID 1 supervises the shell instead of being replaced by it.
assert_supervised_rescue "4a"

INIT_STDIN=/dev/null
kill "$HOLDER" 2>/dev/null || true
HOLDER=""
stop_init

# --------------------------------------------------------------- scenario 4b
# A dependency cycle => rescue shell. This shell must inherit an EMPTY signal
# mask; otherwise Ctrl+C would never reach the emergency shell. Its stdin is a
# fifo held open by `sleep` so the shell does not immediately hit EOF and we
# have time to read its /proc/<pid>/status.
printf '\n== 4b. dependency cycle -> rescue shell + empty signal mask ==\n'
start_root cycle
LOG7="$LOG"
printf 'a:once:echo svc-a:requires=b\nb:once:echo svc-b:requires=a\n' > "$ROOT/etc/init.conf"
mkfifo "$ROOT/rescue.stdin"
sleep 15 > "$ROOT/rescue.stdin" &
HOLDER=$!
INIT_STDIN="$ROOT/rescue.stdin"
INIT_ARGS=""
run_init

if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "a dependency cycle did not trigger rescue mode"
fi
check "cycle reported as FATAL" 'FATAL: CYCLE DETECTED'
check "init enters rescue mode (shell)" 'Entering rescue mode (shell)'
check_absent "boot not continued (no 'main loop ready')" 'main loop ready'

# find_rescue_pid() is defined once in the shared helpers above (T15): it now
# locates the FORKED shell child, never PID 1 itself.
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"

rescue_pid=""
i=0
while [ "$i" -lt 50 ]; do
	rescue_pid=$(find_rescue_pid || true)
	[ -n "$rescue_pid" ] && break
	sleep 0.1
	i=$((i + 1))
done

if [ -z "$rescue_pid" ]; then
	bad "rescue shell not found (cannot check the signal mask)"
else
	sigblk=$(awk '/^SigBlk/ { print $2; exit }' "/proc/$rescue_pid/status" 2>/dev/null || true)
	mask_nonzero=$(printf '%s' "${sigblk:-0}" | sed 's/^0*//')
	if [ -z "$mask_nonzero" ]; then
		ok "rescue shell signal mask empty (SigBlk=0, Ctrl+C works)"
	else
		bad "rescue shell inherited a signal mask (SigBlk=$sigblk) -> Ctrl+C does not arrive"
	fi
	# T15: the shell is PID 1's child, and PID 1 is still alive behind it.
	assert_supervised_rescue "4b"
	$SUDO kill -KILL "$rescue_pid" 2>/dev/null || true
fi

kill "$HOLDER" 2>/dev/null || true
HOLDER=""
INIT_STDIN=/dev/null
stop_init

# -------------------------------------------------------------- scenario 4c
# T15/R2: the emergency shell EXITS (operator `exit`/Ctrl-D, or EOF because
# stdin is /dev/null). PID 1 must survive, record the exit and respawn the
# shell. The old execl() implementation died here - and an exited PID 1 panics
# the kernel ("Attempted to kill init!"), which is the regression this locks in.
printf '\n== 4c. rescue shell exit -> respawn, PID 1 stays alive ==\n'
start_root rescueexit
INIT_STDIN=/dev/null
INIT_ARGS=""
printf 'web:once:echo web:requires=nope\n' > "$ROOT/etc/init.conf"
run_init

if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "4c: ninit did not enter rescue mode"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
check "4c: init enters rescue mode (shell)" 'Entering rescue mode (shell)'
check_absent "4c: boot not continued (no 'main loop ready')" 'main loop ready'

if wait_for 'rescue shell exit status=0x0'; then
	ok "4c: shell exit recorded by PID 1 (rescue shell exit status=0x0)"
else
	bad "4c: PID 1 never recorded the rescue shell exit"
fi

if wait_for 'rescue shell exited; respawning'; then
	ok "4c: shell respawned under supervision (bounded budget)"
else
	bad "4c: no respawn after the shell exited"
fi

if [ -n "${INIT_PID:-}" ] && kill -0 "$INIT_PID" 2>/dev/null; then
	ok "4c: PID 1 (ninit) STILL ALIVE after the shell exited (no panic path)"
else
	bad "4c: PID 1 is gone after the shell exited (kernel panic risk)"
fi
check_absent "4c: no kernel panic message in the ninit log" 'Attempted to kill init'
stop_init

# -------------------------------------------------------------- scenario 4d
# Stable rescue shell (ran >= RESCUE_STABLE_MS) resets the respawn budget.
printf '\n== 4d. stable rescue shell -> budget reset ==\n'
start_root rescuestable
mkfifo "$ROOT/rescue.stdin"
# Hold stdin open for 3 seconds then exit cleanly (RESCUE_STABLE_MS is 2s in NINIT_TESTING)
( sleep 3; echo "exit" ) > "$ROOT/rescue.stdin" &
HOLDER=$!
INIT_STDIN="$ROOT/rescue.stdin"
printf 'web:once:echo web:requires=nope\n' > "$ROOT/etc/init.conf"
run_init

if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "4d: ninit did not enter rescue mode"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"

if wait_for 'respawn budget reset'; then
	ok "4d: rescue shell stable run reset the respawn budget"
else
	bad "4d: respawn budget was not reset after stable execution"
fi

kill "$HOLDER" 2>/dev/null || true
HOLDER=""
INIT_STDIN=/dev/null
stop_init

# -------------------------------------------------------------- scenario 5
printf '\n== 5. over-long string rejection (name, command, dependency) ==\n'
start_root trunc
LOG8="$LOG"

long_name=$(printf 'longname_%.0s' $(seq 1 15))
long_cmd=$(printf 'echo hello_%.0s' $(seq 1 48))
long_deps="dep,"$(printf 'd%02d,' $(seq 1 63))
cat > "$ROOT/etc/init.conf" <<EOCFG
dep:once:true
${long_name}:once:${long_cmd}:requires=${long_deps}
EOCFG

run_init
if ! wait_for 'entry rejected'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not log the over-long string rejection within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "over-long name rejected" 'Parse err: service name too long'
check "over-long command rejected" 'Parse err: service command'
check "over-long dependency rejected" 'Parse err: service dependency'
check "healthy service still runs ('started dep')" 'ninit: started dep (pid'
check_absent "over-long service NOT run" 'started longname'

# -------------------------------------------------------------- scenario 6
printf '\n== 6. the 65th service exceeds the MAX_SERVICES limit ==\n'
start_root maxsvc
LOG9="$LOG"

{
	i=1
	while [ "$i" -le 65 ]; do
		printf 'svc%02d:once::\n' "$i"
		i=$((i + 1))
	done
} > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop ready'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not finish booting within ${READY_TIMEOUT}s on the 65th-service test"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "warning that the 64-service limit is reached" 'Warning: limit of 64 services reached'
check_absent "65th service not run" 'started svc65'

# -------------------------------------------------------------- scenario 7
printf '\n== 7. the dependency order promised by the README (logd once -> net once) ==\n'
start_root readmedep
LOG10="$LOG"

cat > "$ROOT/etc/init.conf" <<'EOCFG'
logd:once:/bin/sh -c 'sleep 0.3 && echo logd-ready'
net:once:echo net-started:requires=logd
EOCFG

run_init
if ! wait_for 'net-started'; then
	sed 's/^/  | /' "$LOG"
	fail "net did not run within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

seq_logd=$(grep -n '\[service\] logd-ready' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_net=$(grep -n 'ninit: started net' "$LOG" | head -n 1 | cut -d: -f1 || true)

if [ -n "$seq_logd" ] && [ -n "$seq_net" ] && [ "$seq_logd" -lt "$seq_net" ]; then
	ok "net runs only AFTER logd finishes ('logd-ready' before 'started net')"
else
	bad "README dependency order wrong (logd_ready=$seq_logd net_started=$seq_net)"
fi

# -------------------------------------------------------------- scenario 8
printf '\n== 8. service name validation must not contain / ==\n'
start_root slashname
LOG11="$LOG"

cat > "$ROOT/etc/init.conf" <<'EOCFG'
good_svc:once:true
bad/svc:once:true
EOCFG

run_init
if ! wait_for 'main loop ready'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not boot within ${READY_TIMEOUT}s on the slash-name test"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "name-with-slash error logged" 'Parse err: service name'
check_absent "service with a slash not run" 'started bad/svc'

# -------------------------------------------------------------- scenario 9
printf '\n== 9. config line exceeds MAX_LINE rejected whole (SANE-03 audit) ==\n'
start_root longline
LOG11="$LOG"

pad=$(printf 'x%.0s' $(seq 1 1200))
cat > "$ROOT/etc/init.conf" <<EOCFG
ghost:once:echo boo${pad}
realsvc:once:true
EOCFG

run_init
if ! wait_for 'main loop ready'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not reach the main loop on the long-line scenario within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "over-long line recorded as rejected" 'exceeds MAX_LINE'
check "service after the long line still registered ('started realsvc')" 'ninit: started realsvc (pid'
check_absent "no ghost service from the line fragment ('started ghost')" 'started ghost'

# ------------------------------------------------------------- scenario 10
printf '\n== 10. fstab option classification: VFS flags vs userspace vs data (SANE-02 audit) ==\n'
start_root fstab
LOG12="$LOG"
mkdir -p "$ROOT/mnt"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/a tmpfs ro,nosuid,noatime,size=4M 0 0
tmpfs /mnt/b tmpfs noauto,mode=700 0 0
tmpfs /mnt/c tmpfs _netdev,x-custom,relatime,mode=755 0 0
EOFSTAB
printf 'fstabprobe:once:true\n' > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop ready'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not reach the main loop on the fstab scenario within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "fstab a: VFS flags split out, data holds only filesystem options, mount ok" '\[data: size=4M\] ok'
check "fstab b: noauto entry skipped" 'skipped (noauto option)'
check_absent "fstab b: noauto entry NOT mounted" 'mount tmpfs -> /mnt/b'
check "fstab c: userspace option recorded as ignored" 'is userspace-only, ignored'
check "fstab c: mount ok, data holds only mode=755" '\[data: mode=755\] ok'
check_absent "no fstab mount failed" 'fstab: mount .* failed'

# ------------------------------------------------------------- scenario 11
printf '\n== 11. line limit at EOF: exactly MAX_LINE-1 accepted, MAX_LINE rejected ==\n'
start_root eolbound
LOG13="$LOG"

# A comment line is used so that only the LINE limit (MAX_LINE) is tested,
# not the name/cmd/deps field limits, which have their own rejections.
{ printf 'first:once:true\n'; printf '#%s' "$(printf 'x%.0s' $(seq 1 1022))"; } > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop ready'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not reach the main loop on the EOF-limit scenario within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "normal service still runs on the EOF-limit scenario" 'ninit: started first (pid'
check_absent "EOF line of exactly MAX_LINE-1 (1023) NOT rejected" 'exceeds MAX_LINE'

start_root eolover
LOG14="$LOG"

{ printf 'first:once:true\n'; printf '#%s' "$(printf 'x%.0s' $(seq 1 1023))"; } > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop ready'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit did not reach the main loop on the EOF+1-limit scenario within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "EOF line of MAX_LINE (1024) rejected even without a newline" 'exceeds MAX_LINE'
check "normal service still runs after the EOF line is rejected" 'ninit: started first (pid'

# ------------------------------------------------------------- scenario 12
printf '\n== 12. fstab: exec/suid/dev, user implications, left-to-right override (PR #2 review) ==\n'
start_root fstabflags
LOG15="$LOG"
mkdir -p "$ROOT/mnt"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/e1 tmpfs exec,suid,dev,size=1M 0 0
tmpfs /mnt/e2 tmpfs user,size=1M 0 0
tmpfs /mnt/e3 tmpfs user,exec,size=1M 0 0
tmpfs /mnt/e4 tmpfs ro,rw,size=1M 0 0
EOFSTAB
printf 'dumpro:once:cat /proc/mounts > /var/mounts.txt\n' > "$ROOT/etc/init.conf"

run_init
i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	[ -s "$ROOT/var/mounts.txt" ] && break
	sleep 0.2
	i=$((i + 1))
done
if [ ! -s "$ROOT/var/mounts.txt" ]; then
	sed 's/^/  | /' "$LOG"
	fail "dumpro did not write /var/mounts.txt within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "fstab e1: exec/suid/dev consumed (not data), mount ok" 'mount tmpfs -> /mnt/e1 (tmpfs) \[data: size=1M\] ok'
check "fstab e2: user recorded as applying its implications" "option 'user' applies noexec,nosuid,nodev"
check_absent "no fstab mount failed" 'fstab: mount .* failed'

# Evidence from the guest's /proc/mounts: the flags REALLY in effect, not
# merely a mount() that did not error.
mount_opts() { awk -v m="$1" '$2 == m { print $4 }' "$ROOT/var/mounts.txt"; }
has_opt() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

e1_opts=$(mount_opts /mnt/e1)
if ! has_opt noexec "$e1_opts" && ! has_opt nosuid "$e1_opts" && ! has_opt nodev "$e1_opts"; then
	ok "fstab e1: /proc/mounts without noexec/nosuid/nodev ($e1_opts)"
else
	bad "fstab e1: opts contain an unwanted negator ($e1_opts)"
fi

e2_opts=$(mount_opts /mnt/e2)
if has_opt noexec "$e2_opts" && has_opt nosuid "$e2_opts" && has_opt nodev "$e2_opts"; then
	ok "fstab e2: /proc/mounts proves user -> noexec,nosuid,nodev ($e2_opts)"
else
	bad "fstab e2: user implications not in effect (opts: '$e2_opts')"
fi

e3_opts=$(mount_opts /mnt/e3)
if has_opt nosuid "$e3_opts" && has_opt nodev "$e3_opts" && ! has_opt noexec "$e3_opts"; then
	ok "fstab e3: user,exec -> exec cancels only noexec ($e3_opts)"
else
	bad "fstab e3: user,exec override wrong (opts: '$e3_opts')"
fi

e4_opts=$(mount_opts /mnt/e4)
if has_opt rw "$e4_opts" && ! has_opt ro "$e4_opts"; then
	ok "fstab e4: ro,rw -> ends up rw ($e4_opts)"
else
	bad "fstab e4: ro,rw override wrong (opts: '$e4_opts')"
fi

# ------------------------------------------------------------- scenario 13
printf '\n== 13. fstab: recursive mkdir, bind rejected, skip before mkdir (follow-up PR) ==\n'
start_root fstabdeep
LOG16="$LOG"
# /mnt is created as a control parent; what is tested is the level BELOW it,
# which is not created from outside (scenarios 10/12 always prepare the path).
mkdir -p "$ROOT/mnt" "$ROOT/var/realdir"
touch "$ROOT/mnt/blocked" "$ROOT/var/afile"
ln -s /var/realdir "$ROOT/mnt/linkdir"
ln -s /var/afile "$ROOT/mnt/filelink"
ln -s /var/missing "$ROOT/mnt/dangle"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/deep/nested tmpfs size=1M 0 0
tmpfs /mnt/trail/ tmpfs size=1M 0 0
tmpfs /mnt/noauto-dir tmpfs noauto,size=1M 0 0
/src /mnt/bind-dir none bind 0 0
/src2 /mnt/nobind-dir none bind,noauto 0 0
tmpfs /mnt/filelink/x tmpfs size=1M 0 0
tmpfs /mnt/blocked/x tmpfs size=1M 0 0
tmpfs /mnt/./evil tmpfs size=1M 0 0
tmpfs /mnt/ghostdir/../evil tmpfs size=1M 0 0
tmpfs /mnt/dangle/x tmpfs size=1M 0 0
tmpfs /mnt/linkdir/deep tmpfs size=1M 0 0
tmpfs /mnt/after tmpfs size=1M 0 0
EOFSTAB
printf 'dumpro:once:cat /proc/mounts > /var/mounts.txt\n' > "$ROOT/etc/init.conf"

# Strict umask in the guest: the mountpoint created by mkdir_p must STAY 0755
# thanks to an explicit chmod, not 0700 inherited from the umask.
TEST_UMASK=077
run_init
i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	[ -s "$ROOT/var/mounts.txt" ] && break
	sleep 0.2
	i=$((i + 1))
done
if [ ! -s "$ROOT/var/mounts.txt" ]; then
	sed 's/^/  | /' "$LOG"
	fail "dumpro did not write /var/mounts.txt on scenario 13 within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init
TEST_UMASK=""

check "fstab f1: nested mountpoint created recursively, mount ok" 'mount tmpfs -> /mnt/deep/nested (tmpfs) \[data: size=1M\] ok'
check "fstab f2: trailing slash handled, mount ok" 'mount tmpfs -> /mnt/trail/ (tmpfs) \[data: size=1M\] ok'
check "fstab f3: noauto entry skipped" 'tmpfs -> /mnt/noauto-dir skipped (noauto option)'
check "fstab f4: bind entry explicitly rejected" '/src -> /mnt/bind-dir skipped (bind/rbind not supported)'
check_absent "fstab f4: bind NOT mounted" 'mount /src -> /mnt/bind-dir'
check "fstab f4b: bind+noauto -> the first reason (noauto) is recorded" '/src2 -> /mnt/nobind-dir skipped (noauto option)'
check_absent "fstab f4b: bind+noauto NOT recorded as bind" 'nobind-dir skipped (bind'
check "fstab f5: symlink-to-file component clearly rejected" "component '/mnt/filelink' of mountpoint '/mnt/filelink/x' is not a directory"
check "fstab f6: plain file component clearly rejected" "component '/mnt/blocked' of mountpoint '/mnt/blocked/x' is not a directory"
check "fstab f7: '.' component rejected" "contains component '.', rejected"
check "fstab f7b: '..' component rejected by the pre-scan" "contains component '..', rejected"
check "fstab f7c: dangling symlink clearly rejected" "stat '/mnt/dangle' failed"
check "fstab f8: symlink-to-directory followed, mount ok" 'mount tmpfs -> /mnt/linkdir/deep (tmpfs) \[data: size=1M\] ok'

# Host-side evidence: directories really created / not created.
if [ -d "$ROOT/mnt/deep/nested" ]; then ok "host: /mnt/deep/nested really created"; else bad "host: /mnt/deep/nested not created"; fi
if [ "$(stat -c %a "$ROOT/mnt/deep")" = "755" ] && [ "$(stat -c %a "$ROOT/mnt/deep/nested")" = "755" ]; then ok "host: mountpoint stays 0755 despite guest umask 077 (explicit chmod)"; else bad "host: mountpoint mode is not 0755 (deep=$(stat -c %a "$ROOT/mnt/deep" 2>/dev/null), nested=$(stat -c %a "$ROOT/mnt/deep/nested" 2>/dev/null))"; fi
if [ ! -e "$ROOT/mnt/noauto-dir" ]; then ok "host: noauto entry leaves no ghost directory"; else bad "host: noauto entry leaves a ghost directory"; fi
if [ ! -e "$ROOT/mnt/bind-dir" ]; then ok "host: bind entry leaves no ghost directory"; else bad "host: bind entry leaves a ghost directory"; fi
if [ ! -e "$ROOT/mnt/nobind-dir" ]; then ok "host: bind+noauto entry leaves no ghost directory"; else bad "host: bind+noauto entry leaves a ghost directory"; fi
if [ ! -e "$ROOT/mnt/ghostdir" ]; then ok "host: '..' pre-scan leaves no ghost parent directory"; else bad "host: '..' pre-scan leaves a ghost parent directory"; fi
if [ -d "$ROOT/var/realdir/deep" ]; then ok "host: mkdir through a symlink creates the directory at the real target"; else bad "host: directory at the symlink target not created"; fi
if [ ! -e "$ROOT/mnt/evil" ]; then ok "host: path with '.' NOT created"; else bad "host: path with '.' created"; fi

# Guest /proc/mounts evidence: what is mounted and the per-entry failure isolation.
if [ -n "$(mount_opts /mnt/deep/nested)" ]; then ok "guest: /mnt/deep/nested mounted"; else bad "guest: /mnt/deep/nested not mounted"; fi
if [ -n "$(mount_opts /mnt/trail)" ]; then ok "guest: /mnt/trail mounted (without slash)"; else bad "guest: /mnt/trail not mounted"; fi
if [ -n "$(mount_opts /mnt/after)" ]; then ok "guest: the entry after the failing one is still mounted (per-entry isolation)"; else bad "guest: the entry after the failing one is NOT mounted"; fi
if [ -z "$(mount_opts /mnt/bind-dir)" ]; then ok "guest: /mnt/bind-dir not mounted"; else bad "guest: /mnt/bind-dir mounted"; fi
if [ -z "$(mount_opts /mnt/blocked/x)" ]; then ok "guest: /mnt/blocked/x not mounted"; else bad "guest: /mnt/blocked/x mounted"; fi

# ------------------------------------------------------------- scenario 14
printf '\n== 14. fstab: octal escape decoded + duplicate mountpoint skipped (PR3-C1/C2) ==\n'
start_root fstabesc
LOG17="$LOG"
mkdir -p "$ROOT/mnt"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/spa\040ce tmpfs size=1M 0 0
tmpfs /mnt/dup tmpfs nosuid,size=1M 0 0
tmpfs /mnt/dup tmpfs size=2M 0 0
tmpfs /mnt/\056\056/evil tmpfs size=1M 0 0
tmpfs /mnt/plain tmpfs size=1M 0 0
EOFSTAB
printf 'dumpro:once:cat /proc/mounts > /var/mounts.txt\n' > "$ROOT/etc/init.conf"

run_init
i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	[ -s "$ROOT/var/mounts.txt" ] && break
	sleep 0.2
	i=$((i + 1))
done
if [ ! -s "$ROOT/var/mounts.txt" ]; then
	sed 's/^/  | /' "$LOG"
	fail "dumpro did not write /var/mounts.txt on scenario 14 within ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "fstab g1: octal escape decoded, mount to a path with a space ok" 'mount tmpfs -> /mnt/spa ce (tmpfs) \[data: size=1M\] ok'
check_absent "fstab g1: no mount to the literal backslash name" 'mount tmpfs -> /mnt/spa\\040ce'
check "fstab g2: duplicate entry skipped with a record" 'tmpfs -> /mnt/dup skipped (duplicate mountpoint'
check "fstab g3: escape decoded to '..' then rejected by the pre-scan" "contains component '..', rejected"
check "fstab g4: the normal entry after it is still processed" 'mount tmpfs -> /mnt/plain (tmpfs) \[data: size=1M\] ok'

# Host-side evidence: directories really created / not created.
if [ -d "$ROOT/mnt/spa ce" ]; then ok "host: directory 'spa ce' (real space) really created"; else bad "host: directory 'spa ce' not created"; fi
if [ ! -e "$ROOT/mnt/spa\040ce" ]; then ok "host: no directory literally named 'spa\\040ce'"; else bad "host: a directory literally named with a backslash exists"; fi
if [ ! -e "$ROOT/mnt/evil" ]; then ok "host: the '..' escape does NOT smuggle the path through"; else bad "host: the '..' escape smuggles the path through"; fi

# Guest /proc/mounts evidence: duplicates do not stack, the first entry's
# protection is not overridden, and the space path is recorded (the kernel
# writes spaces as \040 in /proc/mounts).
if [ "$(grep -c ' /mnt/dup ' "$ROOT/var/mounts.txt")" = "1" ]; then ok "guest: /mnt/dup mounted EXACTLY once"; else bad "guest: /mnt/dup mounted other than once"; fi
dup_opts=$(mount_opts /mnt/dup)
if has_opt nosuid "$dup_opts"; then ok "guest: the first entry's protection (nosuid) is NOT overridden by the duplicate ($dup_opts)"; else bad "guest: the first entry's nosuid is lost (opts: '$dup_opts')"; fi
if grep -qF ' /mnt/spa\040ce ' "$ROOT/var/mounts.txt"; then ok "guest: the mount path with a space is recorded in /proc/mounts"; else bad "guest: the mount path with a space is not recorded"; fi

# ------------------------------------------------------------- scenario 15
printf '\n== 15. privilege dropping (:user= and :group=) (FEAT-62) ==\n'
start_root privdrop
LOG18="$LOG"
mkdir -p "$ROOT/bin" "$ROOT/var" "$ROOT/usr/bin"
chmod 0777 "$ROOT/var"
chmod 1777 "$ROOT/tmp"
for a in id cat sleep echo; do
	cp "$BUSYBOX" "$ROOT/bin/$a"
	chmod 0755 "$ROOT/bin/$a"
done
chmod 0755 "$ROOT/bin/sh"

cat > "$ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
daemon:x:1:1:daemon:/usr/sbin:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
emptyuser::1000:1000::/home/emptyuser:/bin/sh
bad_empty_uid:x::1001::/home:/bin/sh
bad_nonnum_uid:x:abc:1001::/home:/bin/sh
EOF

cat > "$ROOT/etc/group" <<'EOF'
root:x:0:
daemon:x:1:
nogroup:x:65534:
customgrp:x:5000:
emptygrp::2000:
bad_empty_gid:x::
bad_nonnum_gid:x:xyz:
EOF

cat > "$ROOT/etc/init.conf" <<'EOF'
u_name:once:/bin/sh -c "/bin/id -u > /var/u_name.txt && /bin/id -g > /var/g_name.txt":user=nobody:group=nogroup
u_uid:once:/bin/sh -c "/bin/id -u > /var/u_uid.txt && /bin/id -g > /var/g_uid.txt":user=1234:group=5678
u_cust:once:/bin/sh -c "/bin/id -u > /var/u_cust.txt && /bin/id -g > /var/g_cust.txt":user=daemon:group=customgrp
u_empty:once:/bin/sh -c "/bin/id -u > /var/u_empty.txt && /bin/id -g > /var/g_empty.txt":user=emptyuser:group=emptygrp
bad_user:once:/bin/sh -c "echo FAIL > /var/bad_user.txt":user=nonexistentuser999
bad_grp:once:/bin/sh -c "echo FAIL > /var/bad_grp.txt":user=nobody:group=nonexistentgrp999
bad_empty_u:once:/bin/sh -c "echo FAIL > /var/bad_empty_u.txt":user=bad_empty_uid
bad_nonnum_u:once:/bin/sh -c "echo FAIL > /var/bad_nonnum_u.txt":user=bad_nonnum_uid
bad_empty_g:once:/bin/sh -c "echo FAIL > /var/bad_empty_g.txt":user=nobody:group=bad_empty_gid
bad_nonnum_g:once:/bin/sh -c "echo FAIL > /var/bad_nonnum_g.txt":user=nobody:group=bad_nonnum_gid
stopper:once:/bin/sh -c "/bin/sleep 1 && echo poweroff > /run/initctl":requires=u_name,u_uid,u_cust,u_empty
EOF

run_init
wait_for 'graceful shutdown' || true
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

if [ -f "$ROOT/var/u_name.txt" ] && [ "$(cat "$ROOT/var/u_name.txt")" = "65534" ]; then
	ok "u_name dropped to user nobody (UID 65534)"
else
	bad "u_name failed to drop to user nobody"
fi

if [ -f "$ROOT/var/g_name.txt" ] && [ "$(cat "$ROOT/var/g_name.txt")" = "65534" ]; then
	ok "u_name dropped to group nogroup (GID 65534)"
else
	bad "u_name failed to drop to group nogroup"
fi

if [ -f "$ROOT/var/u_uid.txt" ] && [ "$(cat "$ROOT/var/u_uid.txt")" = "1234" ]; then
	ok "u_uid dropped to numeric UID 1234"
else
	bad "u_uid failed to drop to numeric UID 1234"
fi

if [ -f "$ROOT/var/g_uid.txt" ] && [ "$(cat "$ROOT/var/g_uid.txt")" = "5678" ]; then
	ok "u_uid dropped to numeric GID 5678"
else
	bad "u_uid failed to drop to numeric GID 5678"
fi

if [ -f "$ROOT/var/u_cust.txt" ] && [ "$(cat "$ROOT/var/u_cust.txt")" = "1" ]; then
	ok "u_cust dropped to user daemon (UID 1)"
else
	bad "u_cust failed to drop to user daemon"
fi

if [ -f "$ROOT/var/g_cust.txt" ] && [ "$(cat "$ROOT/var/g_cust.txt")" = "5000" ]; then
	ok "u_cust dropped to group customgrp (GID 5000)"
else
	bad "u_cust failed to drop to group customgrp"
fi

if [ -f "$ROOT/var/u_empty.txt" ] && [ "$(cat "$ROOT/var/u_empty.txt")" = "1000" ]; then
	ok "u_empty dropped to user emptyuser (UID 1000) with empty password/gecos field"
else
	bad "u_empty failed to drop to user emptyuser (expected UID 1000)"
fi

if [ -f "$ROOT/var/g_empty.txt" ] && [ "$(cat "$ROOT/var/g_empty.txt")" = "2000" ]; then
	ok "u_empty dropped to group emptygrp (GID 2000) with empty password field"
else
	bad "u_empty failed to drop to group emptygrp (expected GID 2000)"
fi

if [ ! -f "$ROOT/var/bad_user.txt" ]; then
	ok "service with invalid user rejected fail-closed"
else
	bad "service with invalid user was executed"
fi

if [ ! -f "$ROOT/var/bad_grp.txt" ]; then
	ok "service with invalid group rejected fail-closed"
else
	bad "service with invalid group was executed"
fi

if [ ! -f "$ROOT/var/bad_empty_u.txt" ]; then
	ok "service with empty UID in passwd rejected fail-closed"
else
	bad "service with empty UID in passwd was executed"
fi

if [ ! -f "$ROOT/var/bad_nonnum_u.txt" ]; then
	ok "service with non-numeric UID in passwd rejected fail-closed"
else
	bad "service with non-numeric UID in passwd was executed"
fi

if [ ! -f "$ROOT/var/bad_empty_g.txt" ]; then
	ok "service with empty GID in group rejected fail-closed"
else
	bad "service with empty GID in group was executed"
fi

if [ ! -f "$ROOT/var/bad_nonnum_g.txt" ]; then
	ok "service with non-numeric GID in group rejected fail-closed"
else
	bad "service with non-numeric GID in group was executed"
fi

check "invalid user rejected log recorded" "Parse err: user 'nonexistentuser999' on service 'bad_user' could not be resolved, entry rejected"
check "invalid group rejected log recorded" "Parse err: group 'nonexistentgrp999' on service 'bad_grp' could not be resolved, entry rejected"
check "empty UID rejected log recorded" "Parse err: user 'bad_empty_uid' on service 'bad_empty_u' could not be resolved, entry rejected"
check "non-numeric UID rejected log recorded" "Parse err: user 'bad_nonnum_uid' on service 'bad_nonnum_u' could not be resolved, entry rejected"
check "empty GID rejected log recorded" "Parse err: group 'bad_empty_gid' on service 'bad_empty_g' could not be resolved, entry rejected"
check "non-numeric GID rejected log recorded" "Parse err: group 'bad_nonnum_gid' on service 'bad_nonnum_g' could not be resolved, entry rejected"

# ------------------------------------------------------------- scenario 16
printf '\n== 16. sane-ctl CLI & service lifecycle control (FEAT-63) ==\n'
start_root sanectl
LOG19="$LOG"
mkdir -p "$ROOT/bin" "$ROOT/var" "$ROOT/usr/bin"
for a in id cat sleep echo; do
	cp "$BUSYBOX" "$ROOT/bin/$a"
done
cp "$REPO_ROOT/packages/ninit/x/usr/bin/sane-ctl" "$ROOT/usr/bin/sane-ctl"
chmod 0755 "$ROOT/usr/bin/sane-ctl"

cat > "$ROOT/test_ctl.sh" <<'EOFCTL'
#!/bin/sh
set -e
st1=$(/usr/bin/sane-ctl status worker)
echo "ST1=$st1" > /var/ctl.txt

/usr/bin/sane-ctl stop worker
i=0
while [ "$i" -lt 30 ]; do
	st=$(/usr/bin/sane-ctl status worker 2>/dev/null || true)
	[ "$st" = "STOPPED" ] && break
	sleep 0.1
	i=$((i + 1))
done
st2=$(/usr/bin/sane-ctl status worker)
echo "ST2=$st2" >> /var/ctl.txt

/usr/bin/sane-ctl start worker
i=0
while [ "$i" -lt 30 ]; do
	st=$(/usr/bin/sane-ctl status worker 2>/dev/null || true)
	[ "$st" = "RUNNING" ] && break
	sleep 0.1
	i=$((i + 1))
done
st3=$(/usr/bin/sane-ctl status worker)
echo "ST3=$st3" >> /var/ctl.txt

/usr/bin/sane-ctl restart worker
i=0
while [ "$i" -lt 30 ]; do
	st=$(/usr/bin/sane-ctl status worker 2>/dev/null || true)
	[ "$st" = "RUNNING" ] && break
	sleep 0.1
	i=$((i + 1))
done
st4=$(/usr/bin/sane-ctl status worker)
echo "ST4=$st4" >> /var/ctl.txt

/usr/bin/sane-ctl status > /var/all.txt
/usr/bin/sane-ctl poweroff
EOFCTL
chmod 0755 "$ROOT/test_ctl.sh"

cat > "$ROOT/etc/init.conf" <<'EOF'
worker:respawn:/bin/sleep 60
tester:once:/bin/sh /test_ctl.sh:requires=worker
EOF

run_init
wait_for 'graceful shutdown' || true
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

if [ -f "$ROOT/var/ctl.txt" ]; then
	if grep -q 'ST1=RUNNING' "$ROOT/var/ctl.txt"; then
		ok "sane-ctl status worker = RUNNING initially"
	else
		bad "sane-ctl status worker initially not RUNNING"
	fi
	if grep -q 'ST2=STOPPED' "$ROOT/var/ctl.txt"; then
		ok "sane-ctl stop worker -> STOPPED"
	else
		bad "sane-ctl stop worker did not transition to STOPPED"
	fi
	if grep -q 'ST3=RUNNING' "$ROOT/var/ctl.txt"; then
		ok "sane-ctl start worker -> RUNNING"
	else
		bad "sane-ctl start worker did not transition to RUNNING"
	fi
	if grep -q 'ST4=RUNNING' "$ROOT/var/ctl.txt"; then
		ok "sane-ctl restart worker -> RUNNING"
	else
		bad "sane-ctl restart worker did not transition to RUNNING"
	fi
else
	bad "test_ctl.sh did not generate /var/ctl.txt"
fi

if [ -f "$ROOT/var/all.txt" ] && grep -q 'worker' "$ROOT/var/all.txt"; then
	ok "sane-ctl status lists all services"
else
	bad "sane-ctl status failed to list services"
fi

check "initctl cmd stop logged" "initctl cmd: 'stop worker'"
check "initctl cmd start logged" "initctl cmd: 'start worker'"
check "initctl cmd restart logged" "initctl cmd: 'restart worker'"
check "initctl cmd poweroff logged" "initctl cmd: 'poweroff'"

# ------------------------------------------------------------- scenario 17
printf '\n== 17. sane-net & udhcpc default.script verification (FEAT-64) ==\n'
start_root sanenet
LOG20="$LOG"
mkdir -p "$ROOT/bin" "$ROOT/var" "$ROOT/usr/bin" "$ROOT/usr/share/udhcpc" "$ROOT/etc"
for a in id cat sleep echo ip; do
	cp "$BUSYBOX" "$ROOT/bin/$a"
done
cp "$REPO_ROOT/packages/ninit/x/usr/bin/sane-net" "$ROOT/usr/bin/sane-net"
chmod 0755 "$ROOT/usr/bin/sane-net"
cp "$REPO_ROOT/packages/busybox/x/usr/share/udhcpc/default.script" "$ROOT/usr/share/udhcpc/default.script"
chmod 0755 "$ROOT/usr/share/udhcpc/default.script"

cat > "$ROOT/test_net.sh" <<'EOFNET'
#!/bin/sh
set -e
/usr/bin/sane-net static lo 127.0.0.99/32 127.0.0.1 8.8.8.8
if grep -q 'nameserver 8.8.8.8' /etc/resolv.conf; then
	echo "NET_DNS=OK" > /var/net.txt
fi

interface=lo ip=127.0.0.100 subnet=32 router=127.0.0.1 dns="1.1.1.1 8.8.4.4" \
	/usr/share/udhcpc/default.script bound
if grep -q 'nameserver 1.1.1.1' /etc/resolv.conf && grep -q 'nameserver 8.8.4.4' /etc/resolv.conf; then
	echo "DHCP_DNS=OK" >> /var/net.txt
fi
echo poweroff > /run/initctl
EOFNET
chmod 0755 "$ROOT/test_net.sh"

cat > "$ROOT/etc/init.conf" <<'EOF'
nettest:once:/bin/sh /test_net.sh
EOF

TEST_UNSHARE_OPTS="-n"
run_init
wait_for 'graceful shutdown' || true
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init
TEST_UNSHARE_OPTS=""

if [ -f "$ROOT/var/net.txt" ] && grep -q 'NET_DNS=OK' "$ROOT/var/net.txt"; then
	ok "sane-net static configured interface and DNS in /etc/resolv.conf"
else
	bad "sane-net static failed"
fi

if [ -f "$ROOT/var/net.txt" ] && grep -q 'DHCP_DNS=OK' "$ROOT/var/net.txt"; then
	ok "udhcpc default.script bound event applied DNS to /etc/resolv.conf"
else
	bad "udhcpc default.script failed"
fi

# --------------------------------------------------------------- summary
printf '\n== log 1a (dependency order) ==\n'
sed 's/^/  | /' "$LOG1"
printf '\n== log 1b (dense configuration; 63 service lines s2..s64 hidden) ==\n'
grep -vE "ninit: (started s[0-9]+ \(pid|cgroup: 's[0-9]+'|s[0-9]+ \(pid [0-9]+\) exit)" \
	"$LOG2" | sed 's/^/  | /'
printf '\n== log 2 (missing dependency) ==\n'
sed 's/^/  | /' "$LOG3"
printf '\n== log 3a (/run/initctl: poweroff + reboot) ==\n'
sed 's/^/  | /' "$LOG4"
printf '\n== log 3b (/run/initctl: status + poweroff) ==\n'
sed 's/^/  | /' "$LOG5"
printf '\n== log 4a (unreadable config) ==\n'
sed 's/^/  | /' "$LOG6"
printf '\n== log 4b (dependency cycle) ==\n'
sed 's/^/  | /' "$LOG7"
printf '\n== log 5 (over-long string rejection) ==\n'
sed 's/^/  | /' "$LOG8"
printf '\n== log 6 (the 65th service) ==\n'
sed 's/^/  | /' "$LOG9"
printf '\n== log 7 (README dependency: logd -> net) ==\n'
sed 's/^/  | /' "$LOG10"
printf '\n== log 9 (line exceeds MAX_LINE) ==\n'
sed 's/^/  | /' "$LOG11"
printf '\n== log 10 (fstab option classification) ==\n'
sed 's/^/  | /' "$LOG12"
printf '\n== log 11 (EOF MAX_LINE limit) ==\n'
sed 's/^/  | /' "$LOG13"
printf '\n== log 11b (EOF MAX_LINE+1 limit) ==\n'
sed 's/^/  | /' "$LOG14"
printf '\n== log 12 (fstab: exec/suid/dev + user implications) ==\n'
sed 's/^/  | /' "$LOG15"
printf '\n== log 13 (fstab: recursive mkdir + bind rejected) ==\n'
sed 's/^/  | /' "$LOG16"
printf '\n== log 14 (fstab: octal escape + duplicate) ==\n'
sed 's/^/  | /' "$LOG17"
printf '\n== log 15 (privilege dropping) ==\n'
sed 's/^/  | /' "$LOG18"
printf '\n== log 16 (sane-ctl) ==\n'
sed 's/^/  | /' "$LOG19"
printf '\n== log 17 (sane-net) ==\n'
sed 's/^/  | /' "$LOG20"

if [ "$fail_count" -eq 0 ]; then
	printf '\nRESULT: PASS (all checks)\n'
else
	printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
	exit 1
fi
