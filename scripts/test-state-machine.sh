#!/bin/sh
# verify-coder1-t10-t11-t13.sh -- focused verification of the three NEW behaviours
# implemented by Coder 1 (Session 25) on top of commit 17f4ea4, which the existing
# suites do not assert directly:
#
#   T10 scenario (A): state machine telemetry
#       - log edges: "state STOPPED -> STARTING", "STARTING -> RUNNING",
#         "RUNNING -> STOPPING"
#       - /run/ninit-<name>.state published with the state NAME (RUNNING)
#   T11 scenario (B): fork() EAGAIN retry loop
#       - exactly 3 retries with 100ms / 200ms / 400ms backoff (proof: the three
#         "retrying in ..." lines; more lines would mean a busy loop)
#       - terminal "fork EAGAIN after 3 retries for <name>: ..." + FAILED
#   T13 scenario (C): :grace=N override
#       - a stub service that ignores SIGTERM is SIGKILLed at ~grace=2s, not at
#         the 5s default, and the escalation is logged once
#
# Usage: sudo sh verify-coder1-t10-t11-t13.sh [BIN]
# Exit: 0 = PASS, 1 = FAIL
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SELF_DIR/.." && pwd)
BIN=${BIN:-}
if [ -z "$BIN" ]; then
	if [ -x "./ninit-test" ]; then
		BIN="./ninit-test"
	elif [ -x "$SELF_DIR/ninit-test" ]; then
		BIN="$SELF_DIR/ninit-test"
	else
		BIN="./ninit"
	fi
fi
BUSYBOX=${BUSYBOX:-/bin/busybox}
SANE_CTL="$REPO_ROOT/packages/ninit/x/usr/bin/sane-ctl"
[ -x "$BIN" ] || BIN="$SELF_DIR/ninit"

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX'"
for t in unshare chroot timeout grep mktemp ps; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required"

RUN_ID="ninit-verify-coder1-$$-$(date +%s%N 2>/dev/null || date +%s)"
SUITE_CG="/sys/fs/cgroup/$RUN_ID"
[ -e "$SUITE_CG" ] && fail "cgroup collision: '$SUITE_CG' exists"
$SUDO mkdir "$SUITE_CG" || fail "cannot create isolation root '$SUITE_CG'"
SUITE_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$SUITE_CG" 2>/dev/null || true)
SUITE_CG_BASE="$SUITE_CG/ninit"

# fork-starvation cgroup (scenario B): a pids.max=1 leaf holds one slot, so the
# guest's first fork() returns EAGAIN deterministically.
STARVE_CG="/sys/fs/cgroup/${RUN_ID}-starve"
STARVE_CG_DEV_INO=""

ROOTS=""
LOGS=""
INNER=""
INNER2=""

clean_suite_cgroup() {
	cg_target="${1:-}"; expected_dev_ino="${2:-}"
	[ -n "$cg_target" ] && [ -d "$cg_target" ] || return 0
	if [ -L "$cg_target" ]; then
		printf 'SECURITY: %s is a symlink, cleanup aborted!\n' "$cg_target" >&2
		return 1
	fi
	if [ -n "$expected_dev_ino" ]; then
		cur=$($SUDO stat -c '%d:%i' "$cg_target" 2>/dev/null || true)
		[ "$cur" = "$expected_dev_ino" ] || {
			printf 'SECURITY: %s dev:ino changed (%s != %s)!\n' "$cg_target" "$cur" "$expected_dev_ino" >&2
			return 1
		}
	fi
	[ -f "$cg_target/cgroup.kill" ] && echo 1 | $SUDO tee "$cg_target/cgroup.kill" >/dev/null 2>&1 || true
	i=0
	while [ "$i" -lt 20 ]; do
		has=0
		set -f
		for pf in $(find "$cg_target" -type f -name cgroup.procs 2>/dev/null); do
			[ -n "$($SUDO cat "$pf" 2>/dev/null || true)" ] && { has=1; break; }
		done
		set +f
		[ "$has" -eq 0 ] && break
		sleep 0.05; i=$((i + 1))
	done
	find "$cg_target" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
	$SUDO rmdir "$cg_target" 2>/dev/null || true
}

cleanup() {
	clean_suite_cgroup "${STARVE_CG:-}" "${STARVE_CG_DEV_INO:-}" || true
	clean_suite_cgroup "${SUITE_CG:-}" "${SUITE_CG_DEV_INO:-}" || true
	for d in ${ROOTS:-}; do $SUDO umount "$d/proc" 2>/dev/null || true; rm -rf "$d"; done
	for f in ${LOGS:-}; do rm -f "$f"; done
	[ -n "${INNER:-}" ] && $SUDO rm -f "$INNER" || true
	[ -n "${INNER2:-}" ] && $SUDO rm -f "$INNER2" || true
}
trap cleanup EXIT INT TERM

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
# check_in <label> <file> <pattern> — same argument order as the repo harness.
check_in()  { if grep -q "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
absent_in() { if grep -q "$3" "$2"; then bad "$1"; else ok "$1"; fi; }

new_root() {
	d=$(mktemp -d /tmp/ninit-verify.XXXXXX)
	mkdir -p "$d/proc" "$d/sys" "$d/dev" "$d/run" "$d/tmp" "$d/etc" "$d/var/log" "$d/bin" "$d/usr/bin"
	cp "$BIN" "$d/ninit"
	cp "$BUSYBOX" "$d/bin/sh"
	for a in "$@"; do cp "$BUSYBOX" "$d/bin/$a"; done
	if [ -f "$SANE_CTL" ]; then
		cp "$SANE_CTL" "$d/usr/bin/sane-ctl"
		chmod 0755 "$d/usr/bin/sane-ctl"
	fi
	: > "$d/dev/null"
	printf '%s\n' "$d"
}

# boot_guest <root> <seconds> [pre-exec-shell-fragment] [stdin-path]
boot_guest() {
	root=$1; secs=$2; pre=${3:-}; stdin_p=${4:-/dev/null}
	inner=$(mktemp /tmp/ninit-verify-inner.XXXXXX)
	INNER2="$INNER2 $inner"
	cat > "$inner" <<EOI
#!/bin/sh
mount -t proc proc $root/proc
export NINIT_CGROUP_BASE="$SUITE_CG_BASE"
$pre
exec chroot $root /ninit
EOI
	$SUDO chmod 755 "$inner"
	$SUDO sh -c "timeout -s KILL $((secs + 5)) unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh $inner < '$stdin_p'" || true
}

printf '== test binary : %s\n' "$BIN"

# ---------------------------------------------------------------- Scenario A
# T10: state edges in the log + /run/ninit-<name>.state published while RUNNING.
printf '\n== Scenario A: state machine telemetry (T10) ==\n'
RA=$(new_root sleep cat)
LA=$(mktemp /tmp/ninit-verify-log.XXXXXX)
ROOTS="$ROOTS $RA"; LOGS="$LOGS $LA"
cat > "$RA/bin/stopper.sh" << 'EOF'
#!/bin/sh
# Wait (bounded poll, deterministic) until the respawn service is published as
# RUNNING, snapshot both state files, then stop the system.
i=0
while [ "$(cat /run/ninit-stateful.state 2>/dev/null)" != "RUNNING" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
done
cat /run/ninit-stateful.state > /var/stateful_state.txt 2>/dev/null || true
cat /run/ninit-stopper.state   > /var/stopper_state.txt  2>/dev/null || true
echo poweroff > /run/initctl
exit 0
EOF
chmod 0755 "$RA/bin/stopper.sh"
printf 'stateful:respawn:/bin/sleep 300\nstopper:once:/bin/sh /bin/stopper.sh\n' > "$RA/etc/init.conf"
boot_guest "$RA" 8 "" >"$LA" 2>&1

check_in "STOPPED -> STARTING edge logged"      "$LA" 'stateful: state STOPPED -> STARTING'
check_in "STARTING -> RUNNING edge logged"      "$LA" 'stateful: state STARTING -> RUNNING'
check_in "RUNNING -> STOPPING edge logged"      "$LA" 'stateful: state RUNNING -> STOPPING'
check_in "STOPPING -> STOPPED edge logged"      "$LA" 'stateful: state STOPPING -> STOPPED'
absent_in "no illegal transition reported"      "$LA" 'illegal state transition'
if [ "$(cat "$RA/var/stateful_state.txt" 2>/dev/null)" = "RUNNING" ]; then
	ok "/run/ninit-stateful.state = RUNNING (name, not number)"
else
	bad "/run/ninit-stateful.state content: '$(cat "$RA/var/stateful_state.txt" 2>/dev/null)'"
fi
if [ "$(cat "$RA/var/stopper_state.txt" 2>/dev/null)" = "RUNNING" ]; then
	ok "/run/ninit-stopper.state = RUNNING"
else
	bad "/run/ninit-stopper.state content: '$(cat "$RA/var/stopper_state.txt" 2>/dev/null)'"
fi
check_in "clean shutdown after state telemetry" "$LA" 'graceful shutdown'

# ---------------------------------------------------------------- Scenario B
# T11: fork() EAGAIN -> exactly 3 retries at 100/200/400 ms, then terminal FAILED.
printf '\n== Scenario B: fork EAGAIN retry + backoff (T11) ==\n'
starve_ok=0
if [ -r /sys/fs/cgroup/cgroup.controllers ] \
   && $SUDO grep -qw pids /sys/fs/cgroup/cgroup.controllers 2>/dev/null \
   && $SUDO mkdir "$STARVE_CG" 2>/dev/null; then
	STARVE_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$STARVE_CG" 2>/dev/null || true)
	if printf '1\n' | $SUDO tee "$STARVE_CG/pids.max" >/dev/null 2>&1; then starve_ok=1; fi
fi
if [ "$starve_ok" -ne 1 ]; then
	printf '  [SKIP]   pids controller unavailable/undelegated\n'
else
	RB=$(new_root)
	LB=$(mktemp /tmp/ninit-verify-log.XXXXXX)
	ROOTS="$ROOTS $RB"; LOGS="$LOGS $LB"
	printf 'boot:once:exit 0\ndep:once:echo DEP > /var/dep.txt:requires=boot\n' > "$RB/etc/init.conf"
	boot_guest "$RB" 10 "echo \$\$ > $STARVE_CG/cgroup.procs;" >"$LB" 2>&1

	check_in "retry 1/3 announced with 100ms"  "$LB" "retrying in 100ms (retry 1/3)"
	check_in "retry 2/3 announced with 200ms"  "$LB" "retrying in 200ms (retry 2/3)"
	check_in "retry 3/3 announced with 400ms"  "$LB" "retrying in 400ms (retry 3/3)"
	check_in "terminal EAGAIN line for the service" "$LB" \
		'fork EAGAIN after 3 retries for boot: Resource temporarily unavailable'
	check_in "service marked FAILED (terminal)" "$LB" 'boot: state STARTING -> FAILED'
	check_in "dependent cancelled instead of hanging" "$LB" \
		"service 'dep' cancelled: dependency 'boot' failed"
	check_in "event loop reached (no busy loop / no hang)" "$LB" 'main loop ready'
	absent_in "no DEP execution for the cancelled dependent" "$LB" 'started dep'
	nretry=$(grep -c 'retrying in' "$LB" 2>/dev/null || true)
	if [ "${nretry:-0}" -eq 3 ]; then
		ok "exactly 3 retries logged (no busy loop): $nretry"
	else
		bad "retry line count is $nretry, expected exactly 3"
	fi
	nfork=$(grep -c 'fork boot' "$LB" 2>/dev/null || true)
	if [ "${nfork:-0}" -le 3 ]; then
		ok "legacy 'fork boot' telemetry bounded: $nfork (max 3, harness contract)"
	else
		bad "'fork boot' lines: $nfork (harness expects <= 3)"
	fi
fi

# ---------------------------------------------------------------- Scenario C
# T13: :grace=2 is honoured for a service that ignores SIGTERM (default is 5s).
printf '\n== Scenario C: :grace=N override + SIGKILL escalation (T13) ==\n'
RC=$(new_root sleep)
LC=$(mktemp /tmp/ninit-verify-log.XXXXXX)
ROOTS="$ROOTS $RC"; LOGS="$LOGS $LC"
printf 'stub:respawn:trap "" TERM; exec /bin/sleep 300:grace=2\nstop:once:/bin/sh -c "/bin/sleep 1 && echo poweroff > /run/initctl"\n' \
	> "$RC/etc/init.conf"
t0=$(date +%s%N)
boot_guest "$RC" 12 "" >"$LC" 2>&1
t1=$(date +%s%N)
if printf '%s%s' "$t0" "$t1" | grep -q '^[0-9][0-9]*$'; then
	elapsed_ms=$(( (t1 - t0) / 1000000 ))
	elapsed_note=""
else
	elapsed_ms=$(( (t1 - t0) * 1000 ))
	elapsed_note=" (second-resolution clock)"
fi

check_in "stub started"                       "$LC" 'started stub'
check_in "grace expiry escalated to SIGKILL"  "$LC" 'stub: grace expired, SIGKILL'
absent_in "no illegal transition during escalation" "$LC" 'illegal state transition'
unique=$(grep -c 'stub: grace expired, SIGKILL' "$LC" 2>/dev/null || true)
if [ "${unique:-0}" -eq 1 ]; then
	ok "one escalation log for stub: $unique"
else
	bad "escalation logged $unique times, expected 1"
fi
# Timeline with :grace=2 honoured: boot (~0.3s) + stopper sleep 1s + grace 2s + teardown
#   => ~3.3-4.0s.
# If :grace=N were ignored and the 5s default used: 1s + 5s + teardown => >6.3s.
# Window [2000ms, 5500ms] therefore proves a real grace wait AND that it was 2s, not 5s.
printf '  [info]   shutdown elapsed: %sms%s\n' "$elapsed_ms" "$elapsed_note"
if [ "$elapsed_ms" -ge 2000 ] && [ "$elapsed_ms" -le 5500 ]; then
	ok "shutdown bounded by :grace=2 (${elapsed_ms}ms; 5s default would be >6300ms)"
else
	bad "shutdown elapsed ${elapsed_ms}ms does not match :grace=2 (expect 2000-5500ms)"
fi
check_in "shutdown still graceful for the other service" "$LC" 'graceful shutdown'

printf '\n== Scenario C log ==\n'
sed 's/^/  | /' "$LC"

# ---------------------------------------------------------------- Scenario D
# P1-5: /run mounted mode=0755,nosuid,nodev (/tmp nosuid,nodev), initial STOPPED
# state files published at registration so sane-ctl status/stop work for
# dependency-waiting services, and O_NOFOLLOW blocks symlink overwrite.
printf '\n== Scenario D: initial STOPPED state + /run mount flags + O_NOFOLLOW ==\n'
RD=$(new_root sleep cat stat ln grep awk)
LD=$(mktemp /tmp/ninit-verify-log.XXXXXX)
ROOTS="$ROOTS $RD"; LOGS="$LOGS $LD"
cat > "$RD/bin/check_p1_5.sh" << 'EOF'
#!/bin/sh
set -u
st_waiter=$(/usr/bin/sane-ctl status waiter 2>&1 || true)
echo "WAITER_STATUS=$st_waiter" > /var/p1_5.txt
/usr/bin/sane-ctl status > /var/p1_5_all.txt 2>&1 || true
if /usr/bin/sane-ctl stop waiter >/var/p1_5_stop.txt 2>&1; then
    echo "STOP_WAITER_RC=0" >> /var/p1_5.txt
else
    echo "STOP_WAITER_RC=1" >> /var/p1_5.txt
fi
echo "RUN_MODE=$(stat -c '%a' /run 2>/dev/null || true)" >> /var/p1_5.txt
echo "TMP_MODE=$(stat -c '%a' /tmp 2>/dev/null || true)" >> /var/p1_5.txt
echo "RUN_OPTS=$(awk '$2 == "/run" { print $4 }' /proc/mounts 2>/dev/null)" >> /var/p1_5.txt
echo "TMP_OPTS=$(awk '$2 == "/tmp" { print $4 }' /proc/mounts 2>/dev/null)" >> /var/p1_5.txt

printf 'SAFE\n' > /var/victim
rm -f /run/ninit-slow.state
ln -s /var/victim /run/ninit-slow.state
i=0
while ! grep -q 'slow (pid .* exit status=' /var/log/ninit.log 2>/dev/null && [ "$i" -lt 80 ]; do
    sleep 0.05
    i=$((i + 1))
done
sleep 0.1
echo poweroff > /run/initctl
exit 0
EOF
chmod 0755 "$RD/bin/check_p1_5.sh"
cat > "$RD/etc/init.conf" << 'EOF'
slow:once:/bin/sleep 2
waiter:once:/bin/true:requires=slow
ctl:once:/bin/sh /bin/check_p1_5.sh
EOF
boot_guest "$RD" 10 "" >"$LD" 2>&1

check_in "dep-waiting service reports initial STOPPED via sane-ctl status" "$RD/var/p1_5.txt" '^WAITER_STATUS=STOPPED$'
check_in "sane-ctl status lists waiter as STOPPED" "$RD/var/p1_5_all.txt" 'waiter.*STOPPED'
check_in "sane-ctl stop waiter succeeds on initial STOPPED service" "$RD/var/p1_5.txt" '^STOP_WAITER_RC=0$'
check_in "/run tmpfs mounted mode 0755" "$RD/var/p1_5.txt" '^RUN_MODE=755$'
check_in "/tmp tmpfs mounted mode 1777" "$RD/var/p1_5.txt" '^TMP_MODE=1777$'
check_in "/run tmpfs has nosuid" "$RD/var/p1_5.txt" '^RUN_OPTS=.*nosuid'
check_in "/run tmpfs has nodev" "$RD/var/p1_5.txt" '^RUN_OPTS=.*nodev'
check_in "/tmp tmpfs has nosuid" "$RD/var/p1_5.txt" '^TMP_OPTS=.*nosuid'
check_in "/tmp tmpfs has nodev" "$RD/var/p1_5.txt" '^TMP_OPTS=.*nodev'
if [ "$(cat "$RD/var/victim" 2>/dev/null)" = "SAFE" ]; then
	ok "O_NOFOLLOW protected /var/victim from symlink state overwrite"
else
	bad "/var/victim was modified through symlink: '$(cat "$RD/var/victim" 2>/dev/null)'"
fi
check_in "O_NOFOLLOW failure logged for symlinked state file" "$LD" 'cannot write state file /run/ninit-slow.state'

# ---------------------------------------------------------------- Scenario E
# P1-4: sane-ctl stop must honor :grace=N > 5s without hardcoded 5s timeout.
printf '\n== Scenario E: sane-ctl stop honors :grace=6 (> 5s) ==\n'
RE=$(new_root sleep cat)
LE=$(mktemp /tmp/ninit-verify-log.XXXXXX)
ROOTS="$ROOTS $RE"; LOGS="$LOGS $LE"
cat > "$RE/bin/stop6.sh" << 'EOF'
#!/bin/sh
i=0
while [ "$(/usr/bin/sane-ctl status stub6 2>/dev/null || true)" != "RUNNING" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
done
if /usr/bin/sane-ctl stop stub6 >/var/stop6.out 2>&1; then
    echo "STOP6_RC=0" > /var/stop6.res
else
    echo "STOP6_RC=1" > /var/stop6.res
fi
echo "STOP6_STATE=$(/usr/bin/sane-ctl status stub6 2>/dev/null || true)" >> /var/stop6.res
/usr/bin/sane-ctl poweroff
exit 0
EOF
chmod 0755 "$RE/bin/stop6.sh"
cat > "$RE/etc/init.conf" << 'EOF'
stub6:respawn:trap "" TERM; exec /bin/sleep 60:grace=6
ctl:once:/bin/sh /bin/stop6.sh
EOF
boot_guest "$RE" 14 "" >"$LE" 2>&1

check_in "sane-ctl stop waited past 5s and exited 0 for :grace=6" "$RE/var/stop6.res" '^STOP6_RC=0$'
check_in "stub6 state became STOPPED after :grace=6 SIGKILL" "$RE/var/stop6.res" '^STOP6_STATE=STOPPED$'
check_in "ninit escalated stop grace at 6s" "$LE" 'stub6: stop grace expired, SIGKILL'
check_in "stub6 transitioned STOPPING -> STOPPED" "$LE" 'stub6: state STOPPING -> STOPPED'
check_in "clean graceful shutdown after :grace=6 stop" "$LE" 'graceful shutdown'

# ---------------------------------------------------------------- Scenario F
# P1-3: timed-out :on_fail=rescue preserves FAILED, stops active services,
# gates start/restart in rescue_loop, and shuts down cleanly via initctl.
printf '\n== Scenario F: :on_fail=rescue lifecycle & rescue initctl gating ==\n'
RF=$(new_root sleep cat)
LF=$(mktemp /tmp/ninit-verify-log.XXXXXX)
ROOTS="$ROOTS $RF"; LOGS="$LOGS $LF"
cat > "$RF/etc/init.conf" << 'EOF'
bg:respawn:/bin/sleep 30
crit:once:/bin/sleep 20:on_fail=rescue:timeout=1
EOF
mkfifo "$RF/rescue.stdin"
(
    i=0
    while ! grep -q 'Entering rescue mode (shell)' "$LF" 2>/dev/null && [ "$i" -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    printf '/usr/bin/sane-ctl start bg\n/usr/bin/sane-ctl restart bg\n/usr/bin/sane-ctl poweroff\n'
    sleep 3
) > "$RF/rescue.stdin" &
FEED_PID=$!
boot_guest "$RF" 12 "" "$RF/rescue.stdin" >"$LF" 2>&1
kill "$FEED_PID" 2>/dev/null || true
wait "$FEED_PID" 2>/dev/null || true

check_in "crit timed out and marked FAILED" "$LF" 'crit: state STOPPING -> FAILED'
check_in "bg stopped cleanly during rescue handoff" "$LF" 'bg: state STOPPING -> STOPPED'
absent_in "no illegal transition during rescue handoff" "$LF" 'illegal state transition'
check_in "start gated in rescue mode" "$LF" "initctl: cannot start service 'bg' in rescue mode"
check_in "restart gated in rescue mode" "$LF" "initctl: cannot restart service 'bg' in rescue mode"
check_in "clean graceful shutdown from rescue via sane-ctl poweroff" "$LF" 'graceful shutdown'
absent_in "no grace expiry stall on shutdown from rescue" "$LF" 'grace expired, SIGKILL'

if [ "$fail_count" -eq 0 ]; then
	printf '\nRESULT: PASS (all checks)\n'
else
	printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
	exit 1
fi
