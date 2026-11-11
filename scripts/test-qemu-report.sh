#!/bin/sh
# Test-qemu-report: proves that the report() checks in scripts/run-qemu.sh are
# not lax — a console log where the console service dies and is respawned again
# must FAIL, not PASS.
#
# Why this test exists (PR #1 note, "next finding"): 'started console' is
# written by spawn_service() at FORK, not after a successful exec. A console
# service that dies immediately (e.g. `console:respawn:/bin/does-not-exist`)
# still produces repeated 'started console' lines, exit status=0x7f00, and
# 'respawn delayed' — while the old harness only matched three markers
# ('ninit start (PID 1)', 'main loop ready', 'started console') and therefore
# still reported RESULT: PASS. This test fails if that laxness returns.
#
# How it works: scripts/run-qemu.sh is run with REPORT_ONLY=1 against console
# log fixtures (no QEMU is booted, no root needed). Each scenario checks both
# the exit code AND the specific expected check line, so a failure cannot come
# from a check aimed at the wrong target.
#
# Pemakaian:
#   sh ./scripts/test-qemu-report.sh
#
# Variabel lingkungan:
#   HARNESS=./scripts/run-qemu.sh   harness under test

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HARNESS=${HARNESS:-$SCRIPT_DIR/run-qemu.sh}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$HARNESS" ] || fail "harness '$HARNESS' not found"
sh -n "$HARNESS" || fail "'$HARNESS' failed sh -n"

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT INT TERM

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); }

expect_rc() { # $1 = scenario, $2 = actual rc, $3 = expected rc
	if [ "$2" = "$3" ]; then ok "$1 (exit=$2)"; else bad "$1: exit=$2, expected $3"; fi
}

expect_line() { # $1 = harness output, $2 = text expected to appear, $3 = label
	if printf '%s' "$1" | grep -qF "$2"; then ok "$3"; else bad "$3 (not found: '$2')"; fi
}

expect_absent() { # $1 = harness output, $2 = text that must NOT appear, $3 = label
	if printf '%s' "$1" | grep -qF "$2"; then bad "$3 (appeared but must not: '$2')"; else ok "$3"; fi
}

run_report() { # $1 = fixture name; sets RC and OUT
	RC=0
	OUT=$(CONSOLE_LOG="$FIX/$1.log" REPORT_ONLY=1 sh "$HARNESS" 2>&1) || RC=$?
}

# ------------------------------------------------------------------ fixture
# Every ninit line is written TWICE (via /dev/kmsg and stderr); the fixture
# imitates that so PID deduplication is exercised too.
cat > "$FIX/healthy.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[2026-11-05 09:00:01] ninit: ninit start (PID 1)
[    1.200000] ninit: fstab: /etc/fstab does not exist, skipped
[    1.250000] ninit: main loop ready
[2026-11-05 09:00:01] ninit: main loop ready
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
/ # 
EOF

# PR #1 proof scenario: console:respawn:/bin/does-not-exist.
# The OLD checks all pass; what must catch it is the new liveness check
# (unique PIDs, exit status, respawn delay).
cat > "$FIX/console-dead.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[2026-11-05 09:00:01] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop ready
[2026-11-05 09:00:01] ninit: main loop ready
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
[    1.301000] ninit: console (pid 42) exit status=0x7f00
[2026-11-05 09:00:02] ninit: console (pid 42) exit status=0x7f00
[    2.300000] ninit: console: respawn delayed (timer 2 seconds, loop unblocked)
[2026-11-05 09:00:03] ninit: console: respawn delayed (timer 2 seconds, loop unblocked)
[    3.400000] ninit: started console (pid 51)
[2026-11-05 09:00:04] ninit: started console (pid 51)
[    3.401000] ninit: console (pid 51) exit status=0x7f00
[2026-11-05 09:00:04] ninit: console (pid 51) exit status=0x7f00
EOF

# 'started console' appears twice for the SAME PID (just kmsg/stderr
# duplication) + one exit status: no respawn loop happened yet, but the
# console did exit -> it must still FAIL via the exit status check.
cat > "$FIX/console-exit-single-pid.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop ready
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
[    2.000000] ninit: console (pid 42) exit status=0x0
[2026-11-05 09:00:02] ninit: console (pid 42) exit status=0x0
EOF

cat > "$FIX/panic.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop ready
[    1.300000] ninit: started console (pid 42)
[    2.000000] Kernel panic - not syncing: Attempted to kill init!
EOF

# The console never started at all.
cat > "$FIX/console-never-start.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop ready
EOF

# ninit never entered the event loop.
cat > "$FIX/no-main-loop.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
EOF

# Healthy console, but ANOTHER respawn service ('web') once delayed its
# respawn window — normal behavior for a multi-service init.conf. The
# console-scoped 'respawn delayed' check must NOT make this FAIL (a
# regression back to the PR #6 review note: a global pattern is too strict).
cat > "$FIX/respawn-other-service.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[2026-11-05 09:00:01] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop ready
[2026-11-05 09:00:01] ninit: main loop ready
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
[    1.310000] ninit: started web (pid 43)
[2026-11-05 09:00:01] ninit: started web (pid 43)
[    4.000000] ninit: web (pid 43) exit status=0x0
[2026-11-05 09:00:04] ninit: web (pid 43) exit status=0x0
[    4.100000] ninit: web: respawn delayed (timer 2 seconds, loop unblocked)
[2026-11-05 09:00:04] ninit: web: respawn delayed (timer 2 seconds, loop unblocked)
[    6.200000] ninit: started web (pid 55)
[2026-11-05 09:00:06] ninit: started web (pid 55)
EOF

# ------------------------------------------------------------------ scenarios
printf '\n== scenario 1: healthy boot -> PASS ==\n'
run_report healthy
expect_rc "scenario 1: exit code" "$RC" 0
expect_line "$OUT" 'RESULT: PASS' "scenario 1: PASS report"
expect_line "$OUT" 'console started with exactly one PID (42)' \
	"scenario 1: duplicate kmsg/stderr lines deduplicated (still one PID)"

printf '\n== scenario 2: console dies + respawn loop -> FAIL (PR #1 regression) ==\n'
run_report console-dead
expect_rc "scenario 2: exit code" "$RC" 1
expect_line "$OUT" 'console has 2 unique PIDs' \
	"scenario 2: respawn loop caught via unique PIDs"
expect_line "$OUT" '[FAIL] console never exited' \
	"scenario 2: console exit status caught"
expect_line "$OUT" '[FAIL] console was not respawn-delayed' \
	"scenario 2: 'console: respawn delayed' caught"
expect_line "$OUT" "[ OK ]   service /etc/init.conf executed ('started console')" \
	"scenario 2: old checks pass (proof: the old harness PASSES on this log)"

printf '\n== scenario 3: console exits, single PID -> FAIL ==\n'
run_report console-exit-single-pid
expect_rc "scenario 3: exit code" "$RC" 1
expect_line "$OUT" '[FAIL] console never exited' \
	"scenario 3: exit status caught despite a single PID"

printf '\n== scenario 4: kernel panic -> FAIL ==\n'
run_report panic
expect_rc "scenario 4: exit code" "$RC" 1
expect_line "$OUT" '[FAIL] no kernel panic' "scenario 4: panic caught"

printf '\n== scenario 5: console service never starts -> FAIL ==\n'
run_report console-never-start
expect_rc "scenario 5: exit code" "$RC" 1
expect_line "$OUT" "[FAIL] service /etc/init.conf executed" \
	"scenario 5: missing 'started console' caught"
expect_line "$OUT" 'console has 0 unique PIDs' \
	"scenario 5: unique PID count 0"

printf '\n== scenario 6: main loop missing -> FAIL ==\n'
run_report no-main-loop
expect_rc "scenario 6: exit code" "$RC" 1
expect_line "$OUT" 'did not appear within' "scenario 6: absence of 'main loop ready' caught"

printf '\n== scenario 7: another service respawns, console healthy -> PASS ==\n'
run_report respawn-other-service
expect_rc "scenario 7: exit code" "$RC" 0
expect_line "$OUT" 'RESULT: PASS' \
	"scenario 7: 'web: respawn delayed' does not drag the harness down (scoped check)"
expect_line "$OUT" "[ OK ]   console was not respawn-delayed" \
	"scenario 7: the console respawn check still runs and passes"

printf '\n== console: REPORT_ONLY without CONSOLE_LOG -> stops with a clear message ==\n'
RC=0
CONSOLE_LOG="$FIX/missing.log" REPORT_ONLY=1 sh "$HARNESS" >/dev/null 2>&1 || RC=$?
expect_rc "bad configuration: non-zero exit code" "$RC" 1

if [ "$fail_count" -eq 0 ]; then
	printf '\nRESULT: PASS (all checks)\n'
else
	printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
	exit 1
fi
