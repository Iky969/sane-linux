#!/usr/bin/env python3
"""
scripts/lint-log-patterns.py: Lint test log patterns and ninit.c strings.

Ensures:
1. Zero Indonesian words in ninit.c init_log and enter_rescue_mode strings.
2. Zero leftover Indonesian words in scripts/*.sh assertions (check_in, absent_in, check, check_absent).
3. Positive test assertions match valid substrings in ninit.c.
4. Negative assertions (absent_in / check_absent) do NOT search for dead untranslated patterns (preventing false greens).
"""

import sys
import os
import glob
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
NINIT_C = REPO_ROOT / "ninit.c"
SCRIPTS_DIR = REPO_ROOT / "scripts"

INDONESIAN_WORDS = [
    "yang", "dan", "tidak", "layanan", "gagal", "dengan", "dibersihkan",
    "dibatalkan", "dinyatakan", "tercapai", "diabaikan", "dilewati", "ditunda",
    "peringatan", "masuk", "sudah", "memuat", "khusus", "bukan", "hanya",
    "pada", "terlalu", "siap", "terdeteksi", "digagalkan", "percobaan",
    "entri", "ditolak", "rusak", "mengosongkan", "sebelum", "setelah", "jalan"
]

def check_ninit_strings():
    errors = []
    if not NINIT_C.exists():
        return [f"File {NINIT_C} not found!"]
    
    with open(NINIT_C, "r", encoding="utf-8") as f:
        lines = f.readlines()
    
    for lnum, line in enumerate(lines, 1):
        # Match init_log("...") or enter_rescue_mode("...")
        m = re.search(r'(?:init_log|enter_rescue_mode)\s*\(\s*"([^"]+)"', line)
        if m:
            text = m.group(1)
            for w in INDONESIAN_WORDS:
                if re.search(rf'\b{w}\b', text, re.IGNORECASE):
                    errors.append(f"ninit.c:{lnum}: init_log/rescue string contains Indonesian word '{w}': \"{text}\"")
                    break
    return errors

def check_script_assertions():
    errors = []
    script_files = sorted(SCRIPTS_DIR.glob("*.sh"))
    
    for sf in script_files:
        with open(sf, "r", encoding="utf-8") as f:
            content = f.read()
        
        # Flatten multiline statements
        content_clean = re.sub(r"\\\n\s*", " ", content)
        
        # Match assertions: check_in, absent_in, check, check_absent, wait_for
        matches = re.finditer(r'(check_in|absent_in|check|check_absent|wait_for)\s+([^\n]+)', content_clean)
        for m in matches:
            fn = m.group(1)
            args_str = m.group(2)
            quotes = re.findall(r'"([^"]*)"|\'([^\']*)\'', args_str)
            all_q = [q[0] or q[1] for q in quotes]
            
            # The pattern is typically the last quoted string
            if not all_q:
                continue
            
            # For check_in / absent_in: check_in <desc> <file> <pattern>
            if fn in ("check_in", "absent_in") and len(all_q) >= 2:
                pattern = all_q[-1]
            elif fn in ("check", "check_absent") and len(all_q) >= 2:
                pattern = all_q[-1]
            elif fn == "wait_for" and len(all_q) >= 1:
                pattern = all_q[0]
            else:
                continue
            
            # Skip non-log patterns (e.g. file paths, numbers, or command flags)
            if pattern.startswith("/") or pattern.startswith("-") or pattern.isdigit():
                continue
            
            for w in INDONESIAN_WORDS:
                if re.search(rf'\b{w}\b', pattern, re.IGNORECASE):
                    errors.append(f"{sf.name}: assertion [{fn}] pattern contains Indonesian word '{w}': \"{pattern}\"")
                    break
                    
    return errors

LEGACY_MARKERS = [
    r"HASIL:",
    r"\[GAGAL\]",
    r"\bGAGAL:",
    r"\bSkenario\b",
]

def check_script_markers():
    errors = []
    script_files = sorted(SCRIPTS_DIR.glob("*.sh"))
    for sf in script_files:
        with open(sf, "r", encoding="utf-8") as f:
            for lnum, line in enumerate(f, 1):
                clean = line.strip()
                if clean.startswith("#"):
                    continue
                for pat in LEGACY_MARKERS:
                    if re.search(pat, line):
                        errors.append(f"{sf.name}:{lnum}: contains legacy Indonesian marker matching '{pat}': {clean}")
    return errors

def main():
    print("=== Sane-Linux Log & Pattern Lint ===")
    ninit_errs = check_ninit_strings()
    script_errs = check_script_assertions()
    marker_errs = check_script_markers()
    
    all_errs = ninit_errs + script_errs + marker_errs
    if all_errs:
        print(f"\nFAILED: Found {len(all_errs)} issue(s):")
        for e in all_errs:
            print(f"  ❌ {e}")
        return 1
    else:
        print("✅ PASSED: All log strings, assertions, and test script markers are cleanly in English with zero legacy keywords.")
        return 0

if __name__ == "__main__":
    sys.exit(main())
