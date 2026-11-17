#!/bin/sh
# Recipe: GNU binutils 2.44 (as, ld, ar, ...) installed into $DESTDIR.
set -eu
DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
WORK=${WORK:-/tmp/clawrza-binutils-build}
VERSION=2.44
SHA256=ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237
TARBALL=binutils-${VERSION}.tar.xz

mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "$TARBALL" ]; then
    wget -O "$TARBALL" "https://ftp.gnu.org/gnu/binutils/binutils-${VERSION}.tar.xz"
fi
echo "$SHA256  $TARBALL" | sha256sum -c -
[ -d "binutils-${VERSION}" ] || tar -xf "$TARBALL"

mkdir -p build && cd build
../binutils-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --target=x86_64-linux-gnu \
    --disable-nls --disable-werror --disable-multilib --enable-shared
make -j"$(nproc)" all
make install DESTDIR="$DESTDIR"
