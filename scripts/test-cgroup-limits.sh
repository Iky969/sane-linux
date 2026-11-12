#!/bin/sh
# test-cgroup-limits.sh -- cgroup v2 resource limit tests (memory, cpu, pids)
# and orphan lifecycle cleanup when a service respawns.
#
# Why this suite exists: Requirement R4 demands an automated test suite to
# verify that:
#   1. memory_max limits overallocation and triggers a deterministic OOM kill
#      (exit status 0x9 / 137).
#   2. pids_max limits excessive forks and deterministically rejects new
#      processes with EAGAIN (Resource temporarily unavailable).
#   3. cgroup_kill_service cleans up the child/orphan processes left behind by
#      a respawn service's leader before the new generation is started.
#   4. The leaf cgroup configuration (memory.max, cpu.max, pids.max) is written
#      correctly to the service's cgroup v2 hierarchy and supports free option order.
#   5. Parser validation accepts valid limit formats and rejects broken
#      (malformed) ones with an informative warning log, without crashing PID 1.
#   6. Subtree control writing tolerates a nested/container environment and
#      partial subtree control without breaking the boot.
#   7. PR #9 interaction: a once service with pids_max=1 that hits fork EAGAIN
#      retries up to MAX_SPAWN_RETRY (3x), transitions to FAILED, and
#      deterministically cancels its dependent services.
#   8. Orphan lifecycle cleanup on a once service (cgroup_kill_service before
#      rmdir) sweeps the orphan child processes clean before the leaf rmdir.
#   9. Descendant escape test with a fast double-fork + setsid daemonize
#      workload, ensuring every descendant process is in the leaf cgroup.procs
#      via the T1 handshake and cgroup_kill_service sweeps the whole process
#      tree with no leftovers (LINGERING_ESCAPE_ORPHANS=0). Cleanup is also
#      verified from the cgroup side: cgroup.events (populated 0) and an empty
#      cgroup.procs BEFORE the leaf rmdir.
#  10. Multi-tier hierarchical resource limits:
#      - 10A: Hierarchical pids.max nested fork rejection with EAGAIN
#             (NESTED_EAGAIN_CONFIRMED depth=3).
#      - 10B: Cumulative parallel memory.max deterministic OOM: the leader
#             orchestrates 3 workers x 12MB (36MB > 32MB limit) so the OOM
#             killer kills a worker; the control of 2 workers x 12MB (24MB)
#             passes without OOM. The leader does not allocate large amounts
#             and does not call raise(SIGKILL).
#  11. Fail-open fallback when cgroup v2 is unavailable:
#      - Detect the /sys/fs/cgroup mount failure and log the active fail-open.
#      - Warn about the ignored resource limits.
#      - Service execution still runs normally through the pre-exec handshake.
#      - The kill(-pgid) fallback on a once service when the leader dies,
#        ensuring background (orphan) processes are swept clean with no cgroup.
# 12. T14: leaf cgroup directory cleanup hygiene -- after a service stops and
#     its processes are gone, the leaf directory is deterministically removed
#     (rmdir succeeds after cgroup.kill, no EBUSY; failures log a warning and
#     never crash PID 1).
# 13. T14B: controller delegation verification -- the leaf cgroup.controllers
#     file must list the controllers delegated by the parent subtree
#     (memory, pids, cpu); an available controller that is missing is a failure.
#
# Usage:
#   sudo sh ./scripts/test-cgroup-limits.sh      # or: make test
#
# Environment variables:
#   BIN=./ninit              binary under test
#   BUSYBOX=/bin/busybox     static busybox (apt-get install busybox-static)
#   WAIT1..WAIT11            observation time window per scenario (seconds)
#
# Note: this suite uses unshare with `--mount --propagation private` and a
# manual `mount -t proc` (not `--mount-proc`), consistent with the repo
# convention to avoid EINVAL rejections on certain kernels.

set -eu

BIN=${BIN:-./ninit}
BUSYBOX=${BUSYBOX:-/bin/busybox}
WAIT1=${WAIT1:-6}
WAIT2=${WAIT2:-6}
WAIT3=${WAIT3:-8}
WAIT4=${WAIT4:-6}
WAIT5=${WAIT5:-6}
WAIT6=${WAIT6:-6}
WAIT7=${WAIT7:-12}
WAIT8=${WAIT8:-6}
WAIT9=${WAIT9:-8}
WAIT10A=${WAIT10A:-6}
WAIT10B=${WAIT10B:-8}
WAIT11=${WAIT11:-6}


if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary '$BIN' not found/not executable (run: make)"
[ -f "$BUSYBOX" ] || fail "static busybox missing at '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout grep mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "tool '$t' not found"
done
$SUDO true 2>/dev/null || fail "root or passwordless sudo required (unshare + chroot)"

# Safety guard: this suite writes cgroup.kill and rmdir under /sys/fs/cgroup/ninit.
# If the host's PID 1 is ninit, this suite would kill the host's init
# (kernel panic). Abort before touching any host cgroup.
pid1_comm=$(cat /proc/1/comm 2>/dev/null || true)
if [ "$pid1_comm" = "ninit" ]; then
	fail "the host's PID 1 is 'ninit' -- this suite is forbidden on a live host (host isolation guard)"
fi

CG_CONTROLLERS="/sys/fs/cgroup/cgroup.controllers"
has_cg2=0
has_mem=0
has_pids=0
has_cpu=0
if [ -r "$CG_CONTROLLERS" ]; then
	has_cg2=1
	$SUDO grep -qw memory "$CG_CONTROLLERS" 2>/dev/null && has_mem=1 || true
	$SUDO grep -qw pids "$CG_CONTROLLERS" 2>/dev/null && has_pids=1 || true
	$SUDO grep -qw cpu "$CG_CONTROLLERS" 2>/dev/null && has_cpu=1 || true
fi

ROOTS=""
LOGS=""
HELPERS=""
CG_DYNAMIC=""

# Snapshot the existence of /sys/fs/cgroup/ninit on the host before testing starts
HOST_NINIT_PREEXISTED=0
[ -d /sys/fs/cgroup/ninit ] && HOST_NINIT_PREEXISTED=1

# Sentinel Guard: an independent external cgroup on the host to prove
# deterministically that the test suite NEVER touches a cgroup outside RUN_CG.
EXTERNAL_GUARD_CG="/sys/fs/cgroup/ninit-ext-guard-$$"
if [ -e "$EXTERNAL_GUARD_CG" ]; then
	fail "sentinel guard cgroup '$EXTERNAL_GUARD_CG' already exists (collision)"
fi
$SUDO mkdir "$EXTERNAL_GUARD_CG" || fail "failed to create the sentinel guard cgroup"

# -----------------------------------------------------------------------------
# 1. $RUN_CG isolation (Test Exclusive Root) & inode identity verification
# -----------------------------------------------------------------------------
RUN_ID="ninit-test-$$-$(date +%s%N 2>/dev/null || date +%s)"
RUN_CG="/sys/fs/cgroup/$RUN_ID"
RUN_CG_BASE="$RUN_CG/ninit"
NINIT_BASE="$RUN_CG_BASE"
TEST_TRACKED_LEAVES=""

# Point 8: TEST_LEAVES is purely an assertion expectation list (not a host sweep)
TEST_LEAVES="mem_test pids_test leak limits_audit valid_svc bad_mem1 bad_mem2 bad_mem3
bad_cpu1 bad_cpu2 bad_cpu3 bad_pid1 bad_pid2 bad_pid3 stopper svc_nested boot_pr9 app_dep
orphan_maker checker escape_svc pids_tree mem_cumul failopen_svc"

# Point 2: Strict mkdir without -p, abort on collision
if [ -e "$RUN_CG" ]; then
	fail "cgroup collision: path '$RUN_CG' already exists before the test starts (abort)"
fi

$SUDO mkdir "$RUN_CG" || fail "failed to create the cgroup isolation root '$RUN_CG'"

# Point 3: Record the dev:ino identity right after creation for TOCTOU/symlink protection
RUN_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$RUN_CG" 2>/dev/null || true)
[ -n "$RUN_CG_DEV_INO" ] || fail "failed to read dev:ino for '$RUN_CG'"

# Enable the memory, pids, cpu controllers on $RUN_CG
for c in memory pids cpu; do
	if grep -qw "$c" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		echo "+$c" | $SUDO tee "$RUN_CG/cgroup.subtree_control" >/dev/null 2>&1 || true
	fi
done

# Create the ninit service base cgroup under $RUN_CG
$SUDO mkdir "$RUN_CG_BASE" || fail "failed to create the base cgroup '$RUN_CG_BASE'"
for c in memory pids cpu; do
	if grep -qw "$c" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		echo "+$c" | $SUDO tee "$RUN_CG_BASE/cgroup.subtree_control" >/dev/null 2>&1 || true
	fi
done

INNER=$(mktemp /tmp/ninit-cginner.XXXXXX)

# Process ownership verification: proves whether the process with PID $1 runs
# inside the test isolation cgroup ($RUN_CG) AND inside one of the test guest
# roots ($ROOTS). Fail-closed: a dead/missing PID, a cgroup outside RUN_CG, or
# a root outside $ROOTS are all REJECTED (return 1).
is_test_process() {
	p=$1
	# PID reuse guard: a missing /proc/$p must NOT be considered part of the test.
	# This condition returns 1 (fail-closed), not 0.
	[ -n "$p" ] && [ -d "/proc/$p" ] || return 1

	# Verify cgroup membership (cgroup v2, format "0::$path"):
	# /sys/fs/cgroup$path must be inside or a descendant of $RUN_CG.
	if [ -n "${RUN_CG:-}" ] && [ -d "$RUN_CG" ]; then
		p_cg_path=""
		if [ -r "/proc/$p/cgroup" ]; then
			p_cg_path=$(sed -n 's/^0::\([^[:space:]]*\).*$/\1/p' "/proc/$p/cgroup" 2>/dev/null | head -n 1)
		fi
		[ -n "$p_cg_path" ] || return 1
		case "/sys/fs/cgroup$p_cg_path" in
			"$RUN_CG"|"$RUN_CG"/*)
				;;
			*)
				return 1
				;;
		esac
		[ -d "/sys/fs/cgroup$p_cg_path" ] || return 1
	else
		return 1
	fi

	# Verify the chroot root: /proc/$p/root must be under one of $ROOTS.
	p_root=$($SUDO readlink /proc/"$p"/root 2>/dev/null || true)
	[ -n "$p_root" ] || return 1
	for r in ${ROOTS:-}; do
		case "$p_root" in
			"$r"|"$r"/*|"$r (deleted)"|"$r/"*|"/tmp/ninit-cgtest."*)
				return 0
				;;
		esac
	done
	return 1
}

# Point 5 & 6: Parent-first cgroup.kill cleanup, then depth-first rmdir
clean_run_cgroup() {
	# Point 4: The ${RUN_CG:-} and ${RUN_CG_DEV_INO:-} guards are safe in every setup phase
	[ -n "${RUN_CG:-}" ] || return 0
	[ -n "${RUN_CG_DEV_INO:-}" ] || return 0
	[ -d "$RUN_CG" ] || return 0

	# Point 1 & 3: Ensure the path is not a symlink and the inode identity is unchanged
	if [ -L "$RUN_CG" ]; then
		printf 'SECURITY: %s is a symlink! The cleanup operation is aborted.\n' "$RUN_CG" >&2
		return 1
	fi
	cur_dev_ino=$($SUDO stat -c '%d:%i' "$RUN_CG" 2>/dev/null || true)
	if [ "$cur_dev_ino" != "$RUN_CG_DEV_INO" ]; then
		printf 'SECURITY: dev:ino %s changed (initial: %s, now: %s)! Operation aborted.\n' 			"$RUN_CG" "$RUN_CG_DEV_INO" "$cur_dev_ino" >&2
		return 1
	fi

	# Point 5: The cgroup.kill path (kernel >= 5.14) -- kill ALL processes in the
	# whole $RUN_CG subtree at once. If cgroup.kill is available AND succeeds in
	# emptying the cgroup.procs under $RUN_CG, the manual fallback scan is NEVER run.
	kill_ok=0
	if [ -f "$RUN_CG/cgroup.kill" ]; then
		echo 1 | $SUDO tee "$RUN_CG/cgroup.kill" >/dev/null 2>&1 || true
		# Wait for the cgroup.procs under $RUN_CG to become empty (polling <= ~1s).
		waited=0
		while [ "$waited" -lt 20 ]; do
			remaining=0
			for pfile in $(find "$RUN_CG" -type f -name "cgroup.procs" 2>/dev/null); do
				procs=$($SUDO cat "$pfile" 2>/dev/null || true)
				for p in $procs; do
					[ -n "$p" ] && remaining=$((remaining + 1))
				done
			done
			[ "$remaining" -eq 0 ] && { kill_ok=1; break; }
			sleep 0.05
			waited=$((waited + 1))
		done
	fi

	# Fallback (kernel < 5.14 or cgroup.kill failed to empty the processes):
	# scan the cgroup.procs under $RUN_CG and kill only test-owned processes.
	if [ "$kill_ok" -ne 1 ]; then
		for pfile in $(find "$RUN_CG" -type f -name "cgroup.procs" 2>/dev/null); do
			procs=$($SUDO cat "$pfile" 2>/dev/null || true)
			for p in $procs; do
				if is_test_process "$p"; then
					$SUDO kill -9 "$p" 2>/dev/null || true
				fi
			done
		done
	fi

	# Point 6: Depth-first rmdir strictly within the $RUN_CG boundary
	find "$RUN_CG" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || {
		sleep 0.1
		find "$RUN_CG" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
	}

	$SUDO rmdir "$RUN_CG" 2>/dev/null || {
		sleep 0.1
		$SUDO rmdir "$RUN_CG" 2>/dev/null || true
	}
}

cleanup() {
	# 1. Clean up the test isolation cgroup hierarchy.
	# Trap safety: a dev:ino / inode failure must NOT abort the whole trap via
	# set -e. The other resource cleanup stages still run.
	clean_run_cgroup || printf 'WARN: clean_run_cgroup failed (status %d), continuing with the other resource cleanup...\n' $? >&2

	# 2. Unmount and clean up the test guest directories
	for d in ${ROOTS:-}; do
		$SUDO umount -R "$d" 2>/dev/null || $SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d" 2>/dev/null || true
	done
	for f in ${LOGS:-}; do rm -f "$f" 2>/dev/null || true; done
	for h in ${HELPERS:-}; do rm -f "$h" 2>/dev/null || true; done
	$SUDO rm -f "$INNER" 2>/dev/null || true

	# 3. Clean up the additional dynamic/ephemeral cgroups
	for cg in ${CG_DYNAMIC:-}; do
		if [ -d "$cg" ] && [ ! -L "$cg" ]; then
			if [ -f "$cg/cgroup.kill" ]; then
				echo 1 | $SUDO tee "$cg/cgroup.kill" >/dev/null 2>&1 || true
			fi
			$SUDO rmdir "$cg" 2>/dev/null || true
		fi
	done

	# 4. Clean up the sentinel guard if it still exists
	if [ -n "${EXTERNAL_GUARD_CG:-}" ] && [ -d "$EXTERNAL_GUARD_CG" ] && [ ! -L "$EXTERNAL_GUARD_CG" ]; then
		$SUDO rmdir "$EXTERNAL_GUARD_CG" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

fail_count=0
ok()   { printf '  [ OK ]   %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  [SKIP]   %s\n' "$1"; }
check_in()  { if grep -q "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
absent_in() { if grep -q "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi; }
before_in() {
	desc=$1; file=$2; first=$3; second=$4
	if awk -v a="$first" -v b="$second" '$0 ~ a {seen=1} seen && $0 ~ b {found=1; exit} END {exit !(seen && found)}' "$file" 2>/dev/null; then
		ok "$desc"
	else
		bad "$desc"
	fi
}

# T14B: assert that a controller is present in the leaf cgroup.controllers
# file. Controllers that are unavailable on the host are skipped (the suite
# already detects them from /sys/fs/cgroup/cgroup.controllers); an available
# controller that was NOT delegated down the subtree is a hard failure.
check_controller() {
	desc=$1; file=$2; ctrl=$3; avail=$4
	if [ "$avail" -eq 1 ]; then
		if grep -qw "$ctrl" "$file" 2>/dev/null; then
			ok "$desc"
		else
			bad "$desc"
		fi
	else
		skip "$desc (controller not available on host)"
	fi
}

new_root() {
	d=$(mktemp -d /tmp/ninit-cgtest.XXXXXX)
	mkdir -p "$d/proc" "$d/sys" "$d/dev" "$d/run" "$d/tmp" "$d/etc" \
	         "$d/var/log" "$d/bin"
	cp "$BIN" "$d/ninit"
	cp "$BUSYBOX" "$d/bin/sh"
	for a in "$@"; do cp "$BUSYBOX" "$d/bin/$a"; done
	: > "$d/dev/null"
	printf '%s\n' "$d"
}

new_log() {
	mktemp /tmp/ninit-cgtest-log.XXXXXX
}

boot_guest() {
	root=$1; secs=$2; cg=${3:-}; extra_setup=${4:-}

	# Register the cgroup leaves from init.conf into TEST_TRACKED_LEAVES
	if [ -f "$root/etc/init.conf" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
				\#*|"") continue ;;
			esac
			svc_name=$(printf '%s\n' "$line" | cut -d: -f1)
			[ -n "$svc_name" ] || continue
			case " ${TEST_TRACKED_LEAVES:-} " in
				*" $svc_name "*) ;;
				*) TEST_TRACKED_LEAVES="${TEST_TRACKED_LEAVES:-} $svc_name" ;;
			esac
		done < "$root/etc/init.conf"
	fi

	if [ -n "$cg" ]; then
		move="echo \$\$ > $cg/cgroup.procs;"
	else
		move=""
	fi
	cat > "$INNER" <<EOI
#!/bin/sh
mount -t proc proc $root/proc
export NINIT_CGROUP_BASE="$RUN_CG_BASE"
$move
$extra_setup
exec chroot $root /ninit
EOI
	$SUDO chmod 755 "$INNER"
	$SUDO sh -c "timeout -s KILL $((secs + 4)) unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh $INNER" || true
}

# Prepare static helper binaries for overallocation and fork tests
HOG_BIN=""
FORK_BIN=""
ESCAPE_BIN=""
FORK_TREE_BIN=""
CUMUL_MEM_BIN=""
if command -v gcc >/dev/null 2>&1; then
	HOG_SRC=$(mktemp /tmp/ninit-hog.XXXXXX.c)
	HOG_BIN=$(mktemp /tmp/ninit-hog-bin.XXXXXX)
	FORK_SRC=$(mktemp /tmp/ninit-fork.XXXXXX.c)
	FORK_BIN=$(mktemp /tmp/ninit-fork-bin.XXXXXX)
	ESCAPE_SRC=$(mktemp /tmp/ninit-escape.XXXXXX.c)
	ESCAPE_BIN=$(mktemp /tmp/ninit-escape-bin.XXXXXX)
	FORK_TREE_SRC=$(mktemp /tmp/ninit-forktree.XXXXXX.c)
	FORK_TREE_BIN=$(mktemp /tmp/ninit-forktree-bin.XXXXXX)
	CUMUL_MEM_SRC=$(mktemp /tmp/ninit-cumulmem.XXXXXX.c)
	CUMUL_MEM_BIN=$(mktemp /tmp/ninit-cumulmem-bin.XXXXXX)
	HELPERS="$HELPERS $HOG_SRC $HOG_BIN $FORK_SRC $FORK_BIN $ESCAPE_SRC $ESCAPE_BIN $FORK_TREE_SRC $FORK_TREE_BIN $CUMUL_MEM_SRC $CUMUL_MEM_BIN"

	cat > "$HOG_SRC" << 'EOF'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    /* Allocate aggressively without a pause so the memory.max limit (16M) is
       exceeded and the OOM killer is triggered deterministically */
    for (int i = 0; i < 256; i++) {
        void *p = malloc(1024 * 1024);
        if (!p) return 1;
        memset(p, 0x55, 1024 * 1024);
    }
    return 0;
}
EOF
	gcc -static -O2 "$HOG_SRC" -o "$HOG_BIN" 2>/dev/null || HOG_BIN=""

	cat > "$FORK_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
int main(void) {
    pid_t pids[10]; int count = 0;
    int eagain = 0;
    for (int i = 0; i < 10; i++) {
        pid_t p = fork();
        if (p < 0) {
            if (errno == EAGAIN) eagain = 1;
            break;
        } else if (p == 0) {
            sleep(2);
            _exit(0);
        } else {
            pids[count++] = p;
        }
    }
    FILE *f = fopen("/var/pids_audit.txt", "w");
    if (f) {
        if (eagain) fprintf(f, "EAGAIN_CONFIRMED count=%d\n", count);
        else fprintf(f, "FAILED_WITHOUT_EAGAIN\n");
        fclose(f);
    }
    for (int i = 0; i < count; i++) waitpid(pids[i], NULL, 0);
    return 0;
}
EOF
	gcc -static -O2 "$FORK_SRC" -o "$FORK_BIN" 2>/dev/null || FORK_BIN=""

	cat > "$ESCAPE_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int main(void) {
    /* =========================================================================
     * FIRST INSTRUCTION (BEFORE FORK):
     * Read /proc/self/cgroup and verify that the process is ALREADY in a leaf
     * cgroup (/ninit/... or escape_svc).
     * A binary without the handshake sees the root cgroup (0::/) -> deterministic FAIL.
     * A binary with the T1 handshake is guaranteed to be in the leaf -> PASS.
     * ========================================================================= */
    int in_leaf = 0;
    char cgroup_line[256] = {0};
    FILE *fcg = fopen("/proc/self/cgroup", "r");
    if (fcg) {
        while (fgets(cgroup_line, sizeof(cgroup_line), fcg)) {
            if (strstr(cgroup_line, "/ninit/") || strstr(cgroup_line, "escape_svc")) {
                in_leaf = 1;
                break;
            }
        }
        fclose(fcg);
    }

    if (!in_leaf) {
        /* Binary without the handshake: root cgroup / not yet in a leaf cgroup -> FAIL */
        FILE *fa = fopen("/var/escape_audit.txt", "w");
        if (fa) {
            fprintf(fa, "PRE_FORK_LEAF_CGROUP=0\nFAILED_REASON=not_in_leaf_cgroup\n");
            fflush(fa);
            fclose(fa);
        }
        return 1; /* Exit immediately, no child or grandchild fork */
    }

    pid_t leader_pid = getpid();

    /* Generation 2: Child */
    pid_t child = fork();
    if (child < 0) return 1;
    if (child > 0) {
        /* Leader: wait until the grandchild finishes writing the audit evidence, then exit 0 */
        int waited = 0;
        while (access("/var/escape_audit.txt", F_OK) != 0 && waited < 40) {
            usleep(50000);
            waited++;
        }
        usleep(50000);
        return 0;
    }

    /* Child creates new session */
    setsid();

    /* Generation 3: Grandchild daemon */
    pid_t grandchild = fork();
    if (grandchild < 0) return 1;
    if (grandchild > 0) {
        /* Child exits immediately, reparenting grandchild as orphan */
        return 0;
    }

    /* Grandchild establishes its own session */
    setsid();
    pid_t gc_pid = getpid();

    /* Verify grandchild cgroup membership via /proc/self/cgroup */
    int gc_in_leaf = 0;
    fcg = fopen("/proc/self/cgroup", "r");
    if (fcg) {
        char buf[256];
        while (fgets(buf, sizeof(buf), fcg)) {
            if (strstr(buf, "/ninit/") || strstr(buf, "escape_svc")) {
                gc_in_leaf = 1;
                break;
            }
        }
        fclose(fcg);
    }

    /* Verify grandchild PID is present in escape_svc/cgroup.procs */
    const char *cg_base = getenv("NINIT_CGROUP_BASE");
    char esc_procs_path[320];
    snprintf(esc_procs_path, sizeof(esc_procs_path), "%s/escape_svc/cgroup.procs",
             cg_base ? cg_base : "/sys/fs/cgroup/ninit");
    int in_procs = 0;
    for (int retry = 0; retry < 10 && !in_procs; retry++) {
        FILE *fp = fopen(esc_procs_path, "r");
        if (fp) {
            int p;
            while (fscanf(fp, "%d", &p) == 1) {
                if (p == gc_pid) { in_procs = 1; break; }
            }
            fclose(fp);
        }
        if (!in_procs) usleep(10000);
    }

    FILE *fa = fopen("/var/escape_audit.txt", "w");
    if (fa) {
        fprintf(fa, "LEADER=%d\nCHILD=%d\nGRANDCHILD=%d\nPRE_FORK_LEAF_CGROUP=1\nIN_LEAF_CGROUP=%d\nIN_CGROUP_PROCS=%d\nGRANDCHILD_ACTIVE=1\n",
                leader_pid, getppid(), gc_pid, gc_in_leaf, in_procs);
        fflush(fa);
        fclose(fa);
    }

    /* Grandchild daemon stays alive until killed by cgroup_kill_service */
    while (1) {
        sleep(60);
    }
    return 0;
}
EOF
	gcc -static -O2 "$ESCAPE_SRC" -o "$ESCAPE_BIN" 2>/dev/null || ESCAPE_BIN=""

	cat > "$FORK_TREE_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

int main(void) {
    pid_t p1 = getpid();
    FILE *f = fopen("/var/pids_tree_audit.txt", "w");
    if (f) { fprintf(f, "GEN1_PID=%d\n", p1); fflush(f); fclose(f); }

    /* Leader forks Child (Gen 2) */
    pid_t p2 = fork();
    if (p2 < 0) return 1;
    if (p2 == 0) {
        FILE *f2 = fopen("/var/pids_tree_audit.txt", "a");
        if (f2) { fprintf(f2, "GEN2_PID=%d\n", getpid()); fflush(f2); fclose(f2); }

        /* Child forks Grandchild (Gen 3) */
        pid_t p3 = fork();
        if (p3 < 0) return 1;
        if (p3 == 0) {
            FILE *f3 = fopen("/var/pids_tree_audit.txt", "a");
            if (f3) { fprintf(f3, "GEN3_PID=%d\n", getpid()); fflush(f3); fclose(f3); }

            /* The cgroup pids_max=3 quota.
               There are currently 3 processes: p1 (leader), p2 (child), p3 (grandchild).
               The grandchild (depth 3) tries to fork a great-grandchild (Gen 4). */
            errno = 0;
            pid_t p4 = fork();
            FILE *f4 = fopen("/var/pids_tree_audit.txt", "a");
            if (p4 < 0) {
                if (errno == EAGAIN) {
                    if (f4) fprintf(f4, "NESTED_EAGAIN_CONFIRMED depth=3 errno=%d\n", errno);
                } else {
                    if (f4) fprintf(f4, "NESTED_FORK_FAILED_OTHER errno=%d\n", errno);
                }
            } else if (p4 == 0) {
                _exit(0);
            } else {
                if (f4) fprintf(f4, "UNEXPECTED_FORK_SUCCESS pid=%d\n", p4);
                waitpid(p4, NULL, 0);
            }
            if (f4) { fflush(f4); fclose(f4); }
            _exit(0);
        }
        waitpid(p3, NULL, 0);
        _exit(0);
    }
    waitpid(p2, NULL, 0);
    return 0;
}
EOF
	gcc -static -O2 "$FORK_TREE_SRC" -o "$FORK_TREE_BIN" 2>/dev/null || FORK_TREE_BIN=""

	cat > "$CUMUL_MEM_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/wait.h>

#define WORKER_MB   12
#define AUDIT_PATH  "/var/cumul_mem_audit.txt"

static void audit_msg(const char *msg) {
    int fd = open(AUDIT_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t unused = write(fd, msg, strlen(msg));
    (void)unused;
    close(fd);
}

static void auditf(const char *fmt, ...) {
    char buf[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    audit_msg(buf);
}

/* Fork a worker that allocates and TOUCHES WORKER_MB MB.
   Volatile per-page writes are mandatory: without them gcc -O2 turns
   malloc+memset into a lazy (calloc) allocation that never charges the pages,
   so the cumulative limit is never exceeded.
   adj raises the worker's oom_score_adj so the kernel picks the worker
   (not the leader) as the OOM victim when the quota is exceeded. */
static pid_t spawn_worker(int id, const char *tag, int adj) {
    pid_t p = fork();
    if (p < 0) return -1;
    if (p == 0) {
        int fd = open("/proc/self/oom_score_adj", O_WRONLY);
        if (fd >= 0) {
            dprintf(fd, "%d\n", adj);
            close(fd);
        }
        size_t sz = (size_t)WORKER_MB * 1024 * 1024;
        volatile unsigned char *m = malloc(sz);
        if (m) {
            for (size_t i = 0; i < sz; i += 4096) m[i] = 0x5A;
            m[sz - 1] = 0x5A;
        }
        auditf("%s_WORKER%d_ALLOCATED_12M\n", tag, id);
        /* Hold the memory until the OOM killer or the leader stops the worker. */
        for (;;) sleep(60);
        _exit(0);
    }
    return p;
}

static int read_audit(char *buf, size_t sz) {
    int fd = open(AUDIT_PATH, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sz - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    return 1;
}

static int wait_for_marker(const char *marker, int timeout_ms) {
    char buf[4096];
    for (int i = 0; i < timeout_ms / 20; i++) {
        if (read_audit(buf, sizeof(buf)) && strstr(buf, marker)) return 1;
        usleep(20000);
    }
    return 0;
}

static int child_alive(pid_t pid) {
    if (pid <= 0) return 0;
    int st;
    return waitpid(pid, &st, WNOHANG) == 0;
}

int main(void) {
    /* Protect the leader so it does not become the kernel OOM killer's victim.
       Only child worker processes may be chosen as OOM targets. */
    int oom_fd = open("/proc/self/oom_score_adj", O_WRONLY);
    if (oom_fd >= 0) {
        dprintf(oom_fd, "-1000\n");
        close(oom_fd);
    }

    /* ---- Control phase (anti-vacuous): 2 workers x 12MB = 24MB < 32MB.
       Both must survive without the OOM killer. ---- */
    pid_t c1 = spawn_worker(1, "CONTROL", 1000);
    pid_t c2 = spawn_worker(2, "CONTROL", 1000);
    int c1_ok = wait_for_marker("CONTROL_WORKER1_ALLOCATED_12M", 2000);
    int c2_ok = wait_for_marker("CONTROL_WORKER2_ALLOCATED_12M", 2000);
    usleep(500000); /* observation window: the OOM killer must not fire */
    int c1_alive = child_alive(c1);
    int c2_alive = child_alive(c2);
    if (c1_ok && c2_ok && c1_alive && c2_alive)
        audit_msg("CONTROL_2_WORKERS_NO_OOM=1\n");
    else
        audit_msg("CONTROL_2_WORKERS_NO_OOM=0\n");

    /* Clean up the control workers before the test phase. */
    if (c1 > 0) { kill(c1, SIGKILL); waitpid(c1, NULL, 0); }
    if (c2 > 0) { kill(c2, SIGKILL); waitpid(c2, NULL, 0); }
    usleep(100000); /* give the kernel time to reclaim the cgroup pages */

    /* ---- Test phase: 3 workers x 12MB = 36MB > 32MB.
       Spawn workers 1 & 2 gradually to ensure both hold 24MB in parallel
       without OOM before worker 3 pushes the accumulation past the 32MB quota.
       The kernel OOM killer must kill a worker; the leader does NOT allocate
       large amounts and does NOT call raise(SIGKILL). ---- */
    audit_msg("TEST_WORKERS_FORKED=3\n");
    pid_t w[3];
    w[0] = spawn_worker(1, "TEST", 1000);
    wait_for_marker("TEST_WORKER1_ALLOCATED_12M", 3000);
    w[1] = spawn_worker(2, "TEST", 1000);
    wait_for_marker("TEST_WORKER2_ALLOCATED_12M", 3000);
    w[2] = spawn_worker(3, "TEST", 1000);

    char buf[4096];
    int seen1 = 0, seen2 = 0, seen3 = 0, oom_kills = 0, st;
    for (int i = 0; i < 300; i++) {
        if (read_audit(buf, sizeof(buf))) {
            if (strstr(buf, "TEST_WORKER1_ALLOCATED_12M")) seen1 = 1;
            if (strstr(buf, "TEST_WORKER2_ALLOCATED_12M")) seen2 = 1;
            if (strstr(buf, "TEST_WORKER3_ALLOCATED_12M")) seen3 = 1;
        }
        pid_t p = waitpid(-1, &st, WNOHANG);
        if (p > 0 && WIFSIGNALED(st) && WTERMSIG(st) == SIGKILL)
            oom_kills++;
        if (oom_kills > 0) break;
        usleep(20000);
    }
    auditf("TEST_WORKERS_ALLOCATED=%d\n", seen1 + seen2 + seen3);
    auditf("WORKER_KILLED_BY_OOM=%d\n", oom_kills > 0);
    auditf("OOM_KILLED_WORKERS=%d\n", oom_kills);

    /* Sweep the remaining workers before the leader exits (the leader survives). */
    for (int i = 0; i < 3; i++) {
        if (w[i] > 0) {
            if (waitpid(w[i], &st, WNOHANG) == 0)
                kill(w[i], SIGKILL);
            waitpid(w[i], NULL, 0);
        }
    }
    audit_msg("LEADER_SURVIVED=1\n");
    return 0;
}
EOF
	gcc -static -O2 "$CUMUL_MEM_SRC" -o "$CUMUL_MEM_BIN" 2>/dev/null || CUMUL_MEM_BIN=""
fi

printf '== test binary : %s\n' "$BIN"

# ------------------------------------------------------------- Scenario 1
# Memory limit (memory.max) & deterministic OOM killer
# The service is limited to memory_max=16M. The workload allocates and touches
# memory past the limit. The cgroup v2 kernel triggers the OOM killer (SIGKILL, exit 0x9).
# Init PID 1 handles exit status=0x9 without crashing and cleans up the leaf cgroup.
printf '\n== Scenario 1: memory limit (memory_max=16M) & deterministic OOM ==\n'
if [ "$has_cg2" -ne 1 ] || [ "$has_mem" -ne 1 ] || [ -z "$HOG_BIN" ]; then
	skip "scenario 1 skipped: cgroup v2 + memory controller unavailable or gcc missing"
else
	R1=$(new_root sleep)
	L1=$(new_log)
	ROOTS="$ROOTS $R1"
	LOGS="$LOGS $L1"
	cp "$HOG_BIN" "$R1/bin/mem_hog"
	printf 'mem_test:once:/bin/mem_hog:memory_max=16M\nstopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl"\n' \
		> "$R1/etc/init.conf"
	boot_guest "$R1" "$WAIT1" >"$L1" 2>&1

	check_in  "memory.max limit configuration applied" "$L1" \
		"cgroup: 'mem_test' memory.max = 16M"
	check_in  "mem_test service deterministically stopped by OOM (exit status=0x9)" "$L1" \
		'mem_test (pid .* exit status=0x9'
	check_in  "leaf cgroup cleaned up after OOM" "$L1" \
		"cgroup: cleaned up 'mem_test'"
	check_in  "event loop keeps running and shutdown is clean" "$L1" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Scenario 2
# PIDs limit (pids.max) & deterministic fork EAGAIN
# The service is limited to pids_max=5. The parent process loops forking children.
# Once the processes inside the cgroup reach 5, the next fork() call is
# deterministically rejected with EAGAIN (Resource temporarily unavailable).
printf '\n== Scenario 2: process limit (pids_max=5) & deterministic fork EAGAIN ==\n'
if [ "$has_cg2" -ne 1 ] || [ "$has_pids" -ne 1 ] || [ -z "$FORK_BIN" ]; then
	skip "scenario 2 skipped: cgroup v2 + pids controller unavailable or gcc missing"
else
	R2=$(new_root sleep)
	L2=$(new_log)
	ROOTS="$ROOTS $R2"
	LOGS="$LOGS $L2"
	cp "$FORK_BIN" "$R2/bin/fork_test"
	printf 'pids_test:once:/bin/fork_test:pids_max=5\nstopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl"\n' \
		> "$R2/etc/init.conf"
	boot_guest "$R2" "$WAIT2" >"$L2" 2>&1

	check_in  "pids.max limit configuration applied" "$L2" \
		"cgroup: 'pids_test' pids.max = 5"
	check_in  "fork past the limit deterministically rejected with EAGAIN" "$R2/var/pids_audit.txt" \
		'EAGAIN_CONFIRMED count=4'
	check_in  "leaf cgroup cleaned up after completion" "$L2" \
		"cgroup: cleaned up 'pids_test'"
	check_in  "event loop keeps running and shutdown is clean" "$L2" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Scenario 3
# Lifecycle cleanup on respawn (lifecycle orphan clean sweep)
# The respawn service creates background child processes (`sleep 300 &`) and then
# the leader exits. `cgroup_kill_service` must sweep all child/orphan processes
# clean before the new generation is started after the RESPAWN_DELAY pause.
printf '\n== Scenario 3: orphan cleanup on respawn (cgroup_kill_service) ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "scenario 3 skipped: cgroup v2 unavailable"
else
	R3=$(new_root sleep)
	L3=$(new_log)
	ROOTS="$ROOTS $R3"
	LOGS="$LOGS $L3"
	cat > "$R3/bin/leak.sh" << 'EOF'
#!/bin/sh
if [ ! -f /var/gen1_started ]; then
    touch /var/gen1_started
    /bin/sleep 300 &
    /bin/sleep 300 &
    /bin/sleep 0.2
    exit 0
else
    # Generation 2: check whether any orphan sleep process from Gen 1 survived
    touch /var/gen2_started
    lingering=0
    for d in /proc/[0-9]*; do
        if [ -f "$d/comm" ] && [ "$(cat "$d/comm" 2>/dev/null)" = "sleep" ]; then
            lingering=$((lingering + 1))
        fi
    done
    echo "LINGERING_ORPHANS=$lingering" > /var/leak_audit.txt
    echo poweroff > /run/initctl
    exit 0
fi
EOF
	chmod 0755 "$R3/bin/leak.sh"
	printf 'leak:respawn:/bin/sh /bin/leak.sh\n' > "$R3/etc/init.conf"
	boot_guest "$R3" "$WAIT3" >"$L3" 2>&1

	check_in  "generation 1 leak service ran" "$L3" \
		"started leak (pid "
	check_in  "generation 1 respawn delayed by the timer" "$L3" \
		'leak: respawn delayed'
	if [ -f "$R3/var/gen2_started" ]; then
		ok "generation 2 leak service successfully restarted"
	else
		bad "generation 2 leak service successfully restarted"
	fi
	check_in  "generation 1 orphans swept clean with no leftovers (LINGERING_ORPHANS=0)" "$R3/var/leak_audit.txt" \
		'LINGERING_ORPHANS=0'
	check_in  "leaf cgroup cleaned up at shutdown" "$L3" \
		"cgroup: cleaned up 'leak'"
fi

# ------------------------------------------------------------- Scenario 4
# Leaf cgroup verification (memory.max, cpu.max, pids.max) & free option order
# Verifies that the configuration values are written directly to the cgroup
# filesystem at the service leaf node, and that the configuration options are
# processed correctly even when the tag order is reversed
# (:pids_max=...:cpu_max=...:memory_max=...).
printf '\n== Scenario 4: leaf cgroup values & free option order ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "scenario 4 skipped: cgroup v2 unavailable"
else
	R4=$(new_root cat sleep)
	L4=$(new_log)
	ROOTS="$ROOTS $R4"
	LOGS="$LOGS $L4"
	printf 'limits_audit:once:/bin/sh -c "cat %s/limits_audit/memory.max > /var/mem.val && cat %s/limits_audit/cpu.max > /var/cpu.val && cat %s/limits_audit/pids.max > /var/pids.val && cat %s/limits_audit/cgroup.controllers > /var/controllers.val && echo poweroff > /run/initctl":pids_max=20:cpu_max=50000 100000:memory_max=32M\n' \
		"$RUN_CG_BASE" "$RUN_CG_BASE" "$RUN_CG_BASE" "$RUN_CG_BASE" > "$R4/etc/init.conf"
	boot_guest "$R4" "$WAIT4" >"$L4" 2>&1

	check_in "memory.max configuration logged" "$L4" \
		"cgroup: 'limits_audit' memory.max = 32M"
	check_in "cpu.max configuration logged" "$L4" \
		"cgroup: 'limits_audit' cpu.max = 50000 100000"
	check_in "pids.max configuration logged" "$L4" \
		"cgroup: 'limits_audit' pids.max = 20"
	if [ "$has_mem" -eq 1 ]; then
		check_in "leaf memory.max value reads 32M (33554432 bytes)" "$R4/var/mem.val" \
			'33554432'
	else
		skip "leaf memory.max read skipped: memory controller not active"
	fi
	if [ "$has_cpu" -eq 1 ]; then
		check_in "leaf cpu.max value reads 50000 100000" "$R4/var/cpu.val" \
			'50000 100000'
	else
		skip "leaf cpu.max read skipped: cpu controller not active"
	fi
	if [ "$has_pids" -eq 1 ]; then
		check_in "leaf pids.max value reads 20" "$R4/var/pids.val" \
			'20'
	else
		skip "leaf pids.max read skipped: pids controller not active"
	fi
	# T14B: controller delegation verification. The parent subtree delegates
	# +memory +pids +cpu, so the leaf cgroup.controllers file must list them.
	check_controller "T14B: leaf cgroup.controllers delegates the memory controller" \
		"$R4/var/controllers.val" memory "$has_mem"
	check_controller "T14B: leaf cgroup.controllers delegates the pids controller" \
		"$R4/var/controllers.val" pids "$has_pids"
	check_controller "T14B: leaf cgroup.controllers delegates the cpu controller" \
		"$R4/var/controllers.val" cpu "$has_cpu"
	check_in "leaf cgroup cleaned up after completion" "$L4" \
		"cgroup: cleaned up 'limits_audit'"
fi

# ------------------------------------------------------------- Scenario 5
# Resource limit parser validation (valid vs invalid/malformed)
# Verifies that the parser accepts valid limit formats (memory_max, cpu_max,
# pids_max) and rejects broken/malformed values with a warning log, without
# causing PID 1 to crash.
printf '\n== Scenario 5: resource limit parser validation (valid vs malformed) ==\n'
R5=$(new_root sleep true)
L5=$(new_log)
ROOTS="$ROOTS $R5"
LOGS="$LOGS $L5"

cat > "$R5/etc/init.conf" << 'EOF'
# Service with valid options
valid_svc:once:/bin/sh -c "echo VALID_OK > /var/valid.txt":memory_max=64M:cpu_max=50000 100000:pids_max=25
# Service with a broken memory_max option (invalid suffix, random letters, negative number)
bad_mem1:once:/bin/true:memory_max=64MB
bad_mem2:once:/bin/true:memory_max=-100M
bad_mem3:once:/bin/true:memory_max=corrupted!@#
# Service with a broken cpu_max option (non-numeric, extra spaces, wrong token format)
bad_cpu1:once:/bin/true:cpu_max=invalid 100000
bad_cpu2:once:/bin/true:cpu_max=50000  100000
bad_cpu3:once:/bin/true:cpu_max=50000
# Service with a broken pids_max option (negative number, non-numeric characters, zero)
bad_pid1:once:/bin/true:pids_max=-5
bad_pid2:once:/bin/true:pids_max=invalid
bad_pid3:once:/bin/true:pids_max=0
# Stopper
stopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl":requires=valid_svc
EOF

boot_guest "$R5" "$WAIT5" >"$L5" 2>&1

check_in  "invalid memory_max warning logged" "$L5" \
	"invalid memory_max '64MB'"
check_in  "invalid cpu_max warning logged" "$L5" \
	"invalid cpu_max 'invalid 100000'"
check_in  "invalid pids_max warning logged" "$L5" \
	"invalid pids_max '-5'"
check_in  "service with valid limits still runs normally" "$R5/var/valid.txt" \
	'VALID_OK'
check_in  "valid limit applied to the leaf cgroup" "$L5" \
	"cgroup: 'valid_svc' memory.max = 64M"
absent_in "broken memory_max limit was NEVER applied" "$L5" \
	"memory.max = 64MB"
absent_in "broken cpu_max limit was NEVER applied" "$L5" \
	"cpu.max = invalid"
absent_in "broken pids_max limit was NEVER applied" "$L5" \
	"pids.max = -5"
check_in  "event loop stays stable and shutdown is clean" "$L5" \
	'graceful shutdown'

# ------------------------------------------------------------- Scenario 6
# Subtree control environment tolerance (nested / partial subtree control)
# Verifies that failed or partial subtree control writes in a nested/container
# environment do not break ninit's boot.
printf '\n== Scenario 6: cgroup root environment tolerance (nested / partial) ==\n'
R6=$(new_root sleep)
L6=$(new_log)
ROOTS="$ROOTS $R6"
LOGS="$LOGS $L6"

cat > "$R6/etc/init.conf" << 'EOF'
svc_nested:once:/bin/sh -c "echo NESTED_OK > /var/nested.txt && echo poweroff > /run/initctl":pids_max=10
EOF

# Prepare a simulated nested cgroup environment with a read-only subtree_control on tmpfs
setup_r6="mount -t sysfs sysfs $R6/sys; mkdir -p $R6/sys/fs/cgroup; mount -t tmpfs tmpfs $R6/sys/fs/cgroup; touch $R6/sys/fs/cgroup/cgroup.controllers; echo pids > $R6/sys/fs/cgroup/cgroup.controllers; touch $R6/sys/fs/cgroup/cgroup.subtree_control; mount -o remount,ro $R6/sys/fs/cgroup;"

boot_guest "$R6" "$WAIT6" "" "$setup_r6" >"$L6" 2>&1

check_in  "subtree_control open/write failure tolerated with a log" "$L6" \
	'open .*subtree_control failed'
check_in  "nested/container tolerant recorded in the log" "$L6" \
	'nested/container tolerant'
check_in  "service spawned successfully despite the blocked subtree_control" "$R6/var/nested.txt" \
	'NESTED_OK'
check_in  "system enters the main loop and shutdown is clean" "$L6" \
	'graceful shutdown'

# ------------------------------------------------------------- Scenario 7
# PR #9 interaction: a 'once' service with pids_max=1 fork EAGAIN -> FAILED -> cancel dependents
# Verifies that cgroup resource exhaustion on the init process triggers a
# deterministic fork EAGAIN, the 'once' service retries up to MAX_SPAWN_RETRY (3x),
# then transitions to the FAILED state, and deterministically cancels its
# dependent services.
printf '\n== Scenario 7: PR #9 interaction (once + pids.max=1 fork EAGAIN -> FAILED) ==\n'
CG_PR9=""
pids_available=0
if [ "$has_cg2" -eq 1 ] && [ "$has_pids" -eq 1 ]; then
	CG_PR9=$($SUDO mktemp -d "$RUN_CG/ninit-cg-pr9.XXXXXX")
	CG_DYNAMIC="$CG_DYNAMIC $CG_PR9"
	if [ -e "$CG_PR9/pids.max" ] && printf '1\n' | $SUDO tee "$CG_PR9/pids.max" >/dev/null 2>&1; then
		pids_available=1
	fi
fi

if [ "$pids_available" -ne 1 ]; then
	skip "scenario 7 skipped: cgroup v2 + pids controller unavailable or failed to prepare"
else
	R7=$(new_root)
	L7=$(new_log)
	ROOTS="$ROOTS $R7"
	LOGS="$LOGS $L7"

	printf 'boot_pr9:once:exit 0\napp_dep:respawn:exit 0:requires=boot_pr9\n' > "$R7/etc/init.conf"
	boot_guest "$R7" "$WAIT7" "$CG_PR9" >"$L7" 2>&1

	check_in  "event loop still entered and responsive" "$L7" 'main loop ready'
	check_in  "fork() failure detected because the cgroup pids are exhausted" "$L7" \
		'fork boot_pr9: Resource temporarily unavailable'
	check_in  "once service retries up to the limit then is marked failed" "$L7" \
		'attempts, service marked failed'
	check_in  "dependent service deterministically cancelled" "$L7" \
		"service 'app_dep' cancelled: dependency 'boot_pr9' failed"
	absent_in "boot_pr9 never spawned successfully" "$L7" 'started boot_pr9'
	absent_in "app_dep never spawned when the dependency failed" "$L7" 'fork app_dep'
	nfork=$(grep -c 'fork boot_pr9' "$L7" 2>/dev/null || true)
	if [ "${nfork:-0}" -le 3 ]; then
		ok "boot_pr9 fork() attempts limited: $nfork (max 3, no busy-loop)"
	else
		bad "boot_pr9 fork() attempts unbounded: $nfork lines (suspected busy-loop)"
	fi
fi

# ------------------------------------------------------------- Scenario 8
# Orphan lifecycle cleanup on a 'once' service (cgroup_kill_service before rmdir)
# Verifies that the child/orphan processes left by a 'once' service are swept
# clean via cgroup.kill before the leaf cgroup rmdir call.
printf '\n== Scenario 8: orphan cleanup on a once service before rmdir ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "scenario 8 skipped: cgroup v2 unavailable"
else
	R8=$(new_root sleep grep)
	L8=$(new_log)
	ROOTS="$ROOTS $R8"
	LOGS="$LOGS $L8"

	cat > "$R8/bin/once_fork.sh" << 'EOF'
#!/bin/sh
/bin/sleep 300 &
/bin/sleep 300 &
/bin/sleep 0.2
exit 0
EOF
	chmod 0755 "$R8/bin/once_fork.sh"

	cat > "$R8/bin/check_orphans.sh" << 'EOF'
#!/bin/sh
/bin/sleep 0.5
lingering=0
for cmd in /proc/[0-9]*/cmdline; do
    [ -f "$cmd" ] || continue
    if grep -q "300" "$cmd" 2>/dev/null; then
        lingering=$((lingering + 1))
    fi
done
echo "LINGERING_ONCE_ORPHANS=$lingering" > /var/once_orphan_audit.txt
# T14: the leaf cgroup directory must be gone after the once service stopped
# (rmdir succeeds after cgroup.kill, no EBUSY).
if [ -d "${NINIT_CGROUP_BASE:-/sys/fs/cgroup/ninit}/orphan_maker" ]; then
    echo "LEAF_REMOVED=0" >> /var/once_orphan_audit.txt
else
    echo "LEAF_REMOVED=1" >> /var/once_orphan_audit.txt
fi
echo poweroff > /run/initctl
exit 0
EOF
	chmod 0755 "$R8/bin/check_orphans.sh"

	cat > "$R8/etc/init.conf" << 'EOF'
orphan_maker:once:/bin/sh /bin/once_fork.sh
checker:once:/bin/sh /bin/check_orphans.sh:requires=orphan_maker
EOF

	boot_guest "$R8" "$WAIT8" >"$L8" 2>&1

	check_in  "orphan_maker service ran" "$L8" \
		'started orphan_maker'
	check_in  "orphan_maker leaf cgroup cleaned up without EBUSY" "$L8" \
		"cgroup: cleaned up 'orphan_maker'"
	absent_in "no leaf cgroup rmdir failure" "$L8" \
		"Device or resource busy"
	check_in  "orphans from the once service swept clean before the checker (LINGERING_ONCE_ORPHANS=0)" \
		"$R8/var/once_orphan_audit.txt" 'LINGERING_ONCE_ORPHANS=0'
	check_in  "T14: leaf cgroup directory removed after the service stopped (LEAF_REMOVED=1)" \
		"$R8/var/once_orphan_audit.txt" 'LEAF_REMOVED=1'
	before_in "orphan_maker leaf cgroup cleaned up before graceful shutdown" "$L8" \
		"cgroup: cleaned up 'orphan_maker'" 'graceful shutdown'
	check_in  "event loop keeps running and shutdown is clean" "$L8" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Scenario 9
# Descendant escape test (pre-exec pipe handshake synchronization)
# The adversarial workload does a fast double-fork and setsid to try to escape
# the leaf cgroup.
# Verifies that the T1 parent-child synchronization handshake guarantees all
# descendant processes (child, grandchild, orphan) are in the correct leaf
# cgroup.procs, and cgroup_kill_service sweeps the whole process tree clean
# (LINGERING_ESCAPE_ORPHANS=0). Cleanup is verified from two sides:
# (a) cgroup.events populated 0 and cgroup.procs empty BEFORE the leaf rmdir,
# (b) a /proc cmdline scan with no leftovers.
printf '\n== Scenario 9: descendant escape test & handshake synchronization ==\n'
if [ "$has_cg2" -ne 1 ] || [ -z "$ESCAPE_BIN" ]; then
	skip "scenario 9 skipped: cgroup v2 unavailable or gcc missing"
else
	R9=$(new_root sleep grep cut cat awk wc)
	L9=$(new_log)
	ROOTS="$ROOTS $R9"
	LOGS="$LOGS $L9"

	cp "$ESCAPE_BIN" "$R9/bin/escape_workload"

	# -----------------------------------------------------------------
	# Phase 1: Negative control test (Binary Without Handshake -> FAIL)
	# -----------------------------------------------------------------
	# Run the binary directly in the root cgroup environment without the T1 handshake.
	# The binary must detect the absence of a leaf cgroup on its first instruction and exit 1.
	neg_ret=0
	$SUDO timeout -s KILL 5 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh -c \
		"mount -t proc proc '$R9/proc' && chroot '$R9' /bin/escape_workload" >/dev/null 2>&1 || neg_ret=$?

	if [ "$neg_ret" -ne 0 ] && [ -f "$R9/var/escape_audit.txt" ]; then
		check_in  "negative anti-vacuous test: binary without handshake sees the root cgroup and FAILs deterministically" \
			"$R9/var/escape_audit.txt" 'PRE_FORK_LEAF_CGROUP=0'
		absent_in "negative anti-vacuous test: binary without handshake never spawns a grandchild" \
			"$R9/var/escape_audit.txt" 'GRANDCHILD_ACTIVE=1'
	else
		bad "negative anti-vacuous test: binary without handshake should fail but passed (exit=$neg_ret)"
	fi
	rm -f "$R9/var/escape_audit.txt"

	# -----------------------------------------------------------------
	# Phase 2: Positive test (With T1 Handshake under ninit -> PASS)
	# -----------------------------------------------------------------
	cat > "$R9/bin/check_escape.sh" << 'EOF'
#!/bin/sh
# Verify the cleanup from two sides:
#   (a) cgroup: cgroup.events (populated 0) and cgroup.procs empty BEFORE the
#       leaf rmdir. The leaf is deliberately left alive (escape_svc respawn) so
#       the post-cgroup_kill_service state can be observed before ninit removes
#       it at shutdown.
#   (b) /proc: no escape_workload process is still running.
CG="${NINIT_CGROUP_BASE:-/sys/fs/cgroup/ninit}/escape_svc"

# Wait for the adversarial workload to write the audit evidence (grandchild is active).
waited=0
while [ ! -f /var/escape_audit.txt ] && [ "$waited" -lt 100 ]; do
    /bin/sleep 0.05
    waited=$((waited + 1))
done

gc_pid=""
if [ -f /var/escape_audit.txt ]; then
    gc_pid=$(grep '^GRANDCHILD=' /var/escape_audit.txt 2>/dev/null | cut -d= -f2)
fi

# Wait for cgroup_kill_service to sweep the leaf: populated 0 AND cgroup.procs empty.
populated="unknown"
nprocs="unknown"
waited=0
while [ "$waited" -lt 100 ]; do
    if [ -d "$CG" ] && [ -f "$CG/cgroup.events" ]; then
        p=$(awk '/^populated /{print $2}' "$CG/cgroup.events" 2>/dev/null)
        n=$(wc -l < "$CG/cgroup.procs" 2>/dev/null || echo unknown)
        if [ "$p" = "0" ] && [ "$n" = "0" ]; then
            populated=0
            nprocs=0
            break
        fi
    fi
    /bin/sleep 0.05
    waited=$((waited + 1))
done

# Scan /proc: ensure no escaped descendant processes remain.
lingering=0
if [ -n "$gc_pid" ] && [ -d "/proc/$gc_pid" ]; then
    lingering=$((lingering + 1))
fi

for cmd in /proc/[0-9]*/cmdline; do
    [ -f "$cmd" ] || continue
    if grep -q "escape_workload" "$cmd" 2>/dev/null; then
        lingering=$((lingering + 1))
    fi
done

echo "POPULATED=$populated" > /var/escape_clean_audit.txt
echo "CGROUP_PROCS=$nprocs" >> /var/escape_clean_audit.txt
echo "LINGERING_ESCAPE_ORPHANS=$lingering" >> /var/escape_clean_audit.txt
echo poweroff > /run/initctl
exit 0
EOF
	chmod 0755 "$R9/bin/check_escape.sh"

	cat > "$R9/etc/init.conf" << 'EOF'
# escape_svc is deliberately 'respawn': when the leader exits, ninit calls
# cgroup_kill_service but does NOT rmdir the leaf yet, so the checker can
# verify cgroup.events (populated 0) and cgroup.procs empty BEFORE the rmdir
# (the leaf rmdir happens at shutdown).
escape_svc:respawn:/bin/escape_workload
checker:once:/bin/sh /bin/check_escape.sh
EOF

	boot_guest "$R9" "$WAIT9" >"$L9" 2>&1

	check_in  "the child process's first instruction validates presence in a leaf cgroup (/ninit/...)" \
		"$R9/var/escape_audit.txt" 'PRE_FORK_LEAF_CGROUP=1'
	check_in  "adversary successfully spawns an orphan grandchild thanks to the T1 handshake (positive anti-vacuous)" \
		"$R9/var/escape_audit.txt" 'GRANDCHILD_ACTIVE=1'
	check_in  "orphan grandchild is in the leaf cgroup.procs thanks to the T1 handshake" \
		"$R9/var/escape_audit.txt" 'IN_CGROUP_PROCS=1'
	check_in  "grandchild cgroup membership is in the escape_svc leaf" \
		"$R9/var/escape_audit.txt" 'IN_LEAF_CGROUP=1'
	check_in  "cgroup_kill_service sweeps the whole descendant process tree clean (LINGERING_ESCAPE_ORPHANS=0)" \
		"$R9/var/escape_clean_audit.txt" 'LINGERING_ESCAPE_ORPHANS=0'
	check_in  "escape_svc leaf cgroup.events populated 0 before rmdir" \
		"$R9/var/escape_clean_audit.txt" 'POPULATED=0'
	check_in  "escape_svc leaf cgroup.procs empty before rmdir" \
		"$R9/var/escape_clean_audit.txt" 'CGROUP_PROCS=0'
	check_in  "escape_svc leaf cgroup cleaned up after the sweep" "$L9" \
		"cgroup: cleaned up 'escape_svc'"
	absent_in "no leaf cgroup rmdir failure (EBUSY)" "$L9" \
		"Device or resource busy"
	check_in  "event loop keeps running and shutdown is clean" "$L9" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Scenario 10
# Multi-tier workload resource limits (multi-tier hierarchical limits)
# Verifies that cgroup v2 hierarchical limits bind the whole subtree:
# Part 10A: Hierarchical pids.max (leader -> child -> grandchild -> 4th fork rejected EAGAIN)
# Part 10B: Cumulative parallel memory.max -- the leader orchestrates 3 workers x 12MB
#           (total 36MB > 32MB limit) so the OOM killer kills a worker, plus the
#           anti-vacuous control of 2 workers x 12MB (24MB) which passes without OOM.
printf '\n== Scenario 10: multi-tier workload resource limits (cgroup v2 hierarchy) ==\n'

# 10A: Hierarchical PIDs
if [ "$has_cg2" -ne 1 ] || [ "$has_pids" -ne 1 ] || [ -z "$FORK_TREE_BIN" ]; then
	skip "scenario 10A skipped: cgroup v2 + pids controller unavailable or gcc missing"
else
	R10A=$(new_root sleep)
	L10A=$(new_log)
	ROOTS="$ROOTS $R10A"
	LOGS="$LOGS $L10A"

	cp "$FORK_TREE_BIN" "$R10A/bin/fork_tree"
	cat > "$R10A/etc/init.conf" << 'EOF'
pids_tree:once:/bin/fork_tree:pids_max=3
stopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl":requires=pids_tree
EOF

	boot_guest "$R10A" "$WAIT10A" >"$L10A" 2>&1

	check_in  "pids.max limit configuration applied to the hierarchy" "$L10A" \
		"cgroup: 'pids_tree' pids.max = 3"
	check_in  "grandchild fork deterministically rejected with EAGAIN when the hierarchy quota is exhausted" \
		"$R10A/var/pids_tree_audit.txt" 'NESTED_EAGAIN_CONFIRMED depth=3'
	absent_in "no fork slipped past the pids.max limit" \
		"$R10A/var/pids_tree_audit.txt" 'UNEXPECTED_FORK_SUCCESS'
	check_in  "leaf cgroup cleaned up after completion" "$L10A" \
		"cgroup: cleaned up 'pids_tree'"
	check_in  "event loop keeps running and shutdown is clean" "$L10A" \
		'graceful shutdown'
fi

# 10B: Cumulative Parallel Memory OOM
if [ "$has_cg2" -ne 1 ] || [ "$has_mem" -ne 1 ] || [ -z "$CUMUL_MEM_BIN" ]; then
	skip "scenario 10B skipped: cgroup v2 + memory controller unavailable or gcc missing"
else
	R10B=$(new_root sleep)
	L10B=$(new_log)
	ROOTS="$ROOTS $R10B"
	LOGS="$LOGS $L10B"

	cp "$CUMUL_MEM_BIN" "$R10B/bin/cumul_mem"
	cat > "$R10B/etc/init.conf" << 'EOF'
mem_cumul:once:/bin/cumul_mem:memory_max=32M
stopper:once:/bin/sh -c "/bin/sleep 3 && echo poweroff > /run/initctl"
EOF

	boot_guest "$R10B" "$WAIT10B" >"$L10B" 2>&1

	check_in  "cumulative memory.max limit configuration applied" "$L10B" \
		"cgroup: 'mem_cumul' memory.max = 32M"
	check_in  "anti-vacuous control: 2 workers x 12M (24M) pass without OOM" \
		"$R10B/var/cumul_mem_audit.txt" 'CONTROL_2_WORKERS_NO_OOM=1'
	check_in  "leader orchestrates 3 workers in the test phase (total 36M > 32M)" \
		"$R10B/var/cumul_mem_audit.txt" 'TEST_WORKERS_FORKED=3'
	check_in  "at least 2 workers allocate 12M (real parallel accumulation)" \
		"$R10B/var/cumul_mem_audit.txt" 'TEST_WORKERS_ALLOCATED=[23]'
	check_in  "OOM killer kills a worker (waitpid SIGKILL evidence, not a self-kill)" \
		"$R10B/var/cumul_mem_audit.txt" 'WORKER_KILLED_BY_OOM=1'
	check_in  "leader survives and reports (no raise(SIGKILL))" \
		"$R10B/var/cumul_mem_audit.txt" 'LEADER_SURVIVED=1'
	absent_in "no fake exit status=0x9 on the mem_cumul leader" "$L10B" \
		'mem_cumul (pid .* exit status=0x9'
	check_in  "leaf cgroup cleaned up after cumulative OOM" "$L10B" \
		"cgroup: cleaned up 'mem_cumul'"
	check_in  "event loop keeps running and shutdown is clean" "$L10B" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Scenario 11
# Fail-open fallback when cgroup v2 is unavailable (cgroup mount fails)
# Verifies that when the cgroup v2 hierarchy cannot be mounted or prepared:
# 1. Init logs the active fail-open line: "cgroup: fail-open active for ..."
# 2. Init logs the limit-ignore warning: "Warning: resource limits ignored on service '...' because cgroup unavailable"
# 3. Services still execute normally through the T1 handshake
# 4. The kill(-pgid) fallback on a once service cleans up background orphan
#    child processes when the leader dies
# 5. Init PID 1 performs a clean shutdown (graceful shutdown) without crashing or a hung orphan
printf '\n== Scenario 11: fail-open fallback when cgroup v2 is unavailable ==\n'
R11=$(new_root sleep grep)
L11=$(new_log)
ROOTS="$ROOTS $R11"
LOGS="$LOGS $L11"

cat > "$R11/bin/check_failopen.sh" << 'EOF'
#!/bin/sh
# Verify that the background orphan (sleep 300) has been swept clean by the kill(-pgid) fallback
lingering=0
for cmd in /proc/[0-9]*/cmdline; do
    [ -f "$cmd" ] || continue
    if grep -q "300" "$cmd" 2>/dev/null; then
        lingering=$((lingering + 1))
    fi
done
echo "LINGERING_FAILOPEN_ORPHANS=$lingering" > /var/failopen_clean_audit.txt
echo poweroff > /run/initctl
exit 0
EOF
chmod 0755 "$R11/bin/check_failopen.sh"

cat > "$R11/etc/init.conf" << 'EOF'
failopen_svc:once:/bin/sh -c "/bin/sleep 300 & echo FAILOPEN_EXECUTED > /var/failopen_audit.txt":memory_max=32M:pids_max=10
checker:once:/bin/sh /bin/check_failopen.sh:requires=failopen_svc
EOF

# Prepare a simulated environment where /sys/fs/cgroup is a regular file on tmpfs,
# so the mount("cgroup2", "/sys/fs/cgroup", ...) call fails deterministically with ENOTDIR
setup_r11="mount -t sysfs sysfs $R11/sys; mkdir -p $R11/sys/fs; mount -t tmpfs tmpfs $R11/sys/fs; touch $R11/sys/fs/cgroup;"

boot_guest "$R11" "$WAIT11" "" "$setup_r11" >"$L11" 2>&1

check_in  "cgroup v2 mount failure logged" "$L11" \
	'cgroup2: mount /sys/fs/cgroup failed'
check_in  "active fail-open fallback logged" "$L11" \
	"cgroup: fail-open active for 'failopen_svc'"
check_in  "resource limit ignored warning logged" "$L11" \
	"Warning: resource limits ignored on service 'failopen_svc' because cgroup unavailable"
check_in  "service still executes normally when cgroup is unavailable" \
	"$R11/var/failopen_audit.txt" 'FAILOPEN_EXECUTED'
check_in  "sleep 300 orphan swept clean via the kill(-pgid) fallback in fail-open (LINGERING_FAILOPEN_ORPHANS=0)" \
	"$R11/var/failopen_clean_audit.txt" 'LINGERING_FAILOPEN_ORPHANS=0'
check_in  "event loop stays stable and shutdown is clean" "$L11" \
	'graceful shutdown'

# ------------------------------------------------------------- Guard & edge case verification
printf '\n== Isolation Guard & Edge Case Verification ==\n'

# 1. TEST_LEAVES assertion: no test leaf in $RUN_CG_BASE leaks
leaked=""
for leaf in $TEST_LEAVES; do
	if [ -d "$RUN_CG_BASE/$leaf" ]; then
		leaked="$leaked $leaf"
	fi
done
if [ -n "$leaked" ]; then
	bad "test-owned cgroup leaf leak:$leaked"
else
	ok "TEST_LEAVES assertion: all test leaves in $RUN_CG_BASE are reaped clean"
fi

# 2. Host external cgroup protection (sentinel guard)
if [ -d "$EXTERNAL_GUARD_CG" ]; then
	ok "external host cgroup ($EXTERNAL_GUARD_CG) is 100% intact and untouched"
	$SUDO rmdir "$EXTERNAL_GUARD_CG" 2>/dev/null || true
else
	bad "external host cgroup is disturbed or missing!"
fi

# 3. The host /sys/fs/cgroup/ninit is never touched
if [ "$HOST_NINIT_PREEXISTED" -eq 0 ]; then
	if [ -d /sys/fs/cgroup/ninit ]; then
		bad "/sys/fs/cgroup/ninit appeared on the host (isolation broken)"
	else
		ok "host /sys/fs/cgroup/ninit was never created/touched (100% isolation in $RUN_CG)"
	fi
fi

# 4. Collision rejection test
collision_code=0
(
	mkdir "$RUN_CG" 2>/dev/null
) || collision_code=$?
if [ "$collision_code" -ne 0 ]; then
	ok "collision guard: strict mkdir rejects an existing cgroup collision (exit=$collision_code)"
else
	bad "collision guard: strict mkdir should fail if the directory already exists!"
fi

# 5. Trap safety on a partial setup (RUN_CG empty / not yet created)
partial_trap_ok=1
(
	RUN_CG=""
	RUN_CG_DEV_INO=""
	clean_run_cgroup || exit 1
) || partial_trap_ok=0
if [ "$partial_trap_ok" -eq 1 ]; then
	ok "trap safety guard: clean_run_cgroup runs safely when RUN_CG is not yet initialized"
else
	bad "trap safety guard: clean_run_cgroup throws an error on a partial setup"
fi

# 6. Inode identity / symlink tampering detection
tamper_detected=0
(
	temp_d=$(mktemp -d /tmp/cg-tamper.XXXXXX)
	fake_ino="0:0"
	(
		RUN_CG="$temp_d"
		RUN_CG_DEV_INO="$fake_ino"
		if clean_run_cgroup 2>/dev/null; then
			exit 0
		else
			exit 1
		fi
	) || tamper_detected=1
	rmdir "$temp_d" 2>/dev/null || true
	exit "$tamper_detected"
) || tamper_detected=1
if [ "$tamper_detected" -eq 1 ]; then
	ok "inode integrity guard: clean_run_cgroup rejects the operation when dev:ino changes"
else
	bad "inode integrity guard: clean_run_cgroup slips through when dev:ino does not match"
fi

# 7. PID reuse assertion guard: a non-existent PID MUST be rejected (fail-closed).
pid_reuse_guard=0
dead_pid=9999999
if [ -r /proc/sys/kernel/pid_max ]; then
	dead_pid=$(($(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 4194304) + 1))
fi
is_test_process "$dead_pid" 2>/dev/null && pid_reuse_guard=1
if [ "$pid_reuse_guard" -ne 1 ]; then
	ok "PID reuse guard: is_test_process $dead_pid (non-existent PID) rejected fail-closed (status 1)"
else
	bad "PID reuse guard: is_test_process $dead_pid (non-existent PID) is considered test-owned!"
fi

# 8. Host external process assertion guard: a process outside the test
#    cgroup/chroot MUST be rejected AND NEVER killed by clean_run_cgroup.
ext_pid=""
if command -v sleep >/dev/null 2>&1; then
	sleep 60 &
	ext_pid=$!
fi
if [ -n "$ext_pid" ] && kill -0 "$ext_pid" 2>/dev/null; then
	ext_rej=0
	if is_test_process "$ext_pid" 2>/dev/null; then
		ext_rej=1
	fi
	if [ "$ext_rej" -ne 1 ]; then
		ok "external process guard: is_test_process $ext_pid (host process outside the test cgroup/chroot) rejected"
	else
		bad "external process guard: is_test_process $ext_pid wrongly considers an external host process test-owned!"
	fi

	# clean_run_cgroup must NOT kill the external host process.
	clean_run_cgroup >/dev/null 2>&1 || true
	sleep 0.3
	if kill -0 "$ext_pid" 2>/dev/null; then
		ok "external process guard: clean_run_cgroup does not kill the external host process (pid $ext_pid)"
	else
		bad "external process guard: clean_run_cgroup KILLS the external host process (pid $ext_pid)!"
	fi

	# Stop the dummy sleep (not part of the test cleanup).
	kill "$ext_pid" 2>/dev/null || true
	wait "$ext_pid" 2>/dev/null || true
else
	skip "external process guard skipped: cannot run a dummy host process"
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
