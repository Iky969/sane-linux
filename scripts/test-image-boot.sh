#!/usr/bin/env bash
# test-image-boot.sh -- headless verification of S.A.N.E raw GPT disk image (sane.img)
# Boots sane.img in QEMU via Limine BIOS and UEFI bootloaders and asserts complete boot pipeline.
#
# Usage:
#   bash scripts/test-image-boot.sh [--image <path>] [--timeout <sec>] [--mem <mb>] [--bios|--uefi|--all] [--ovmf <path>]
#
# Assertions (within timeout):
#   1. Kernel & initramfs switch_root execution to /dev/vda2
#   2. ninit PID 1 startup banner & 'main loop ready'
#   3. Execution of hello service (or console shell)
#   4. Zero kernel panics (no 'Kernel panic' or 'Attempted to kill init')
#
# Return code:
#   0 = PASS (all requested boot modes verified)
#   1 = FAIL (markers missing or panic detected)
#   2 = PARTIAL / SKIP (UEFI skipped when --all was requested without OVMF)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DISTRO_DIR="${DISTRO_DIR:-$REPO_ROOT/distro}"

IMAGE_FILE="${IMAGE_FILE:-$DISTRO_DIR/sane.img}"
TIMEOUT_SECS="${TIMEOUT_SECS:-20}"
MEM="${MEM:-256M}"
MODE="all"
OVMF_PATH="${OVMF_PATH:-}"

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
        --bios)
            MODE="bios"
            shift
            ;;
        --uefi)
            MODE="uefi"
            shift
            ;;
        --all)
            MODE="all"
            shift
            ;;
        --ovmf)
            OVMF_PATH="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: scripts/test-image-boot.sh [OPTIONS]

Options:
  --image <path>     Path to raw GPT disk image (default: distro/sane.img)
  --timeout <sec>    Timeout per boot test in seconds (default: 20)
  --mem <mb>         Memory size for QEMU (default: 256M)
  --bios             Run BIOS boot test only
  --uefi             Run UEFI boot test only (requires OVMF)
  --all              Run both BIOS and UEFI boot tests sequentially (default)
  --ovmf <path>      Path to OVMF UEFI firmware file (auto-detected if omitted)
  -h, --help         Show this help message
EOF
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

# Auto-detect standard OVMF firmware file paths
find_ovmf() {
    if [ -n "$OVMF_PATH" ]; then
        if [ -f "$OVMF_PATH" ]; then
            echo "$OVMF_PATH"
            return 0
        fi
        return 1
    fi

    local candidates=(
        "/usr/share/ovmf/OVMF.fd"
        "/usr/share/OVMF/OVMF.fd"
        "/usr/share/qemu/OVMF.fd"
        "/usr/share/edk2-ovmf/x64/OVMF.fd"
        "/usr/share/edk2/ovmf/OVMF.fd"
    )

    for cand in "${candidates[@]}"; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done

    return 1
}

ACTIVE_OVMF=""
if [ "$MODE" = "uefi" ] || [ "$MODE" = "all" ]; then
    ACTIVE_OVMF="$(find_ovmf || true)"
    if [ -z "$ACTIVE_OVMF" ]; then
        if [ "$MODE" = "uefi" ]; then
            die "OVMF UEFI firmware not found. Please install ovmf (apt-get install -y ovmf) or pass --ovmf <path>"
        else
            printf 'WARNING: OVMF firmware not detected on host; UEFI boot test will be SKIPPED.\n\n'
        fi
    fi
fi

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

# Clean up QEMU processes on exit or interrupt
qemu_pid=""
cleanup() {
    set +e
    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill -TERM "$qemu_pid" 2>/dev/null || true
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

# Test status and milestone tracking variables
bios_status="NOT RUN"
bios_details="Test not executed"
bios_switch_root_ms="N/A"
bios_banner_ms="N/A"
bios_ready_ms="N/A"
bios_service_ms="N/A"
bios_panic="N/A"

uefi_status="NOT RUN"
uefi_details="Test not executed"
uefi_skip_reason=""
uefi_switch_root_ms="N/A"
uefi_banner_ms="N/A"
uefi_ready_ms="N/A"
uefi_service_ms="N/A"
uefi_panic="N/A"

OVERALL_RESULT="FAIL"
FINAL_EXIT_CODE=1

run_boot_test() {
    local target_mode="$1"
    local mode_label
    mode_label="$(echo "$target_mode" | tr '[:lower:]' '[:upper:]')"

    local console_log="$DISTRO_DIR/qemu-image-console-${target_mode}.log"
    local qemu_log="$DISTRO_DIR/qemu-image-${target_mode}.log"
    : > "$console_log"
    : > "$qemu_log"

    # Also sync to default logs for backward compatibility
    ln -sf "qemu-image-console-${target_mode}.log" "$DISTRO_DIR/qemu-image-console.log" 2>/dev/null || cp "$console_log" "$DISTRO_DIR/qemu-image-console.log" 2>/dev/null || true
    ln -sf "qemu-image-${target_mode}.log" "$DISTRO_DIR/qemu-image.log" 2>/dev/null || cp "$qemu_log" "$DISTRO_DIR/qemu-image.log" 2>/dev/null || true

    local test_mem="$MEM"
    if [ "$target_mode" = "uefi" ] && [ "$MEM" = "128M" ]; then
        # OVMF runtime services and high-memory allocation requirements for Limine x64
        test_mem="256M"
    fi

    local qemu_cmd=(
        qemu-system-x86_64
    )
    if [ "$target_mode" = "uefi" ]; then
        qemu_cmd+=(-bios "$ACTIVE_OVMF")
    fi
    qemu_cmd+=(
        -drive "file=$IMAGE_FILE,format=raw,if=virtio"
        -snapshot
        -m "$test_mem"
        -serial "file:$console_log"
        -display none
        -no-reboot
        "${ACCEL_ARGS[@]}"
    )

    printf '== Starting Headless Image Boot Test [%s] ==\n' "$mode_label"
    printf '   Mode      : %s\n' "$mode_label"
    if [ "$target_mode" = "uefi" ]; then
        printf '   Firmware  : %s\n' "$ACTIVE_OVMF"
    fi
    printf '   Image     : %s (%s)\n' "$IMAGE_FILE" "$(du -h "$IMAGE_FILE" 2>/dev/null | cut -f1 || echo 'unknown')"
    printf '   Timeout   : %ss\n' "$TIMEOUT_SECS"
    printf '   Memory    : %s\n' "$test_mem"
    printf '   Console   : %s\n' "$console_log"
    printf '   Accel     : %s\n\n' "${ACCEL_ARGS[*]:-TCG default}"

    timeout -k 2 "${TIMEOUT_SECS}s" "${qemu_cmd[@]}" >>"$qemu_log" 2>&1 &
    qemu_pid=$!

    local T0
    T0=$(date +%s%N)
    local deadline=$(( $(date +%s) + TIMEOUT_SECS ))

    local switch_root_detected=0
    local banner_detected=0
    local ready_detected=0
    local service_detected=0
    local panic_detected=0

    local switch_root_ms=""
    local banner_ms=""
    local ready_ms=""
    local service_ms=""

    mark_elapsed() {
        printf '%s' "$(( ($(date +%s%N) - T0) / 1000000 ))"
    }

    while [ $(date +%s) -le $deadline ]; do
        if grep -qiE "Kernel panic|Attempted to kill init" "$console_log" 2>/dev/null; then
            panic_detected=1
            break
        fi

        if [ "$switch_root_detected" -eq 0 ]; then
            if grep -qiE "switch_root.*vda2|pivoting to /dev/vda2|switch_root /newroot" "$console_log" 2>/dev/null || \
               (grep -qi "switch_root" "$console_log" 2>/dev/null && grep -qi "vda2" "$console_log" 2>/dev/null); then
                switch_root_detected=1
                switch_root_ms=$(mark_elapsed)
            fi
        fi

        if [ "$banner_detected" -eq 0 ]; then
            if grep -q "ninit start (PID 1)" "$console_log" 2>/dev/null; then
                banner_detected=1
                banner_ms=$(mark_elapsed)
            fi
        fi

        if [ "$ready_detected" -eq 0 ]; then
            if grep -q "main loop ready" "$console_log" 2>/dev/null; then
                ready_detected=1
                ready_ms=$(mark_elapsed)
            fi
        fi

        if [ "$service_detected" -eq 0 ]; then
            if grep -qiE "started sane-hello|started hello|started console|Hello from S.A.N.E Linux" "$console_log" 2>/dev/null; then
                service_detected=1
                service_ms=$(mark_elapsed)
            fi
        fi

        if [ "$switch_root_detected" -eq 1 ] && \
           [ "$banner_detected" -eq 1 ] && \
           [ "$ready_detected" -eq 1 ] && \
           [ "$service_detected" -eq 1 ]; then
            break
        fi

        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            break
        fi

        sleep 0.1
    done

    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill -TERM "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi

    local fail_count=0
    printf '== Boot Milestone Assertions [%s] ==\n' "$mode_label"

    if [ "$switch_root_detected" -eq 1 ]; then
        printf '  [ OK ]   Kernel & initramfs switch_root execution to /dev/vda2 (%s ms)\n' "$switch_root_ms"
    else
        printf '  [FAIL] Kernel & initramfs switch_root execution to /dev/vda2 (NOT FOUND)\n'
        fail_count=$((fail_count + 1))
    fi

    if [ "$banner_detected" -eq 1 ]; then
        printf '  [ OK ]   ninit PID 1 startup banner detected (%s ms)\n' "$banner_ms"
    else
        printf '  [FAIL] ninit PID 1 startup banner "ninit start (PID 1)" (NOT FOUND)\n'
        fail_count=$((fail_count + 1))
    fi

    if [ "$ready_detected" -eq 1 ]; then
        printf '  [ OK ]   ninit main loop ready event loop entered (%s ms)\n' "$ready_ms"
    else
        printf '  [FAIL] ninit event loop "main loop ready" (NOT FOUND)\n'
        fail_count=$((fail_count + 1))
    fi

    if [ "$service_detected" -eq 1 ]; then
        local matched_svc
        matched_svc=$(grep -oE "started sane-hello|started hello|started console|Hello from S.A.N.E Linux" "$console_log" 2>/dev/null | head -n 1 || echo "service")
        printf '  [ OK ]   Execution of service verified: "%s" (%s ms)\n' "$matched_svc" "$service_ms"
    else
        printf '  [FAIL] Execution of hello service or console shell (NOT FOUND)\n'
        fail_count=$((fail_count + 1))
    fi

    if grep -qiE "Kernel panic|Attempted to kill init" "$console_log" 2>/dev/null || [ "$panic_detected" -eq 1 ]; then
        local panic_line
        panic_line=$(grep -iE "Kernel panic|Attempted to kill init" "$console_log" 2>/dev/null | head -n 1 || echo "Kernel panic")
        printf '  [FAIL] Kernel panic detected: %s\n' "$panic_line"
        fail_count=$((fail_count + 1))
    else
        printf '  [ OK ]   Zero kernel panics detected (clean kernel state)\n'
    fi

    printf '\n'

    local res=0
    if [ "$fail_count" -eq 0 ]; then
        printf '========================================\n'
        printf 'RESULT [%s]: PASS (all boot pipeline markers verified)\n' "$mode_label"
        printf '========================================\n'
        res=0
        if [ "$target_mode" = "bios" ]; then
            bios_status="PASS"
            bios_details="All boot pipeline markers verified"
        else
            uefi_status="PASS"
            uefi_details="All boot pipeline markers verified"
        fi
    else
        printf '========================================\n'
        printf 'RESULT [%s]: FAIL (%d milestone checks failed)\n' "$mode_label" "$fail_count"
        printf '========================================\n'
        printf '\n-- Full Diagnostic Serial Console Log (%s) --\n' "$console_log" >&2
        if [ -s "$console_log" ]; then
            sed 's/^/  | /' "$console_log" >&2
        else
            printf '  | <CONSOLE LOG IS EMPTY>\n' >&2
        fi
        if [ -s "$qemu_log" ]; then
            printf '\n-- QEMU Stderr Log (%s) --\n' "$qemu_log" >&2
            sed 's/^/  | /' "$qemu_log" >&2
        fi
        res=1
        if [ "$target_mode" = "bios" ]; then
            bios_status="FAIL"
            bios_details="${fail_count} milestone checks failed"
        else
            uefi_status="FAIL"
            uefi_details="${fail_count} milestone checks failed"
        fi
    fi

    if [ "$target_mode" = "bios" ]; then
        bios_switch_root_ms="$([ "$switch_root_detected" -eq 1 ] && echo "${switch_root_ms} ms" || echo "NOT FOUND (FAIL)")"
        bios_banner_ms="$([ "$banner_detected" -eq 1 ] && echo "${banner_ms} ms" || echo "NOT FOUND (FAIL)")"
        bios_ready_ms="$([ "$ready_detected" -eq 1 ] && echo "${ready_ms} ms" || echo "NOT FOUND (FAIL)")"
        bios_service_ms="$([ "$service_detected" -eq 1 ] && echo "${service_ms} ms" || echo "NOT FOUND (FAIL)")"
        bios_panic="$([ "$panic_detected" -eq 1 ] && echo "Kernel panic detected (FAIL)" || echo "Zero panics (OK)")"
    else
        uefi_switch_root_ms="$([ "$switch_root_detected" -eq 1 ] && echo "${switch_root_ms} ms" || echo "NOT FOUND (FAIL)")"
        uefi_banner_ms="$([ "$banner_detected" -eq 1 ] && echo "${banner_ms} ms" || echo "NOT FOUND (FAIL)")"
        uefi_ready_ms="$([ "$ready_detected" -eq 1 ] && echo "${ready_ms} ms" || echo "NOT FOUND (FAIL)")"
        uefi_service_ms="$([ "$service_detected" -eq 1 ] && echo "${service_ms} ms" || echo "NOT FOUND (FAIL)")"
        uefi_panic="$([ "$panic_detected" -eq 1 ] && echo "Kernel panic detected (FAIL)" || echo "Zero panics (OK)")"
    fi

    return "$res"
}

archive_test_results() {
    local doc_dir="$REPO_ROOT/doc"
    local archives_dir="$doc_dir/archives"
    mkdir -p "$archives_dir"

    # Ensure docs symlink exists
    if [ ! -e "$REPO_ROOT/docs" ] && [ ! -L "$REPO_ROOT/docs" ]; then
        ln -sf doc "$REPO_ROOT/docs"
    fi

    # Archive console logs (always overwrite)
    local bios_console="$DISTRO_DIR/qemu-image-console-bios.log"
    local uefi_console="$DISTRO_DIR/qemu-image-console-uefi.log"

    if [ "$bios_status" != "NOT RUN" ] && [ -f "$bios_console" ]; then
        cp -f "$bios_console" "$archives_dir/qemu-image-console-bios.log"
    else
        printf 'BIOS boot test was not executed in this run (mode: %s).\n' "$MODE" > "$archives_dir/qemu-image-console-bios.log"
    fi

    if [ "$uefi_status" = "SKIP" ]; then
        printf 'UEFI boot test was SKIPPED: %s\n' "${uefi_skip_reason:-OVMF firmware not detected on host}" > "$archives_dir/qemu-image-console-uefi.log"
    elif [ "$uefi_status" != "NOT RUN" ] && [ -f "$uefi_console" ]; then
        cp -f "$uefi_console" "$archives_dir/qemu-image-console-uefi.log"
    else
        printf 'UEFI boot test was not executed in this run (mode: %s).\n' "$MODE" > "$archives_dir/qemu-image-console-uefi.log"
    fi

    # Generate boot-test-report.md (always overwrite)
    local img_size
    img_size="$(du -h "$IMAGE_FILE" 2>/dev/null | cut -f1 || echo 'unknown')"
    local img_bytes
    img_bytes="$(stat -c %s "$IMAGE_FILE" 2>/dev/null || stat -f %z "$IMAGE_FILE" 2>/dev/null || echo '0')"
    local test_date
    test_date="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    local bios_timings_md
    if [ "$bios_status" = "NOT RUN" ]; then
        bios_timings_md="- Test not executed in this run (mode: \`${MODE}\`)"
    else
        bios_timings_md="- **switch_root to /dev/vda2**: ${bios_switch_root_ms}
- **ninit PID 1 startup banner**: ${bios_banner_ms}
- **ninit main loop ready**: ${bios_ready_ms}
- **Service execution (sane-hello / console)**: ${bios_service_ms}
- **Kernel panic check**: ${bios_panic}"
    fi

    local uefi_timings_md
    if [ "$uefi_status" = "SKIP" ]; then
        uefi_timings_md="- **Skip Reason**: ${uefi_skip_reason:-OVMF firmware not detected on host}"
    elif [ "$uefi_status" = "NOT RUN" ]; then
        uefi_timings_md="- Test not executed in this run (mode: \`${MODE}\`)"
    else
        uefi_timings_md="- **switch_root to /dev/vda2**: ${uefi_switch_root_ms}
- **ninit PID 1 startup banner**: ${uefi_banner_ms}
- **ninit main loop ready**: ${uefi_ready_ms}
- **Service execution (sane-hello / console)**: ${uefi_service_ms}
- **Kernel panic check**: ${uefi_panic}"
    fi

    cat > "$archives_dir/boot-test-report.md" <<EOF
# S.A.N.E Linux Boot Verification Report

- **Timestamp**: ${test_date}
- **Test Mode**: \`${MODE}\`
- **Overall Result**: **${OVERALL_RESULT}** (Exit code: ${FINAL_EXIT_CODE})
- **Disk Image**: \`$(basename "$IMAGE_FILE")\` (${img_size}, ${img_bytes} bytes)
- **QEMU Acceleration**: \`${ACCEL_ARGS[*]:-TCG default}\`
- **UEFI Firmware**: \`${ACTIVE_OVMF:-Not detected / None}\`

## Test Summary

| Test Mode | Status | Details |
| :--- | :--- | :--- |
| **BIOS Boot** | \`${bios_status}\` | ${bios_details} |
| **UEFI Boot** | \`${uefi_status}\` | ${uefi_skip_reason:-${uefi_details}} |

## Milestone Check Timings

### BIOS Boot Verification
- **Status**: \`${bios_status}\`
${bios_timings_md}

### UEFI Boot Verification
- **Status**: \`${uefi_status}\`
${uefi_timings_md}

## Console Logs
- BIOS Console Log: [\`qemu-image-console-bios.log\`](./qemu-image-console-bios.log)
- UEFI Console Log: [\`qemu-image-console-uefi.log\`](./qemu-image-console-uefi.log)
EOF

    printf '== Test report archived to %s/boot-test-report.md ==\n\n' "$archives_dir"
}

case "$MODE" in
    bios)
        if run_boot_test "bios"; then
            OVERALL_RESULT="PASS"
            FINAL_EXIT_CODE=0
        else
            OVERALL_RESULT="FAIL"
            FINAL_EXIT_CODE=1
        fi
        archive_test_results
        exit "$FINAL_EXIT_CODE"
        ;;
    uefi)
        if [ -z "$ACTIVE_OVMF" ]; then
            die "OVMF UEFI firmware not found. Please install ovmf (apt-get install -y ovmf) or pass --ovmf <path>"
        fi
        if run_boot_test "uefi"; then
            OVERALL_RESULT="PASS"
            FINAL_EXIT_CODE=0
        else
            OVERALL_RESULT="FAIL"
            FINAL_EXIT_CODE=1
        fi
        archive_test_results
        exit "$FINAL_EXIT_CODE"
        ;;
    all)
        printf '==================================================\n'
        printf 'Starting Dual Boot Verification: BIOS and UEFI\n'
        printf '==================================================\n\n'
        run_boot_test "bios" || true
        printf '\n'
        if [ -n "$ACTIVE_OVMF" ]; then
            run_boot_test "uefi" || true
        else
            uefi_status="SKIP"
            uefi_skip_reason="OVMF firmware not detected on host"
            uefi_details="SKIP (OVMF firmware not detected on host)"
            printf '== Skipping Headless Image Boot Test [UEFI] ==\n'
            printf '   Reason: OVMF firmware not detected on host\n\n'
        fi
        printf '\n'
        printf '==================================================\n'
        printf 'Dual Boot Summary:\n'
        printf '  BIOS Boot : %s\n' "$bios_status"
        if [ "$uefi_status" = "SKIP" ]; then
            printf '  UEFI Boot : SKIP (%s)\n' "$uefi_skip_reason"
        else
            printf '  UEFI Boot : %s\n' "$uefi_status"
        fi
        printf '==================================================\n'

        if [ "$bios_status" = "PASS" ] && [ "$uefi_status" = "PASS" ]; then
            OVERALL_RESULT="PASS"
            FINAL_EXIT_CODE=0
            printf 'RESULT: ALL BOOT MODES PASSED\n'
        elif [ "$bios_status" = "FAIL" ] || [ "$uefi_status" = "FAIL" ]; then
            OVERALL_RESULT="FAIL"
            FINAL_EXIT_CODE=1
            printf 'RESULT: BOOT VERIFICATION FAILED\n'
        else
            OVERALL_RESULT="PARTIAL / SKIP"
            FINAL_EXIT_CODE=2
            printf 'RESULT: PARTIAL / SKIP (UEFI boot test was skipped)\n'
        fi
        archive_test_results
        exit "$FINAL_EXIT_CODE"
        ;;
esac
