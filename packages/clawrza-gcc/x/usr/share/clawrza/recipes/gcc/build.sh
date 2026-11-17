#!/bin/sh
# Recipe: GCC 14.2.0 (C only) installed into an absolute $DESTDIR.
#
# Host-side bootstrap: gcc is built with the host seed compiler because
# --disable-bootstrap is used (fast, deterministic). The resulting toolchain
# becomes self-hosting once installed into the sysroot; the independent
# clawrza-glibc-selfhost image proves kinit/spkg rebuild inside the guest.
# No zlib build dependency: --with-system-zlib is intentionally omitted.
# No hardcoded rpath: the guest exports LD_LIBRARY_PATH/GCC_EXEC_PREFIX at boot.
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
WORK=${WORK:-/tmp/clawrza-gcc-build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
TARBALL=gcc-${VERSION}.tar.xz

cd "$WORK"
if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$TARBALL.part" "$URL"
    echo "$SHA256  $TARBALL.part" | sha256sum -c -
    mv -f "$TARBALL.part" "$TARBALL"
fi
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
    CFLAGS="-O2 -g0"
make -j"$(nproc)"
make install DESTDIR="$DESTDIR"
