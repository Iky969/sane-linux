#!/bin/sh
# check-ninit-c-refs.sh -- fail if a NEW file references ninit.c directly.
#
# During the ninit source split, ninit.c stays the single compilation entry
# point until the final per-TU commit. A new file that mentions ninit.c would
# silently become another consumer; it must be reviewed and allowlisted
# explicitly, never added by accident.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$REPO_ROOT"

ALLOWLIST="scripts/ninit-c-refs.allow"
if [ ! -f "$ALLOWLIST" ]; then
    echo "FAIL: missing allowlist $ALLOWLIST" >&2
    exit 1
fi

MATCHES=$(git grep -Il -e 'ninit\.c' -- '*.c' '*.h' '*.sh' '*.py' Makefile '*.yml' | sort -u)

FAILED=0
for file in $MATCHES; do
    if ! grep -Fxq "$file" "$ALLOWLIST"; then
        echo "FAIL: $file references ninit.c directly (add to $ALLOWLIST only if intentional)" >&2
        FAILED=1
    fi
done

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

echo "PASS: no unlisted file references ninit.c"
