#!/bin/sh
# Boot and lifecycle regression suite for S.A.N.E Linux.
#
# Boots a persistent disk image in QEMU and drives the console through nine
# scenarios: first boot with no default credentials, interrupted setup, reboot
# before setup, wrong-password retry, normal login, repeated reboots,
# recovery from a corrupted account configuration, reliability rollback
# of an interrupted upgrade after reboot, and :on_fail=rescue failure entering
# supervised rescue mode.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE="$REPO_ROOT/distro/sane.img"
LOGDIR="${LIFECYCLE_LOGDIR:-/tmp/sane-lifecycle-logs}"
PY="$REPO_ROOT/scripts/qemu_lifecycle.py"

fail_or_skip() {
    if [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ]; then
        printf 'FAIL: %s (required in CI)\n' "$1" >&2
        exit 1
    fi
    printf 'SKIP: %s\n' "$1"
    exit 77
}

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    fail_or_skip "qemu-system-x86_64 not installed"
fi
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    fail_or_skip "root or passwordless sudo required for loop devices"
fi
if [ ! -f "$IMAGE" ]; then
    fail_or_skip "$IMAGE not built (run 'make image' first)"
fi
if ! command -v losetup >/dev/null 2>&1; then
    fail_or_skip "losetup (util-linux) not installed"
fi

mkdir -p "$LOGDIR"
echo "Boot lifecycle logs: $LOGDIR"
python3 "$PY" "$IMAGE" --logdir "$LOGDIR" "$@"
