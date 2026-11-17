#!/usr/bin/env bash
# contrib/muslbox/httpsget/build.sh -- build a musl-static HTTPS GET client.
#
# Pinned upstream: mbedTLS 3.6.8 (URL + SHA256).  No cmake needed: the release
# tarball ships the legacy library Makefiles and framework/exported.make.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WORK=${1:-$HERE/work}
CACHE="$WORK/cache"
SRC="$WORK/mbedtls-3.6.8"
MBEDTLS_URL=${MBEDTLS_URL:-https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.8/mbedtls-3.6.8.tar.bz2}
MBEDTLS_SHA=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}

log() { printf '==> %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v musl-gcc >/dev/null || die "musl-gcc missing (install musl-tools)"

mkdir -p "$CACHE"
if [ ! -s "$CACHE/mbedtls-3.6.8.tar.bz2" ]; then
	log "downloading mbedtls 3.6.8"
	curl -fL --retry 3 -o "$CACHE/mbedtls-3.6.8.tar.bz2.part" "$MBEDTLS_URL"
	mv "$CACHE/mbedtls-3.6.8.tar.bz2.part" "$CACHE/mbedtls-3.6.8.tar.bz2"
fi
actual=$(sha256sum "$CACHE/mbedtls-3.6.8.tar.bz2" | cut -d' ' -f1)
[ "$actual" = "$MBEDTLS_SHA" ] || die "mbedtls checksum mismatch: $actual"

if [ ! -d "$SRC" ]; then
	log "extracting"
	tar -xjf "$CACHE/mbedtls-3.6.8.tar.bz2" -C "$WORK"
fi
if [ ! -f "$SRC/library/libmbedtls.a" ]; then
	log "building static libs with musl-gcc -j$JOBS"
	make -C "$SRC/library" -j"$JOBS" CC=musl-gcc \
		CFLAGS='-O2 -D_FILE_OFFSET_BITS=64' >/dev/null
fi

log "linking httpsget"
musl-gcc -O2 -Wall -Wextra -static -I"$SRC/include" \
	"$HERE/httpsget.c" \
	"$SRC/library/libmbedtls.a" \
	"$SRC/library/libmbedx509.a" \
	"$SRC/library/libmbedcrypto.a" \
	-o "$HERE/httpsget"
readelf -lW "$HERE/httpsget" | grep -q INTERP && die "httpsget is not static"
printf 'OK: %s (%s, static musl)\n' "$HERE/httpsget" "$(du -h "$HERE/httpsget" | cut -f1)"
