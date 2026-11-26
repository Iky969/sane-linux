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
BUILD=${BUILD:-$REPO_ROOT/scripts/build-rootfs.sh}

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

# R1: malformed and explicitly empty checksums must fail before curl runs.
# The fake curl leaves a marker if validation is accidentally too late.
check_sha_rejected_before_download() {
	d=$1; value=$2; name=$3
	dir="$T/sha-$name"
	mkdir -p "$dir/bin"
	cat > "$dir/bin/curl" <<'EOF'
#!/bin/sh
: > "$SANE_TEST_CURL_MARKER"
exit 1
EOF
	chmod 0755 "$dir/bin/curl"
	if err=$(SANE_TEST_CURL_MARKER="$dir/curl-called" \
		PATH="$dir/bin:$PATH" BB_SHA256="$value" \
		BB_URL="https://example.invalid/busybox.tar.bz2" \
		BUSYBOX_MODE=source DISTRO_DIR="$dir/distro" \
		sh "$BUILD" 2>&1 >/dev/null); then
		fail "$d"
	elif ! printf '%s\n' "$err" | grep -q 'BB_SHA256 must be a 64-digit hex checksum'; then
		fail "$d (diagnostic: $err)"
	elif [ -e "$dir/curl-called" ]; then
		fail "$d (download was attempted)"
	else
		pass "$d"
	fi
}
check_sha_rejected_before_download "empty BB_SHA256 is rejected before download" "" empty
check_sha_rejected_before_download "malformed BB_SHA256 is rejected before download" "abc" malformed

# Source only the function definitions. The sourced script sets -eu; drop -e so
# a failing probe below is reported by the harness instead of aborting it.
# shellcheck disable=SC1090
BUILD_ROOTFS_LIB_ONLY=1 . "$BUILD"
set +e

# --- Part A: link_applet idempotency over a dangling symlink -----------------
ROOTFS="$T/a"
mkdir -p "$ROOTFS/bin"
# Consumed indirectly by link_applet in the sourced build-rootfs.sh.
# shellcheck disable=SC2034
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

# Verify link_applet handles all P1-19 required applets (including mountpoint when compiled)
ROOTFS="$T/p119"
mkdir -p "$ROOTFS/bin"
# shellcheck disable=SC2034
APPLET_LIST=$(printf '%s\n' cttyhack stty awk mktemp sha256sum gzip mountpoint)
for req_applet in cttyhack stty awk mktemp sha256sum gzip mountpoint; do
	if link_applet bin "$req_applet" && test -L "$ROOTFS/bin/$req_applet"; then
		pass "link_applet creates symlink for $req_applet when present"
	else
		fail "link_applet creates symlink for $req_applet when present"
	fi
done

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
# Smoke test, NOT a bug reproduction: it exercises the dangling-symlink path
# only when the build host lacks /bin/busybox. On hosts with busybox-static
# (e.g. CI) the absolute links resolve and this is a happy-path build check.
# The deterministic, host-independent regression for the bug is Part A/A2.
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
	for req_applet in cttyhack stty awk mktemp sha256sum gzip; do
		check "prebuilt rootfs provides $req_applet applet" sh -c \
			"test -L '$T/distro/rootfs/bin/$req_applet' || test -e '$T/distro/rootfs/bin/$req_applet' || \
			 test -L '$T/distro/rootfs/sbin/$req_applet' || test -e '$T/distro/rootfs/sbin/$req_applet' || \
			 test -L '$T/distro/rootfs/usr/bin/$req_applet' || test -e '$T/distro/rootfs/usr/bin/$req_applet'"
	done
	if "$BB" --list 2>/dev/null | grep -qx mountpoint; then
		check "prebuilt rootfs provides mountpoint applet" sh -c \
			"test -L '$T/distro/rootfs/bin/mountpoint' || test -e '$T/distro/rootfs/bin/mountpoint' || \
			 test -L '$T/distro/rootfs/usr/bin/mountpoint' || test -e '$T/distro/rootfs/usr/bin/mountpoint'"
	else
		pass "mountpoint skipped cleanly when absent from prebuilt busybox --list"
	fi
	check "init.conf removes firstboot fallback shell" sh -c \
		"grep -q '^firstboot:once:.*/usr/bin/sane-firstboot'\'':requires=recovery:on_fail=rescue:timeout=0\$' '$T/distro/rootfs/etc/init.conf' && \
		 ! grep -q '^firstboot:.*exec /bin/sh -i' '$T/distro/rootfs/etc/init.conf'"
	check "init.conf supervises network dhcp -f after firstboot" sh -c \
		"grep -q '^network:respawn:.*sane-net dhcp -f eth0.*:requires=firstboot\$' '$T/distro/rootfs/etc/init.conf'"

	# P1-19: BusyBox cpio compatibility (no --quiet) and fail-closed cpio errors.
	mkdir -p "$T/bbcpio-bin"
	cat > "$T/bbcpio-bin/cpio" <<EOF
#!/bin/sh
for arg in "\$@"; do
    case "\$arg" in
        --quiet|--owner*) printf 'cpio: unrecognized option %s\n' "\$arg" >&2; exit 1 ;;
    esac
done
exec "$BB" cpio "\$@"
EOF
	chmod 0755 "$T/bbcpio-bin/cpio"
	if PATH="$T/bbcpio-bin:$PATH" ROOTFS="$T/distro/rootfs" INITRAMFS="$T/bb-initramfs.cpio.gz" \
		sh -c 'BUILD_ROOTFS_LIB_ONLY=1 . "'"$BUILD"'"; pack_initramfs' >"$T/bbcpio.log" 2>&1; then
		pass "pack_initramfs succeeds with BusyBox cpio (no --quiet/--owner)"
	else
		fail "pack_initramfs succeeds with BusyBox cpio (no --quiet/--owner)"
	fi
	check "BusyBox cpio initramfs is valid gzip" gzip -t "$T/bb-initramfs.cpio.gz"
	cat > "$T/bbcpio-bin/cpio" <<'EOF'
#!/bin/sh
exit 1
EOF
	chmod 0755 "$T/bbcpio-bin/cpio"
	expect_fail "pack_initramfs fails closed when cpio fails" \
		env PATH="$T/bbcpio-bin:$PATH" ROOTFS="$T/distro/rootfs" INITRAMFS="$T/fail-initramfs.cpio.gz" \
		sh -c 'BUILD_ROOTFS_LIB_ONLY=1 . "'"$BUILD"'"; pack_initramfs'
	check "failed pack_initramfs leaves no empty gzip artifact" test ! -e "$T/fail-initramfs.cpio.gz"

	# X3: the network:once service must find its CLI applets in the image.
	check "rootfs has executable sane-net" test -x "$T/distro/rootfs/usr/bin/sane-net"
	check "rootfs has executable sane-ctl" test -x "$T/distro/rootfs/usr/bin/sane-ctl"
	# X12: an unprivileged build must warn loudly; it may not silently leave a
	# builder-owned rootfs with an ineffective setuid doas.
	if [ "${SUDO_USER:-}" != "" ] || [ "$(id -u)" -eq 0 ]; then
		printf 'ok   - non-root ownership warning check skipped (already privileged)\n'
		PASS=$((PASS+1))
	else
		check "non-root build warns about rootfs ownership" \
			grep -q 'WARNING: rootfs ownership' "$T/build.log"
	fi

	# --- Part C: QEMU NIC / DHCP lease marker (X3, executed boot) ------------
	if command -v qemu-system-x86_64 >/dev/null 2>&1 && \
	   [ -r "$REPO_ROOT/packages/kernel/x/boot/vmlinuz-virt" ]; then
		QD="$T/qemu-distro"
		if DISTRO_DIR="$QD" ROOTFS="$QD/rootfs" INITRAMFS="$QD/initramfs.cpio.gz" \
			SANE_WEAK_DEFAULT_CREDS=1 \
			BUSYBOX_MODE=prebuilt BUSYBOX_PREBUILT="$BB" NINIT="$NINIT" \
			sh "$BUILD" >"$T/qemu-build.log" 2>&1; then
			pass "QEMU scenario rootfs build succeeds"
		else
			fail "QEMU scenario rootfs build succeeds"
		fi
		# TCG boot with the pinned virt kernel and an e1000 NIC; host kernel
		# has no e1000 module, so KERNEL override is mandatory.
		KERNEL="$REPO_ROOT/packages/kernel/x/boot/vmlinuz-virt" \
		EXTRA_QEMU_ARGS="-nic user,model=e1000" SECS=45 \
		CONSOLE_LOG="$T/qemu-console.log" DISTRO_DIR="$QD" ROOTFS="$QD/rootfs" \
		INITRAMFS="$QD/initramfs.cpio.gz" \
			sh "$REPO_ROOT/scripts/run-qemu.sh" >"$T/qemu-run.log" 2>&1 || true
		check "QEMU boot report passes" grep -q '^RESULT: PASS' "$T/qemu-run.log"
		check "guest console has no 'sane-net: not found'" sh -c \
			"! grep -q 'sane-net: not found' '$T/qemu-console.log'"
		check "guest console shows udhcpc lease marker" \
			grep -q 'lease of 10.0.2.15 obtained' "$T/qemu-console.log"
		check "guest console shows network dhcp was not exited/SIGKILLed by ninit" sh -c \
			"! grep -q 'network (pid [0-9]*) exit status' '$T/qemu-console.log'"
	else
		printf 'SKIP - qemu-system-x86_64 or pinned virt kernel unavailable\n'
	fi

	# --- Part C2: ownership under a sudo build (X12) -------------------------
	if sudo -n true 2>/dev/null; then
		SDIR="$T/sudo-distro"
		mkdir -p "$SDIR"
		# The build log lives in the caller-owned temp dir, not a root-only path.
		# shellcheck disable=SC2024
		if sudo -n env DISTRO_DIR="$SDIR/distro" ROOTFS="$SDIR/distro/rootfs" \
			INITRAMFS="$SDIR/distro/initramfs.cpio.gz" \
			BUSYBOX_MODE=prebuilt BUSYBOX_PREBUILT="$BB" NINIT="$NINIT" \
			sh "$BUILD" >"$T/sudo-build.log" 2>&1; then
			pass "sudo rootfs build succeeds"
		else
			fail "sudo rootfs build succeeds"
		fi
		check "sudo build leaves doas root-owned setuid 4755" sh -c \
			"test \"\$(stat -c '%u:%g %a' '$SDIR/distro/rootfs/usr/bin/doas' 2>/dev/null)\" = '0:0 4755'"
		check "sudo build leaves shadow root-owned 0600" sh -c \
			"test \"\$(stat -c '%u:%g %a' '$SDIR/distro/rootfs/etc/shadow' 2>/dev/null)\" = '0:0 600'"
		sudo -n rm -rf "$SDIR"
	else
		printf 'SKIP - passwordless sudo unavailable for ownership variant\n'
	fi
else
	printf 'SKIP - no static busybox available for the end-to-end prebuilt build\n'
fi

printf '\nBuild-rootfs tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
