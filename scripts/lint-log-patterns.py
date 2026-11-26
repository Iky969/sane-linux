#!/usr/bin/env python3
"""
scripts/lint-log-patterns.py: Lint test log patterns and ninit.c strings.

Enforces:
1. Zero Indonesian words in ninit.c init_log and enter_rescue_mode strings.
2. Zero Indonesian words in scripts/*.sh assertion patterns (check_in,
   absent_in, check, check_absent, wait_for).
3. Zero legacy Indonesian result markers in non-comment lines of scripts/*.sh.

Assertion patterns are not cross-checked against ninit.c strings; that
contract is not implemented by this linter.
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
NINIT_C = REPO_ROOT / "ninit.c"
SCRIPTS_DIR = REPO_ROOT / "scripts"

INDONESIAN_WORDS = [
    "yang", "dan", "tidak", "layanan", "gagal", "dengan", "dibersihkan",
    "dibatalkan", "dinyatakan", "tercapai", "diabaikan", "dilewati", "ditunda",
    "peringatan", "masuk", "sudah", "memuat", "khusus", "bukan", "hanya",
    "pada", "terlalu", "siap", "terdeteksi", "digagalkan", "percobaan",
    "entri", "ditolak", "rusak", "mengosongkan", "sebelum", "setelah", "jalan",
]

_WORD_RE = re.compile(
    r"\b(" + "|".join(re.escape(w) for w in INDONESIAN_WORDS) + r")\b",
    re.IGNORECASE,
)


def check_ninit_strings():
    errors = []
    if not NINIT_C.exists():
        return [f"File {NINIT_C} not found!"]

    content = NINIT_C.read_text(encoding="utf-8")
    # Match single- or multi-line init_log("...") / enter_rescue_mode("...") calls.
    call_re = re.compile(
        r'\b(?:init_log|enter_rescue_mode)\s*\(\s*"((?:[^"\\]|\\.)*)"',
        re.DOTALL,
    )
    for m in call_re.finditer(content):
        text = m.group(1)
        hit = _WORD_RE.search(text)
        if hit:
            lnum = content.count("\n", 0, m.start()) + 1
            errors.append(
                f"ninit.c:{lnum}: init_log/rescue string contains Indonesian word "
                f"'{hit.group(1)}': \"{text}\""
            )
    return errors


def _extract_shell_args(tail):
    """Extract shell command arguments from a flattened line up to an unquoted
    command separator (;, &&, ||, &, |, #, newline) or closing subshell."""
    args = []
    cur = []
    in_tok = False
    quote = None
    i = 0
    n = len(tail)
    while i < n:
        ch = tail[i]
        if quote == "'":
            if ch == "'":
                quote = None
            else:
                cur.append(ch)
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < n:
                cur.append(tail[i + 1])
                i += 2
                continue
            if ch == '"':
                quote = None
            else:
                cur.append(ch)
            i += 1
            continue
        if ch in (" ", "\t"):
            if in_tok:
                args.append("".join(cur))
                cur = []
                in_tok = False
            i += 1
            continue
        if ch in ("\n", "#", ";", "&", "|", ")"):
            break
        if ch == "\\" and i + 1 < n:
            in_tok = True
            cur.append(tail[i + 1])
            i += 2
            continue
        if ch in ("'", '"'):
            in_tok = True
            quote = ch
            i += 1
            continue
        in_tok = True
        cur.append(ch)
        i += 1
    if in_tok:
        args.append("".join(cur))
    return args


def check_script_assertions():
    errors = []
    script_files = sorted(SCRIPTS_DIR.glob("*.sh"))

    for sf in script_files:
        content = sf.read_text(encoding="utf-8")
        # Flatten backslash-newline continuations.
        content_clean = re.sub(r"\\\n[ \t]*", " ", content)

        for line in content_clean.splitlines():
            stripped = line.lstrip()
            if not stripped or stripped.startswith("#"):
                continue
            m = re.search(
                r"(?:^|[;&|(\s])(check_in|absent_in|check|check_absent|wait_for)[ \t]+(.+)$",
                line,
            )
            if not m:
                continue
            fn = m.group(1)
            args = _extract_shell_args(m.group(2))

            if fn in ("check_in", "absent_in") and len(args) >= 3:
                pattern = args[2]
            elif fn in ("check", "check_absent") and len(args) >= 2:
                if args[1] in ("sh", "test", "["):
                    continue
                pattern = args[1]
            elif fn == "wait_for" and len(args) >= 1:
                pattern = args[0]
            else:
                continue

            if not pattern or pattern.startswith("/") or pattern.startswith("-") or pattern.isdigit():
                continue

            hit = _WORD_RE.search(pattern)
            if hit:
                errors.append(
                    f"{sf.name}: assertion [{fn}] pattern contains Indonesian word "
                    f"'{hit.group(1)}': \"{pattern}\""
                )

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
                        errors.append(
                            f"{sf.name}:{lnum}: contains legacy Indonesian marker matching '{pat}': {clean}"
                        )
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
    print("✅ PASSED: All log strings, assertions, and test script markers are cleanly in English with zero legacy keywords.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
