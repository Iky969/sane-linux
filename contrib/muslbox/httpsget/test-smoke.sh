#!/usr/bin/env bash
# Smoke test for httpsget: no network required unless NETWORK=1.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
BIN="$HERE/httpsget"
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || die "run build.sh first"
if readelf -lW "$BIN" | grep -q INTERP; then
	die "binary has a PT_INTERP segment"
fi

"$BIN" > "$HERE/usage.out" 2>&1 && die "missing URL should exit non-zero"
grep -q 'usage: httpsget' "$HERE/usage.out" || die "usage text missing"
rm -f "$HERE/usage.out"

"$BIN" 'http://example.com/' >/dev/null 2>&1 && die "non-https URL should fail"
"$BIN" $'https://example.com/a\r\nX: 1' >/dev/null 2>&1 && die "CRLF path should fail"
"$BIN" 'https://[::1]/' >/dev/null 2>&1 && die "IPv6 URL should fail"
"$BIN" 'https://u@example.com/' >/dev/null 2>&1 && die "userinfo should fail"
"$BIN" 'https://example.com:99999/' >/dev/null 2>&1 && die "bad port should fail"

if [ "${NETWORK:-0}" = 1 ]; then
	"$BIN" https://example.com/ | grep -q 'HTTP/1.1 200'
fi
printf 'PASS: httpsget smoke test (static ELF, usage, URL validation%s)\n' \
	"${NETWORK:+ , network}"
