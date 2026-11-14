#!/bin/sh
# fuzz-parsers.sh -- ASan + UBSan fuzz harness for ninit's input parsers.
#
# Driver : tests/fuzz/fuzz_parse.c (includes ninit.c with main() renamed)
# Targets (real code):
#   - parse_config()        : /etc/init.conf parser (mode "config")
#   - parse_mount_flags()   : /etc/fstab option classifier (mode "fstab")
#   - initctl_parse_stream() : /run/initctl streaming line reader (mode "initctl")
#   - deterministic LCG mutations through all three (mode "mutate")
#
# mount_fstab() itself is NOT executed: it performs real mount(2)/mkdir(2)
# syscalls on the host, which is unsafe for a fuzzer. Its pure parsing half
# (parse_mount_flags) is fuzzed instead; the syscall glue is covered by the
# chroot/unshare suites (test-cgroup-limits.sh, test-integration.sh).
#
# Every generated input (0/1/1000 lines, raw hex bytes, no trailing newline,
# empty/".." names, cyclic :requires=, stacked tags, odd fstab options,
# multi-line initctl) must leave the driver exit code 0 with zero sanitizer
# report. Exit 0 = PASS, 1 = FAIL, 77 = SKIP (sanitizer unsupported).
#
# Usage:
#   make fuzz              # or: sh ./scripts/fuzz-parsers.sh
#
# Environment:
#   CC=gcc                 compiler (must support -fsanitize=address,undefined)
#   MUT_SEED=12345         LCG seed for the mutation loop
#   MUT_ITERS=2000         mutation iterations

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DRIVER="$REPO_ROOT/tests/fuzz/fuzz_parse.c"
CC=${CC:-gcc}
MUT_SEED=${MUT_SEED:-12345}
MUT_ITERS=${MUT_ITERS:-2000}

[ -f "$DRIVER" ] || { echo "FAIL: fuzz driver not found at $DRIVER"; exit 1; }

WORK=$(mktemp -d /tmp/ninit-fuzz.XXXXXX)
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# 1. Build the driver with AddressSanitizer + UndefinedBehaviorSanitizer.
#    Fail-closed: no sanitizer support -> SKIP (77), never a fake PASS.
# ---------------------------------------------------------------------------
if ! "$CC" -O1 -g -fno-omit-frame-pointer \
        -fsanitize=address,undefined \
        -o "$WORK/fuzz_parse" "$DRIVER" 2>"$WORK/build.log"; then
    if grep -qiE "unsupported|unrecognized|cannot find|not supported" "$WORK/build.log"; then
        echo "SKIP: compiler $CC has no ASan/UBSan support"
        sed 's/^/    | /' "$WORK/build.log" | head -10
        exit 77
    fi
    echo "FAIL: could not build the ASan/UBSan driver with $CC"
    sed 's/^/    | /' "$WORK/build.log" | head -30
    exit 1
fi

export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0:exitcode=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"

# ---------------------------------------------------------------------------
# 2. Case runner: exit code 0 AND zero sanitizer report required
# ---------------------------------------------------------------------------
run_case() {
    _mode=$1; _name=$2; _file=$3
    _rc=0
    _out=$("$WORK/fuzz_parse" "$_mode" "$_file" 2>&1) || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        fail "$_name" "driver exit code $_rc"
        printf '%s\n' "$_out" | sed 's/^/    | /' | head -20
        return
    fi
    if printf '%s\n' "$_out" | grep -qE "AddressSanitizer|LeakSanitizer|runtime error:|SUMMARY: .*Sanitizer"; then
        fail "$_name" "sanitizer report detected"
        printf '%s\n' "$_out" | grep -E "AddressSanitizer|LeakSanitizer|runtime error:|SUMMARY" | head -10 | sed 's/^/    | /'
        return
    fi
    pass "$_name"
}

# ---------------------------------------------------------------------------
# 3. Generated inputs
# ---------------------------------------------------------------------------
printf '== fuzz-parsers: ASan+UBSan parser harness ==\n'

# ---- init.conf (parse_config) ----
: > "$WORK/c_empty"
printf 'svc:once:/bin/true\n' > "$WORK/c_one"
: > "$WORK/c_many"
_i=0
while [ "$_i" -lt 1000 ]; do
    printf 's%s:once:/bin/true:memory_max=1M:pids_max=2\n' "$_i" >> "$WORK/c_many"
    _i=$((_i + 1))
done
printf '\x00\x01\x02\xff\xfe\xfd\x7f' > "$WORK/c_hex"
printf 'svc:once:/bin/true' > "$WORK/c_nonewline"
printf ':once:/bin/true\n' > "$WORK/c_emptyname"
printf '..:once:/bin/true\n' > "$WORK/c_dotdot"
printf 'a/b:once:/bin/true\n' > "$WORK/c_slash"
printf 'a:once:/bin/true:requires=b\nb:once:/bin/true:requires=a\n' > "$WORK/c_cyclic"
printf 'a:once:/bin/true:memory_max=1M:memory_max=2M:cpu_max=1 1:pids_max=1:pids_max=2\n' > "$WORK/c_stacked"
head -c 4096 /dev/zero | tr '\0' 'a' > "$WORK/c_longline"; printf '\n' >> "$WORK/c_longline"
printf 'a:b:c:d:e:f:g:h\n' > "$WORK/c_colons"
printf 'a:once:/bin/true\r\nb:once:/bin/true\r\n' > "$WORK/c_crlf"

run_case config "config: empty file" "$WORK/c_empty"
run_case config "config: single valid line" "$WORK/c_one"
run_case config "config: 1000 lines" "$WORK/c_many"
run_case config "config: raw hex bytes" "$WORK/c_hex"
run_case config "config: no trailing newline" "$WORK/c_nonewline"
run_case config "config: empty service name" "$WORK/c_emptyname"
run_case config "config: '..' service name" "$WORK/c_dotdot"
run_case config "config: name containing '/'" "$WORK/c_slash"
run_case config "config: cyclic :requires=" "$WORK/c_cyclic"
run_case config "config: stacked tags" "$WORK/c_stacked"
run_case config "config: over-long line (> MAX_LINE)" "$WORK/c_longline"
run_case config "config: many colon fields" "$WORK/c_colons"
run_case config "config: CRLF line endings" "$WORK/c_crlf"

# ---- /etc/fstab options (parse_mount_flags) ----
printf '' > "$WORK/f_empty"
printf 'rw,ro,noatime,user,bind,noauto,x-foo\n' > "$WORK/f_mixed"
printf 'defaults\n' > "$WORK/f_defaults"
printf '!!!,@@@,###,with space,tab\there,=,,,\n' > "$WORK/f_garbage"
head -c 4096 /dev/zero | tr '\0' 'x' > "$WORK/f_long"; printf '\n' >> "$WORK/f_long"
printf 'remount,bind,rbind,user,exec,suid,dev,nouser,auto,_netdev,nofail\n' > "$WORK/f_flags"
printf '\x00\x01\xff\n' > "$WORK/f_hex"

run_case fstab "fstab: empty options" "$WORK/f_empty"
run_case fstab "fstab: mixed flags + userspace + data" "$WORK/f_mixed"
run_case fstab "fstab: defaults" "$WORK/f_defaults"
run_case fstab "fstab: garbage tokens" "$WORK/f_garbage"
run_case fstab "fstab: over-long option string" "$WORK/f_long"
run_case fstab "fstab: bind/rbind/remount/user implications" "$WORK/f_flags"
run_case fstab "fstab: raw hex bytes" "$WORK/f_hex"

# ---- /run/initctl (initctl_parse_stream) ----
: > "$WORK/i_empty"
printf 'poweroff\nreboot\n' > "$WORK/i_multi"
printf '\n\npoweroff\n\nreboot\n\n' > "$WORK/i_blank"
printf 'poweroff' > "$WORK/i_nonewline"
head -c 4096 /dev/zero | tr '\0' 'p' > "$WORK/i_long"; printf '\n' >> "$WORK/i_long"
printf '\x00\x01\xffpoweroff\n' > "$WORK/i_hex"
printf '  poweroff  \n\treboot\t\n' > "$WORK/i_spaces"

run_case initctl "initctl: empty buffer" "$WORK/i_empty"
run_case initctl "initctl: multi-line commands" "$WORK/i_multi"
run_case initctl "initctl: blank lines interspersed" "$WORK/i_blank"
run_case initctl "initctl: no trailing newline" "$WORK/i_nonewline"
run_case initctl "initctl: over-long line" "$WORK/i_long"
run_case initctl "initctl: raw hex bytes" "$WORK/i_hex"
run_case initctl "initctl: leading/trailing whitespace" "$WORK/i_spaces"

# ---- deterministic mutation loop (all three parsers) ----
_mut_rc=0
_mut_out=$("$WORK/fuzz_parse" mutate "$MUT_SEED" "$MUT_ITERS" 2>&1) || _mut_rc=$?
if [ "$_mut_rc" -ne 0 ]; then
    fail "mutations" "driver exit code $_mut_rc"
    printf '%s\n' "$_mut_out" | sed 's/^/    | /' | head -20
elif printf '%s\n' "$_mut_out" | grep -qE "AddressSanitizer|LeakSanitizer|runtime error:|SUMMARY: .*Sanitizer"; then
    fail "mutations" "sanitizer report detected"
    printf '%s\n' "$_mut_out" | grep -E "AddressSanitizer|LeakSanitizer|runtime error:|SUMMARY" | head -10 | sed 's/^/    | /'
else
    pass "mutations: $MUT_ITERS deterministic iterations (seed $MUT_SEED)"
fi

# ---------------------------------------------------------------------------
# 4. Report
# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS: fuzz-parsers (%s checks passed, zero ASan/UBSan reports)\n' "$PASS"
    exit 0
fi
printf 'FAIL: fuzz-parsers (%s failures)\n' "$FAIL"
exit 1
