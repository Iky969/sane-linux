#!/bin/sh
# Recipe: glibc 2.41 HEADERS ONLY, installed into an absolute $DESTDIR.
#
# Host-side bootstrap: needs a seed C toolchain plus gawk/bison/python3.
# It stages headers into a SEPARATE sysroot; it never installs libc into a
# running S.A.N.E musl rootfs.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
recipe_get() { sed -n "s/^$1=//p" "$SCRIPT_DIR/RECIPE" | head -n 1; }

VERSION=$(recipe_get version)
SHA256=$(recipe_get sha256)
URL=$(recipe_get url)
[ -n "$VERSION" ] && [ -n "$SHA256" ] && [ -n "$URL" ] || {
    echo "ERROR: RECIPE is missing version/sha256/url" >&2; exit 1; }

for tool in gcc make gawk bison python3 curl sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: missing host tool: $tool" >&2; exit 1; }
done

DESTDIR=${1:-${DESTDIR:?set DESTDIR}}
mkdir -p "$DESTDIR"
DESTDIR=$(cd "$DESTDIR" && pwd -P)
[ -f "$DESTDIR/usr/include/linux/version.h" ] || {
    echo "ERROR: stage kernel headers into $DESTDIR/usr/include first" >&2; exit 1; }

WORK=${WORK:-/tmp/clawrza-glibc-headers-build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
TARBALL=glibc-${VERSION}.tar.xz

cd "$WORK"
if [ ! -f "$TARBALL" ] || ! echo "$SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
    curl -fSL --retry 3 -o "$TARBALL.part" "$URL"
    # Verify BEFORE promoting the download to its final name.
    echo "$SHA256  $TARBALL.part" | sha256sum -c -
    mv -f "$TARBALL.part" "$TARBALL"
fi
rm -rf "glibc-${VERSION}" build
tar -xf "$TARBALL"
mkdir build && cd build

../glibc-${VERSION}/configure \
    --prefix=/usr --host=x86_64-linux-gnu --build=x86_64-linux-gnu \
    --enable-shared --disable-nls --disable-werror \
    --with-headers="$DESTDIR/usr/include" \
    CC=gcc CFLAGS="-O2 -g0"

# Headers and generated bits/ only. No libc.so, no crt*.o.
make -j"$(nproc)" install-headers install_root="$DESTDIR"

# Classic glibc header-bootstrap gap: install-headers does not create stubs.h.
mkdir -p "$DESTDIR/usr/include/gnu"
: > "$DESTDIR/usr/include/gnu/stubs.h"

# Smoke test: a consumer can compile <stdio.h> against this sysroot.
# gcc's own internal headers (stddef.h etc.) are supplied explicitly.
smoke=$(mktemp /tmp/clawrza-hdr-smoke.XXXXXX.c)
printf '#include <stdio.h>\nint main(void){return 0;}\n' > "$smoke"
gcc -nostdinc -isystem "$(gcc -print-file-name=include)" \
    -I "$DESTDIR/usr/include" -c "$smoke" -o "$smoke.o"
rm -f "$smoke" "$smoke.o"
echo "clawrza-glibc-headers: sysroot smoke compile OK"
