#!/usr/bin/env python3
"""Regression checks for the CI build gate and cgroup snapshots."""
from __future__ import annotations

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/ci.yml"


def job_block() -> str:
    text = WORKFLOW.read_text()
    start = text.index("  build-and-smoke-test:\n")
    end = text.index("  rootfs-distro:\n", start)
    return text[start:end]


def job_environment() -> dict[str, str]:
    block = job_block()
    env_text = block.split("    env:\n", 1)[1].split("    steps:\n", 1)[0]
    result: dict[str, str] = {}
    for line in env_text.splitlines():
        match = re.match(r"^      ([A-Z_]+):\s*(.+?)\s*$", line)
        if match:
            result[match.group(1)] = shlex.split(match.group(2))[0]
    return result


def named_run_block(name: str) -> str:
    block = job_block()
    step = block.split(f"      - name: {name}\n", 1)[1]
    run = step.split("        run: |\n", 1)[1]
    lines = []
    for line in run.splitlines(keepends=True):
        if line.startswith("          "):
            lines.append(line[10:])
        else:
            break
    return "".join(lines)


def run_workflow_shell(script: str, cwd: Path, env: dict[str, str] | None = None):
    return subprocess.run(
        ["bash", "-e", "-o", "pipefail"],
        input=script,
        text=True,
        cwd=cwd,
        env=env,
        capture_output=True,
    )


def test_static_gate() -> str | None:
    script = named_run_block("Strictly static binary check")
    with tempfile.TemporaryDirectory(prefix="sane-static-gate-") as tmp_name:
        tmp = Path(tmp_name)
        missing = run_workflow_shell(script, tmp)
        if missing.returncode == 0:
            return "static gate returned success without ninit\n" + missing.stdout + missing.stderr

        shutil.copy2(ROOT / "Makefile", tmp / "Makefile")
        shutil.copy2(ROOT / "ninit.c", tmp / "ninit.c")
        env = os.environ.copy()
        env.pop("BIN", None)
        env.update(job_environment())
        build = subprocess.run(["make", "--no-print-directory"], cwd=tmp, env=env,
                               text=True, capture_output=True)
        if build.returncode != 0:
            return "production build failed\n" + build.stdout + build.stderr
        checked = run_workflow_shell(script, tmp, env)
        if checked.returncode != 0:
            return "static gate rejected the real production binary\n" + checked.stdout + checked.stderr
    return None


def test_workflow_builds_and_runs_both_binaries() -> str | None:
    env = os.environ.copy()
    env.pop("BIN", None)
    env.pop("TESTBIN", None)
    env.update(job_environment())
    with tempfile.TemporaryDirectory(prefix="sane-ci-build-") as tmp_name:
        tmp = Path(tmp_name)
        shutil.copy2(ROOT / "Makefile", tmp / "Makefile")
        shutil.copy2(ROOT / "ninit.c", tmp / "ninit.c")
        outputs = []
        for args in (["make", "--no-print-directory"],
                     ["make", "--no-print-directory", "ninit-test"]):
            proc = subprocess.run(args, cwd=tmp, env=env, text=True, capture_output=True)
            outputs.append(f"$ {' '.join(args)}\n{proc.stdout}{proc.stderr}")
            if proc.returncode != 0:
                return "\n".join(outputs)

        production = tmp / "ninit"
        test_binary = tmp / "ninit-test"
        if not production.is_file() or not os.access(production, os.X_OK):
            return "workflow environment did not produce executable ninit\n" + "\n".join(outputs)
        if not test_binary.is_file() or not os.access(test_binary, os.X_OK):
            return "make ninit-test did not produce its separate executable\n" + "\n".join(outputs)
        if b"cgroup: base path overridden" in production.read_bytes():
            return "production binary unexpectedly contains the test-only cgroup override"
        if b"cgroup: base path overridden" not in test_binary.read_bytes():
            return "test binary is missing the -DNINIT_TESTING cgroup override"

        for binary in (production, test_binary):
            proc = subprocess.run([str(binary), "/nonexistent"], text=True, capture_output=True)
            if proc.returncode != 1 or "ninit must be run as PID 1" not in proc.stderr:
                return f"{binary.name} did not execute its non-PID-1 guard safely\n{proc.stdout}{proc.stderr}"
    return None


def test_cgroup_snapshots_allow_no_matches_and_detect_leaks() -> str | None:
    before_script = named_run_block("Record host cgroups before test battery")
    after_script = named_run_block("Verify no lingering /sys/fs/cgroup/ninit* leaks")
    with tempfile.TemporaryDirectory(prefix="sane-ci-cgroups-") as tmp_name:
        tmp = Path(tmp_name)
        fake_cgroups = tmp / "cgroups"
        fake_cgroups.mkdir()
        pattern = str(fake_cgroups / "ninit*")
        before_script = before_script.replace("/sys/fs/cgroup/ninit*", pattern)
        after_script = after_script.replace("/sys/fs/cgroup/ninit*", pattern)

        github_env = tmp / "github-env"
        env = os.environ.copy()
        env["GITHUB_ENV"] = str(github_env)
        before = run_workflow_shell(before_script, tmp, env)
        if before.returncode != 0:
            return "before snapshot failed with no matching cgroups\n" + before.stdout + before.stderr
        recorded = github_env.read_text().splitlines()
        if recorded != ["PRE_CGROUPS="]:
            return f"no-match snapshot recorded unexpected value: {recorded!r}"

        after_env = os.environ.copy()
        after_env["PRE_CGROUPS"] = ""
        clean_after = run_workflow_shell(after_script, tmp, after_env)
        if clean_after.returncode != 0:
            return "after snapshot failed when no cgroups matched\n" + clean_after.stdout + clean_after.stderr

        baseline = fake_cgroups / "ninit-baseline"
        baseline.mkdir()
        github_env.write_text("")
        recorded_before = run_workflow_shell(before_script, tmp, env)
        if recorded_before.returncode != 0:
            return "before snapshot failed with a matching cgroup\n" + recorded_before.stdout + recorded_before.stderr
        expected = f"PRE_CGROUPS={baseline} "
        recorded = github_env.read_text().splitlines()
        if recorded != [expected]:
            return f"matching cgroup snapshot recorded unexpected value: {recorded!r}"

        after_env["PRE_CGROUPS"] = f"{baseline} "
        existing_after = run_workflow_shell(after_script, tmp, after_env)
        if existing_after.returncode != 0:
            return "after snapshot rejected an unchanged cgroup set\n" + existing_after.stdout + existing_after.stderr

        (fake_cgroups / "ninit-leaked").mkdir()
        leaked_after = run_workflow_shell(after_script, tmp, after_env)
        if leaked_after.returncode == 0 or "FAIL: new lingering cgroups detected" not in leaked_after.stderr:
            return "after snapshot did not reject a newly created cgroup\n" + leaked_after.stdout + leaked_after.stderr
    return None


def test_installer_boot_uses_cpu_compatible_qemu_args() -> str | None:
    """The installer boot check must not fall back to QEMU's AVX-less qemu64 CPU."""
    script = (ROOT / "scripts/test-installer.sh").read_text()
    if "ACCEL_ARGS=()" not in script:
        return "test-installer.sh no longer configures ACCEL_ARGS"
    if "-enable-kvm -cpu host" not in script or "-cpu max" not in script:
        return "test-installer.sh is missing a KVM or TCG CPU compatibility branch"
    if '"${ACCEL_ARGS[@]}"' not in script:
        return "test-installer.sh does not pass ACCEL_ARGS to qemu-system-x86_64"
    return None


def test_third_party_licenses() -> str | None:
    notice = ROOT / "THIRD_PARTY_LICENSES.md"
    if not notice.is_file():
        return "THIRD_PARTY_LICENSES.md is missing"
    text = notice.read_text()
    expected = {
        "busybox": "GPL-2.0",
        "linux kernel": "GPL-2.0",
        "libressl": "ISC",
        "curl": "curl",
        "wpa_supplicant": "BSD-3-Clause",
        "musl": "MIT",
        "limine": "BSD-2-Clause",
    }
    for component, license_id in expected.items():
        if component.lower() not in text.lower() or license_id.lower() not in text.lower():
            return f"third-party notice is missing {component} / {license_id}"
    if re.search(r"^\|\s*clawrza", text, re.M | re.I):
        return "maintainer-owned clawrza packages must not be listed as third-party"
    for link in ("THIRD_PARTY_LICENSES.md", "NOTICE"):
        if link not in (ROOT / "README.md").read_text():
            return f"README.md does not link {link}"
    return None


def test_security_scope_and_signing_freeze() -> str | None:
    for name in ("SECURITY.md", "SECURITY.id.md"):
        text = (ROOT / name).read_text().lower()
        for term in ("spm", "installer", "sane-accounts", "sane-net", "snapshot", "rollback"):
            if term not in text:
                return f"{name} does not cover {term}"
        if "frozen" not in text:
            return f"{name} does not record the frozen package-signature item"
    return None


def test_docs_sync() -> str | None:
    doc_readme = (ROOT / "doc/README.md").read_text()
    for command in ("start", "stop", "restart", "status"):
        if command not in doc_readme:
            return f"doc/README.md IPC list is missing {command}"
    for item in ("spm", "sane-install.sh", "sane-firstboot"):
        if item not in doc_readme:
            return f"doc/README.md structure is missing {item}"
    root_readme = (ROOT / "README.md").read_text()
    for item in ("boot-pipeline.md", "package-format.md", "package-manager.md"):
        if item not in root_readme:
            return f"root README documentation index is missing {item}"
    builder = (ROOT / "doc/distro-builder.md").read_text()
    image = (ROOT / "doc/distro-image-builder.md").read_text()
    if "distro-image-builder.md" not in builder or "distro-builder.md" not in image:
        return "builder docs do not cross-link each other"
    return None


def test_community_files() -> str | None:
    required = [
        "CONTRIBUTING.md", "CODE_OF_CONDUCT.md",
        ".github/ISSUE_TEMPLATE/bug_report.md",
        ".github/ISSUE_TEMPLATE/feature_request.md",
        ".github/ISSUE_TEMPLATE/config.yml",
        ".github/PULL_REQUEST_TEMPLATE.md", ".github/CODEOWNERS",
        ".github/dependabot.yml",
    ]
    for name in required:
        if not (ROOT / name).is_file():
            return f"missing community file: {name}"
    dependabot = (ROOT / ".github/dependabot.yml").read_text()
    if "github-actions" not in dependabot:
        return "dependabot.yml has no github-actions ecosystem"
    return None


def test_static_analysis_gates() -> str | None:
    ci = (ROOT / ".github/workflows/ci.yml").read_text()
    if "cppcheck" not in ci:
        return "ci.yml has no cppcheck gate"
    workflow = ROOT / ".github/workflows/codeql.yml"
    if not workflow.is_file():
        return "codeql.yml is missing"
    if "github/codeql-action/init@74c1aea9df7c0f02e9b7bfe4a8935abf2e5e3aa6" not in workflow.read_text():
        return "CodeQL action is not SHA-pinned to v3"
    makefile = (ROOT / "Makefile").read_text()
    if "ubsan:" not in makefile or "-fsanitize=undefined" not in makefile:
        return "Makefile has no static UBSan target"
    if not (ROOT / "scripts/test-ubsan.sh").is_file():
        return "scripts/test-ubsan.sh is missing"
    return None


def main() -> int:
    tests = [
        ("static gate rejects missing artifact and accepts a static build", test_static_gate),
        ("workflow environment builds and runs production and test binaries", test_workflow_builds_and_runs_both_binaries),
        ("cgroup snapshots tolerate no matches and detect leaks", test_cgroup_snapshots_allow_no_matches_and_detect_leaks),
        ("installer boot check uses KVM host CPU or TCG -cpu max", test_installer_boot_uses_cpu_compatible_qemu_args),
        ("third-party license notice covers bundled components", test_third_party_licenses),
        ("security policy covers all components and freezes SPM signing", test_security_scope_and_signing_freeze),
        ("documentation index and IPC list are current", test_docs_sync),
        ("community and dependabot files exist", test_community_files),
        ("static analysis and UBSan gates are configured", test_static_analysis_gates),
    ]
    failures = 0
    for name, test in tests:
        detail = test()
        if detail is None:
            print(f"PASS: {name}")
        else:
            failures += 1
            print(f"FAIL: {name}\n{detail}")
    print(f"RESULT: {len(tests) - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
