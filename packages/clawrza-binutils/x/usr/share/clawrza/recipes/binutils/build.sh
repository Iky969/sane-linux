#!/bin/sh
# Recipe: GNU binutils 2.44 (as, ld, ar, ...) installed into an absolute $DESTDIR.
# Host-side bootstrap: requires a seed C toolchain on the build host.
set -eu
DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
mkdir -p "$DESTDIR"
DESTDIR=$(cd "$DESTDIR" && pwd -P)
WORK=${WORK:-/tmp/clawrza-binutils-build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
VERSION=2.44
SHA256=ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237
TARBALL=binutils-${VERSION}.tar.xz
URL=https://ftp.gnu.org/gnu/binutils/binutils-${VERSION}.tar.xz

cd "$WORK"
if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$TARBALL.part" "$URL"
    mv -f "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | sha256sum -c -
rm -rf "binutils-${VERSION}" build
tar -xf "$TARBALL"
mkdir build && cd build

../binutils-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --target=x86_64-linux-gnu \
    --disable-nls --disable-werror --disable-multilib --enable-shared
make -j"$(nproc)" all
make install DESTDIR="$DESTDIR"
