#!/bin/sh
# scripts/test-reliability.sh -- Phase C reliability regression suite.
# Runs without root against a temporary target rootfs. No host state is touched.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TOOL="$REPO_ROOT/scripts/sane-reliability"

PASS=0
FAIL=0
T=

pass() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1" >&2; }

check() { desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
expect_ok() { desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
expect_fail() { desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi; }

base() {
	[ -n "$T" ] && rm -rf -- "$T"
	T=$(mktemp -d)
	mkdir -p "$T/etc" "$T/var/lib/spm/installed/demo" "$T/var/log"
	printf 'network:once:/bin/true\n' > "$T/etc/init.conf"
	printf '1.0.0\n' > "$T/var/lib/spm/installed/demo/version"
	chmod 0644 "$T/etc/init.conf"
}

cleanup() { [ -n "$T" ] && rm -rf -- "$T"; }
trap cleanup EXIT HUP INT TERM

run() { sh "$TOOL" --root "$T" "$@"; }

base

# --- init ------------------------------------------------------------------
expect_ok "init creates the reliability state" run init
check "snapshot dir exists" test -d "$T/var/lib/sane/reliability/snapshots"
check "staging dir exists" test -d "$T/var/lib/sane/reliability/staging"
check "log dir exists" test -d "$T/var/log/sane"
check "journal starts idle" sh -c "grep -q '^state=idle$' '$T/var/lib/sane/reliability/journal'"
expect_ok "init is idempotent" run init

# --- snapshot / list / verify ----------------------------------------------
expect_ok "snapshot with a valid tag" run snapshot baseline
check "snapshot dir created" test -d "$T/var/lib/sane/reliability/snapshots/baseline"
check "snapshot keeps manifest" test -f "$T/var/lib/sane/reliability/snapshots/baseline/manifest.sha256"
check "snapshot keeps meta" test -f "$T/var/lib/sane/reliability/snapshots/baseline/meta"
check "snapshot copies /etc/init.conf" sh -c \
	"cmp -s '$T/etc/init.conf' '$T/var/lib/sane/reliability/snapshots/baseline/etc/init.conf'"
check "snapshot copies spm DB" sh -c \
	"cmp -s '$T/var/lib/spm/installed/demo/version' '$T/var/lib/sane/reliability/snapshots/baseline/var/lib/spm/installed/demo/version'"
expect_ok "verify accepts an intact snapshot" run verify baseline
expect_fail "invalid tag rejected" run snapshot ../escape
expect_fail "duplicate tag rejected" run snapshot baseline
expect_ok "force replaces an existing tag" run snapshot baseline --force

base
run init
run snapshot baseline
expect_ok "list prints the snapshot tag" sh -c "run() { sh '$TOOL' --root '$T' \"\$@\"; }; run list | grep -q baseline"
printf 'corrupted\n' > "$T/var/lib/sane/reliability/snapshots/baseline/etc/init.conf"
expect_fail "verify rejects a corrupted snapshot" run verify baseline

base
run init
expect_fail "verify unknown snapshot rejected" run verify missing

# --- rollback ---------------------------------------------------------------
base
run init
run snapshot golden
printf 'network:once:/bin/false\n' > "$T/etc/init.conf"
chmod 0600 "$T/etc/init.conf"
expect_ok "rollback restores a file" run rollback golden
check "rollback restored content" sh -c \
	"grep -q '^network:once:/bin/true$' '$T/etc/init.conf'"
check "rollback restored mode" test "$(stat -c %a "$T/etc/init.conf")" = 644
check "rollback journal records state" sh -c \
	"grep -q '^state=rolled-back$' '$T/var/lib/sane/reliability/journal'"
check "rollback made a safety snapshot" sh -c \
	"ls -d '$T/var/lib/sane/reliability/snapshots'/auto-pre-rollback-* >/dev/null 2>&1"
expect_fail "rollback to unknown tag rejected" run rollback missing

base
run init
run snapshot broken
printf 'bad\n' > "$T/var/lib/sane/reliability/snapshots/broken/etc/init.conf"
expect_fail "rollback rejects a corrupted snapshot" run rollback broken

# --- upgrade / recover ------------------------------------------------------
base
run init
mkdir -p "$T/payload/etc"
printf 'network:once:/bin/sleep 5\n' > "$T/payload/etc/init.conf"
expect_fail "upgrade rejects payload without manifest" run upgrade "$T/payload"
(cd "$T/payload" && sha256sum etc/init.conf > manifest.sha256)
expect_ok "upgrade with a valid payload" run upgrade "$T/payload"
check "upgrade committed the new file" sh -c \
	"grep -q '/bin/sleep 5' '$T/etc/init.conf'"
check "upgrade created a pre-upgrade snapshot" sh -c \
	"ls -d '$T/var/lib/sane/reliability/snapshots'/auto-pre-upgrade-* >/dev/null 2>&1"
check "upgrade journal records done" sh -c \
	"grep -q '^state=done$' '$T/var/lib/sane/reliability/journal'"
expect_ok "recover is a no-op after a successful upgrade" run recover

base
run init
run snapshot before
printf 'network:once:/bin/false\n' > "$T/etc/init.conf"
printf 'state=in-progress\nsnapshot=before\n' > "$T/var/lib/sane/reliability/journal"
expect_ok "recover restores the recorded snapshot" run recover
check "recover restored content" sh -c \
	"grep -q '/bin/true' '$T/etc/init.conf'"
check "recover journal records recovered" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal'"

base
run init
run snapshot broken2
printf 'bad\n' > "$T/var/lib/sane/reliability/snapshots/broken2/etc/init.conf"
printf 'state=in-progress\nsnapshot=broken2\n' > "$T/var/lib/sane/reliability/journal"
expect_fail "recover rejects a corrupted snapshot" run recover

# --- logging ---------------------------------------------------------------
base
run init
expect_ok "log writes an INFO entry" run log INFO "upgrade started"
check "log line has timestamp and level" sh -c \
	"grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* INFO upgrade started$' '$T/var/log/sane/reliability.log'"
expect_fail "log rejects an invalid level" run log VERBOSE "nope"
expect_fail "log rejects an empty message" run log INFO ""

base
run init
dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\0' 'x' > "$T/var/log/sane/reliability.log"
expect_ok "log rotates an oversized file" run log INFO "after rotation"
check "rotated log exists" test -f "$T/var/log/sane/reliability.log.1"
check "current log only has the new entry" test "$(wc -l < "$T/var/log/sane/reliability.log")" = 1

# --- backup / restore -------------------------------------------------------
base
run init
run snapshot keepme
expect_ok "backup creates an archive" run backup "$T/backup.tar.gz"
check "archive is non-empty" test -s "$T/backup.tar.gz"
expect_fail "backup refuses to overwrite by default" run backup "$T/backup.tar.gz"
expect_ok "backup --force overwrites" run backup "$T/backup.tar.gz" --force

base
expect_fail "restore rejects a missing archive" run restore "$T/nope.tar.gz"

base
run init
run snapshot keepme
run backup "$T/backup.tar.gz"
T2=$(mktemp -d)
mkdir -p "$T2/etc"
expect_ok "restore into a fresh root" sh -c \
	"sh '$TOOL' --root '$T2' restore '$T/backup.tar.gz'"
check "restore brings back the snapshot" test -d \
	"$T2/var/lib/sane/reliability/snapshots/keepme"
check "restore brings back the log dir" test -d "$T2/var/log/sane"
rm -rf -- "$T2"

printf '\nPhase C reliability tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
