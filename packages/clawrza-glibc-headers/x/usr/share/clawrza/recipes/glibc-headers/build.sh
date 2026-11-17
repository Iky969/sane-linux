#!/bin/sh
# Recipe: glibc 2.41 headers + startup files, installed into $DESTDIR.
# Requires kernel headers already present at $DESTDIR/usr/include.
set -eu
DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
WORK=${WORK:-/tmp/clawrza-glibc-headers-build}
VERSION=2.41
SHA256=a5a26b22f545d6b7d7b3dd828e11e428f24f4fac43c934fb071b6a7d0828e901
TARBALL=glibc-${VERSION}.tar.xz

mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "$TARBALL" ]; then
    wget -O "$TARBALL" "https://ftp.gnu.org/gnu/glibc/glibc-${VERSION}.tar.xz"
fi
echo "$SHA256  $TARBALL" | sha256sum -c -
[ -d "glibc-${VERSION}" ] || tar -xf "$TARBALL"

mkdir -p build && cd build
../glibc-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --enable-shared --disable-nls --disable-werror \
    --with-headers="$DESTDIR/usr/include" \
    CC=gcc CFLAGS="-O2 -g0"
make -j"$(nproc)"
make install DESTDIR="$DESTDIR"
