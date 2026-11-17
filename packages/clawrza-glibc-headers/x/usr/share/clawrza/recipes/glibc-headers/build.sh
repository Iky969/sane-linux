#!/bin/sh
# Recipe: glibc 2.41 HEADERS ONLY, installed into an absolute $DESTDIR.
#
# Bootstrap model: this script runs on a HOST that already has a seed C
# toolchain (gcc/make). It stages headers into a target sysroot; it does NOT
# install libc.so/crt*.o into a live S.A.N.E musl rootfs.
# Kernel headers must already be staged at $DESTDIR/usr/include (manual step;
# there is no kernel-headers spm package in this repo).
set -eu
DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
mkdir -p "$DESTDIR"
DESTDIR=$(cd "$DESTDIR" && pwd -P)
WORK=${WORK:-/tmp/clawrza-glibc-headers-build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
VERSION=2.41
SHA256=a5a26b22f545d6b7d7b3dd828e11e428f24f4fac43c934fb071b6a7d0828e901
TARBALL=glibc-${VERSION}.tar.xz
URL=https://ftp.gnu.org/gnu/glibc/glibc-${VERSION}.tar.xz

cd "$WORK"
if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$TARBALL.part" "$URL"
    mv -f "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | sha256sum -c -
rm -rf "glibc-${VERSION}" build
tar -xf "$TARBALL"
mkdir build && cd build

../glibc-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --enable-shared --disable-nls --disable-werror \
    --with-headers="$DESTDIR/usr/include" \
    CC=gcc CFLAGS="-O2 -g0"

# Headers + generated bits/ headers only. No libc, no startup objects.
make -j"$(nproc)" install-headers install_root="$DESTDIR"
