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

    # Case A: Valid service snippet (3-field <name>:<mode>:<cmd>)
    cat > "$srv_dir/app.service" <<'EOF'
app:respawn:/usr/bin/app -D
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

    # Case A2: 2-field snippet without service name must be rejected (parity with ninit.c)
    cat > "$srv_dir/app.service" <<'EOF'
respawn:/usr/bin/app -D
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Service snippet" "2-field snippet without name was not rejected"
        return
    fi

    # Case B: Dangerous keyword (/run/initctl)
    cat > "$srv_dir/app.service" <<'EOF'
app:once:echo reboot > /run/initctl
EOF
    if "$BUILD_PKG" --source "$tdir/src" --output "$tdir/out" >/dev/null 2>&1; then
        test_fail "Service snippet" "Dangerous keyword /run/initctl was not rejected"
        return
    fi

    # Case C: Shell piping or redirection
    cat > "$srv_dir/app.service" <<'EOF'
app:respawn:/usr/bin/app | grep evil
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

# Helper: create an isolated scratch repository copy so tracked packages/ are never mutated
setup_scratch_repo() {
    local scratch="$1"
    shift
    mkdir -p "$scratch/packages" "$scratch/distro/cache" "$scratch/distro/rootfs/bin"
    cp -a "$REPO_ROOT/scripts" "$scratch/scripts"
    local pkg
    for pkg in "$@"; do
        cp -a "$REPO_ROOT/packages/$pkg" "$scratch/packages/$pkg"
    done
}

# Snapshot tracked packages/ tree (paths, types, modes, symlink targets, file hashes)
snapshot_packages_tree() {
    local out_file="$1"
    (
        cd "$REPO_ROOT/packages"
        {
            find . -mindepth 1 -type l | LC_ALL=C sort | while IFS= read -r l; do
                printf 'L|%s|%s\n' "$l" "$(readlink "$l")"
            done
            find . -mindepth 1 -type d | LC_ALL=C sort | while IFS= read -r d; do
                printf 'D|%s\n' "$d"
            done
            find . -mindepth 1 -type f | LC_ALL=C sort | xargs -r sha256sum
        } > "$out_file"
    )
}

# -----------------------------------------------------------------------------
# Test 10: Base package recipe build (packages/sane-hello in isolated scratch)
# -----------------------------------------------------------------------------
test_recipe_build() {
    local tdir="$TEST_TMP/recipe_test"
    local odir="$tdir/out"
    mkdir -p "$odir"

    if [ ! -x "$REPO_ROOT/packages/sane-hello/build.sh" ]; then
        test_fail "Recipe build" "packages/sane-hello/build.sh not found or not executable"
        return
    fi

    setup_scratch_repo "$tdir/repo" "sane-hello"
    local recipe_script="$tdir/repo/packages/sane-hello/build.sh"

    if "$recipe_script" "$odir" >/dev/null 2>&1; then
        local pkg_file="$odir/sane-hello-0.1.0-1-x86_64.spm.tar.xz"
        if [ ! -f "$pkg_file" ]; then
            test_fail "Recipe build" "Output sane-hello package missing"
            return
        fi

        # Verify manifest inside package and synced dependency
        local manifest_content depends_content
        manifest_content="$(tar -xOf "$pkg_file" ./.META/package)"
        depends_content="$(tar -xOf "$pkg_file" ./.META/depends)"
        if ! echo "$manifest_content" | grep -q "^name=sane-hello$" || \
           ! echo "$manifest_content" | grep -q "^base=false$" || \
           ! echo "$manifest_content" | grep -q "^dependencies=busybox$" || \
           ! echo "$depends_content" | grep -qx "busybox"; then
            test_fail "Recipe build" "Package manifest or depends incorrect inside built archive"
            return
        fi

        test_pass "Base package recipe build in isolated scratch (packages/sane-hello blueprint)"
    else
        test_fail "Recipe build" "packages/sane-hello/build.sh returned non-zero"
    fi
}

# -----------------------------------------------------------------------------
# Test 11: Static ELF verification in busybox package builder (isolated scratch)
# -----------------------------------------------------------------------------
test_busybox_static_elf() {
    local tdir="$TEST_TMP/bb_elf_test"
    local odir="$tdir/out"
    mkdir -p "$tdir" "$odir"

    if [ ! -x "$REPO_ROOT/packages/busybox/build.sh" ]; then
        test_fail "BusyBox ELF verification" "packages/busybox/build.sh not found or not executable"
        return
    fi

    setup_scratch_repo "$tdir/repo" "busybox"
    local bb_script="$tdir/repo/packages/busybox/build.sh"

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

    # Case C: Valid static binary acceptance + P1-19 applet symlinks check
    local valid_bb="$REPO_ROOT/packages/busybox/x/bin/busybox"
    [ -x "$valid_bb" ] || valid_bb="/bin/busybox"
    if [ -x "$valid_bb" ]; then
        if ! BUSYBOX_BIN="$valid_bb" "$bb_script" "$odir" >/dev/null 2>&1; then
            test_fail "BusyBox ELF verification" "BusyBox builder rejected valid static busybox"
            return
        fi
        local bb_pkg="$odir/busybox-1.36.1-1-x86_64.spm.tar.xz"
        local bb_files
        bb_files="$(tar -xOf "$bb_pkg" ./.META/files)"
        for req_applet in bin/stty bin/sha256sum bin/gzip bin/mountpoint bin/awk bin/mktemp; do
            if ! printf '%s\n' "$bb_files" | grep -qx "$req_applet"; then
                test_fail "BusyBox ELF verification" "Missing required symlink '$req_applet' in built busybox package"
                return
            fi
        done
    fi

    test_pass "BusyBox static ELF verification, applet symlinks, and dynamic binary rejection (fail-closed)"
}

test_disk_tools_static_elf() {
    local tdir="$TEST_TMP/disk_tools_elf_test"
    local odir="$tdir/out"
    mkdir -p "$tdir" "$odir"

    if [ ! -x "$REPO_ROOT/packages/disk-tools/build.sh" ]; then
        test_fail "disk-tools ELF verification" "packages/disk-tools/build.sh not found or not executable"
        return
    fi

    setup_scratch_repo "$tdir/repo" "disk-tools"
    local mock_pkg="$tdir/repo/packages/disk-tools"

    # Case A: Valid static binaries in scratch tree
    if ! (cd "$mock_pkg" && bash ./build.sh "$odir") >/dev/null 2>&1; then
        test_fail "disk-tools ELF verification" "disk-tools builder rejected repository static binaries"
        return
    fi

    # Case B: Dynamic binary rejection
    cat > "$tdir/dyn.c" <<'EOF'
int main(void) { return 0; }
EOF
    gcc "$tdir/dyn.c" -o "$mock_pkg/x/usr/sbin/sgdisk"

    if (cd "$mock_pkg" && bash ./build.sh "$odir") >/dev/null 2>&1; then
        test_fail "disk-tools ELF verification" "disk-tools builder accepted dynamically linked binary"
        return
    fi

    # Case C: Non-ELF script rejection
    cat > "$mock_pkg/x/usr/sbin/sgdisk" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 755 "$mock_pkg/x/usr/sbin/sgdisk"
    if (cd "$mock_pkg" && bash ./build.sh "$odir") >/dev/null 2>&1; then
        test_fail "disk-tools ELF verification" "disk-tools builder accepted non-ELF script"
        return
    fi

    test_pass "disk-tools static ELF verification & dynamic binary rejection (fail-closed, scratch repo)"
}

# -----------------------------------------------------------------------------
# Test 13: Shared validator agreement (build-package delegates to spm)
# -----------------------------------------------------------------------------
test_shared_validator_agreement() {
    local tdir="$TEST_TMP/shared_validator"
    local src="$tdir/src" out="$tdir/out"
    mkdir -p "$src/x/usr/bin" "$src/.META" "$out"
    cat > "$src/.META/package" <<'EOF'
name=shared-validator
version=1.0.0
arch=x86_64
description=Shared validator agreement
base=false
EOF
    printf 'tool\n' > "$src/x/usr/bin/tool"
    chmod 755 "$src/x/usr/bin/tool"

    if ! "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>"$tdir/err"; then
        test_fail "Shared validator agreement" "baseline build rejected: $(cat "$tdir/err")"
        return
    fi

    mkdir -p "$src/x/usr/share/ninit/services"
    local svc="$src/x/usr/share/ninit/services/v.service"

    # Legacy key: both builder and spm must reject (single vocabulary).
    printf 'v:respawn:/bin/true :deps=base\n' > "$svc"
    if "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>&1; then
        test_fail "Shared validator agreement" "builder accepted legacy :deps= snippet"
        return
    fi
    if sh "$REPO_ROOT/scripts/spm" validate-source "$src" >/dev/null 2>&1; then
        test_fail "Shared validator agreement" "spm validator accepted legacy :deps= snippet"
        return
    fi

    # Quoted argument with '=' must be accepted by both paths (3-field format).
    printf 'v:respawn:/bin/echo "hello world" status=ok\n' > "$svc"
    if ! "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>"$tdir/err"; then
        test_fail "Shared validator agreement" "builder rejected quoted argument: $(cat "$tdir/err")"
        return
    fi
    if ! sh "$REPO_ROOT/scripts/spm" validate-source "$src" >/dev/null 2>&1; then
        test_fail "Shared validator agreement" "spm rejected quoted argument"
        return
    fi

    # Absolute target outside the allowlist is rejected by the builder too;
    # a valid internal relative symlink roundtrips.
    ln -s /etc/hostname "$src/x/usr/bin/hostlink"
    if "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>&1; then
        test_fail "Shared validator agreement" "builder accepted /etc/hostname symlink target"
        return
    fi
    rm -f "$src/x/usr/bin/hostlink"
    ln -s tool "$src/x/usr/bin/hostlink"
    if ! "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>"$tdir/err"; then
        test_fail "Shared validator agreement" "builder rejected internal symlink: $(cat "$tdir/err")"
        return
    fi

    test_pass "Shared validator agreement: single snippet vocabulary and symlink policy in builder and spm"
}

# -----------------------------------------------------------------------------
# Test 14: 0600 secret permission preservation & xz -T1 determinism (P1-13)
# -----------------------------------------------------------------------------
test_0600_and_xz_determinism() {
    local tdir="$TEST_TMP/perm_0600_test"
    local src="$tdir/src" out="$tdir/out"
    mkdir -p "$src/x/etc" "$src/x/usr/bin" "$src/.META" "$out"

    cat > "$src/.META/package" <<'EOF'
name=secret-pkg
version=1.0.0
arch=x86_64
description=Secret permission test
base=false
EOF
    printf 'permit persist :wheel\n' > "$src/x/etc/doas.conf"
    printf 'ctrl_interface=/run/wpa_supplicant\n' > "$src/x/etc/wpa_supplicant.conf"
    printf 'public=1\n' > "$src/x/etc/public.conf"
    printf '#!/bin/sh\nexit 0\n' > "$src/x/usr/bin/tool"
    printf '#!/bin/sh\nexit 0\n' > "$src/x/usr/bin/suid"

    chmod 0600 "$src/x/etc/doas.conf" "$src/x/etc/wpa_supplicant.conf"
    chmod 0664 "$src/x/etc/public.conf"
    chmod 0775 "$src/x/usr/bin/tool"
    chmod 4755 "$src/x/usr/bin/suid"

    if ! "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>&1; then
        test_fail "0600 preservation" "build-package.sh failed on 0600 package"
        return
    fi

    local pkg="$out/secret-pkg-1.0.0-1-x86_64.spm.tar.xz"
    local tv
    tv="$(tar -tvf "$pkg")"
    if ! printf '%s\n' "$tv" | grep -qE '^-rw------- .* \./x/etc/doas\.conf$'; then
        test_fail "0600 preservation" "doas.conf mode was not preserved as 0600: $tv"
        return
    fi
    if ! printf '%s\n' "$tv" | grep -qE '^-rw------- .* \./x/etc/wpa_supplicant\.conf$'; then
        test_fail "0600 preservation" "wpa_supplicant.conf mode was not preserved as 0600: $tv"
        return
    fi
    if ! printf '%s\n' "$tv" | grep -qE '^-rw-r--r-- .* \./x/etc/public\.conf$'; then
        test_fail "0600 preservation" "public.conf group-write was not normalized to 0644"
        return
    fi
    if ! printf '%s\n' "$tv" | grep -qE '^-rwxr-xr-x .* \./x/usr/bin/tool$'; then
        test_fail "0600 preservation" "tool group-write was not normalized to 0755"
        return
    fi
    if ! printf '%s\n' "$tv" | grep -qE '^-rwxr-xr-x .* \./x/usr/bin/suid$'; then
        test_fail "0600 preservation" "suid bit was not stripped to 0755"
        return
    fi

    # Verify real doas and wpa-supplicant recipes preserve 0600 and sync .META/depends (scratch repo)
    setup_scratch_repo "$tdir/repo" "doas" "wpa-supplicant"
    local out_recipes="$tdir/out_recipes"
    mkdir -p "$out_recipes"
    if ! "$tdir/repo/packages/doas/build.sh" "$out_recipes" >/dev/null 2>&1; then
        test_fail "0600 preservation" "doas/build.sh failed in scratch repo"
        return
    fi
    if ! "$tdir/repo/packages/wpa-supplicant/build.sh" "$out_recipes" >/dev/null 2>&1; then
        test_fail "0600 preservation" "wpa-supplicant/build.sh failed in scratch repo"
        return
    fi

    local doas_pkg="$out_recipes/doas-6.8.2-1-x86_64.spm.tar.xz"
    local wpa_pkg="$out_recipes/wpa-supplicant-2.10-1-x86_64.spm.tar.xz"
    local doas_tv wpa_tv doas_deps wpa_deps
    doas_tv="$(tar -tvf "$doas_pkg")"
    wpa_tv="$(tar -tvf "$wpa_pkg")"
    doas_deps="$(tar -xOf "$doas_pkg" ./.META/depends)"
    wpa_deps="$(tar -xOf "$wpa_pkg" ./.META/depends)"
    if ! printf '%s\n' "$doas_tv" | grep -qE '^-rw------- .* \./x/etc/doas\.conf$'; then
        test_fail "0600 preservation" "built doas package lost 0600 on etc/doas.conf"
        return
    fi
    if ! printf '%s\n' "$wpa_tv" | grep -qE '^-rw------- .* \./x/etc/wpa_supplicant\.conf$'; then
        test_fail "0600 preservation" "built wpa-supplicant package lost 0600 on etc/wpa_supplicant.conf"
        return
    fi
    if ! printf '%s\n' "$doas_deps" | grep -qx "musl"; then
        test_fail "0600 preservation" "doas .META/depends missing musl"
        return
    fi
    if ! printf '%s\n' "$wpa_deps" | grep -qx "libressl"; then
        test_fail "0600 preservation" "wpa-supplicant .META/depends missing libressl"
        return
    fi

    # Verify single-threaded xz -T1 is enforced in build-package.sh
    if ! grep -qE 'xz -T1[[:space:]]' "$BUILD_PKG"; then
        test_fail "0600 preservation" "build-package.sh does not use xz -T1"
        return
    fi

    test_pass "0600 secret mode preservation (doas.conf, wpa_supplicant.conf) & xz -T1 determinism"
}

# -----------------------------------------------------------------------------
# Test 15: Dependency sync, ELF checks, limine SHA-256, P0-1 symlinked roots
# -----------------------------------------------------------------------------
test_dep_sync_elf_limine_and_p0() {
    local tdir="$TEST_TMP/hardening_test"
    local src="$tdir/src" out="$tdir/out"
    mkdir -p "$src/x/usr/bin" "$src/.META" "$out"

    # 1. Dependency sync: dependencies= -> .META/depends
    cat > "$src/.META/package" <<'EOF'
name=dep-sync-a
version=1.0.0
arch=x86_64
description=Dep sync A
dependencies=musl,libressl
EOF
    printf 'ok\n' > "$src/x/usr/bin/a"
    if ! "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "build failed syncing dependencies= to .META/depends"
        return
    fi
    if [ "$(LC_ALL=C sort "$src/.META/depends" | tr '\n' ',')" != "libressl,musl," ]; then
        test_fail "Builder hardening" ".META/depends was not synced from dependencies="
        return
    fi

    # 2. Dependency sync: .META/depends -> dependencies=
    cat > "$src/.META/package" <<'EOF'
name=dep-sync-b
version=1.0.0
arch=x86_64
description=Dep sync B
EOF
    printf 'busybox\n' > "$src/.META/depends"
    if ! "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "build failed syncing .META/depends to dependencies="
        return
    fi
    if ! grep -qx "dependencies=busybox" "$src/.META/package"; then
        test_fail "Builder hardening" ".META/package missing synced dependencies=busybox"
        return
    fi

    # 3. Mismatched dependencies= vs .META/depends must fail
    cat > "$src/.META/package" <<'EOF'
name=dep-mismatch
version=1.0.0
arch=x86_64
description=Dep mismatch
dependencies=musl
EOF
    printf 'curl\n' > "$src/.META/depends"
    if "$BUILD_PKG" --source "$src" --output "$out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "mismatched dependencies= and .META/depends were accepted"
        return
    fi

    # 4. build-package.sh must reject dynamic ELF binary (PT_INTERP)
    local elf_src="$tdir/elf_src"
    mkdir -p "$elf_src/x/usr/bin" "$elf_src/.META"
    cat > "$elf_src/.META/package" <<'EOF'
name=dyn-elf
version=1.0.0
arch=x86_64
description=Dynamic ELF rejection
EOF
    printf 'int main(void) { return 0; }\n' > "$tdir/dyn.c"
    gcc "$tdir/dyn.c" -o "$elf_src/x/usr/bin/dyn"
    if "$BUILD_PKG" --source "$elf_src" --output "$out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "build-package.sh accepted dynamically linked ELF"
        return
    fi

    # 5. libressl & limine-static ELF verification + limine-static SHA-256 check (scratch repo)
    setup_scratch_repo "$tdir/repo" "libressl" "limine-static"
    local scratch_out="$tdir/scratch_out"
    mkdir -p "$scratch_out"

    if ! "$tdir/repo/packages/libressl/build.sh" "$scratch_out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "libressl/build.sh failed on valid static payload in scratch"
        return
    fi
    cp "$tdir/dyn.c" "$tdir/dyn_ssl.c"
    gcc "$tdir/dyn_ssl.c" -o "$tdir/repo/packages/libressl/x/usr/bin/openssl"
    if "$tdir/repo/packages/libressl/build.sh" "$scratch_out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "libressl/build.sh accepted dynamic openssl binary"
        return
    fi

    if ! "$tdir/repo/packages/limine-static/build.sh" "$scratch_out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "limine-static/build.sh failed on valid static payload in scratch"
        return
    fi
    gcc "$tdir/dyn.c" -o "$tdir/repo/packages/limine-static/x/usr/bin/limine"
    if "$tdir/repo/packages/limine-static/build.sh" "$scratch_out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "limine-static/build.sh accepted dynamic limine binary"
        return
    fi

    # Tampered tarball SHA-256 rejection in limine-static (stub curl, REBUILD=1)
    mkdir -p "$tdir/fake_bin"
    cat > "$tdir/fake_bin/curl" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift 2; continue; fi
    shift
done
printf 'tampered payload\n' > "$out"
EOF
    chmod 0755 "$tdir/fake_bin/curl"
    rm -f "$tdir/repo/distro/cache"/limine*
    if PATH="$tdir/fake_bin:$PATH" REBUILD=1 "$tdir/repo/packages/limine-static/build.sh" "$scratch_out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "limine-static/build.sh accepted tampered tarball without SHA-256 failure"
        return
    fi

    # 6. P0-1 in build-package.sh: symlinked x and symlinked .META must be rejected without touching target
    local p0_src="$tdir/p0_src" p0_outside="$tdir/p0_outside"
    mkdir -p "$p0_src" "$p0_outside"
    printf 'keep\n' > "$p0_outside/package"
    printf 'name=p0\nversion=1.0.0\narch=x86_64\ndescription=p0\n' > "$p0_outside/manifest"
    mkdir -p "$p0_src/x/usr/bin"
    printf 'tool\n' > "$p0_src/x/usr/bin/t"
    ln -s "$p0_outside" "$p0_src/.META"
    if "$BUILD_PKG" --source "$p0_src" --output "$out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "build-package.sh accepted symlinked .META"
        return
    fi
    if [ -e "$p0_outside/files" ] || [ -e "$p0_outside/sha256" ]; then
        test_fail "Builder hardening" "build-package.sh wrote through symlinked .META!"
        return
    fi

    local p0_src2="$tdir/p0_src2"
    mkdir -p "$p0_src2/.META"
    printf 'name=p0x\nversion=1.0.0\narch=x86_64\ndescription=p0x\n' > "$p0_src2/.META/package"
    ln -s "$p0_outside" "$p0_src2/x"
    if "$BUILD_PKG" --source "$p0_src2" --output "$out" >/dev/null 2>&1; then
        test_fail "Builder hardening" "build-package.sh accepted symlinked x"
        return
    fi

    # 7. packages/ninit getty.service passes 3-field parity validation
    if ! sh "$REPO_ROOT/scripts/spm" validate-source "$REPO_ROOT/packages/ninit" >/dev/null 2>&1; then
        test_fail "Builder hardening" "packages/ninit failed spm validate-source (getty.service 3-field parity)"
        return
    fi

    test_pass "Dependency sync, static ELF checks, limine SHA-256, P0-1 root symlink guard, getty.service parity"
}

# -----------------------------------------------------------------------------
# Runner
# -----------------------------------------------------------------------------
main() {
    printf '=== Running S.A.N.E Package Builder Test Suite ===\n'
    local snap_before="$TEST_TMP/pkg_snap_before"
    local snap_after="$TEST_TMP/pkg_snap_after"
    snapshot_packages_tree "$snap_before"

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
    test_disk_tools_static_elf
    test_shared_validator_agreement
    test_0600_and_xz_determinism
    test_dep_sync_elf_limine_and_p0

    snapshot_packages_tree "$snap_after"
    if cmp -s "$snap_before" "$snap_after"; then
        test_pass "Tracked packages/ tree remained completely unmutated during tests"
    else
        test_fail "Repo cleanliness" "Tracked packages/ tree was mutated during test-build-package.sh!"
        diff -u "$snap_before" "$snap_after" >&2 || true
    fi

    printf '\n=== Test Summary: %d passed, %d failed ===\n' "$PASSED_COUNT" "$FAILED_COUNT"
    if [ "$FAILED_COUNT" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
