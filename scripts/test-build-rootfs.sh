#!/bin/sh
# scripts/test-build-rootfs.sh -- regression for build-rootfs.sh busybox linking.
#
# Covers the prebuilt-busybox dangling-symlink bug: applet symlinks target the
# guest's /bin/busybox, which need not resolve on the build host. The guards
# must detect an existing (even dangling) symlink with -L and never recreate it,
# and /bin/sh must still be validated as a usable busybox link.
#
# Part A/A2 are deterministic and host-independent (they do not rely on whether
# the build host happens to have /bin/busybox). Part B is an end-to-end smoke
# test of the prebuilt build. Runs without root and without touching host state.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BUILD="$REPO_ROOT/scripts/build-rootfs.sh"

PASS=0
FAIL=0
T=$(mktemp -d)
cleanup() { rm -rf -- "$T"; }
trap cleanup EXIT HUP INT TERM

pass() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1" >&2; }
check() { d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
expect_fail() { d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }

check "build-rootfs.sh is present" test -f "$BUILD"
check "build-rootfs.sh passes shell syntax" sh -n "$BUILD"

# Source only the function definitions. The sourced script sets -eu; drop -e so
# a failing probe below is reported by the harness instead of aborting it.
# shellcheck disable=SC1090
BUILD_ROOTFS_LIB_ONLY=1 . "$BUILD"
set +e

# --- Part A: link_applet idempotency over a dangling symlink -----------------
ROOTFS="$T/a"
mkdir -p "$ROOTFS/bin"
APPLET_LIST="sh"
ln -s "/nonexistent-sane-busybox-target" "$ROOTFS/bin/sh"
if link_applet bin sh; then
	pass "link_applet does not fail on an existing dangling symlink"
else
	fail "link_applet does not fail on an existing dangling symlink"
fi
check "dangling symlink was not replaced" \
	test "$(readlink "$ROOTFS/bin/sh")" = "/nonexistent-sane-busybox-target"
rm -f "$ROOTFS/bin/sh"
if link_applet bin sh; then
	pass "link_applet creates the applet symlink when absent"
else
	fail "link_applet creates the applet symlink when absent"
fi
check "created applet symlink is present" test -L "$ROOTFS/bin/sh"

# --- Part A2: ensure_sh_link validates a usable busybox link (host-independent)
ROOTFS="$T/sh"
mkdir -p "$ROOTFS/bin"
printf '#!/bin/sh\n' > "$ROOTFS/bin/busybox"
chmod 0755 "$ROOTFS/bin/busybox"
ln -s /bin/busybox "$ROOTFS/bin/sh"
if ensure_sh_link; then
	pass "ensure_sh_link accepts a /bin/busybox link with executable busybox"
else
	fail "ensure_sh_link accepts a /bin/busybox link with executable busybox"
fi
rm -f "$ROOTFS/bin/sh"
ln -s "/nonexistent-sane-other-target" "$ROOTFS/bin/sh"
expect_fail "ensure_sh_link rejects a link to a non-busybox absent target" ensure_sh_link
rm -f "$ROOTFS/bin/sh"
expect_fail "ensure_sh_link rejects a missing /bin/sh" ensure_sh_link

# --- Part B: end-to-end prebuilt build (smoke) -------------------------------
BB="$REPO_ROOT/packages/busybox/x/bin/busybox"
[ -x "$BB" ] || BB=$(command -v busybox || true)
if [ -n "$BB" ] && [ -x "$BB" ]; then
	NINIT="$T/ninit"
	if gcc -static -O2 -o "$NINIT" "$REPO_ROOT/ninit.c" 2>"$T/gcc.err"; then
		pass "ninit compiles for the prebuilt build"
	else
		fail "ninit compiles for the prebuilt build"
	fi
	if DISTRO_DIR="$T/distro" ROOTFS="$T/distro/rootfs" \
		INITRAMFS="$T/distro/initramfs.cpio.gz" \
		BUSYBOX_MODE=prebuilt BUSYBOX_PREBUILT="$BB" NINIT="$NINIT" \
		sh "$BUILD" >"$T/build.log" 2>&1; then
		pass "prebuilt rootfs build succeeds"
	else
		fail "prebuilt rootfs build succeeds"
	fi
	check "prebuilt build has no ln 'File exists' symlink error" \
		sh -c "! grep -q 'ln:.*File exists' '$T/build.log'"
	check "prebuilt rootfs /bin/sh is a symlink" test -L "$T/distro/rootfs/bin/sh"
	check "prebuilt rootfs /bin/busybox is executable" test -x "$T/distro/rootfs/bin/busybox"
	check "prebuilt initramfs was created" test -s "$T/distro/initramfs.cpio.gz"
else
	printf 'SKIP - no static busybox available for the end-to-end prebuilt build\n'
fi

printf '\nBuild-rootfs tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
