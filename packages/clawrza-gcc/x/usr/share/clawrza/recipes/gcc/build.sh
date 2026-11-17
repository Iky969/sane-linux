#!/bin/sh
# Recipe: GCC 14.2.0 (C only) installed into $DESTDIR.
# Build with --with-build-sysroot=$DESTDIR so cc1/cc1plus resolve guest paths.
set -eu
DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
WORK=${WORK:-/tmp/clawrza-gcc-build}
VERSION=14.2.0
SHA256=a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9
TARBALL=gcc-${VERSION}.tar.xz

mkdir -p "$WORK"
cd "$WORK"
if [ ! -f "$TARBALL" ]; then
    wget -O "$TARBALL" "https://ftp.gnu.org/gnu/gcc/gcc-${VERSION}.tar.xz"
fi
echo "$SHA256  $TARBALL" | sha256sum -c -
[ -d "gcc-${VERSION}" ] || tar -xf "$TARBALL"

mkdir -p build && cd build
../gcc-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --target=x86_64-linux-gnu \
    --enable-languages=c \
    --disable-nls --disable-werror --disable-multilib --disable-bootstrap \
    --disable-libssp --disable-libgomp --disable-libquadmath \
    --with-system-zlib \
    --with-native-system-header-dir=/usr/include \
    --with-build-sysroot="$DESTDIR" \
    --with-local-prefix=/usr \
    CFLAGS="-O2 -g0" LDFLAGS="-Wl,-rpath,/usr/lib -Wl,-rpath,/lib"
make -j"$(nproc)"
make install DESTDIR="$DESTDIR"
