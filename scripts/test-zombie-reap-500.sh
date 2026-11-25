#!/bin/sh
# test-zombie-reap-500.sh -- Prove ninit PID 1 reaps 500 adopted short-lived
# children in an isolated unshare + chroot + NINIT_CGROUP_BASE environment
# with zero lingering zombies.
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
THRESHOLD=${THRESHOLD:-0}
READY_TIMEOUT=${READY_TIMEOUT:-15}
CC_BIN=${CC:-gcc}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable (run: make ninit-test)"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout awk mktemp grep; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required (unshare + chroot)"

HOST_NINIT_PREEXISTED=0
[ -d /sys/fs/cgroup/ninit ] && HOST_NINIT_PREEXISTED=1

ROOT=$(mktemp -d /tmp/ninit-zombie500.XXXXXX)
chmod 0755 "$ROOT"
LOG=$(mktemp /tmp/ninit-zombie500-log.XXXXXX)
HELPER_SRC=""
HELPER_BIN=""

RUN_ID="ninit-zombie500-$$-$(date +%s%N 2>/dev/null || date +%s)"
SUITE_CG="/sys/fs/cgroup/$RUN_ID"
if [ -e "$SUITE_CG" ]; then
	fail "cgroup collision: path '$SUITE_CG' already exists before test starts"
fi
$SUDO mkdir "$SUITE_CG" || fail "failed to create isolation root '$SUITE_CG'"
SUITE_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$SUITE_CG" 2>/dev/null || true)
[ -n "$SUITE_CG_DEV_INO" ] || fail "failed to read dev:ino for '$SUITE_CG'"
SUITE_CG_BASE="$SUITE_CG/ninit"
$SUDO mkdir -p "$SUITE_CG/init"

is_test_process() {
	p=$1
	[ -n "$p" ] && [ -d "/proc/$p" ] || return 1
	p_cg_path=$(sed -n 's/^0::\([^[:space:]]*\).*$/\1/p' "/proc/$p/cgroup" 2>/dev/null | head -n 1 || true)
	[ -n "$p_cg_path" ] || return 1
	case "/sys/fs/cgroup$p_cg_path" in
		"$SUITE_CG"|"$SUITE_CG"/*) ;;
		*) return 1 ;;
	esac
	p_root=$($SUDO readlink /proc/"$p"/root 2>/dev/null || true)
	case "$p_root" in
		"$ROOT"|"$ROOT"/*|"$ROOT (deleted)"|"$ROOT/"*) return 0 ;;
	esac
	return 1
}

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
	set -f
	for pf in $(find "$cg_target" -type f -name "cgroup.procs" 2>/dev/null); do
		for p in $($SUDO cat "$pf" 2>/dev/null || true); do
			is_test_process "$p" && $SUDO kill -9 "$p" 2>/dev/null || true
		done
	done
	set +f
	find "$cg_target" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
	$SUDO rmdir "$cg_target" 2>/dev/null || true
}

cleanup() {
	clean_suite_cgroup "${SUITE_CG:-}" "${SUITE_CG_DEV_INO:-}" || true
	$SUDO umount "$ROOT/proc" 2>/dev/null || true
	rm -rf "$ROOT" "$LOG"
	[ -n "${HELPER_SRC:-}" ] && rm -f "$HELPER_SRC" || true
	[ -n "${HELPER_BIN:-}" ] && rm -f "$HELPER_BIN" || true
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
cp "$BIN" "$ROOT/ninit"
for applet in sh sleep awk cat rm tr; do
	cp "$BUSYBOX" "$ROOT/bin/$applet"
	chmod 0755 "$ROOT/bin/$applet"
done
: > "$ROOT/dev/null"

# Compile a static orphan-spawner binary when a C compiler is available so all
# 500 children are guaranteed alive until orphan_spawner exits without wait(),
# reparenting every single child directly to PID 1 (ninit) to reap.
HAVE_C_HELPER=0
if command -v "$CC_BIN" >/dev/null 2>&1; then
	HELPER_SRC=$(mktemp /tmp/ninit-orphan500.XXXXXX.c)
	HELPER_BIN=$(mktemp /tmp/ninit-orphan500-bin.XXXXXX)
	cat > "$HELPER_SRC" <<'EOF'
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    int count = argc > 1 ? atoi(argv[1]) : 500;
    int pfd[2];
    if (pipe2(pfd, O_CLOEXEC) < 0)
        return 1;

    FILE *pf = fopen("/var/spawned_pids.txt", "w");
    if (!pf)
        return 1;

    int spawned = 0;
    for (int i = 0; i < count; i++) {
        pid_t p = fork();
        if (p < 0)
            break;
        if (p == 0) {
            close(pfd[1]);
            char ch;
            while (read(pfd[0], &ch, 1) > 0) {}
            close(pfd[0]);
            _exit(0);
        }
        fprintf(pf, "%d\n", (int)p);
        spawned++;
    }
    fclose(pf);

    FILE *cf = fopen("/var/spawned_count.txt", "w");
    if (cf) {
        fprintf(cf, "%d\n", spawned);
        fclose(cf);
    }

    /* Exit without waiting: kernel closes pfd[1] and reparents all 500
       children directly to PID 1 (ninit), which must reap them all. */
    _exit(spawned == count ? 0 : 1);
}
EOF
	if "$CC_BIN" -static -O2 -Wall -Werror "$HELPER_SRC" -o "$HELPER_BIN" 2>/dev/null; then
		cp "$HELPER_BIN" "$ROOT/bin/orphan_spawner"
		chmod 0755 "$ROOT/bin/orphan_spawner"
		HAVE_C_HELPER=1
	fi
fi

cat > "$ROOT/bin/reap_driver.sh" <<'EOSVC'
#!/bin/sh
set -eu

pid1_comm=$(cat /proc/1/comm 2>/dev/null || true)
spawn_rc=0
if [ -x /bin/orphan_spawner ]; then
	/bin/orphan_spawner 500 || spawn_rc=$?
else
	(
		: > /var/spawned_pids.txt
		i=0
		while [ "$i" -lt 500 ]; do
			/bin/sleep 0.2 &
			printf '%d\n' "$!" >> /var/spawned_pids.txt
			i=$((i + 1))
		done
		printf '%d\n' "$i" > /var/spawned_count.txt
	) || spawn_rc=$?
fi

spawned=$(cat /var/spawned_count.txt 2>/dev/null || echo 0)

count_state() {
	z=0
	for stf in /proc/[0-9]*/stat; do
		[ -r "$stf" ] || continue
		st=$(awk '{print $3}' "$stf" 2>/dev/null || true)
		[ "$st" = "Z" ] && z=$((z + 1))
	done
	printf '%d\n' "$z"
}

count_remaining_500() {
	rem=0
	if [ -r /var/spawned_pids.txt ]; then
		while IFS= read -r cpid; do
			[ -n "$cpid" ] || continue
			[ -d "/proc/$cpid" ] && rem=$((rem + 1))
		done < /var/spawned_pids.txt
	fi
	printf '%d\n' "$rem"
}

# Poll up to 10 seconds until PID 1 reaps all 500 adopted children.
step=0
time_to_zero_ms=-1
zombies_at_1s=""
rem_at_1s=""
while [ "$step" -lt 200 ]; do
	z=$(count_state)
	rem=$(count_remaining_500)
	if [ "$time_to_zero_ms" -lt 0 ] && [ "$z" -eq 0 ] && [ "$rem" -eq 0 ]; then
		time_to_zero_ms=$((step * 50))
	fi
	if [ "$step" -eq 20 ]; then
		zombies_at_1s=$z
		rem_at_1s=$rem
	fi
	if [ "$time_to_zero_ms" -ge 0 ] && [ "$step" -ge 20 ]; then
		break
	fi
	/bin/sleep 0.05
	step=$((step + 1))
done

[ -n "$zombies_at_1s" ] || zombies_at_1s=$(count_state)
[ -n "$rem_at_1s" ] || rem_at_1s=$(count_remaining_500)
final_zombies=$(count_state)
final_rem=$(count_remaining_500)

{
	printf 'PID1_COMM=%s\n' "$pid1_comm"
	printf 'SPAWN_RC=%s\n' "$spawn_rc"
	printf 'SPAWNED=%s\n' "$spawned"
	printf 'TIME_TO_ZERO_MS=%s\n' "$time_to_zero_ms"
	printf 'ZOMBIES_AT_1S=%s\n' "$zombies_at_1s"
	printf 'REMAINING_AT_1S=%s\n' "$rem_at_1s"
	printf 'FINAL_ZOMBIES=%s\n' "$final_zombies"
	printf 'FINAL_REMAINING=%s\n' "$final_rem"
} > /var/zombie_audit.txt

printf 'poweroff\n' > /run/initctl
exit 0
EOSVC
chmod 0755 "$ROOT/bin/reap_driver.sh"
printf 'spawner:once:/bin/sh /bin/reap_driver.sh:timeout=30\n' > "$ROOT/etc/init.conf"

printf '== I2: spawning 500 short-lived children under isolated PID 1 (%s, c_helper=%d) ==\n' \
	"$BIN" "$HAVE_C_HELPER"

rc=0
$SUDO timeout -k 5 "$READY_TIMEOUT" unshare --pid --fork --kill-child=SIGKILL \
	--mount --propagation private \
	sh -c "echo \$\$ > '$SUITE_CG/init/cgroup.procs' 2>/dev/null || true; mount -t proc proc '$ROOT/proc' && export NINIT_CGROUP_BASE='$SUITE_CG_BASE' && exec chroot '$ROOT' /ninit" \
	>"$LOG" 2>&1 || rc=$?

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
check() { if grep -q "$2" "$LOG" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }

check "banner 'ninit start (PID 1)'" 'ninit start (PID 1)'
check "cgroup base path overridden ($SUITE_CG_BASE)" "cgroup: base path overridden: $SUITE_CG_BASE"
check "event loop entered ('main loop ready')" 'main loop ready'
check "spawner service started" 'started spawner'
check "clean shutdown via /run/initctl poweroff" 'graceful shutdown'

audit_val() {
	awk -F= -v k="$1" '$1 == k { print $2; exit }' "$ROOT/var/zombie_audit.txt" 2>/dev/null || true
}

if [ -r "$ROOT/var/zombie_audit.txt" ]; then
	pid1_comm=$(audit_val PID1_COMM)
	spawn_rc=$(audit_val SPAWN_RC)
	spawned=$(audit_val SPAWNED)
	zombies_at_1s=$(audit_val ZOMBIES_AT_1S)
	time_to_zero_ms=$(audit_val TIME_TO_ZERO_MS)
	final_zombies=$(audit_val FINAL_ZOMBIES)
	final_rem=$(audit_val FINAL_REMAINING)

	echo "zombies_at_1s=$zombies_at_1s"
	echo "time_to_zero_ms=$time_to_zero_ms"

	[ "$pid1_comm" = "ninit" ] && ok "namespace PID 1 is ninit ($pid1_comm)" || bad "namespace PID 1 is '${pid1_comm:-missing}', expected 'ninit'"
	[ "$spawn_rc" = "0" ] && [ "$spawned" = "500" ] && ok "500 short-lived orphan children spawned (rc=$spawn_rc)" || bad "expected 500 spawned children (rc=${spawn_rc:-?}, spawned=${spawned:-?})"
	[ -n "$zombies_at_1s" ] && [ "$zombies_at_1s" -le "$THRESHOLD" ] && ok "zombies_at_1s=$zombies_at_1s <= threshold=$THRESHOLD" || bad "zombies_at_1s=${zombies_at_1s:-?} > threshold=$THRESHOLD"
	[ -n "$time_to_zero_ms" ] && [ "$time_to_zero_ms" -ge 0 ] && ok "PID 1 reaped all 500 children to 0 zombies in ${time_to_zero_ms}ms" || bad "zombies/children did not reach 0 within 10s"
	[ "$final_zombies" = "0" ] && [ "$final_rem" = "0" ] && ok "final zombie count = 0 and remaining children = 0" || bad "final_zombies=${final_zombies:-?} final_rem=${final_rem:-?}"
else
	bad "guest audit file /var/zombie_audit.txt not created (unshare rc=$rc)"
fi

if [ "$HOST_NINIT_PREEXISTED" -eq 0 ]; then
	if [ -d /sys/fs/cgroup/ninit ]; then
		bad "/sys/fs/cgroup/ninit appeared on host (isolation broken)"
	else
		ok "host /sys/fs/cgroup/ninit untouched (isolated in $SUITE_CG)"
	fi
fi

if [ "$fail_count" -eq 0 ]; then
	printf 'I2 PASS: zombies_at_1s=%s time_to_zero_ms=%s threshold=%s\n' \
		"$zombies_at_1s" "$time_to_zero_ms" "$THRESHOLD"
	exit 0
else
	printf '\n== ninit log ==\n'
	sed 's/^/  | /' "$LOG" || true
	printf 'I2 FAIL: %s checks failed\n' "$fail_count"
	exit 1
fi
