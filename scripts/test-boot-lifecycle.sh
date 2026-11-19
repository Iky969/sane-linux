#!/bin/sh
# Boot and lifecycle regression suite for S.A.N.E Linux.
#
# Boots a persistent disk image in QEMU and drives the console through eight
# scenarios: first boot with no default credentials, interrupted setup, reboot
# before setup, wrong-password retry, normal login, repeated reboots,
# recovery from a corrupted account configuration, and reliability rollback
# of an interrupted upgrade after reboot.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE="$REPO_ROOT/distro/sane.img"
LOGDIR="${LIFECYCLE_LOGDIR:-/tmp/sane-lifecycle-logs}"
PY="$REPO_ROOT/scripts/qemu_lifecycle.py"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "SKIP: qemu-system-x86_64 not installed"
    exit 77
fi
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "SKIP: root or passwordless sudo required for loop devices"
    exit 77
fi
if [ ! -f "$IMAGE" ]; then
    echo "SKIP: $IMAGE not built (run 'make image' first)"
    exit 77
fi
if ! command -v losetup >/dev/null 2>&1; then
    echo "SKIP: losetup (util-linux) not installed"
    exit 77
fi

mkdir -p "$LOGDIR"
echo "Boot lifecycle logs: $LOGDIR"
python3 "$PY" "$IMAGE" --logdir "$LOGDIR" "$@"
