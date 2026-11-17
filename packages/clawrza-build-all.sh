#!/usr/bin/env bash
# Build the three clawrza self-hosting toolchain recipes as .spm packages.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT="${1:-$REPO_ROOT/distro/packages}"

for pkg in clawrza-glibc-headers clawrza-binutils clawrza-gcc; do
    bash "$REPO_ROOT/scripts/build-package.sh" \
        --source "$REPO_ROOT/packages/$pkg" \
        --output "$OUT"
done
