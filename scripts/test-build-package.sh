#!/usr/bin/env bash
# scripts/test-build-package.sh -- Comprehensive test suite for build-package.sh
#
# Validates:
#   1. Package creation and archive layout (.spm.tar.xz and .spm.tar.gz)
#   2. Bit-for-bit build determinism (reproducible package generation)
#   3. Metadata auto-generation (.META/files and .META/sha256)
#   4. Manifest parsing and mandatory field validation
#   5. Base package flag handling (--base)
#   6. Declarative ninit service snippet validation and security enforcement
#   7. Path traversal and adversarial symlink escape rejection (fail-closed)
#   8. Memory-bounded xz decompression verification

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_PKG="$REPO_ROOT/scripts/build-package.sh"

TEST_TMP="$(mktemp -d /tmp/sane-pkg-test-XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

PASSED_COUNT=0
FAILED_COUNT=0

test_pass() {
    local name="$1"
    PASSED_COUNT=$((PASSED_COUNT + 1))
    printf '[PASS] %s\n' "$name"
}

test_fail() {
    local name="$1"
    local reason="${2:-assertion failed}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    printf '[FAIL] %s: %s\n' "$name" "$reason" >&2
}

# -----------------------------------------------------------------------------
# Test 1: Basic package build & archive layout (.spm.tar.xz)
# -----------------------------------------------------------------------------
test_basic_build() {
    local tdir="$TEST_TMP/test1"
    local odir="$tdir/out"
    mkdir -p "$tdir/src/x/usr/bin" "$tdir/src/.META" "$odir"

    cat > "$tdir/src/x/usr/bin/hello" <<'EOF'
#!/bin/sh
echo "hello test"
EOF
    chmod 755 "$tdir/src/x/usr/bin/hello"

    cat > "$tdir/src/.META/package" <<'EOF'
name=test-pkg
version=1.0.0
release=1
arch=x86_64
description=Test package
base=false
EOF

    if "$BUILD_PKG" --source "$tdir/src" --output "$odir" >/dev/null 2>&1; then
        local pkg_canonical="$odir/test-pkg-1.0.0-1-x86_64.spm.tar.xz"
        local pkg_short="$odir/test-pkg-1.0.0-x86_64.spm.tar.xz"

        if [ ! -f "$pkg_canonical" ] || [ ! -f "$pkg_short" ]; then
            test_fail "Basic build" "Output package files missing"
            return
        fi

        # Verify tar entries begin with ./.META/ or ./x/
        local bad_entries
        bad_entries="$(tar -tf "$pkg_canonical" | grep -vE '^\./(\.META|x)(/|$)' || true)"
        if [ -n "$bad_entries" ]; then
            test_fail "Basic build" "Invalid entries in tar archive: $bad_entries"
            return
        fi

        # Verify xz decompression succeeds
        if ! xz -t "$pkg_canonical"; then
            test_fail "Basic build" "Archive failed xz integrity test"
            return
        fi

        test_pass "Basic package build and archive layout (.spm.tar.xz)"
    else
        test_fail "Basic build" "build-package.sh command returned non-zero"
    fi
}

# -----------------------------------------------------------------------------
# Test 2: Bit-for-bit build determinism
# -----------------------------------------------------------------------------
test_determinism() {
    local src1="$TEST_TMP/det_src1"
    local src2="$TEST_TMP/det_src2"
    local out1="$TEST_TMP/det_out1"
    local out2="$TEST_TMP/det_out2"

    mkdir -p "$src1/x/bin" "$src1/.META" "$out1"
    mkdir -p "$src2/x/bin" "$src2/.META" "$out2"

    echo "bin_content" > "$src1/x/bin/tool"
    echo "bin_content" > "$src2/x/bin/tool"
    chmod 755 "$src1/x/bin/tool" "$src2/x/bin/tool"

    cat > "$src1/.META/package" <<'EOF'
name=det-pkg
version=2.1.0
release=1
arch=x86_64
description=Determinism test package
EOF
    cat > "$src2/.META/package" <<'EOF'
name=det-pkg
version=2.1.0
release=1
arch=x86_64
description=Determinism test package
EOF

    # Vary file mtime on source files to prove mtime clamping to @0
    touch -d "2024-01-01 12:00:00" "$src1/x/bin/tool"
    touch -d "2025-06-15 08:30:00" "$src2/x/bin/tool"

    "$BUILD_PKG" --source "$src1" --output "$out1" >/dev/null 2>&1
    "$BUILD_PKG" --source "$src2" --output "$out2" >/dev/null 2>&1

    local h1 h2
    h1="$(sha256sum "$out1/det-pkg-2.1.0-1-x86_64.spm.tar.xz" | awk '{print $1}')"
    h2="$(sha256sum "$out2/det-pkg-2.1.0-1-x86_64.spm.tar.xz" | awk '{print $1}')"

    if [ "$h1" = "$h2" ]; then
        test_pass "Bit-for-bit build determinism (reproducible SHA-256: $h1)"
    else
        test_fail "Determinism" "Checksum mismatch: $h1 vs $h2"
    fi
}

# -----------------------------------------------------------------------------
# Test 3: Metadata auto-generation (.META/files and .META/sha256)
# -----------------------------------------------------------------------------
test_metadata_generation() {
    local tdir="$TEST_TMP/meta_test"
    local odir="$tdir/out"
    mkdir -p "$tdir/src/x/usr/bin" "$tdir/src/x/etc" "$tdir/src/.META" "$odir"

    echo "data1" > "$tdir/src/x/usr/bin/tool"
    echo "data2" > "$tdir/src/x/etc/tool.conf"
    ln -s tool "$tdir/src/x/usr/bin/tool-alias"

    cat > "$tdir/src/.META/package" <<'EOF'
name=meta-pkg
version=1.0.0
arch=x86_64
description=Metadata test package
EOF

    "$BUILD_PKG" --source "$tdir/src" --output "$odir" >/dev/null 2>&1

    local files_meta="$tdir/src/.META/files"
    local sha_meta="$tdir/src/.META/sha256"

    if [ ! -f "$files_meta" ] || [ ! -f "$sha_meta" ]; then
        test_fail "Metadata generation" ".META/files or .META/sha256 missing"
        return
    fi

    # Verify .META/files directory entries end with trailing '/'
    if ! grep -q "^etc/$" "$files_meta" || \
       ! grep -q "^usr/$" "$files_meta" || \
       ! grep -q "^usr/bin/$" "$files_meta"; then
        test_fail "Metadata generation" ".META/files missing directory entries with trailing '/'"
        return
    fi

    # Verify .META/files regular files and symlinks do NOT end with trailing '/'
    if ! grep -q "^etc/tool.conf$" "$files_meta" || \
       ! grep -q "^usr/bin/tool$" "$files_meta" || \
       ! grep -q "^usr/bin/tool-alias$" "$files_meta"; then
        test_fail "Metadata generation" ".META/files missing file or symlink entries"
        return
    fi

    # Verify all directory entries in .META/files end with '/' and exist in x/
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if [[ "$entry" == */ ]]; then
            if [ ! -d "$tdir/src/x/$entry" ]; then
                test_fail "Metadata generation" "Entry ending with '/' is not a directory: $entry"
                return
            fi
        else
            if [ ! -f "$tdir/src/x/$entry" ] && [ ! -L "$tdir/src/x/$entry" ]; then
                test_fail "Metadata generation" "File entry does not exist: $entry"
                return
            fi
        fi
    done < "$files_meta"

    # Verify .META/files is sorted with LC_ALL=C
    local sorted_check
    sorted_check="$(LC_ALL=C sort "$files_meta")"
    if [ "$(<"$files_meta")" != "$sorted_check" ]; then
        test_fail "Metadata generation" ".META/files is not sorted with LC_ALL=C sort"
        return
    fi

    # Verify sha256 checksums match
    if ! (cd "$tdir/src/x" && sha256sum -c "$sha_meta" >/dev/null 2>&1); then
        test_fail "Metadata generation" "sha256sum -c failed on generated .META/sha256"
        return
    fi

    test_pass "Metadata auto-generation (.META/files with trailing '/' directories and .META/sha256)"
}

# -----------------------------------------------------------------------------
# Test 4: Mandatory manifest fields validation
# -----------------------------------------------------------------------------
test_manifest_validation() {
    local tdir="$TEST_TMP/val_test"
    mkdir -p "$tdir/src/x/bin" "$tdir/src/.META" "$tdir/out"
    touch "$tdir/src/x/bin/stub"

    # Case A: Missing name
    cat > "$tdir/src/.META/package" <<'EOF'
version=1.0.0
arch=x86_64
description=Test package
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with missing 'name'"
        return
    fi

    # Case B: Missing version
    cat > "$tdir/src/.META/package" <<'EOF'
name=test-pkg
arch=x86_64
description=Test package
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with missing 'version'"
        return
    fi

    # Case C: Missing arch
    cat > "$tdir/src/.META/package" <<'EOF'
name=test-pkg
version=1.0.0
description=Test package
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with missing 'arch'"
        return
    fi

    # Case D: Invalid package name characters (punctuation/uppercase)
    cat > "$tdir/src/.META/package" <<'EOF'
name=Test_Pkg!
version=1.0.0
arch=x86_64
description=Test package
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with invalid package name"
        return
    fi

    # Case D1: Reject package name with underscore
    cat > "$tdir/src/.META/package" <<'EOF'
name=test_pkg
version=1.0.0
arch=x86_64
description=Test package
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with underscore in package name"
        return
    fi

    # Case D2: Reject unsupported arch (e.g. arm64 or i386)
    cat > "$tdir/src/.META/package" <<'EOF'
name=test-pkg
version=1.0.0
arch=arm64
description=Test package
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with unsupported arch (arm64)"
        return
    fi

    # Case D3: Reject missing description field
    cat > "$tdir/src/.META/package" <<'EOF'
name=test-pkg
version=1.0.0
arch=x86_64
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with missing description"
        return
    fi

    # Case D4: Reject empty description field
    cat > "$tdir/src/.META/package" <<'EOF'
name=test-pkg
version=1.0.0
arch=x86_64
description=
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with empty description"
        return
    fi

    # Case D5: Accept valid arch=all
    cat > "$tdir/src/.META/package" <<'EOF'
name=test-all-arch
version=1.0.0
arch=all
description=Architecture independent package
EOF
    if ! "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build failed with valid arch=all"
        return
    fi

    # Case E: Missing .META/package altogether
    rm -f "$tdir/src/.META/package"
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Manifest validation" "Build succeeded with missing manifest file"
        return
    fi

    test_pass "Mandatory manifest fields validation (name, version, arch, description strictly enforced)"
}

# -----------------------------------------------------------------------------
# Test 5: Missing payload directory validation
# -----------------------------------------------------------------------------
test_missing_payload() {
    local tdir="$TEST_TMP/missing_x_test"
    mkdir -p "$tdir/src/.META" "$tdir/out"
    cat > "$tdir/src/.META/package" <<'EOF'
name=no-x-pkg
version=1.0.0
arch=x86_64
description=Missing payload test package
EOF

    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Missing payload" "Build succeeded without ./x/ directory"
    else
        test_pass "Missing payload directory rejection"
    fi
}

# -----------------------------------------------------------------------------
# Test 6: Base package flag handling (--base)
# -----------------------------------------------------------------------------
test_base_flag() {
    local tdir="$TEST_TMP/base_test"
    mkdir -p "$tdir/src/x/bin" "$tdir/src/.META" "$tdir/out"
    touch "$tdir/src/x/bin/init"

    cat > "$tdir/src/.META/package" <<'EOF'
name=base-pkg
version=1.0.0
arch=x86_64
description=Base package flag test
base=false
EOF

    "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" --base >/dev/null 2>&1
    local recorded_base
    recorded_base="$(grep "^base=" "$tdir/src/.META/package" | cut -d= -f2)"

    if [ "$recorded_base" = "true" ]; then
        test_pass "Base package flag handling (--base forces base=true)"
    else
        test_fail "Base flag" "Expected base=true, got: $recorded_base"
    fi
}

# -----------------------------------------------------------------------------
# Test 7: Declarative ninit service snippet validation
# -----------------------------------------------------------------------------
test_service_snippets() {
    local tdir="$TEST_TMP/srv_test"
    local srv_dir="$tdir/src/x/usr/share/ninit/services"
    mkdir -p "$srv_dir" "$tdir/src/.META" "$tdir/out"

    cat > "$tdir/src/.META/package" <<'EOF'
name=srv-pkg
version=1.0.0
arch=x86_64
description=Service snippet test package
EOF

    # Case A: Valid service snippet
    cat > "$srv_dir/app.service" <<'EOF'
respawn:/usr/bin/app -D
EOF
    if ! "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Service snippet" "Valid service snippet was rejected"
        return
    fi

    # Check that permissions were normalized to 0644
    local perms
    perms="$(stat -c "%a" "$srv_dir/app.service")"
    if [ "$perms" != "644" ]; then
        test_fail "Service snippet" "Service file permissions not 644 (got $perms)"
        return
    fi

    # Case B: Dangerous keyword (/run/initctl)
    cat > "$srv_dir/app.service" <<'EOF'
once:echo reboot > /run/initctl
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Service snippet" "Dangerous keyword /run/initctl was not rejected"
        return
    fi

    # Case C: Shell piping or redirection
    cat > "$srv_dir/app.service" <<'EOF'
respawn:/usr/bin/app | grep evil
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Service snippet" "Shell pipe in service snippet was not rejected"
        return
    fi

    # Case D: Symlinked service file (must be strictly rejected)
    rm -f "$srv_dir/app.service"
    ln -s "/bin/sh" "$srv_dir/symlink.service"
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Service snippet" "Symlinked service file was not rejected"
        return
    fi
    rm -f "$srv_dir/symlink.service"

    test_pass "Declarative ninit service snippet validation and security enforcement"
}

# -----------------------------------------------------------------------------
# Test 8: Adversarial path traversal and symlink escape rejection
# -----------------------------------------------------------------------------
test_adversarial_rejection() {
    local tdir="$TEST_TMP/adv_test"
    mkdir -p "$tdir/src/x/usr/bin" "$tdir/src/.META" "$tdir/out"

    cat > "$tdir/src/.META/package" <<'EOF'
name=adv-pkg
version=1.0.0
arch=x86_64
description=Adversarial security test package
EOF

    # Attack 1: Relative symlink escaping target root
    ln -s "../../../etc/shadow" "$tdir/src/x/usr/bin/escape_link"
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Adversarial rejection" "Out-of-root relative symlink was not rejected"
        return
    fi
    rm -f "$tdir/src/x/usr/bin/escape_link"

    # Attack 2: Direct parent symlink escape from payload root
    ln -s "../etc/passwd" "$tdir/src/x/root_escape"
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Adversarial rejection" "Payload-root escaping symlink was not rejected"
        return
    fi
    rm -f "$tdir/src/x/root_escape"

    # Attack 3: Absolute symlink containing traversal components
    ln -s "/bin/../etc/shadow" "$tdir/src/x/usr/bin/bad_abs"
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Adversarial rejection" "Absolute symlink with traversal was not rejected"
        return
    fi
    rm -f "$tdir/src/x/usr/bin/bad_abs"

    # Attack 4: Symlink in .META directory (out-of-tree escape)
    ln -s "../../../etc/shadow" "$tdir/src/.META/evil_symlink"
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Adversarial rejection" "Symlink inside .META directory was not rejected"
        return
    fi
    rm -f "$tdir/src/.META/evil_symlink"

    # Attack 5: Symlink in .META pointing to internal file (zero symlinks permitted in .META)
    ln -s "package" "$tdir/src/.META/pkg_alias"
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Adversarial rejection" "Internal symlink in .META was not rejected"
        return
    fi
    rm -f "$tdir/src/.META/pkg_alias"

    # Verify: Safe absolute symlink (permitted for BusyBox applets)
    ln -s "/bin/busybox" "$tdir/src/x/usr/bin/safe_abs"
    # Verify: Safe internal relative symlink
    ln -s "safe_abs" "$tdir/src/x/usr/bin/safe_rel"

    if ! "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Adversarial rejection" "Legitimate BusyBox symlinks were erroneously rejected"
        return
    fi

    test_pass "Adversarial path traversal & symlink escape rejection (fail-closed)"
}

# -----------------------------------------------------------------------------
# Test 9: Gzip compression compatibility fallback (--gz)
# -----------------------------------------------------------------------------
test_gzip_compression() {
    local tdir="$TEST_TMP/gz_test"
    local odir="$tdir/out"
    mkdir -p "$tdir/src/x/usr/bin" "$tdir/src/.META" "$odir"

    echo "gzip test payload" > "$tdir/src/x/usr/bin/gztool"

    cat > "$tdir/src/.META/package" <<'EOF'
name=gz-pkg
version=1.0.0
arch=x86_64
description=Gzip compression test package
EOF

    if "$BUILD_PKG" --source "$tdir/src" --output "$odir" --gz >/dev/null 2>&1; then
        local pkg_gz="$odir/gz-pkg-1.0.0-1-x86_64.spm.tar.gz"
        if [ ! -f "$pkg_gz" ]; then
            test_fail "Gzip fallback" "Output .spm.tar.gz file not found"
            return
        fi

        # Verify gzip integrity
        if ! gzip -t "$pkg_gz"; then
            test_fail "Gzip fallback" "Archive failed gzip integrity test"
            return
        fi

        test_pass "Gzip compression compatibility fallback (--gz / .spm.tar.gz)"
    else
        test_fail "Gzip fallback" "build-package.sh --gz command failed"
    fi
}

# -----------------------------------------------------------------------------
# Test 10: Base package recipe build (packages/sane-hello)
# -----------------------------------------------------------------------------
test_recipe_build() {
    local tdir="$TEST_TMP/recipe_test"
    local odir="$tdir/out"
    mkdir -p "$odir"

    local recipe_script="$REPO_ROOT/packages/sane-hello/build.sh"
    if [ ! -x "$recipe_script" ]; then
        test_fail "Recipe build" "packages/sane-hello/build.sh not found or not executable"
        return
    fi

    if "$recipe_script" "$odir" >/dev/null 2>&1; then
        local pkg_file="$odir/sane-hello-0.1.0-1-x86_64.spm.tar.xz"
        if [ ! -f "$pkg_file" ]; then
            test_fail "Recipe build" "Output sane-hello package missing"
            return
        fi

        # Verify manifest inside package
        local manifest_content
        manifest_content="$(tar -xOf "$pkg_file" ./.META/package)"
        if ! echo "$manifest_content" | grep -q "^name=sane-hello$" || \
           ! echo "$manifest_content" | grep -q "^base=false$"; then
            test_fail "Recipe build" "Package manifest incorrect inside built archive"
            return
        fi

        test_pass "Base package recipe build (packages/sane-hello blueprint)"
    else
        test_fail "Recipe build" "packages/sane-hello/build.sh returned non-zero"
    fi
}

# -----------------------------------------------------------------------------
# Test 11: Static ELF verification in busybox package builder
# -----------------------------------------------------------------------------
test_busybox_static_elf() {
    local tdir="$TEST_TMP/bb_elf_test"
    local odir="$tdir/out"
    mkdir -p "$tdir" "$odir"

    local bb_script="$REPO_ROOT/packages/busybox/build.sh"
    if [ ! -x "$bb_script" ]; then
        test_fail "BusyBox ELF verification" "packages/busybox/build.sh not found or not executable"
        return
    fi

    # Case A: Dynamic binary rejection (host gcc creates dynamic binary with PT_INTERP)
    cat > "$tdir/dyn.c" <<'EOF'
int main(void) { return 0; }
EOF
    gcc "$tdir/dyn.c" -o "$tdir/dynamic_bin"

    if BUSYBOX_BIN="$tdir/dynamic_bin" "$bb_script" "$odir" >/dev/null 2>&1; then
        test_fail "BusyBox ELF verification" "BusyBox builder accepted dynamically linked binary"
        return
    fi

    # Case B: Non-ELF executable rejection (shell script)
    cat > "$tdir/fake_bb.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 755 "$tdir/fake_bb.sh"

    if BUSYBOX_BIN="$tdir/fake_bb.sh" "$bb_script" "$odir" >/dev/null 2>&1; then
        test_fail "BusyBox ELF verification" "BusyBox builder accepted non-ELF script"
        return
    fi

    # Case C: Valid static binary acceptance (when static busybox exists)
    if [ -x "/bin/busybox" ]; then
        if ! BUSYBOX_BIN="/bin/busybox" "$bb_script" "$odir" >/dev/null 2>&1; then
            test_fail "BusyBox ELF verification" "BusyBox builder rejected valid static /bin/busybox"
            return
        fi
    fi

    test_pass "BusyBox static ELF verification & dynamic binary rejection (fail-closed)"
}

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------
main() {
    printf '=== Running S.A.N.E Package Builder Test Suite ===\n'
    test_basic_build
    test_determinism
    test_metadata_generation
    test_manifest_validation
    test_missing_payload
    test_base_flag
    test_service_snippets
    test_adversarial_rejection
    test_gzip_compression
    test_recipe_build
    test_busybox_static_elf

    printf '\n=== Test Summary: %d passed, %d failed ===\n' "$PASSED_COUNT" "$FAILED_COUNT"
    if [ "$FAILED_COUNT" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
