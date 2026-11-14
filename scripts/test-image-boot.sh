#!/usr/bin/env bash
# test-image-boot.sh -- headless verification of S.A.N.E raw GPT disk image (sane.img)
# Boots sane.img in QEMU via Limine BIOS bootloader and asserts complete boot pipeline.
#
# Usage:
#   bash scripts/test-image-boot.sh [--image <path>] [--timeout <sec>] [--mem <mb>]
#
# Assertions (within 15s timeout):
#   1. Kernel & initramfs switch_root execution to /dev/vda2
#   2. ninit PID 1 startup banner & 'main loop ready'
#   3. Execution of hello service (or console shell)
#   4. Zero kernel panics (no 'Kernel panic' or 'Attempted to kill init')
#
# Return code:
#   0 = PASS (all markers verified)
#   1 = FAIL (markers missing or panic detected; dumps full diagnostic log)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DISTRO_DIR="${DISTRO_DIR:-$REPO_ROOT/distro}"

IMAGE_FILE="${IMAGE_FILE:-$DISTRO_DIR/sane.img}"
TIMEOUT_SECS="${TIMEOUT_SECS:-15}"
MEM="${MEM:-128M}"
CONSOLE_LOG="${CONSOLE_LOG:-$DISTRO_DIR/qemu-image-console.log}"
QEMU_LOG="${QEMU_LOG:-$DISTRO_DIR/qemu-image.log}"

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --image)
            IMAGE_FILE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT_SECS="$2"
            shift 2
            ;;
        --mem)
            MEM="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--image <path>] [--timeout <sec>] [--mem <mb>]"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

die()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "tool '$1' not found${2:+ ($2)}"; }

need qemu-system-x86_64 "apt-get install -y qemu-system-x86"
need timeout "coreutils"
need grep "grep"

# Ensure image exists; if absent, trigger make-image.sh
if [ ! -f "$IMAGE_FILE" ]; then
    printf '== Image %s not found. Invoking scripts/make-image.sh...\n' "$IMAGE_FILE"
    MAKE_IMAGE="$SCRIPT_DIR/make-image.sh"
    [ -f "$MAKE_IMAGE" ] || die "Cannot find $MAKE_IMAGE to build image"

    if [ "$(id -u)" -eq 0 ]; then
        bash "$MAKE_IMAGE" --output "$IMAGE_FILE"
    else
        sudo bash "$MAKE_IMAGE" --output "$IMAGE_FILE"
    fi

    [ -f "$IMAGE_FILE" ] || die "Failed to create image: $IMAGE_FILE does not exist after make-image.sh"
fi

mkdir -p "$DISTRO_DIR"
: > "$CONSOLE_LOG"
: > "$QEMU_LOG"

# Clean up QEMU processes on exit or interrupt
qemu_pid=""
cleanup() {
    set +e
    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill -TERM "$qemu_pid" 2>/dev/null || true
        # Wait up to 1 second for graceful termination
        for _ in $(seq 1 10); do
            kill -0 "$qemu_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Hardware acceleration vs TCG configuration
ACCEL_ARGS=()
if [ -w /dev/kvm ] 2>/dev/null; then
    ACCEL_ARGS+=(-enable-kvm -cpu host)
else
    ACCEL_ARGS+=(-cpu max)
fi

printf '== Starting Headless Image Boot Test ==\n'
printf '   Image     : %s (%s)\n' "$IMAGE_FILE" "$(du -h "$IMAGE_FILE" 2>/dev/null | cut -f1 || echo 'unknown')"
printf '   Timeout   : %ss\n' "$TIMEOUT_SECS"
printf '   Memory    : %s\n' "$MEM"
printf '   Console   : %s\n' "$CONSOLE_LOG"
printf '   Accel     : %s\n\n' "${ACCEL_ARGS[*]:-TCG default}"

# Launch QEMU with raw virtio-blk disk drive
timeout -k 2 "${TIMEOUT_SECS}s" qemu-system-x86_64 \
    -drive "file=$IMAGE_FILE,format=raw,if=virtio" \
    -m "$MEM" \
    -serial "file:$CONSOLE_LOG" \
    -display none \
    -no-reboot \
    "${ACCEL_ARGS[@]}" >>"$QEMU_LOG" 2>&1 &
qemu_pid=$!

T0=$(date +%s%N)
deadline=$(( $(date +%s) + TIMEOUT_SECS ))

switch_root_detected=0
banner_detected=0
ready_detected=0
service_detected=0
panic_detected=0

switch_root_ms=""
banner_ms=""
ready_ms=""
service_ms=""

mark_elapsed() {
    printf '%s' "$(( ($(date +%s%N) - T0) / 1000000 ))"
}

# Bounded poll loop (100ms ticks, deterministic bounded timeout)
while [ $(date +%s) -le $deadline ]; do
    # Check for panic immediately
    if grep -qiE "Kernel panic|Attempted to kill init" "$CONSOLE_LOG" 2>/dev/null; then
        panic_detected=1
        break
    fi

    # Check for switch_root to /dev/vda2
    if [ "$switch_root_detected" -eq 0 ]; then
        if grep -qiE "switch_root.*vda2|pivoting to /dev/vda2|switch_root /newroot" "$CONSOLE_LOG" 2>/dev/null || \
           (grep -qi "switch_root" "$CONSOLE_LOG" 2>/dev/null && grep -qi "vda2" "$CONSOLE_LOG" 2>/dev/null); then
            switch_root_detected=1
            switch_root_ms=$(mark_elapsed)
        fi
    fi

    # Check for ninit PID 1 startup banner
    if [ "$banner_detected" -eq 0 ]; then
        if grep -q "ninit start (PID 1)" "$CONSOLE_LOG" 2>/dev/null; then
            banner_detected=1
            banner_ms=$(mark_elapsed)
        fi
    fi

    # Check for ninit main loop ready
    if [ "$ready_detected" -eq 0 ]; then
        if grep -q "main loop ready" "$CONSOLE_LOG" 2>/dev/null; then
            ready_detected=1
            ready_ms=$(mark_elapsed)
        fi
    fi

    # Check for service execution (hello service or console shell)
    if [ "$service_detected" -eq 0 ]; then
        if grep -qiE "started sane-hello|started hello|started console|Hello from S.A.N.E Linux" "$CONSOLE_LOG" 2>/dev/null; then
            service_detected=1
            service_ms=$(mark_elapsed)
        fi
    fi

    # If all positive markers are detected and no panic, success!
    if [ "$switch_root_detected" -eq 1 ] && \
       [ "$banner_detected" -eq 1 ] && \
       [ "$ready_detected" -eq 1 ] && \
       [ "$service_detected" -eq 1 ]; then
        break
    fi

    # Check if QEMU exited early
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        break
    fi

    sleep 0.1
done

# Terminate QEMU child cleanly after assertions completed or timeout
if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill -TERM "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
fi

# Final checks and structured reporting
fail_count=0

printf '== Boot Milestone Assertions ==\n'

# Check 1: switch_root to /dev/vda2
if [ "$switch_root_detected" -eq 1 ]; then
    printf '  [ OK ]   Kernel & initramfs switch_root execution to /dev/vda2 (%s ms)\n' "$switch_root_ms"
else
    printf '  [FAIL] Kernel & initramfs switch_root execution to /dev/vda2 (NOT FOUND)\n'
    fail_count=$((fail_count + 1))
fi

# Check 2: ninit startup banner
if [ "$banner_detected" -eq 1 ]; then
    printf '  [ OK ]   ninit PID 1 startup banner detected (%s ms)\n' "$banner_ms"
else
    printf '  [FAIL] ninit PID 1 startup banner "ninit start (PID 1)" (NOT FOUND)\n'
    fail_count=$((fail_count + 1))
fi

# Check 3: ninit main loop ready
if [ "$ready_detected" -eq 1 ]; then
    printf '  [ OK ]   ninit main loop ready event loop entered (%s ms)\n' "$ready_ms"
else
    printf '  [FAIL] ninit event loop "main loop ready" (NOT FOUND)\n'
    fail_count=$((fail_count + 1))
fi

# Check 4: Service execution (hello service or console)
if [ "$service_detected" -eq 1 ]; then
    matched_svc=$(grep -oE "started sane-hello|started hello|started console|Hello from S.A.N.E Linux" "$CONSOLE_LOG" 2>/dev/null | head -n 1 || echo "service")
    printf '  [ OK ]   Execution of service verified: "%s" (%s ms)\n' "$matched_svc" "$service_ms"
else
    printf '  [FAIL] Execution of hello service or console shell (NOT FOUND)\n'
    fail_count=$((fail_count + 1))
fi

# Check 5: Zero kernel panics
if grep -qiE "Kernel panic|Attempted to kill init" "$CONSOLE_LOG" 2>/dev/null || [ "$panic_detected" -eq 1 ]; then
    panic_line=$(grep -iE "Kernel panic|Attempted to kill init" "$CONSOLE_LOG" 2>/dev/null | head -n 1 || echo "Kernel panic")
    printf '  [FAIL] Kernel panic detected: %s\n' "$panic_line"
    fail_count=$((fail_count + 1))
else
    printf '  [ OK ]   Zero kernel panics detected (clean kernel state)\n'
fi

printf '\n'

if [ "$fail_count" -eq 0 ]; then
    printf '========================================\n'
    printf 'RESULT: PASS (all boot pipeline markers verified)\n'
    printf '========================================\n'
    exit 0
else
    printf '========================================\n'
    printf 'RESULT: FAIL (%d milestone checks failed)\n' "$fail_count"
    printf '========================================\n'
    printf '\n-- Full Diagnostic Serial Console Log (%s) --\n' "$CONSOLE_LOG" >&2
    if [ -s "$CONSOLE_LOG" ]; then
        sed 's/^/  | /' "$CONSOLE_LOG" >&2
    else
        printf '  | <CONSOLE LOG IS EMPTY>\n' >&2
    fi
    if [ -s "$QEMU_LOG" ]; then
        printf '\n-- QEMU Stderr Log (%s) --\n' "$QEMU_LOG" >&2
        sed 's/^/  | /' "$QEMU_LOG" >&2
    fi
    exit 1
fi
