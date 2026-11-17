#!/bin/sh
# Recipe: GNU binutils 2.44 (as, ld, ar, ...) installed into an absolute $DESTDIR.
# Host-side bootstrap: requires a seed C toolchain on the build host.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
recipe_get() { sed -n "s/^$1=//p" "$SCRIPT_DIR/RECIPE" | head -n 1; }

VERSION=$(recipe_get version)
SHA256=$(recipe_get sha256)
URL=$(recipe_get url)
[ -n "$VERSION" ] && [ -n "$SHA256" ] && [ -n "$URL" ] || {
    echo "ERROR: RECIPE is missing version/sha256/url" >&2; exit 1; }

DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
mkdir -p "$DESTDIR"
DESTDIR=$(cd "$DESTDIR" && pwd -P)
WORK=${WORK:-/tmp/clawrza-binutils-build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
TARBALL=binutils-${VERSION}.tar.xz

cd "$WORK"
if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$TARBALL.part" "$URL"
    echo "$SHA256  $TARBALL.part" | sha256sum -c -
    mv -f "$TARBALL.part" "$TARBALL"
fi
rm -rf "binutils-${VERSION}" build
tar -xf "$TARBALL"
mkdir build && cd build

../binutils-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --target=x86_64-linux-gnu \
    --disable-nls --disable-werror --disable-multilib --disable-shared
make -j"$(nproc)" all
make install DESTDIR="$DESTDIR"
