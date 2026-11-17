#!/bin/sh
# Recipe: GCC 14.2.0 (C only) installed into an absolute $DESTDIR.
#
# Host-side bootstrap: gcc is built with the host's seed compiler because
# --disable-bootstrap is used (fast, deterministic). The resulting toolchain is
# self-hosting once installed into the sysroot; the independent
# clawrza-glibc-selfhost image proves that kinit/spkg rebuild inside the guest.
# No zlib build dependency: --with-system-zlib is intentionally omitted.
set -eu
DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
mkdir -p "$DESTDIR"
DESTDIR=$(cd "$DESTDIR" && pwd -P)
WORK=${WORK:-/tmp/clawrza-gcc-build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
VERSION=14.2.0
SHA256=a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9
TARBALL=gcc-${VERSION}.tar.xz
URL=https://ftp.gnu.org/gnu/gcc/gcc-${VERSION}.tar.xz

cd "$WORK"
if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$TARBALL.part" "$URL"
    mv -f "$TARBALL.part" "$TARBALL"
fi
echo "$SHA256  $TARBALL" | sha256sum -c -
rm -rf "gcc-${VERSION}" build
tar -xf "$TARBALL"
mkdir build && cd build

../gcc-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --target=x86_64-linux-gnu \
    --enable-languages=c \
    --disable-nls --disable-werror --disable-multilib --disable-bootstrap \
    --disable-libssp --disable-libgomp --disable-libquadmath \
    --with-native-system-header-dir=/usr/include \
    --with-build-sysroot="$DESTDIR" \
    --with-local-prefix=/usr \
    CFLAGS="-O2 -g0" LDFLAGS="-Wl,-rpath,/usr/lib -Wl,-rpath,/lib"
make -j"$(nproc)"
make install DESTDIR="$DESTDIR"
