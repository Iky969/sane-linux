#!/usr/bin/env bash
# packages/build-all.sh -- Build all base S.A.N.E distro packages
set -euo pipefail

PACKAGES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$PACKAGES_DIR/.." && pwd -P)"
OUT_DIR="${1:-$REPO_ROOT/distro/packages}"

mkdir -p "$OUT_DIR"

PACKAGES=(
    sane-hello
    ninit
    busybox
    kernel
    limine-static
)

printf '=== Building S.A.N.E Distro Packages ===\n'
printf 'Output directory: %s\n\n' "$OUT_DIR"

for pkg in "${PACKAGES[@]}"; do
    printf '>>> Building package: %s\n' "$pkg"
    "$PACKAGES_DIR/$pkg/build.sh" "$OUT_DIR"
    printf '<<< Completed package: %s\n\n' "$pkg"
done

printf '=== All %d packages built successfully ===\n' "${#PACKAGES[@]}"
ls -lh "$OUT_DIR"/*.spm.tar.xz
