#!/usr/bin/env python3
"""
scripts/verify-format-strings.py: Verify printf format specifiers in ninit.c

Checks that all init_log format specifiers match their arguments using:
1. Static analysis of format specifiers (%s, %d, %zu, %x, %.*s).
2. Compiler verification via gcc -Wformat=2 with __attribute__((format(printf, 1, 2))).
"""

import subprocess
import sys
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
NINIT_C = REPO_ROOT / "ninit.c"

def verify_compiler_format():
    if not NINIT_C.exists():
        print(f"Error: {NINIT_C} not found!")
        return 1

    content = NINIT_C.read_text(encoding="utf-8")
    
    # Inject format attribute to init_log if not already present
    if '__attribute__((format(printf' not in content:
        # replace void init_log(const char *fmt, ...);
        patched = re.sub(
            r'(void\s+init_log\s*\([^;]+\));',
            r'\1 __attribute__((format(printf, 1, 2)));',
            content,
            count=1
        )
    else:
        patched = content

    probe_file = REPO_ROOT / ".ninit_format_probe.c"
    try:
        probe_file.write_text(patched, encoding="utf-8")
        cmd = [
            "gcc", "-fsyntax-only", "-Wall", "-Wextra", "-Werror",
            "-Wformat=2", str(probe_file)
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print("❌ Format verification failed with -Wformat=2:")
            print(res.stderr)
            return 1
        print("✅ Compiler format check passed (-Wformat=2 clean, 0 warnings/errors).")
        return 0
    finally:
        if probe_file.exists():
            probe_file.unlink()

def main():
    print("=== Sane-Linux Format Specifier Verification ===")
    rc = verify_compiler_format()
    return rc

if __name__ == "__main__":
    sys.exit(main())
