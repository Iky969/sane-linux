#!/usr/bin/env bash
# scripts/test-spm.sh -- Adversarial Test Harness for S.A.N.E Package Manager (spm)
#
# Validates the 12 core SPM contracts (SPM-35):
#   1. Fresh install of valid package -> verify files on disk and DB index.
#   2. Tar-slip attack archive (./x/../../etc/passwd) -> reject with exit 1.
#   3. Symlink escape attack (./x/usr/bin/evil -> /etc/shadow) -> reject with exit 1.
#   4. File collision between two user packages -> second install must abort with exit 1.
#   5. Base package file claim -> verify base package (base=true) claims unowned rootfs files.
#   6. Bottom-up removal -> files and empty dirs removed, non-empty shared dirs preserved.
#   7. Rollback verification -> simulate failure during staging and verify zero residue.
#   8. Forbidden ninit snippet (e.g. respawn:kill -9 1) -> rejected with exit 1.
#   9. Active binary replacement -> atomic rename replaces running daemon binary (no ETXTBSY).
#  10. Query and info subcommands -> verify accurate reporting.
#  11. Concurrency lock test -> verify concurrent spm commands respect spm.lock via readiness signaling.
#  12. Reverse dependency blocking -> verify spm remove blocks when package has active dependents.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SPM_BIN="$REPO_ROOT/scripts/spm"

TEST_TMP="$(mktemp -d /tmp/sane-spm-test-XXXXXX)"

cleanup() {
    set +e
    # Terminate any background child processes started by this harness
    local pids
    pids="$(jobs -p 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        kill -9 $pids 2>/dev/null || true
    fi
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT INT TERM

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
# Python Package Generation Helper
# -----------------------------------------------------------------------------
python_pkg_helper() {
    python3 - "$@" <<'PYEOF'
import sys, os, io, tarfile, lzma, hashlib

def make_package(out_path, name, version="1.0.0", release="1", arch="x86_64",
                 desc="Test package", base=False, deps="",
                 payload_files=None, symlinks=None, raw_entries=None,
                 corrupt_sha=False):
    """
    Build an .spm.tar.xz package archive.
    payload_files: dict of rel_path -> content (str or bytes)
    symlinks: dict of rel_path -> target (str)
    raw_entries: list of tuples: (archive_path, data_bytes, typeflag, linkname, mode)
    """
    if payload_files is None:
        payload_files = {}
    if symlinks is None:
        symlinks = {}
    if raw_entries is None:
        raw_entries = []

    # Infer directories for regular files and symlinks
    dirs = set()
    for p in list(payload_files.keys()) + list(symlinks.keys()):
        parts = p.split('/')
        for i in range(1, len(parts)):
            dirs.add('/'.join(parts[:i]) + '/')

    sorted_files = sorted(list(dirs) + list(payload_files.keys()) + list(symlinks.keys()))
    files_txt = "".join(p + "\n" for p in sorted_files)

    sha_lines = []
    for p in sorted(payload_files.keys()):
        data = payload_files[p]
        if isinstance(data, str):
            data = data.encode("utf-8")
        if corrupt_sha:
            h = "0" * 64
        else:
            h = hashlib.sha256(data).hexdigest()
        sha_lines.append(f"{h}  {p}\n")
    sha_txt = "".join(sha_lines)

    pkg_txt = (
        f"name={name}\n"
        f"version={version}\n"
        f"release={release}\n"
        f"arch={arch}\n"
        f"description={desc}\n"
        f"base={'true' if base else 'false'}\n"
    )

    buf = io.BytesIO()
    with lzma.open(buf, "wb", preset=6) as xz_out:
        with tarfile.open(fileobj=xz_out, mode="w") as tar:
            # Metadata entries
            deps_txt = (deps.strip() + "\n") if deps.strip() else ""
            for fname, content in [
                ("./.META/package", pkg_txt),
                ("./.META/files", files_txt),
                ("./.META/sha256", sha_txt),
                ("./.META/depends", deps_txt),
            ]:
                b = content.encode("utf-8")
                ti = tarfile.TarInfo(fname)
                ti.size = len(b)
                ti.mode = 0o644
                tar.addfile(ti, io.BytesIO(b))

            # Directories
            for d in sorted(dirs):
                ti = tarfile.TarInfo("./x/" + d.rstrip("/"))
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                tar.addfile(ti)

            # Regular files
            for p, content in payload_files.items():
                data = content.encode("utf-8") if isinstance(content, str) else content
                ti = tarfile.TarInfo("./x/" + p)
                ti.size = len(data)
                ti.mode = 0o755 if ("bin/" in p or "sbin/" in p) else 0o644
                tar.addfile(ti, io.BytesIO(data))

            # Symlinks
            for p, target in symlinks.items():
                ti = tarfile.TarInfo("./x/" + p)
                ti.type = tarfile.SYMTYPE
                ti.linkname = target
                tar.addfile(ti)

            # Raw entries (for adversarial / malformed tar archives)
            for raw_name, raw_data, raw_type, raw_link, raw_mode in raw_entries:
                ti = tarfile.TarInfo(raw_name)
                ti.type = raw_type
                ti.mode = raw_mode
                if raw_link:
                    ti.linkname = raw_link
                if raw_data is not None:
                    ti.size = len(raw_data)
                    tar.addfile(ti, io.BytesIO(raw_data))
                else:
                    tar.addfile(ti)

    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(buf.getvalue())

# CLI dispatcher for python_pkg_helper
cmd = sys.argv[1]
if cmd == "create_valid":
    out = sys.argv[2]
    name = sys.argv[3]
    version = sys.argv[4] if len(sys.argv) > 4 else "1.0.0"
    base = (sys.argv[5] == "true") if len(sys.argv) > 5 else False
    desc = sys.argv[6] if len(sys.argv) > 6 else "Valid test package"
    payload = {}
    for arg in sys.argv[7:]:
        if ":" in arg:
            k, v = arg.split(":", 1)
            payload[k] = v
    make_package(out, name, version=version, base=base, desc=desc, payload_files=payload)

elif cmd == "create_with_deps":
    out = sys.argv[2]
    name = sys.argv[3]
    version = sys.argv[4]
    deps = sys.argv[5]
    payload = {}
    for arg in sys.argv[6:]:
        if ":" in arg:
            k, v = arg.split(":", 1)
            payload[k] = v
    make_package(out, name, version=version, deps=deps, desc="Dependent package", payload_files=payload)

elif cmd == "create_tarslip":
    out = sys.argv[2]
    name = sys.argv[3]
    slip_target = sys.argv[4]
    slip_content = sys.argv[5].encode("utf-8")
    raw = [(slip_target, slip_content, tarfile.REGTYPE, "", 0o644)]
    make_package(out, name, raw_entries=raw)

elif cmd == "create_symlink_escape":
    out = sys.argv[2]
    name = sys.argv[3]
    link_path = sys.argv[4]
    link_target = sys.argv[5]
    syms = {link_path: link_target}
    make_package(out, name, symlinks=syms)

elif cmd == "create_corrupted_sha":
    out = sys.argv[2]
    name = sys.argv[3]
    rel_path = sys.argv[4]
    content = sys.argv[5]
    payload = {rel_path: content}
    make_package(out, name, payload_files=payload, corrupt_sha=True)

elif cmd == "create_forbidden_service":
    out = sys.argv[2]
    name = sys.argv[3]
    svc_name = sys.argv[4]
    svc_content = sys.argv[5]
    payload = {f"usr/share/ninit/services/{svc_name}.service": svc_content}
    make_package(out, name, payload_files=payload)

elif cmd == "create_binary_pkg":
    out = sys.argv[2]
    name = sys.argv[3]
    version = sys.argv[4]
    bin_rel_path = sys.argv[5]
    bin_source_path = sys.argv[6]
    with open(bin_source_path, "rb") as bf:
        bdata = bf.read()
    payload = {bin_rel_path: bdata}
    make_package(out, name, version=version, payload_files=payload)

PYEOF
}

# -----------------------------------------------------------------------------
# Scenario 1: Fresh install of valid package
# -----------------------------------------------------------------------------
test_fresh_install() {
    local tdir="$TEST_TMP/scenario1"
    local root="$tdir/root"
    local pkg="$tdir/pkg-valid-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    python_pkg_helper create_valid "$pkg" "pkg-valid" "1.0.0" "false" "Valid fresh install test" \
        "usr/bin/valid-tool:echo valid tool" \
        "etc/valid-pkg/valid.conf:setting=true"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    if ! "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 1" "Fresh install of valid package failed"
        return
    fi

    # Verify files on disk
    if [ ! -f "$root/usr/bin/valid-tool" ]; then
        test_fail "Scenario 1" "File usr/bin/valid-tool missing on disk"
        return
    fi
    if [ ! -f "$root/etc/valid-pkg/valid.conf" ]; then
        test_fail "Scenario 1" "File etc/valid-pkg/valid.conf missing on disk"
        return
    fi

    # Verify DB index: installed/, providers, world
    if [ ! -f "$root/var/lib/spm/installed/pkg-valid/package" ]; then
        test_fail "Scenario 1" "DB installed/pkg-valid/package missing"
        return
    fi
    if [ ! -f "$root/var/lib/spm/installed/pkg-valid/files.list" ]; then
        test_fail "Scenario 1" "DB installed/pkg-valid/files.list missing"
        return
    fi
    if [ ! -f "$root/var/lib/spm/installed/pkg-valid/sha256" ]; then
        test_fail "Scenario 1" "DB installed/pkg-valid/sha256 missing"
        return
    fi

    if ! grep -q "pkg-valid" "$root/var/lib/spm/providers" 2>/dev/null; then
        test_fail "Scenario 1" "DB providers does not record pkg-valid"
        return
    fi

    if ! grep -q "^pkg-valid$" "$root/var/lib/spm/world" 2>/dev/null; then
        test_fail "Scenario 1" "DB world does not contain pkg-valid"
        return
    fi

    # Verify staging scratch area is clean (zero residue)
    local staging_residue
    staging_residue="$(find "$root/var/lib/spm/staging" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
    if [ -n "$staging_residue" ]; then
        test_fail "Scenario 1" "DB staging residue found after install: $staging_residue"
        return
    fi

    test_pass "Scenario 1: Fresh install of valid package (disk files and DB index verified)"
}

# -----------------------------------------------------------------------------
# Scenario 2: Tar-slip attack archive (./x/../../etc/passwd)
# -----------------------------------------------------------------------------
test_tar_slip_attack() {
    local tdir="$TEST_TMP/scenario2"
    local root="$tdir/root"
    local pkg="$tdir/tarslip-attack-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root/etc"
    echo "original_rootfs_passwd" > "$root/etc/passwd"

    # Craft archive with tar-slip relative traversal
    python_pkg_helper create_tarslip "$pkg" "tarslip-pkg" "./x/../../etc/passwd" "attack_payload_passwd"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    local exit_code=0
    "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 2" "Expected exit code 1 for tar-slip attack, got $exit_code"
        return
    fi

    # Verify protected target file was not overwritten
    local content
    content="$(cat "$root/etc/passwd")"
    if [ "$content" != "original_rootfs_passwd" ]; then
        test_fail "Scenario 2" "Target file was compromised by tar-slip archive!"
        return
    fi

    # Verify DB was not updated
    if [ -d "$root/var/lib/spm/installed/tarslip-pkg" ]; then
        test_fail "Scenario 2" "Malicious package recorded in DB installed/"
        return
    fi

    test_pass "Scenario 2: Tar-slip attack archive (./x/../../etc/passwd rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 3: Symlink escape attack (./x/usr/bin/evil -> /etc/shadow)
# -----------------------------------------------------------------------------
test_symlink_escape_attack() {
    local tdir="$TEST_TMP/scenario3"
    local root="$tdir/root"
    local pkg="$tdir/symlink-escape-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    # Craft archive with out-of-root symlink escape
    python_pkg_helper create_symlink_escape "$pkg" "evil-symlink" "usr/bin/evil" "/etc/shadow"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    local exit_code=0
    "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 3" "Expected exit code 1 for symlink escape attack, got $exit_code"
        return
    fi

    # Verify symlink was not created on target rootfs
    if [ -e "$root/usr/bin/evil" ] || [ -L "$root/usr/bin/evil" ]; then
        test_fail "Scenario 3" "Escaping symlink was extracted to disk!"
        return
    fi

    test_pass "Scenario 3: Symlink escape attack (./x/usr/bin/evil -> /etc/shadow rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 4: File collision between two user packages
# -----------------------------------------------------------------------------
test_file_collision_user_packages() {
    local tdir="$TEST_TMP/scenario4"
    local root="$tdir/root"
    local pkg_a="$tdir/pkg-coll-a-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_b="$tdir/pkg-coll-b-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    python_pkg_helper create_valid "$pkg_a" "pkg-coll-a" "1.0.0" "false" "Collision User Package A" \
        "usr/bin/collision-cli:tool version a"
    python_pkg_helper create_valid "$pkg_b" "pkg-coll-b" "1.0.0" "false" "Collision User Package B" \
        "usr/bin/collision-cli:tool version b"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # First package must succeed
    if ! "$SPM_BIN" install "$pkg_a" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 4" "Initial package install failed"
        return
    fi

    # Second package colliding on usr/bin/collision-cli must abort with exit 1
    local exit_code=0
    "$SPM_BIN" install "$pkg_b" --root "$root" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 4" "Colliding install did not abort with exit 1 (got $exit_code)"
        return
    fi

    # Verify original file content remains untouched
    local content
    content="$(cat "$root/usr/bin/collision-cli")"
    if [ "$content" != "tool version a" ]; then
        test_fail "Scenario 4" "File content modified despite collision failure"
        return
    fi

    # Verify second package was not recorded in world
    if grep -q "^pkg-coll-b$" "$root/var/lib/spm/world" 2>/dev/null; then
        test_fail "Scenario 4" "Colliding package found in DB world"
        return
    fi

    test_pass "Scenario 4: File collision between two user packages (second install aborted with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 5: Base package file claim
# -----------------------------------------------------------------------------
test_base_package_file_claim() {
    local tdir="$TEST_TMP/scenario5"
    local root="$tdir/root"
    local user_pkg="$tdir/user-claim-1.0.0-1-x86_64.spm.tar.xz"
    local base_pkg="$tdir/base-core-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root/bin"

    # Pre-create unowned file in rootfs (not in providers index)
    echo "pre-existing unowned binary" > "$root/bin/busybox"

    python_pkg_helper create_valid "$user_pkg" "user-claim" "1.0.0" "false" "User package cannot claim" \
        "bin/busybox:overwritten by user"
    python_pkg_helper create_valid "$base_pkg" "base-core" "1.0.0" "true" "Base package claim" \
        "bin/busybox:claimed by base"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # User package (base=false) must abort when encountering pre-existing unowned file
    local exit_user=0
    "$SPM_BIN" install "$user_pkg" --root "$root" >/dev/null 2>&1 || exit_user=$?
    if [ "$exit_user" -ne 1 ]; then
        test_fail "Scenario 5" "User package erroneously claimed unowned file (expected exit 1, got $exit_user)"
        return
    fi

    # Base package (base=true) must succeed and claim unowned rootfs file
    local exit_base=0
    "$SPM_BIN" install "$base_pkg" --root "$root" >/dev/null 2>&1 || exit_base=$?
    if [ "$exit_base" -ne 0 ]; then
        test_fail "Scenario 5" "Base package failed to claim unowned file (expected exit 0, got $exit_base)"
        return
    fi

    # Verify providers records ownership
    if ! grep -q "base-core" "$root/var/lib/spm/providers" 2>/dev/null; then
        test_fail "Scenario 5" "Base package not registered in providers index"
        return
    fi

    test_pass "Scenario 5: Base package file claim (base=true successfully claims unowned rootfs files)"
}

# -----------------------------------------------------------------------------
# Scenario 6: Bottom-up removal
# -----------------------------------------------------------------------------
test_bottom_up_removal() {
    local tdir="$TEST_TMP/scenario6"
    local root="$tdir/root"
    local pkg="$tdir/pkg-remove-test-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root/usr/bin" "$root/etc"

    # Keep a shared file in /usr/bin to prove shared directory preservation
    echo "shared tool" > "$root/usr/bin/keep-shared"
    echo "shared conf" > "$root/etc/system.conf"

    python_pkg_helper create_valid "$pkg" "pkg-remove-test" "1.0.0" "false" "Removal test package" \
        "usr/bin/removable-app:echo removable" \
        "usr/share/pkg-remove-test/nested/data.txt:nested payload data"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    if ! "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 6" "Package installation failed prior to removal"
        return
    fi

    # Confirm installation
    [ -f "$root/usr/bin/removable-app" ] || { test_fail "Scenario 6" "removable-app not present"; return; }
    [ -f "$root/usr/share/pkg-remove-test/nested/data.txt" ] || { test_fail "Scenario 6" "data.txt not present"; return; }

    # Perform removal
    if ! "$SPM_BIN" remove "pkg-remove-test" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 6" "spm remove command failed"
        return
    fi

    # Verify package files removed
    if [ -f "$root/usr/bin/removable-app" ]; then
        test_fail "Scenario 6" "File usr/bin/removable-app was not removed"
        return
    fi
    if [ -f "$root/usr/share/pkg-remove-test/nested/data.txt" ]; then
        test_fail "Scenario 6" "File usr/share/pkg-remove-test/nested/data.txt was not removed"
        return
    fi

    # Verify empty directories removed bottom-up
    if [ -d "$root/usr/share/pkg-remove-test/nested" ] || [ -d "$root/usr/share/pkg-remove-test" ]; then
        test_fail "Scenario 6" "Empty package directories were not pruned bottom-up"
        return
    fi

    # Verify shared non-empty directories preserved
    if [ ! -d "$root/usr/bin" ] || [ ! -f "$root/usr/bin/keep-shared" ]; then
        test_fail "Scenario 6" "Shared directory /usr/bin or preserved file damaged during removal!"
        return
    fi
    if [ ! -f "$root/etc/system.conf" ]; then
        test_fail "Scenario 6" "Shared directory /etc or preserved conf damaged!"
        return
    fi

    # Verify DB index cleanup
    if [ -d "$root/var/lib/spm/installed/pkg-remove-test" ]; then
        test_fail "Scenario 6" "DB installed/ directory not removed for package"
        return
    fi
    if grep -q "pkg-remove-test" "$root/var/lib/spm/world" 2>/dev/null; then
        test_fail "Scenario 6" "Package still present in DB world"
        return
    fi

    test_pass "Scenario 6: Bottom-up removal (files & empty dirs pruned, shared dirs preserved)"
}

# -----------------------------------------------------------------------------
# Scenario 7: Rollback verification
# -----------------------------------------------------------------------------
test_rollback_verification() {
    local tdir="$TEST_TMP/scenario7"
    local root="$tdir/root"
    local pkg="$tdir/pkg-rollback-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    # Create package with corrupted SHA256 checksum to trigger staging verification failure
    python_pkg_helper create_corrupted_sha "$pkg" "pkg-rollback" "usr/bin/corrupted-tool" "payload data"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    local exit_code=0
    "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 7" "Expected exit code 1 for corrupted checksum, got $exit_code"
        return
    fi

    # Verify zero residue on target rootfs
    if [ -f "$root/usr/bin/corrupted-tool" ]; then
        test_fail "Scenario 7" "File committed to disk despite staging failure!"
        return
    fi

    # Verify staging directory wiped (zero residue)
    local staging_residue
    staging_residue="$(find "$root/var/lib/spm/staging" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
    if [ -n "$staging_residue" ]; then
        test_fail "Scenario 7" "Staging directory residue found after rollback: $staging_residue"
        return
    fi

    # Verify zero residue in DB
    if [ -d "$root/var/lib/spm/installed/pkg-rollback" ]; then
        test_fail "Scenario 7" "DB installed/ record created despite failure"
        return
    fi
    if grep -q "pkg-rollback" "$root/var/lib/spm/providers" 2>/dev/null; then
        test_fail "Scenario 7" "DB providers contains corrupted package entry"
        return
    fi

    test_pass "Scenario 7: Rollback verification (staging failure leaves zero residue on disk or DB)"
}

# -----------------------------------------------------------------------------
# Scenario 8: Forbidden ninit snippet (e.g. respawn:kill -9 1)
# -----------------------------------------------------------------------------
test_forbidden_ninit_snippet() {
    local tdir="$TEST_TMP/scenario8"
    local root="$tdir/root"
    local pkg="$tdir/pkg-bad-service-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    # Craft package with forbidden ninit command snippet
    python_pkg_helper create_forbidden_service "$pkg" "bad-service-pkg" "evil" "respawn:kill -9 1"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    local exit_code=0
    "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 8" "Expected exit code 1 for forbidden ninit snippet, got $exit_code"
        return
    fi

    # Verify service file was not placed on disk
    if [ -f "$root/usr/share/ninit/services/evil.service" ]; then
        test_fail "Scenario 8" "Forbidden service snippet installed to disk!"
        return
    fi

    # Verify staging directory wiped (zero residue)
    local staging_residue
    staging_residue="$(find "$root/var/lib/spm/staging" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
    if [ -n "$staging_residue" ]; then
        test_fail "Scenario 8" "Staging directory residue found after forbidden snippet rejection: $staging_residue"
        return
    fi

    # Verify zero residue in DB
    if [ -d "$root/var/lib/spm/installed/bad-service-pkg" ]; then
        test_fail "Scenario 8" "DB installed record created despite forbidden snippet"
        return
    fi

    test_pass "Scenario 8: Forbidden ninit snippet (rejected with exit 1 and zero disk residue)"
}

# -----------------------------------------------------------------------------
# Scenario 9: Active binary replacement (atomic rename avoiding ETXTBSY)
# -----------------------------------------------------------------------------
test_active_binary_replacement() {
    local tdir="$TEST_TMP/scenario9"
    local root="$tdir/root"
    local bin_v1="$tdir/daemon_v1"
    local bin_v2="$tdir/daemon_v2"
    local src_c="$tdir/daemon.c"
    local pkg_v1="$tdir/daemon-pkg-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_v2="$tdir/daemon-pkg-2.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    # Compile a minimal long-running daemon binary in C
    cat > "$src_c" <<'EOF'
#include <unistd.h>
int main(void) {
    while (1) {
        usleep(50000);
    }
    return 0;
}
EOF
    gcc -O2 -o "$bin_v1" "$src_c"

    # Create v2 binary with distinct payload
    cat > "$tdir/daemon2.c" <<'EOF'
#include <unistd.h>
const char *ver = "v2.0.0";
int main(void) {
    while (1) {
        usleep(50000);
    }
    return 0;
}
EOF
    gcc -O2 -o "$bin_v2" "$tdir/daemon2.c"

    python_pkg_helper create_binary_pkg "$pkg_v1" "daemon-pkg" "1.0.0" "usr/bin/my-daemon" "$bin_v1"
    python_pkg_helper create_binary_pkg "$pkg_v2" "daemon-pkg" "2.0.0" "usr/bin/my-daemon" "$bin_v2"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Install version 1
    if ! "$SPM_BIN" install "$pkg_v1" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 9" "Initial install of daemon binary failed"
        return
    fi

    # Start the daemon running from target rootfs
    "$root/usr/bin/my-daemon" &
    local daemon_pid=$!

    # Bounded poll: verify daemon process is active
    local running=false
    for _ in $(seq 1 10); do
        if kill -0 "$daemon_pid" 2>/dev/null; then
            running=true
            break
        fi
        sleep 0.05
    done

    if [ "$running" != "true" ]; then
        test_fail "Scenario 9" "Failed to start background daemon process"
        return
    fi

    # Under Linux, executing binaries return ETXTBSY if overwritten in-place with cp.
    # Atomic rename (mv) succeeds without error.
    local install_status=0
    "$SPM_BIN" install "$pkg_v2" --root "$root" >/dev/null 2>&1 || install_status=$?

    # Clean up running daemon process immediately
    kill -9 "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true

    if [ "$install_status" -ne 0 ]; then
        test_fail "Scenario 9" "Binary replacement of running daemon failed (likely ETXTBSY)"
        return
    fi

    test_pass "Scenario 9: Active binary replacement (atomic rename replaces running daemon binary without ETXTBSY)"
}

# -----------------------------------------------------------------------------
# Scenario 10: Query and info subcommands
# -----------------------------------------------------------------------------
test_query_and_info() {
    local tdir="$TEST_TMP/scenario10"
    local root="$tdir/root"
    local pkg="$tdir/pkg-info-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    python_pkg_helper create_valid "$pkg" "pkg-info" "1.2.3" "false" "Information reporting test package" \
        "usr/bin/info-tool:echo info"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1
    "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1

    # Test query with absolute path
    local q_out
    q_out="$("$SPM_BIN" query "/usr/bin/info-tool" --root "$root" 2>/dev/null || true)"
    if ! echo "$q_out" | grep -q "pkg-info"; then
        # Also test query with relative path
        q_out="$("$SPM_BIN" query "usr/bin/info-tool" --root "$root" 2>/dev/null || true)"
        if ! echo "$q_out" | grep -q "pkg-info"; then
            test_fail "Scenario 10" "Query for /usr/bin/info-tool failed to return pkg-info (got: $q_out)"
            return
        fi
    fi

    # Test query for unmanaged path returns non-zero
    local q_missing_exit=0
    "$SPM_BIN" query "/usr/bin/unmanaged-path" --root "$root" >/dev/null 2>&1 || q_missing_exit=$?
    if [ "$q_missing_exit" -eq 0 ]; then
        test_fail "Scenario 10" "Query on unmanaged path unexpectedly returned 0"
        return
    fi

    # Test info subcommand
    local info_out
    info_out="$("$SPM_BIN" info "pkg-info" --root "$root" 2>/dev/null || true)"
    if ! echo "$info_out" | grep -q "1.2.3"; then
        test_fail "Scenario 10" "Info output missing package version (got: $info_out)"
        return
    fi

    # Test list subcommand
    local list_out
    list_out="$("$SPM_BIN" list --root "$root" 2>/dev/null || true)"
    if ! echo "$list_out" | grep -q "pkg-info"; then
        test_fail "Scenario 10" "List output missing pkg-info (got: $list_out)"
        return
    fi

    test_pass "Scenario 10: Query and info subcommands (accurate metadata reporting and provider lookups)"
}

# -----------------------------------------------------------------------------
# Scenario 11: Concurrency lock test (readiness FIFO synchronization)
# -----------------------------------------------------------------------------
test_concurrency_lock() {
    local tdir="$TEST_TMP/scenario11"
    local root="$tdir/root"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1
    local lockfile="$root/var/lib/spm/spm.lock"

    if [ ! -f "$lockfile" ]; then
        touch "$lockfile"
    fi

    local ready_fifo="$tdir/lock_acquired.fifo"
    local release_fifo="$tdir/release_lock.fifo"
    mkfifo "$ready_fifo" "$release_fifo"

    # Acquire an exclusive flock in a subshell background job
    (
        exec 200>"$lockfile"
        flock -x 200
        # Signal readiness: lock is held!
        printf 'READY\n' > "$ready_fifo"
        # Wait for release signal
        read -r _ < "$release_fifo"
    ) &
    local holder_pid=$!

    # Read from ready_fifo: guarantees the lock is 100% held before proceeding
    local signal
    read -r signal < "$ready_fifo"

    # Start competing spm command in background
    "$SPM_BIN" list --root "$root" >/dev/null 2>&1 &
    local spm_pid=$!

    # Verify SPM command is blocked waiting for lock while holder is active
    local lock_respected=false
    sleep 0.05
    if kill -0 "$holder_pid" 2>/dev/null && kill -0 "$spm_pid" 2>/dev/null; then
        lock_respected=true
    fi

    # Release lock
    printf 'RELEASE\n' > "$release_fifo"

    wait "$holder_pid" 2>/dev/null || true
    wait "$spm_pid" 2>/dev/null || true

    rm -f "$ready_fifo" "$release_fifo"

    if [ "$lock_respected" != "true" ]; then
        test_fail "Scenario 11" "Concurrency lock was not respected (spm did not block while lock was held)"
        return
    fi

    test_pass "Scenario 11: Concurrency lock test (spm commands respect flock exclusive locking with readiness signal)"
}

# -----------------------------------------------------------------------------
# Scenario 12: Reverse dependency blocking (rdeps guard on remove)
# -----------------------------------------------------------------------------
test_reverse_dependency_blocking() {
    local tdir="$TEST_TMP/scenario12"
    local root="$tdir/root"
    local pkg_dep="$tdir/pkg-dep-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_app="$tdir/pkg-app-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    # Base dependency package
    python_pkg_helper create_valid "$pkg_dep" "pkg-dep" "1.0.0" "false" "Dependency base package" \
        "usr/lib/libdep.so:dep library content"

    # Dependent package declaring dependency on pkg-dep
    python_pkg_helper create_with_deps "$pkg_app" "pkg-app" "1.0.0" "pkg-dep" \
        "usr/bin/app-bin:app binary depending on dep"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Install both packages
    "$SPM_BIN" install "$pkg_dep" --root "$root" >/dev/null 2>&1
    "$SPM_BIN" install "$pkg_app" --root "$root" >/dev/null 2>&1

    # Attempt to remove dependency while dependent package is still installed
    local remove_dep_exit=0
    "$SPM_BIN" remove "pkg-dep" --root "$root" >/dev/null 2>&1 || remove_dep_exit=$?

    if [ "$remove_dep_exit" -ne 1 ]; then
        test_fail "Scenario 12" "Expected exit code 1 when removing required dependency, got $remove_dep_exit"
        return
    fi

    # Verify dependency files and DB records were NOT removed
    if [ ! -f "$root/usr/lib/libdep.so" ]; then
        test_fail "Scenario 12" "Dependency file was removed despite active reverse dependency!"
        return
    fi
    if [ ! -d "$root/var/lib/spm/installed/pkg-dep" ]; then
        test_fail "Scenario 12" "Dependency package was removed from DB installed/"
        return
    fi

    # Now remove dependent package first -> must succeed
    if ! "$SPM_BIN" remove "pkg-app" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 12" "Failed to remove dependent package"
        return
    fi

    # Now removal of dependency must succeed
    if ! "$SPM_BIN" remove "pkg-dep" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 12" "Failed to remove dependency after dependent was uninstalled"
        return
    fi

    # Verify dependency file is now cleaned up
    if [ -f "$root/usr/lib/libdep.so" ]; then
        test_fail "Scenario 12" "Dependency file still present after uninstallation"
        return
    fi

    test_pass "Scenario 12: Reverse dependency blocking (spm remove blocks when package has active dependents)"
}

# -----------------------------------------------------------------------------
# Main Runner
# -----------------------------------------------------------------------------
main() {
    printf '=== S.A.N.E Package Manager (spm) Adversarial Test Suite ===\n'
    if [ ! -x "$SPM_BIN" ]; then
        printf 'ERROR: %s not found or not executable!\n' "$SPM_BIN" >&2
        exit 1
    fi

    test_fresh_install
    test_tar_slip_attack
    test_symlink_escape_attack
    test_file_collision_user_packages
    test_base_package_file_claim
    test_bottom_up_removal
    test_rollback_verification
    test_forbidden_ninit_snippet
    test_active_binary_replacement
    test_query_and_info
    test_concurrency_lock
    test_reverse_dependency_blocking

    printf '\n==================================================\n'
    printf 'SPM Test Suite Summary: %d passed, %d failed\n' "$PASSED_COUNT" "$FAILED_COUNT"

    if [ "$FAILED_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"