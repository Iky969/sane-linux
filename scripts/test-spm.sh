#!/bin/sh
# scripts/test-spm.sh -- Adversarial Test Harness for S.A.N.E Package Manager (spm)
#
# Validates the 20 core SPM contracts (SPM-35 & Hardening Suite):
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
#  13. .META/files traversal rejection -> relative and absolute paths rejected with exit 1.
#  14. .META/files mismatch rejection -> unrecorded staging file or ghost manifest entry rejected with exit 1.
#  15. Regular file rollback restoration -> commit failure restores regular file from backup.
#  16. Unified DB rollback -> DB commit failure rolls back filesystem and restores DB snapshot.
#  17. Destination symlink escape rejection -> parent dir resolving outside target root rejected with exit 1.
#  18. Fail-closed checksum -> missing manifest, malformed hash, missing file, or ghost checksum rejected with exit 1.
#  19. Package upgrade obsolete file pruning -> obsolete files and empty dirs pruned bottom-up, DB consistent.
#  20. Package upgrade rdeps pruning -> dropped dependencies pruned from rdeps and safely removable.
#  21. Base package removal protection & atomic replacement -> base=true blocks removal without --force.
#  22. Hardlink rejection -> archive containing hard link member rejected with exit 1.
#  23. Setuid/setgid rejection -> pre-extraction and post-extraction audit reject setuid/setgid binaries with exit 1.
#  24. Duplicate member rejection -> duplicate archive member or duplicate .META/files rejected with exit 1.
#  25. Invalid dependency name rejection -> invalid dependency names in .META/depends or manifest rejected with exit 1.
#  26. Power-cut journal recovery simulation -> leftover transaction journal rolled back cleanly on startup.
#  27. Invalid metadata (name/arch/base) -> rejected with zero filesystem residue.
#  28. Upgrade failing mid-commit -> injected mv failure rolls back file content, DB and staging.
#  29. Real SIGKILL mid-commit -> journal recovery on next command restores disk and DB.
#  30. Shared-file ownership conflict -> intruder rejected; uninstall leaves other package files intact.
#  31. Two simultaneous installs -> serialized by flock, both payloads and DB indexes intact.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
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
                 desc="Test package", base=False, deps="", manifest_deps="",
                 payload_files=None, symlinks=None, raw_entries=None,
                 corrupt_sha=False,
                 custom_files=None, custom_sha=None, omit_sha=False,
                 extra_staging_files=None, ghost_files=None):
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
    if extra_staging_files is None:
        extra_staging_files = {}
    if ghost_files is None:
        ghost_files = []

    # Infer directories for regular files, symlinks, and extra staging
    dirs = set()
    all_keys = list(payload_files.keys()) + list(symlinks.keys()) + list(extra_staging_files.keys())
    for p in all_keys:
        parts = p.split('/')
        for i in range(1, len(parts)):
            dirs.add('/'.join(parts[:i]) + '/')

    if custom_files is not None:
        files_txt = custom_files
    else:
        file_entries = list(dirs) + list(payload_files.keys()) + list(symlinks.keys()) + list(ghost_files)
        sorted_files = sorted(file_entries)
        files_txt = "".join(p + "\n" for p in sorted_files)

    if custom_sha is not None:
        sha_txt = custom_sha
    elif corrupt_sha:
        sha_lines = []
        for p in sorted(payload_files.keys()):
            sha_lines.append(f"{'0'*64}  {p}\n")
        sha_txt = "".join(sha_lines)
    else:
        sha_lines = []
        for p in sorted(payload_files.keys()):
            data = payload_files[p]
            if isinstance(data, str):
                data = data.encode("utf-8")
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
    if manifest_deps:
        pkg_txt += f"dependencies={manifest_deps}\n"

    buf = io.BytesIO()
    with lzma.open(buf, "wb", preset=6) as xz_out:
        with tarfile.open(fileobj=xz_out, mode="w") as tar:
            # Metadata entries
            deps_txt = (deps.strip() + "\n") if deps.strip() else ""
            meta_entries = [
                ("./.META/package", pkg_txt),
                ("./.META/files", files_txt),
                ("./.META/depends", deps_txt),
            ]
            if not omit_sha:
                meta_entries.append(("./.META/sha256", sha_txt))

            for fname, content in meta_entries:
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

            # Regular files (payload + extra staging)
            all_files = dict(payload_files)
            all_files.update(extra_staging_files)
            for p, content in all_files.items():
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

elif cmd == "create_meta_traversal":
    out = sys.argv[2]
    name = sys.argv[3]
    bad_line = sys.argv[4]
    custom_f = f"usr/\nusr/bin/\nusr/bin/tool\n{bad_line}\n"
    payload = {"usr/bin/tool": "echo tool"}
    make_package(out, name, payload_files=payload, custom_files=custom_f)

elif cmd == "create_unrecorded_staging":
    out = sys.argv[2]
    name = sys.argv[3]
    unrecorded_path = sys.argv[4]
    unrecorded_content = sys.argv[5]
    payload = {"usr/bin/valid-tool": "echo valid"}
    extra = {unrecorded_path: unrecorded_content}
    make_package(out, name, payload_files=payload, extra_staging_files=extra)

elif cmd == "create_ghost_entry":
    out = sys.argv[2]
    name = sys.argv[3]
    ghost_path = sys.argv[4]
    payload = {"usr/bin/valid-tool": "echo valid"}
    ghosts = [ghost_path]
    make_package(out, name, payload_files=payload, ghost_files=ghosts)

elif cmd == "create_missing_sha":
    out = sys.argv[2]
    name = sys.argv[3]
    payload = {}
    for arg in sys.argv[4:]:
        if ":" in arg:
            k, v = arg.split(":", 1)
            payload[k] = v
    if not payload:
        payload["usr/bin/tool"] = "echo tool"
    make_package(out, name, payload_files=payload, omit_sha=True)

elif cmd == "create_malformed_sha":
    out = sys.argv[2]
    name = sys.argv[3]
    bad_sha = sys.argv[4]
    payload = {}
    for arg in sys.argv[5:]:
        if ":" in arg:
            k, v = arg.split(":", 1)
            payload[k] = v
    if not payload:
        payload["usr/bin/tool"] = "echo tool"
    make_package(out, name, payload_files=payload, custom_sha=bad_sha)

elif cmd == "create_missing_file_sha":
    out = sys.argv[2]
    name = sys.argv[3]
    p1 = sys.argv[4]
    c1 = sys.argv[5]
    p2 = sys.argv[6]
    c2 = sys.argv[7]
    payload = {p1: c1, p2: c2}
    h1 = hashlib.sha256(c1.encode("utf-8")).hexdigest()
    custom_sha = f"{h1}  {p1}\n"
    make_package(out, name, payload_files=payload, custom_sha=custom_sha)

elif cmd == "create_ghost_sha":
    out = sys.argv[2]
    name = sys.argv[3]
    ghost_rel = sys.argv[4]
    payload = {}
    for arg in sys.argv[5:]:
        if ":" in arg:
            k, v = arg.split(":", 1)
            payload[k] = v
    if not payload:
        payload["usr/bin/tool"] = "echo tool"
    sha_lines = []
    for p, c in payload.items():
        h = hashlib.sha256(c.encode("utf-8")).hexdigest()
        sha_lines.append(f"{h}  {p}\n")
    sha_lines.append(f"{'0'*64}  {ghost_rel}\n")
    make_package(out, name, payload_files=payload, custom_sha="".join(sha_lines))

elif cmd == "create_hardlink":
    out = sys.argv[2]
    name = sys.argv[3]
    link_path = sys.argv[4]
    target_path = sys.argv[5]
    payload = {"usr/bin/tool": "echo tool"}
    raw = [(link_path, None, tarfile.LNKTYPE, target_path, 0o644)]
    make_package(out, name, payload_files=payload, raw_entries=raw)

elif cmd == "create_suid":
    out = sys.argv[2]
    name = sys.argv[3]
    suid_path = sys.argv[4]
    mode = int(sys.argv[5], 8)
    raw = [(suid_path, b"suid content", tarfile.REGTYPE, "", mode)]
    make_package(out, name, raw_entries=raw)

elif cmd == "create_duplicate_member":
    out = sys.argv[2]
    name = sys.argv[3]
    dup_path = sys.argv[4]
    payload = {dup_path: "content 1"}
    raw = [("./x/" + dup_path, b"content 2", tarfile.REGTYPE, "", 0o644)]
    make_package(out, name, payload_files=payload, raw_entries=raw)

elif cmd == "create_duplicate_manifest":
    out = sys.argv[2]
    name = sys.argv[3]
    payload = {"usr/bin/tool": "echo tool"}
    custom_f = "usr/\nusr/bin/\nusr/bin/tool\nusr/bin/tool\n"
    make_package(out, name, payload_files=payload, custom_files=custom_f)

elif cmd == "create_invalid_dep":
    out = sys.argv[2]
    name = sys.argv[3]
    dep_location = sys.argv[4]
    bad_dep = sys.argv[5]
    payload = {"usr/bin/tool": "echo tool"}
    if dep_location == "meta":
        make_package(out, name, deps=bad_dep, payload_files=payload)
    else:
        make_package(out, name, manifest_deps=bad_dep, payload_files=payload)

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
        exec 8>"$lockfile"
        flock -x 8
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
# Scenario 13: .META/files traversal rejection
# -----------------------------------------------------------------------------
test_meta_files_traversal_rejection() {
    local tdir="$TEST_TMP/scenario13"
    local root="$tdir/root"
    local pkg_rel="$tdir/pkg-rel-trav-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_abs="$tdir/pkg-abs-trav-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Test 1: Relative path traversal inside .META/files
    python_pkg_helper create_meta_traversal "$pkg_rel" "pkg-rel-trav" "../../etc/passwd"
    local exit_rel=0
    "$SPM_BIN" install "$pkg_rel" --root "$root" >/dev/null 2>&1 || exit_rel=$?
    if [ "$exit_rel" -ne 1 ]; then
        test_fail "Scenario 13" "Expected exit code 1 for relative traversal in .META/files, got $exit_rel"
        return
    fi

    # Test 2: Leading slash inside .META/files
    python_pkg_helper create_meta_traversal "$pkg_abs" "pkg-abs-trav" "/etc/shadow"
    local exit_abs=0
    "$SPM_BIN" install "$pkg_abs" --root "$root" >/dev/null 2>&1 || exit_abs=$?
    if [ "$exit_abs" -ne 1 ]; then
        test_fail "Scenario 13" "Expected exit code 1 for leading slash in .META/files, got $exit_abs"
        return
    fi

    # Assert neither package was installed to DB
    if [ -d "$root/var/lib/spm/installed/pkg-rel-trav" ] || [ -d "$root/var/lib/spm/installed/pkg-abs-trav" ]; then
        test_fail "Scenario 13" "Forged package record created in DB installed/"
        return
    fi

    test_pass "Scenario 13: .META/files traversal rejection (relative and absolute paths rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 14: .META/files mismatch rejection
# -----------------------------------------------------------------------------
test_meta_files_mismatch_rejection() {
    local tdir="$TEST_TMP/scenario14"
    local root="$tdir/root"
    local pkg_unrec="$tdir/pkg-unrec-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_ghost="$tdir/pkg-ghost-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Test 1: Unrecorded file in staging payload (not in .META/files)
    python_pkg_helper create_unrecorded_staging "$pkg_unrec" "pkg-unrec" "usr/bin/unrecorded" "bad content"
    local exit_unrec=0
    "$SPM_BIN" install "$pkg_unrec" --root "$root" >/dev/null 2>&1 || exit_unrec=$?
    if [ "$exit_unrec" -ne 1 ]; then
        test_fail "Scenario 14" "Expected exit code 1 for unrecorded file in staging, got $exit_unrec"
        return
    fi
    if [ -f "$root/usr/bin/unrecorded" ]; then
        test_fail "Scenario 14" "Unrecorded file was extracted to disk!"
        return
    fi

    # Test 2: Ghost entry in .META/files (not in staging payload)
    python_pkg_helper create_ghost_entry "$pkg_ghost" "pkg-ghost" "usr/bin/ghost"
    local exit_ghost=0
    "$SPM_BIN" install "$pkg_ghost" --root "$root" >/dev/null 2>&1 || exit_ghost=$?
    if [ "$exit_ghost" -ne 1 ]; then
        test_fail "Scenario 14" "Expected exit code 1 for ghost entry in .META/files, got $exit_ghost"
        return
    fi

    # Verify zero residue in DB
    if [ -d "$root/var/lib/spm/installed/pkg-unrec" ] || [ -d "$root/var/lib/spm/installed/pkg-ghost" ]; then
        test_fail "Scenario 14" "DB records created despite parity mismatch"
        return
    fi

    test_pass "Scenario 14: .META/files mismatch rejection (unrecorded payload and ghost entry rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 15: Regular file rollback restoration
# -----------------------------------------------------------------------------
test_regular_file_rollback_restoration() {
    local tdir="$TEST_TMP/scenario15"
    local root="$tdir/root"
    local pkg_v1="$tdir/pkg-rollback-reg-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_v2="$tdir/pkg-rollback-reg-2.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # 1. Install valid version 1 with existing regular file
    python_pkg_helper create_valid "$pkg_v1" "pkg-rollback-reg" "1.0.0" "false" "Rollback regular file test" \
        "usr/bin/target-regular:original regular file content"

    if ! "$SPM_BIN" install "$pkg_v1" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 15" "Initial install of pkg-rollback-reg v1 failed"
        return
    fi

    local orig_content
    orig_content="$(cat "$root/usr/bin/target-regular")"
    if [ "$orig_content" != "original regular file content" ]; then
        test_fail "Scenario 15" "Target regular file was not properly installed initially"
        return
    fi

    # 2. Create a read-only directory to force step 5 commit failure
    mkdir -p "$root/readonly_dir"
    chmod 555 "$root/readonly_dir"

    # 3. Create version 2 which replaces target-regular and attempts to write into readonly_dir
    python_pkg_helper create_valid "$pkg_v2" "pkg-rollback-reg" "2.0.0" "false" "Rollback regular file test v2" \
        "usr/bin/target-regular:compromised new content" \
        "readonly_dir/cannot_write.txt:unreachable payload"

    local exit_code=0
    "$SPM_BIN" install "$pkg_v2" --root "$root" >/dev/null 2>&1 || exit_code=$?

    # Restore write permission for directory cleanup if directory was not rmdir'd
    chmod 755 "$root/readonly_dir" 2>/dev/null || true

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 15" "Expected exit code 1 on commit failure, got $exit_code"
        return
    fi

    # 4. Assert regular file restored with original content
    if [ ! -f "$root/usr/bin/target-regular" ]; then
        test_fail "Scenario 15" "Target regular file missing after rollback (find precedence bug reproduced!)"
        return
    fi

    local restored_content
    restored_content="$(cat "$root/usr/bin/target-regular")"
    if [ "$restored_content" != "original regular file content" ]; then
        test_fail "Scenario 15" "Target regular file content not restored (got: '$restored_content')"
        return
    fi

    # Assert unreachable payload was never committed
    if [ -f "$root/readonly_dir/cannot_write.txt" ]; then
        test_fail "Scenario 15" "Failed payload file committed despite failure!"
        return
    fi

    test_pass "Scenario 15: Regular file rollback restoration (commit failure restores regular file from backup)"
}

# -----------------------------------------------------------------------------
# Scenario 16: Unified DB rollback
# -----------------------------------------------------------------------------
test_unified_db_rollback() {
    local tdir="$TEST_TMP/scenario16"
    local root="$tdir/root"
    local pkg_dep="$tdir/pkg-dep-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_db_v1="$tdir/pkg-db-fail-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_db_v2="$tdir/pkg-db-fail-2.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # 1. Install dependency package
    python_pkg_helper create_valid "$pkg_dep" "pkg-dep" "1.0.0" "false" "Dependency base" \
        "usr/lib/libdep.so:dep library content"
    if ! "$SPM_BIN" install "$pkg_dep" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 16" "Install of dependency package failed"
        return
    fi

    # 2. Install pre-install state (v1)
    python_pkg_helper create_with_deps "$pkg_db_v1" "pkg-db-fail" "1.0.0" "pkg-dep" \
        "usr/bin/db-tool:v1 tool content"

    if ! "$SPM_BIN" install "$pkg_db_v1" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 16" "Initial install of v1 failed"
        return
    fi

    # 3. Force step 6 DB commit failure by replacing rdeps/pkg-dep record with a directory
    rm -f "$root/var/lib/spm/rdeps/pkg-dep"
    mkdir -p "$root/var/lib/spm/rdeps/pkg-dep"

    # 4. Build v2 package
    python_pkg_helper create_with_deps "$pkg_db_v2" "pkg-db-fail" "2.0.0" "pkg-dep" \
        "usr/bin/db-tool:v2 tool content"

    local exit_code=0
    "$SPM_BIN" install "$pkg_db_v2" --root "$root" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 16" "Expected exit code 1 for DB commit failure, got $exit_code"
        return
    fi

    # 5. Assert filesystem rollback restored pre-install regular file content
    if [ ! -f "$root/usr/bin/db-tool" ]; then
        test_fail "Scenario 16" "Tool binary missing on disk after DB rollback"
        return
    fi
    local cur_content
    cur_content="$(cat "$root/usr/bin/db-tool")"
    if [ "$cur_content" != "v1 tool content" ]; then
        test_fail "Scenario 16" "Tool binary was not rolled back to v1 (got: '$cur_content')"
        return
    fi

    # 6. Assert database state restored from journal snapshot
    local ver_restored
    ver_restored="$(cat "$root/var/lib/spm/installed/pkg-db-fail/version" 2>/dev/null || true)"
    if [ "$ver_restored" != "1.0.0-1" ]; then
        test_fail "Scenario 16" "DB version mismatch after rollback (expected 1.0.0-1, got: '$ver_restored')"
        return
    fi

    if [ ! -f "$root/var/lib/spm/installed/pkg-db-fail/package" ]; then
        test_fail "Scenario 16" "DB installed package metadata missing after rollback"
        return
    fi
    if ! grep -q "^pkg-db-fail$" "$root/var/lib/spm/world" 2>/dev/null; then
        test_fail "Scenario 16" "Package missing from DB world after rollback"
        return
    fi
    if ! grep -q "pkg-db-fail" "$root/var/lib/spm/providers" 2>/dev/null; then
        test_fail "Scenario 16" "Package missing from DB providers after rollback"
        return
    fi

    test_pass "Scenario 16: Unified DB rollback (DB commit failure rolls back filesystem and restores DB snapshot)"
}

# -----------------------------------------------------------------------------
# Scenario 17: Destination symlink escape rejection
# -----------------------------------------------------------------------------
test_destination_symlink_escape_rejection() {
    local tdir="$TEST_TMP/scenario17"
    local root="$tdir/root"
    local outside="$tdir/outside_target"
    local pkg="$tdir/pkg-dest-symlink-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root" "$outside"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Create symlinked directory in target pointing outside target root
    ln -s "$outside" "$root/escaped_dir"

    # Package attempts to write a file into escaped_dir
    python_pkg_helper create_valid "$pkg" "pkg-dest-symlink" "1.0.0" "false" "Dest symlink test" \
        "escaped_dir/compromised.txt:outside payload"

    local exit_code=0
    "$SPM_BIN" install "$pkg" --root "$root" >/dev/null 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 17" "Expected exit code 1 for destination symlink escape, got $exit_code"
        return
    fi

    # Assert no file was written to outside directory or target root
    if [ -f "$outside/compromised.txt" ]; then
        test_fail "Scenario 17" "File was written outside target root through destination symlink!"
        return
    fi
    if [ -f "$root/escaped_dir/compromised.txt" ]; then
        test_fail "Scenario 17" "File exists inside escaped destination!"
        return
    fi

    # Assert DB is clean
    if [ -d "$root/var/lib/spm/installed/pkg-dest-symlink" ]; then
        test_fail "Scenario 17" "DB record created despite destination symlink rejection"
        return
    fi

    test_pass "Scenario 17: Destination symlink escape rejection (symlinked destination parent rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 18: Fail-closed checksum verification
# -----------------------------------------------------------------------------
test_fail_closed_checksum() {
    local tdir="$TEST_TMP/scenario18"
    local root="$tdir/root"
    local pkg_no_sha="$tdir/pkg-no-sha-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_bad_sha="$tdir/pkg-bad-sha-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_missing_sha="$tdir/pkg-missing-sha-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_ghost_sha="$tdir/pkg-ghost-sha-1.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # 1. Missing .META/sha256 manifest
    python_pkg_helper create_missing_sha "$pkg_no_sha" "pkg-no-sha" "usr/bin/tool:payload"
    local exit_no_sha=0
    "$SPM_BIN" install "$pkg_no_sha" --root "$root" >/dev/null 2>&1 || exit_no_sha=$?
    if [ "$exit_no_sha" -ne 1 ]; then
        test_fail "Scenario 18" "Expected exit code 1 for missing .META/sha256, got $exit_no_sha"
        return
    fi

    # 2. Malformed hash (32-char MD5 instead of 64-char SHA-256)
    python_pkg_helper create_malformed_sha "$pkg_bad_sha" "pkg-bad-sha" \
        "d41d8cd98f00b204e9800998ecf8427e  usr/bin/tool" "usr/bin/tool:payload"
    local exit_bad_sha=0
    "$SPM_BIN" install "$pkg_bad_sha" --root "$root" >/dev/null 2>&1 || exit_bad_sha=$?
    if [ "$exit_bad_sha" -ne 1 ]; then
        test_fail "Scenario 18" "Expected exit code 1 for malformed hash in .META/sha256, got $exit_bad_sha"
        return
    fi

    # 3. Missing file checksum (payload has 2 regular files, sha256 only has 1)
    python_pkg_helper create_missing_file_sha "$pkg_missing_sha" "pkg-missing-sha" \
        "usr/bin/tool1" "data1" "usr/bin/tool2" "data2"
    local exit_missing_sha=0
    "$SPM_BIN" install "$pkg_missing_sha" --root "$root" >/dev/null 2>&1 || exit_missing_sha=$?
    if [ "$exit_missing_sha" -ne 1 ]; then
        test_fail "Scenario 18" "Expected exit code 1 for payload file missing from .META/sha256, got $exit_missing_sha"
        return
    fi

    # 4. Ghost checksum in .META/sha256 (checksum entry with no corresponding payload file)
    python_pkg_helper create_ghost_sha "$pkg_ghost_sha" "pkg-ghost-sha" "usr/bin/nonexistent" "usr/bin/tool:data"
    local exit_ghost_sha=0
    "$SPM_BIN" install "$pkg_ghost_sha" --root "$root" >/dev/null 2>&1 || exit_ghost_sha=$?
    if [ "$exit_ghost_sha" -ne 1 ]; then
        test_fail "Scenario 18" "Expected exit code 1 for ghost checksum in .META/sha256, got $exit_ghost_sha"
        return
    fi

    # Assert zero residue
    if [ -d "$root/var/lib/spm/installed/pkg-no-sha" ] || [ -d "$root/var/lib/spm/installed/pkg-bad-sha" ] || \
       [ -d "$root/var/lib/spm/installed/pkg-missing-sha" ] || [ -d "$root/var/lib/spm/installed/pkg-ghost-sha" ]; then
        test_fail "Scenario 18" "DB installed records created despite checksum failures"
        return
    fi

    test_pass "Scenario 18: Fail-closed checksum (missing manifest, malformed hash, missing file, and ghost checksum rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 19: Package upgrade obsolete file pruning
# -----------------------------------------------------------------------------
test_package_upgrade_obsolete_file_pruning() {
    local tdir="$TEST_TMP/scenario19"
    local root="$tdir/root"
    local pkg_v1="$tdir/pkg-upgrade-test-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_v2="$tdir/pkg-upgrade-test-2.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    # 1. Package v1 provides file A, file B, and a nested data file
    python_pkg_helper create_valid "$pkg_v1" "pkg-upgrade-test" "1.0.0" "false" "Upgrade pruning test v1" \
        "usr/bin/tool-a:tool a v1" \
        "usr/bin/tool-b:tool b v1" \
        "usr/share/pkg-upgrade-test/nested/data.txt:nested data v1"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Install v1
    if ! "$SPM_BIN" install "$pkg_v1" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 19" "Initial installation of v1 failed"
        return
    fi

    # Verify initial files exist
    [ -f "$root/usr/bin/tool-a" ] || { test_fail "Scenario 19" "v1 tool-a missing"; return; }
    [ -f "$root/usr/bin/tool-b" ] || { test_fail "Scenario 19" "v1 tool-b missing"; return; }
    [ -f "$root/usr/share/pkg-upgrade-test/nested/data.txt" ] || { test_fail "Scenario 19" "v1 data.txt missing"; return; }

    # 2. Package v2 provides file B only (file A and nested data file are obsolete)
    python_pkg_helper create_valid "$pkg_v2" "pkg-upgrade-test" "2.0.0" "false" "Upgrade pruning test v2" \
        "usr/bin/tool-b:tool b v2 updated"

    # Install v2 (upgrade)
    if ! "$SPM_BIN" install "$pkg_v2" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 19" "Upgrade installation of v2 failed"
        return
    fi

    # 3. Assert file B is updated
    local b_content
    b_content="$(cat "$root/usr/bin/tool-b")"
    if [ "$b_content" != "tool b v2 updated" ]; then
        test_fail "Scenario 19" "File B was not updated (got: '$b_content')"
        return
    fi

    # 4. Assert file A is pruned from disk
    if [ -f "$root/usr/bin/tool-a" ]; then
        test_fail "Scenario 19" "Obsolete file usr/bin/tool-a was not pruned from disk!"
        return
    fi

    # 5. Assert obsolete nested file and empty directories pruned bottom-up
    if [ -f "$root/usr/share/pkg-upgrade-test/nested/data.txt" ]; then
        test_fail "Scenario 19" "Obsolete file data.txt was not pruned from disk!"
        return
    fi
    if [ -d "$root/usr/share/pkg-upgrade-test/nested" ] || [ -d "$root/usr/share/pkg-upgrade-test" ]; then
        test_fail "Scenario 19" "Empty obsolete directories were not pruned bottom-up!"
        return
    fi

    # 6. Assert shared directory /usr/bin preserved
    if [ ! -d "$root/usr/bin" ]; then
        test_fail "Scenario 19" "Shared directory /usr/bin was damaged during obsolete pruning!"
        return
    fi

    # 7. Assert providers index is consistent
    if grep -q "tool-a" "$root/var/lib/spm/providers" 2>/dev/null; then
        test_fail "Scenario 19" "Obsolete tool-a still present in providers index"
        return
    fi
    if grep -q "data.txt" "$root/var/lib/spm/providers" 2>/dev/null; then
        test_fail "Scenario 19" "Obsolete data.txt still present in providers index"
        return
    fi
    local tab
    tab="$(printf '\t')"
    if ! grep -q "/usr/bin/tool-b${tab}pkg-upgrade-test" "$root/var/lib/spm/providers" 2>/dev/null; then
        test_fail "Scenario 19" "Updated tool-b missing from providers index"
        return
    fi

    # 8. Assert DB metadata consistent
    local ver_installed
    ver_installed="$(cat "$root/var/lib/spm/installed/pkg-upgrade-test/version" 2>/dev/null || true)"
    if [ "$ver_installed" != "2.0.0-1" ]; then
        test_fail "Scenario 19" "DB version record mismatch (expected 2.0.0-1, got: '$ver_installed')"
        return
    fi

    if grep -q "/usr/bin/tool-a" "$root/var/lib/spm/installed/pkg-upgrade-test/files.list" 2>/dev/null; then
        test_fail "Scenario 19" "Obsolete tool-a still recorded in DB files.list"
        return
    fi
    if ! grep -q "/usr/bin/tool-b" "$root/var/lib/spm/installed/pkg-upgrade-test/files.list" 2>/dev/null; then
        test_fail "Scenario 19" "Updated tool-b missing from DB files.list"
        return
    fi

    if ! grep -q "^pkg-upgrade-test$" "$root/var/lib/spm/world" 2>/dev/null; then
        test_fail "Scenario 19" "Package missing from DB world after upgrade"
        return
    fi

    test_pass "Scenario 19: Package upgrade obsolete file pruning (obsolete files pruned from disk and providers, updated files committed, DB consistent)"
}

# -----------------------------------------------------------------------------
# Scenario 20: Package upgrade rdeps pruning
# -----------------------------------------------------------------------------
test_package_upgrade_rdeps_pruning() {
    local tdir="$TEST_TMP/scenario20"
    local root="$tdir/root"
    local pkg_dep_a="$tdir/pkg-dep-a-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_dep_b="$tdir/pkg-dep-b-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_dep_c="$tdir/pkg-dep-c-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_app_v1="$tdir/pkg-app-1.0.0-1-x86_64.spm.tar.xz"
    local pkg_app_v2="$tdir/pkg-app-2.0.0-1-x86_64.spm.tar.xz"
    local pkg_app_v3="$tdir/pkg-app-3.0.0-1-x86_64.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # 1. Create two dependency packages: pkg-dep-a and pkg-dep-b
    python_pkg_helper create_valid "$pkg_dep_a" "pkg-dep-a" "1.0.0" "false" "Dependency A" \
        "usr/lib/libdepa.so:dep a library content"
    python_pkg_helper create_valid "$pkg_dep_b" "pkg-dep-b" "1.0.0" "false" "Dependency B" \
        "usr/lib/libdepb.so:dep b library content"

    # 2. Create pkg-app v1 declaring dependencies on both pkg-dep-a and pkg-dep-b
    local initial_deps
    initial_deps="$(printf "pkg-dep-a\npkg-dep-b")"
    python_pkg_helper create_with_deps "$pkg_app_v1" "pkg-app" "1.0.0" "$initial_deps" \
        "usr/bin/app-bin:app binary v1"

    # 3. Install initial dependency packages and dependent package v1
    if ! "$SPM_BIN" install "$pkg_dep_a" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 20" "Failed to install pkg-dep-a"
        return
    fi
    if ! "$SPM_BIN" install "$pkg_dep_b" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 20" "Failed to install pkg-dep-b"
        return
    fi
    if ! "$SPM_BIN" install "$pkg_app_v1" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 20" "Failed to install pkg-app v1"
        return
    fi

    # 4. Verify initial reverse dependencies index records pkg-app for both dependencies
    if [ ! -f "$root/var/lib/spm/rdeps/pkg-dep-a" ] || ! grep -q "pkg-app" "$root/var/lib/spm/rdeps/pkg-dep-a"; then
        test_fail "Scenario 20" "pkg-app not recorded in rdeps for pkg-dep-a"
        return
    fi
    if [ ! -f "$root/var/lib/spm/rdeps/pkg-dep-b" ] || ! grep -q "pkg-app" "$root/var/lib/spm/rdeps/pkg-dep-b"; then
        test_fail "Scenario 20" "pkg-app not recorded in rdeps for pkg-dep-b"
        return
    fi

    # 5. Verify removal of pkg-dep-a is initially blocked by reverse dependency guard
    local initial_remove_exit=0
    "$SPM_BIN" remove "pkg-dep-a" --root "$root" >/dev/null 2>&1 || initial_remove_exit=$?
    if [ "$initial_remove_exit" -ne 1 ]; then
        test_fail "Scenario 20" "Expected exit code 1 when removing pkg-dep-a before upgrade, got $initial_remove_exit"
        return
    fi

    # 6. Create pkg-app v2 declaring dependency ONLY on pkg-dep-b (dropping pkg-dep-a)
    python_pkg_helper create_with_deps "$pkg_app_v2" "pkg-app" "2.0.0" "pkg-dep-b" \
        "usr/bin/app-bin:app binary v2 updated"

    # 7. Upgrade pkg-app to v2
    if ! "$SPM_BIN" install "$pkg_app_v2" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 20" "Upgrade of pkg-app to v2 failed"
        return
    fi

    # 8. Assert binary updated and version upgraded
    local app_content
    app_content="$(cat "$root/usr/bin/app-bin" 2>/dev/null || true)"
    if [ "$app_content" != "app binary v2 updated" ]; then
        test_fail "Scenario 20" "App binary was not updated after upgrade (got: '$app_content')"
        return
    fi
    local ver_installed
    ver_installed="$(cat "$root/var/lib/spm/installed/pkg-app/version" 2>/dev/null || true)"
    if [ "$ver_installed" != "2.0.0-1" ]; then
        test_fail "Scenario 20" "DB version mismatch (expected 2.0.0-1, got: '$ver_installed')"
        return
    fi

    # 9. Assert dropped dependency pkg-dep-a was pruned from rdeps
    if [ -f "$root/var/lib/spm/rdeps/pkg-dep-a" ] && grep -q "pkg-app" "$root/var/lib/spm/rdeps/pkg-dep-a"; then
        test_fail "Scenario 20" "Stale reverse dependency record for pkg-dep-a was not pruned!"
        return
    fi

    # 10. Assert retained dependency pkg-dep-b is still tracked in rdeps
    if [ ! -f "$root/var/lib/spm/rdeps/pkg-dep-b" ] || ! grep -q "pkg-app" "$root/var/lib/spm/rdeps/pkg-dep-b"; then
        test_fail "Scenario 20" "Retained dependency pkg-dep-b was incorrectly removed from rdeps!"
        return
    fi

    # 11. Assert dropped dependency pkg-dep-a can now be safely uninstalled without blocking
    if ! "$SPM_BIN" remove "pkg-dep-a" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 20" "Failed to safely remove dropped dependency pkg-dep-a after upgrade"
        return
    fi
    if [ -f "$root/usr/lib/libdepa.so" ]; then
        test_fail "Scenario 20" "Dropped dependency file still present on disk after removal"
        return
    fi
    if [ -d "$root/var/lib/spm/installed/pkg-dep-a" ]; then
        test_fail "Scenario 20" "Dropped dependency still recorded in DB installed/"
        return
    fi

    # 12. Assert retained dependency pkg-dep-b is STILL blocked from removal
    local block_b_exit=0
    "$SPM_BIN" remove "pkg-dep-b" --root "$root" >/dev/null 2>&1 || block_b_exit=$?
    if [ "$block_b_exit" -ne 1 ]; then
        test_fail "Scenario 20" "Expected exit code 1 when removing active dependency pkg-dep-b, got $block_b_exit"
        return
    fi

    # 13. Verify transactional rollback of rdeps:
    # Install pkg-dep-c first
    python_pkg_helper create_valid "$pkg_dep_c" "pkg-dep-c" "1.0.0" "false" "Dependency C" \
        "usr/lib/libdepc.so:dep c library content"
    if ! "$SPM_BIN" install "$pkg_dep_c" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 20" "Failed to install pkg-dep-c"
        return
    fi

    # Build v3 package that drops pkg-dep-b and depends on pkg-dep-c
    python_pkg_helper create_with_deps "$pkg_app_v3" "pkg-app" "3.0.0" "pkg-dep-c" \
        "usr/bin/app-bin:app binary v3"

    # Force Step 6 DB commit failure by replacing rdeps/pkg-dep-c with a directory
    rm -f "$root/var/lib/spm/rdeps/pkg-dep-c"
    mkdir -p "$root/var/lib/spm/rdeps/pkg-dep-c"

    local upgrade_fail_exit=0
    "$SPM_BIN" install "$pkg_app_v3" --root "$root" >/dev/null 2>&1 || upgrade_fail_exit=$?

    if [ "$upgrade_fail_exit" -ne 1 ]; then
        test_fail "Scenario 20" "Expected exit code 1 for forced upgrade failure, got $upgrade_fail_exit"
        return
    fi

    # After rollback, pkg-dep-b rdeps must be fully restored
    if [ ! -f "$root/var/lib/spm/rdeps/pkg-dep-b" ] || ! grep -q "pkg-app" "$root/var/lib/spm/rdeps/pkg-dep-b"; then
        test_fail "Scenario 20" "Transactional rollback failed to restore rdeps for pkg-dep-b"
        return
    fi

    # pkg-app must still be at version 2.0.0-1
    local rollback_ver
    rollback_ver="$(cat "$root/var/lib/spm/installed/pkg-app/version" 2>/dev/null || true)"
    if [ "$rollback_ver" != "2.0.0-1" ]; then
        test_fail "Scenario 20" "DB version mismatch after rollback (expected 2.0.0-1, got: '$rollback_ver')"
        return
    fi

    # And removal of pkg-dep-b must STILL be blocked
    local block_b_post_rollback=0
    "$SPM_BIN" remove "pkg-dep-b" --root "$root" >/dev/null 2>&1 || block_b_post_rollback=$?
    if [ "$block_b_post_rollback" -ne 1 ]; then
        test_fail "Scenario 20" "Expected exit code 1 when removing pkg-dep-b after upgrade rollback, got $block_b_post_rollback"
        return
    fi

    test_pass "Scenario 20: Package upgrade rdeps pruning (dropped dependencies pruned and safely uninstalled, retained dependencies protected, rollback restored)"
}

# -----------------------------------------------------------------------------
# Scenario 21: Base package removal protection & atomic replacement
# -----------------------------------------------------------------------------
test_base_package_protection_and_atomic_replacement() {
    local tdir="$TEST_TMP/scenario21"
    local root="$tdir/root"
    mkdir -p "$tdir" "$root"

    local base_pkg_v1="$tdir/base-sys-1.0.0-1-x86_64.spm.tar.xz"
    local base_pkg_v2="$tdir/base-sys-1.0.1-1-x86_64.spm.tar.xz"

    python_pkg_helper create_valid "$base_pkg_v1" "base-sys" "1.0.0" "true" "Base system package" \
        "bin/sysinit:v1 binary" "etc/sys.conf:config v1"
    python_pkg_helper create_valid "$base_pkg_v2" "base-sys" "1.0.1" "true" "Base system package" \
        "bin/sysinit:v2 binary" "etc/sys.conf:config v2"

    # 1. Install base package v1
    if ! "$SPM_BIN" install "$base_pkg_v1" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 21" "Failed to install base package v1"
        return
    fi

    # 2. Attempt spm remove without --force -> must fail with exit code 1
    local rem_out
    rem_out="$("$SPM_BIN" remove "base-sys" --root "$root" 2>&1 || true)"
    if "$SPM_BIN" remove "base-sys" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 21" "spm remove succeeded on base=true package without --force"
        return
    fi

    if ! echo "$rem_out" | grep -qiE "base.*force|Cannot remove base"; then
        test_fail "Scenario 21" "spm remove output did not mention base package protection / --force: '$rem_out'"
        return
    fi

    # Verify files still intact after rejected removal
    if [ ! -f "$root/bin/sysinit" ]; then
        test_fail "Scenario 21" "File /bin/sysinit missing after rejected base package removal"
        return
    fi

    # 3. Upgrade to v2: verify atomic replacement
    if ! "$SPM_BIN" install "$base_pkg_v2" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 21" "Failed to upgrade base package to v2"
        return
    fi

    if [ "$(cat "$root/bin/sysinit" 2>/dev/null || true)" != "v2 binary" ]; then
        test_fail "Scenario 21" "Atomic replacement failed to update /bin/sysinit to v2"
        return
    fi

    # 4. Remove with --force -> must succeed
    if ! "$SPM_BIN" remove "base-sys" --force --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 21" "spm remove --force failed on base=true package"
        return
    fi

    if [ -e "$root/bin/sysinit" ]; then
        test_fail "Scenario 21" "/bin/sysinit still present after spm remove --force"
        return
    fi

    test_pass "Scenario 21: Base package removal protection & atomic replacement (removal blocked without --force, atomic upgrade verified, removal permitted with --force)"
}

# -----------------------------------------------------------------------------
# Scenario 22: Hardlink rejection
# -----------------------------------------------------------------------------
test_hardlink_rejection() {
    local tdir="$TEST_TMP/scenario22_hardlink"
    local root="$tdir/root"
    local pkg="$tdir/hardlink-pkg-1.0.0.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    python_pkg_helper create_hardlink "$pkg" "hardlink-pkg" "./x/usr/bin/tool-link" "./x/usr/bin/tool"

    local exit_code=0
    local err_out=""
    err_out="$("$SPM_BIN" install "$pkg" --root "$root" 2>&1)" || exit_code=$?

    if [ "$exit_code" -ne 1 ]; then
        test_fail "Scenario 22" "Expected exit code 1 for archive containing hardlink, got $exit_code"
        return
    fi

    if ! echo "$err_out" | grep -qi "hard link"; then
        test_fail "Scenario 22" "Error message did not mention forbidden hard link: '$err_out'"
        return
    fi

    if [ -d "$root/var/lib/spm/installed/hardlink-pkg" ]; then
        test_fail "Scenario 22" "Package record created in DB despite hardlink rejection"
        return
    fi

    if [ -e "$root/usr/bin/tool-link" ] || [ -e "$root/usr/bin/tool" ]; then
        test_fail "Scenario 22" "Files installed to disk despite hardlink rejection"
        return
    fi

    test_pass "Scenario 22: Hardlink rejection (archive containing hard link member rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 23: Setuid/setgid rejection
# -----------------------------------------------------------------------------
test_setuid_setgid_rejection() {
    local tdir="$TEST_TMP/scenario23_suid"
    local root="$tdir/root"
    local pkg_suid="$tdir/suid-pkg-1.0.0.spm.tar.xz"
    local pkg_sgid="$tdir/sgid-pkg-1.0.0.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Part A: Setuid file mode 04755
    python_pkg_helper create_suid "$pkg_suid" "suid-pkg" "./x/usr/bin/suid-tool" "4755"
    local exit_suid=0
    local err_suid=""
    err_suid="$("$SPM_BIN" install "$pkg_suid" --root "$root" 2>&1)" || exit_suid=$?

    if [ "$exit_suid" -ne 1 ]; then
        test_fail "Scenario 23" "Expected exit code 1 for archive containing setuid file, got $exit_suid"
        return
    fi

    if ! echo "$err_suid" | grep -qi "setuid/setgid"; then
        test_fail "Scenario 23" "Error message did not mention forbidden setuid/setgid: '$err_suid'"
        return
    fi

    # Part B: Setgid file mode 02755
    python_pkg_helper create_suid "$pkg_sgid" "sgid-pkg" "./x/usr/bin/sgid-tool" "2755"
    local exit_sgid=0
    local err_sgid=""
    err_sgid="$("$SPM_BIN" install "$pkg_sgid" --root "$root" 2>&1)" || exit_sgid=$?

    if [ "$exit_sgid" -ne 1 ]; then
        test_fail "Scenario 23" "Expected exit code 1 for archive containing setgid file, got $exit_sgid"
        return
    fi

    if ! echo "$err_sgid" | grep -qi "setuid/setgid"; then
        test_fail "Scenario 23" "Error message did not mention forbidden setuid/setgid: '$err_sgid'"
        return
    fi

    # Verify no records or files created
    if [ -d "$root/var/lib/spm/installed/suid-pkg" ] || [ -d "$root/var/lib/spm/installed/sgid-pkg" ]; then
        test_fail "Scenario 23" "Package record created in DB despite setuid/setgid rejection"
        return
    fi
    if [ -e "$root/usr/bin/suid-tool" ] || [ -e "$root/usr/bin/sgid-tool" ]; then
        test_fail "Scenario 23" "Setuid/setgid files installed to disk despite rejection"
        return
    fi

    test_pass "Scenario 23: Setuid/setgid rejection (pre-extraction inspection and post-extraction audit reject setuid/setgid with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 24: Duplicate member rejection
# -----------------------------------------------------------------------------
test_duplicate_member_rejection() {
    local tdir="$TEST_TMP/scenario24_dup"
    local root="$tdir/root"
    local pkg_dup_tar="$tdir/dup-tar-1.0.0.spm.tar.xz"
    local pkg_dup_meta="$tdir/dup-meta-1.0.0.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Part A: Duplicate member in tar archive
    python_pkg_helper create_duplicate_member "$pkg_dup_tar" "dup-tar-pkg" "usr/bin/dup-tool"
    local exit_dup_tar=0
    local err_dup_tar=""
    err_dup_tar="$("$SPM_BIN" install "$pkg_dup_tar" --root "$root" 2>&1)" || exit_dup_tar=$?

    if [ "$exit_dup_tar" -ne 1 ]; then
        test_fail "Scenario 24" "Expected exit code 1 for duplicate tar archive member, got $exit_dup_tar"
        return
    fi

    if ! echo "$err_dup_tar" | grep -qi "duplicate member path"; then
        test_fail "Scenario 24" "Error message did not mention duplicate member path: '$err_dup_tar'"
        return
    fi

    # Part B: Duplicate entry in .META/files manifest
    python_pkg_helper create_duplicate_manifest "$pkg_dup_meta" "dup-meta-pkg"
    local exit_dup_meta=0
    local err_dup_meta=""
    err_dup_meta="$("$SPM_BIN" install "$pkg_dup_meta" --root "$root" 2>&1)" || exit_dup_meta=$?

    if [ "$exit_dup_meta" -ne 1 ]; then
        test_fail "Scenario 24" "Expected exit code 1 for duplicate .META/files entry, got $exit_dup_meta"
        return
    fi

    if ! echo "$err_dup_meta" | grep -qiE "duplicate entry|duplicate member"; then
        test_fail "Scenario 24" "Error message did not mention duplicate entry: '$err_dup_meta'"
        return
    fi

    test_pass "Scenario 24: Duplicate member rejection (duplicate archive member and duplicate .META/files rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 25: Invalid dependency name rejection
# -----------------------------------------------------------------------------
test_invalid_dependency_name_rejection() {
    local tdir="$TEST_TMP/scenario25_deps"
    local root="$tdir/root"
    local pkg_dep_slash="$tdir/dep-slash-1.0.0.spm.tar.xz"
    local pkg_dep_space="$tdir/dep-space-1.0.0.spm.tar.xz"
    local pkg_dep_spec="$tdir/dep-spec-1.0.0.spm.tar.xz"
    local pkg_mani_slash="$tdir/mani-slash-1.0.0.spm.tar.xz"
    local pkg_mani_space="$tdir/mani-space-1.0.0.spm.tar.xz"
    mkdir -p "$root"

    "$SPM_BIN" init --root "$root" >/dev/null 2>&1

    # Part A: .META/depends with slash
    python_pkg_helper create_invalid_dep "$pkg_dep_slash" "dep-slash-pkg" "meta" "invalid/dep"
    local exit_a=0
    local err_a=""
    err_a="$("$SPM_BIN" install "$pkg_dep_slash" --root "$root" 2>&1)" || exit_a=$?
    if [ "$exit_a" -ne 1 ] || ! echo "$err_a" | grep -q "Invalid dependency name 'invalid/dep'"; then
        test_fail "Scenario 25" "Expected exit 1 and 'Invalid dependency name' for slash in .META/depends (got exit $exit_a, msg: '$err_a')"
        return
    fi

    # Part B: .META/depends with space
    python_pkg_helper create_invalid_dep "$pkg_dep_space" "dep-space-pkg" "meta" "invalid dep"
    local exit_b=0
    local err_b=""
    err_b="$("$SPM_BIN" install "$pkg_dep_space" --root "$root" 2>&1)" || exit_b=$?
    if [ "$exit_b" -ne 1 ] || ! echo "$err_b" | grep -q "Invalid dependency name 'invalid dep'"; then
        test_fail "Scenario 25" "Expected exit 1 and 'Invalid dependency name' for space in .META/depends (got exit $exit_b, msg: '$err_b')"
        return
    fi

    # Part C: .META/depends with special characters
    python_pkg_helper create_invalid_dep "$pkg_dep_spec" "dep-spec-pkg" "meta" "dep\$evil"
    local exit_c=0
    local err_c=""
    err_c="$("$SPM_BIN" install "$pkg_dep_spec" --root "$root" 2>&1)" || exit_c=$?
    if [ "$exit_c" -ne 1 ] || ! echo "$err_c" | grep -q "Invalid dependency name 'dep\$evil'"; then
        test_fail "Scenario 25" "Expected exit 1 and 'Invalid dependency name' for special char in .META/depends (got exit $exit_c, msg: '$err_c')"
        return
    fi

    # Part D: manifest dependencies= with slash
    python_pkg_helper create_invalid_dep "$pkg_mani_slash" "mani-slash-pkg" "manifest" "bad/pkg"
    local exit_d=0
    local err_d=""
    err_d="$("$SPM_BIN" install "$pkg_mani_slash" --root "$root" 2>&1)" || exit_d=$?
    if [ "$exit_d" -ne 1 ] || ! echo "$err_d" | grep -q "Invalid dependency name 'bad/pkg'"; then
        test_fail "Scenario 25" "Expected exit 1 and 'Invalid dependency name' for slash in manifest (got exit $exit_d, msg: '$err_d')"
        return
    fi

    # Part E: manifest dependencies= with space
    python_pkg_helper create_invalid_dep "$pkg_mani_space" "mani-space-pkg" "manifest" "bad pkg"
    local exit_e=0
    local err_e=""
    err_e="$("$SPM_BIN" install "$pkg_mani_space" --root "$root" 2>&1)" || exit_e=$?
    if [ "$exit_e" -ne 1 ] || ! echo "$err_e" | grep -q "Invalid dependency name 'bad pkg'"; then
        test_fail "Scenario 25" "Expected exit 1 and 'Invalid dependency name' for space in manifest (got exit $exit_e, msg: '$err_e')"
        return
    fi

    test_pass "Scenario 25: Invalid dependency name rejection (invalid dependency names in .META/depends and manifest rejected with exit 1)"
}

# -----------------------------------------------------------------------------
# Scenario 26: Power-cut journal recovery simulation
# -----------------------------------------------------------------------------
test_power_cut_journal_recovery() {
    local tdir="$TEST_TMP/scenario26_powercut"
    local root="$tdir/root"
    local pkg_orig="$tdir/pkg-orig-1.0.0.spm.tar.xz"
    mkdir -p "$root"

    # 1. Install an original package cleanly
    python_pkg_helper create_valid "$pkg_orig" "pkg-orig" "1.0.0" "false" "Original Package" \
        "usr/bin/orig-tool:orig binary v1 content"

    if ! "$SPM_BIN" install "$pkg_orig" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 26" "Failed to install initial pkg-orig"
        return
    fi

    # 2. Simulate an interrupted power-cut update:
    # Overwrite the target file with incomplete/corrupted content
    echo "corrupted powercut content" > "$root/usr/bin/orig-tool"
    # Create an uncommitted newly created file that was partially staged to disk
    mkdir -p "$root/usr/bin"
    echo "uncommitted leaked tool" > "$root/usr/bin/new-staged-tool"

    # Create the interrupted transaction staging directory with .journal
    local staging_tx="$root/var/lib/spm/staging/tx-pkg-orig-9999"
    mkdir -p "$staging_tx/.journal/backup/usr/bin"
    echo "orig binary v1 content" > "$staging_tx/.journal/backup/usr/bin/orig-tool"

    # Record created file
    printf '%s/usr/bin/new-staged-tool\n' "$root" > "$staging_tx/.journal/created"

    # Create .META/package in staging
    mkdir -p "$staging_tx/.META"
    cat > "$staging_tx/.META/package" <<EOF
name=pkg-orig
version=2.0.0
release=1
arch=x86_64
description=Updated Package
base=false
EOF
    cat > "$staging_tx/.META/files" <<EOF
usr/
usr/bin/
usr/bin/orig-tool
usr/bin/new-staged-tool
EOF

    # Snapshot of installed_pkg
    cp -a "$root/var/lib/spm/installed/pkg-orig" "$staging_tx/.journal/installed_pkg"
    touch "$staging_tx/.journal/had_installed_pkg"

    # Corrupt or alter DB installed record to simulate mid-transaction failure
    echo "2.0.0-1" > "$root/var/lib/spm/installed/pkg-orig/version"

    # 3. Invoke any spm command that acquires the lock (e.g. spm init or list or install)
    local rec_out=""
    rec_out="$("$SPM_BIN" init --root "$root" 2>&1)"

    if ! echo "$rec_out" | grep -qi "Interrupted transaction recovered: rolled back pkg-orig"; then
        test_fail "Scenario 26" "Output did not report journal recovery: '$rec_out'"
        return
    fi

    # 4. Assert disk state rolled back:
    # - /usr/bin/orig-tool restored to original content
    if [ ! -f "$root/usr/bin/orig-tool" ]; then
        test_fail "Scenario 26" "/usr/bin/orig-tool missing after recovery"
        return
    fi
    local restored_content
    restored_content="$(cat "$root/usr/bin/orig-tool")"
    if [ "$restored_content" != "orig binary v1 content" ]; then
        test_fail "Scenario 26" "orig-tool content was not restored (got: '$restored_content')"
        return
    fi

    # - /usr/bin/new-staged-tool was pruned
    if [ -e "$root/usr/bin/new-staged-tool" ]; then
        test_fail "Scenario 26" "Uncommitted file /usr/bin/new-staged-tool still present on disk"
        return
    fi

    # - Staging directory was cleaned
    if [ -d "$staging_tx" ]; then
        test_fail "Scenario 26" "Staging transaction directory was not cleaned up after recovery"
        return
    fi

    # - DB version was restored to 1.0.0-1
    local db_ver
    db_ver="$(cat "$root/var/lib/spm/installed/pkg-orig/version" 2>/dev/null || true)"
    if [ "$db_ver" != "1.0.0-1" ]; then
        test_fail "Scenario 26" "DB version was not restored to 1.0.0-1 (got: '$db_ver')"
        return
    fi

    test_pass "Scenario 26: Power-cut journal recovery simulation (leftover staging transaction journal rolled back cleanly on startup)"
}

# Rewrite one key=value line inside .META/package of an existing .spm archive.
rewrite_manifest_field() {
    python3 - "$1" "$2" "$3" <<'PY'
import io, sys, tarfile, lzma
path, field, value = sys.argv[1:4]
buf = io.BytesIO()
with lzma.open(path, "rb") as fi, lzma.open(buf, "wb") as fo:
    with tarfile.open(fileobj=fi, mode="r:") as tin, tarfile.open(fileobj=fo, mode="w") as tout:
        for member in tin.getmembers():
            data = tin.extractfile(member).read() if member.isfile() else None
            if data is not None and member.name.endswith("/.META/package"):
                lines = data.decode("utf-8", "replace").splitlines()
                out, replaced = [], False
                for line in lines:
                    if line.startswith(field + "="):
                        out.append(field + "=" + value)
                        replaced = True
                    else:
                        out.append(line)
                if not replaced:
                    out.append(field + "=" + value)
                data = ("\n".join(out) + "\n").encode("utf-8")
            ti = tarfile.TarInfo(member.name)
            ti.type = member.type
            ti.mode = member.mode
            ti.linkname = member.linkname
            ti.size = len(data) if data is not None else 0
            tout.addfile(ti, io.BytesIO(data) if data is not None else None)
with open(path, "wb") as out:
    out.write(buf.getvalue())
PY
}

test_invalid_metadata_rejection() {
    local tdir="$TEST_TMP/scenario27_invalid_meta"
    local root="$tdir/root"
    mkdir -p "$root"

    local cases
    cases="name:Invalid_Name arch:armv7 base:yes"
    for case in $cases; do
        local field="${case%%:*}"
        local value="${case#*:}"
        local archive="$tdir/bad-$field.spm.tar.xz"
        python_pkg_helper create_valid "$archive" "meta-probe" "1.0.0" "false" \
            "Metadata probe" "usr/bin/tool:echo tool"
        rewrite_manifest_field "$archive" "$field" "$value"

        if "$SPM_BIN" install "$archive" --root "$root" >/dev/null 2>&1; then
            test_fail "Scenario 27" "Invalid $field='$value' was accepted"
            return
        fi
        if [ -e "$root/usr/bin/tool" ]; then
            test_fail "Scenario 27" "Payload leaked to disk after invalid $field"
            return
        fi
        if [ -n "$(ls -A "$root/var/lib/spm/installed" 2>/dev/null || true)" ]; then
            test_fail "Scenario 27" "DB residue after invalid $field"
            return
        fi
    done
    test_pass "Scenario 27: Invalid metadata (name/arch/base) rejected with zero filesystem residue"
}

test_failed_upgrade_rollback() {
    local tdir="$TEST_TMP/scenario28_upgrade_fail"
    local root="$tdir/root"
    local bin="$tdir/bin"
    mkdir -p "$root" "$bin"

    python_pkg_helper create_valid "$tdir/v1.spm.tar.xz" "upg-test" "1.0.0" "false" \
        "Upgrade test v1" "usr/bin/tool:v1-content"
    "$SPM_BIN" install "$tdir/v1.spm.tar.xz" --root "$root" >/dev/null 2>&1 \
        || { test_fail "Scenario 28" "Initial install failed"; return; }

    python_pkg_helper create_valid "$tdir/v2.spm.tar.xz" "upg-test" "2.0.0" "false" \
        "Upgrade test v2" "usr/bin/tool:v2-content"

    # Fail the first mv -f during commit; pass all later mv calls (rollback needs them).
    cat > "$bin/mv" <<'SHIM'
#!/bin/sh
marker="${SPM_FAIL_MARKER:-}"
if [ "$1" = "-f" ] && [ -n "$marker" ] && [ ! -f "$marker.done" ]; then
    touch "$marker.done"
    echo "injected mv failure" >&2
    exit 1
fi
exec /usr/bin/mv "$@"
SHIM
    chmod +x "$bin/mv"

    if PATH="$bin:$PATH" SPM_FAIL_MARKER="$tdir/fail" \
        "$SPM_BIN" install "$tdir/v2.spm.tar.xz" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 28" "Upgrade unexpectedly succeeded after injected mv failure"
        return
    fi

    local content
    content="$(cat "$root/usr/bin/tool" 2>/dev/null || true)"
    if [ "$content" != "v1-content" ]; then
        test_fail "Scenario 28" "Failed upgrade left payload half-updated: '$content'"
        return
    fi
    local dbver
    dbver="$(cat "$root/var/lib/spm/installed/upg-test/version" 2>/dev/null || true)"
    if [ "$dbver" != "1.0.0-1" ]; then
        test_fail "Scenario 28" "Failed upgrade left DB at '$dbver'"
        return
    fi
    if [ -n "$(ls -A "$root/var/lib/spm/staging" 2>/dev/null || true)" ]; then
        test_fail "Scenario 28" "Staging residue after failed upgrade"
        return
    fi
    test_pass "Scenario 28: Upgrade failing mid-commit rolls back file content, DB version and staging"
}

test_sigkill_interrupted_install_recovery() {
    local tdir="$TEST_TMP/scenario29_sigkill"
    local root="$tdir/root"
    local bin="$tdir/bin"
    mkdir -p "$root" "$bin"

    python_pkg_helper create_valid "$tdir/v1.spm.tar.xz" "kill-test" "1.0.0" "false" \
        "Kill test v1" "usr/bin/tool:v1-content"
    "$SPM_BIN" install "$tdir/v1.spm.tar.xz" --root "$root" >/dev/null 2>&1 \
        || { test_fail "Scenario 29" "Initial install failed"; return; }

    python_pkg_helper create_valid "$tdir/v2.spm.tar.xz" "kill-test" "2.0.0" "false" \
        "Kill test v2" "usr/bin/tool:v2-content"

    cat > "$bin/mv" <<'SHIM'
#!/bin/sh
marker="${SPM_KILL_MARKER:-}"
if [ "$1" = "-f" ] && [ -n "$marker" ] && [ ! -f "$marker.done" ]; then
    touch "$marker.done"
    kill -9 "$PPID" 2>/dev/null || true
    exit 137
fi
exec /usr/bin/mv "$@"
SHIM
    chmod +x "$bin/mv"

    set +e
    ( PATH="$bin:$PATH" SPM_KILL_MARKER="$tdir/kill" \
        "$SPM_BIN" install "$tdir/v2.spm.tar.xz" --root "$root" ) >/dev/null 2>&1
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        test_fail "Scenario 29" "Injected SIGKILL did not interrupt install"
        return
    fi

    local rec_out
    rec_out="$("$SPM_BIN" init --root "$root" 2>&1 || true)"
    if ! echo "$rec_out" | grep -qi "Interrupted transaction recovered"; then
        test_fail "Scenario 29" "No journal recovery after SIGKILL: '$rec_out'"
        return
    fi
    local content
    content="$(cat "$root/usr/bin/tool" 2>/dev/null || true)"
    if [ "$content" != "v1-content" ]; then
        test_fail "Scenario 29" "Recovered file content is '$content', expected v1-content"
        return
    fi
    local dbver
    dbver="$(cat "$root/var/lib/spm/installed/kill-test/version" 2>/dev/null || true)"
    if [ "$dbver" != "1.0.0-1" ]; then
        test_fail "Scenario 29" "Recovered DB version is '$dbver'"
        return
    fi
    if [ -n "$(ls -A "$root/var/lib/spm/staging" 2>/dev/null || true)" ]; then
        test_fail "Scenario 29" "Staging residue after recovery"
        return
    fi
    test_pass "Scenario 29: SIGKILL mid-commit recovered on next command; disk and DB fully restored"
}

test_uninstall_with_shared_file() {
    local tdir="$TEST_TMP/scenario30_shared_uninstall"
    local root="$tdir/root"
    mkdir -p "$root"

    python_pkg_helper create_valid "$tdir/base.spm.tar.xz" "base-shared" "1.0.0" "true" \
        "Base owner" "usr/bin/shared:base-content" "usr/bin/base-only:base-only-content"
    python_pkg_helper create_valid "$tdir/regular.spm.tar.xz" "regular-one" "1.0.0" "false" \
        "Regular owner" "usr/bin/regular:regular-content"
    python_pkg_helper create_valid "$tdir/intruder.spm.tar.xz" "intruder" "1.0.0" "false" \
        "Intruder" "usr/bin/shared:intruder-content"

    "$SPM_BIN" install "$tdir/base.spm.tar.xz" --root "$root" >/dev/null 2>&1 \
        || { test_fail "Scenario 30" "Base install failed"; return; }
    "$SPM_BIN" install "$tdir/regular.spm.tar.xz" --root "$root" >/dev/null 2>&1 \
        || { test_fail "Scenario 30" "Regular install failed"; return; }

    if "$SPM_BIN" install "$tdir/intruder.spm.tar.xz" --root "$root" >/dev/null 2>&1; then
        test_fail "Scenario 30" "Second package was allowed to claim base-owned shared file"
        return
    fi

    "$SPM_BIN" remove regular-one --root "$root" >/dev/null 2>&1 \
        || { test_fail "Scenario 30" "Removing unrelated package failed"; return; }
    local shared
    shared="$(cat "$root/usr/bin/shared" 2>/dev/null || true)"
    if [ "$shared" != "base-content" ]; then
        test_fail "Scenario 30" "Shared file changed after unrelated uninstall: '$shared'"
        return
    fi
    if [ ! -f "$root/usr/bin/base-only" ] || [ -d "$root/var/lib/spm/installed/regular-one" ]; then
        test_fail "Scenario 30" "Base files or DB damaged by unrelated uninstall"
        return
    fi
    test_pass "Scenario 30: Shared-file ownership conflict rejected; uninstall leaves other package files intact"
}

test_concurrent_installs() {
    local tdir="$TEST_TMP/scenario31_concurrent_installs"
    local root="$tdir/root"
    mkdir -p "$root"

    python_pkg_helper create_valid "$tdir/a.spm.tar.xz" "conc-a" "1.0.0" "false" \
        "Concurrent A" "usr/bin/conc-a:a-content"
    python_pkg_helper create_valid "$tdir/b.spm.tar.xz" "conc-b" "1.0.0" "false" \
        "Concurrent B" "usr/bin/conc-b:b-content"

    set +e
    "$SPM_BIN" install "$tdir/a.spm.tar.xz" --root "$root" > "$tdir/a.out" 2>&1 &
    local pid_a=$!
    "$SPM_BIN" install "$tdir/b.spm.tar.xz" --root "$root" > "$tdir/b.out" 2>&1 &
    local pid_b=$!
    wait "$pid_a"
    local rc_a=$?
    wait "$pid_b"
    local rc_b=$?
    set -e

    if [ "$rc_a" -ne 0 ] || [ "$rc_b" -ne 0 ]; then
        test_fail "Scenario 31" "Concurrent installs failed (a=$rc_a b=$rc_b)"
        return
    fi
    if [ "$(cat "$root/usr/bin/conc-a" 2>/dev/null || true)" != "a-content" ] ||
       [ "$(cat "$root/usr/bin/conc-b" 2>/dev/null || true)" != "b-content" ]; then
        test_fail "Scenario 31" "Concurrent install payloads are inconsistent"
        return
    fi
    for pkg in conc-a conc-b; do
        if [ ! -f "$root/var/lib/spm/installed/$pkg/version" ]; then
            test_fail "Scenario 31" "Missing DB record for $pkg after concurrent installs"
            return
        fi
    done
    if ! grep -q '/usr/bin/conc-a' "$root/var/lib/spm/providers" ||
       ! grep -q '/usr/bin/conc-b' "$root/var/lib/spm/providers"; then
        test_fail "Scenario 31" "Providers index incomplete after concurrent installs"
        return
    fi
    test_pass "Scenario 31: Two simultaneous installs serialize through flock; both payloads and DB indexes remain consistent"
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
    test_meta_files_traversal_rejection
    test_meta_files_mismatch_rejection
    test_regular_file_rollback_restoration
    test_unified_db_rollback
    test_destination_symlink_escape_rejection
    test_fail_closed_checksum
    test_package_upgrade_obsolete_file_pruning
    test_package_upgrade_rdeps_pruning
    test_base_package_protection_and_atomic_replacement
    test_hardlink_rejection
    test_setuid_setgid_rejection
    test_duplicate_member_rejection
    test_invalid_dependency_name_rejection
    test_power_cut_journal_recovery
    test_invalid_metadata_rejection
    test_failed_upgrade_rollback
    test_sigkill_interrupted_install_recovery
    test_uninstall_with_shared_file
    test_concurrent_installs

    printf '\n==================================================\n'
    printf 'SPM Test Suite Summary: %d passed, %d failed\n' "$PASSED_COUNT" "$FAILED_COUNT"

    if [ "$FAILED_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"