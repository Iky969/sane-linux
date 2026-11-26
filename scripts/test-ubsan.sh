#!/bin/sh
# scripts/test-ubsan.sh -- run a bounded suite subset with the static UBSan build.
#
# ASan cannot cover these suites: they copy $BIN into a minimal chroot that has
# no libasan/libubsan runtime. `make ubsan` links UBSan statically instead, so
# the same suites can exercise the instrumented PID 1 binary without extra
# payload. Keep this list to suites that are fast and non-root-safe.
set -eu

REPO_ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$REPO_ROOT"

BIN_PATH="$REPO_ROOT/ninit-ubsan"
[ -x "$BIN_PATH" ] || { echo "run 'make ubsan' first" >&2; exit 1; }
file "$BIN_PATH" | grep -q 'statically linked' || {
    echo "FAIL: UBSan binary must be statically linked for the chroot suites" >&2
    exit 1
}

rc=0
for suite in scripts/test-state-machine.sh scripts/test-respawn-cleanup.sh; do
    printf '\n== UBSan: %s ==\n' "$suite"
    BIN="$BIN_PATH" UBSAN_OPTIONS=print_stacktrace=1 sh "$suite" || rc=1
done

if [ "$rc" -ne 0 ]; then
    echo "UBSan battery FAILED" >&2
else
    echo "UBSan battery PASSED"
fi
exit "$rc"
