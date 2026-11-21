#!/usr/bin/env python3
"""
scripts/verify-format-strings.py: Verify printf format specifiers in ninit.c

1. Asserts that init_log is declared with
   __attribute__((format(printf, 1, 2))) in the source. A missing attribute
   FAILS the gate: this script never injects the attribute at check time.
2. Compiles the source with gcc -Wall -Wextra -Werror -Wformat=2, so any
   mismatch between an init_log format string and its arguments fails.

Optional argv[1] overrides the ninit.c path (default REPO_ROOT/ninit.c).
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_NINIT_C = REPO_ROOT / "ninit.c"
FORMAT_ATTR_RE = re.compile(
    r'\binit_log\s*\([^;{]*\)\s*__attribute__\s*\(\(\s*format\s*\(\s*printf\s*,\s*1\s*,\s*2\s*\)\s*\)\)\s*;'
)


def _preprocessed(ninit_c):
    # Textual regexes alone are fooled by declarations in comments and by
    # `#if 0` blocks. Preprocess first so only live declarations are seen.
    res = subprocess.run(
        ["gcc", "-E", str(ninit_c)], capture_output=True, text=True
    )
    if res.returncode != 0:
        raise RuntimeError(res.stderr)
    return res.stdout


def verify_compiler_format(ninit_c):
    if not ninit_c.exists():
        print(f"Error: {ninit_c} not found!")
        return 1

    content = ninit_c.read_text(encoding="utf-8")
    try:
        live_source = _preprocessed(ninit_c)
    except RuntimeError as exc:
        print(f"FAIL: cannot preprocess {ninit_c}:\n{exc}")
        return 1
    if not FORMAT_ATTR_RE.search(live_source):
        print(
            f"FAIL: {ninit_c} has no init_log declaration with "
            "__attribute__((format(printf, 1, 2))) in the LIVE source "
            "(comments and #if 0 blocks do not count)"
        )
        return 1

    # Stage a UNIQUELY named copy next to the source so #include resolution
    # matches the compile step, and remove only our own file afterwards:
    # a pre-existing .ninit_format_probe.c is never clobbered or deleted.
    probe_file = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".c",
            prefix=".ninit_format_probe.", dir=ninit_c.parent, delete=False
        ) as tmp:
            tmp.write(content)
            probe_file = Path(tmp.name)
        cmd = [
            "gcc", "-fsyntax-only", "-Wall", "-Wextra", "-Werror",
            "-Wformat=2", str(probe_file)
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print("FAIL: format verification failed with -Wformat=2:")
            print(res.stderr)
            return 1
        print("PASS: init_log format attribute present; -Wformat=2 clean, 0 warnings/errors.")
        return 0
    except OSError as exc:
        print(f"FAIL: cannot stage format probe: {exc}")
        return 1
    finally:
        if probe_file is not None:
            probe_file.unlink(missing_ok=True)


def main():
    print("=== Sane-Linux Format Specifier Verification ===")
    if len(sys.argv) > 2:
        print("usage: verify-format-strings.py [ninit.c]")
        return 2
    ninit_c = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_NINIT_C
    return verify_compiler_format(ninit_c)


if __name__ == "__main__":
    sys.exit(main())
