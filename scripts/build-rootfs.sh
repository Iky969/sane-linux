#!/bin/sh
# build-rootfs.sh -- minimal S.A.N.E distro rootfs: static busybox + ninit as
# /sbin/init, packed into a cpio.gz initramfs ready to boot in QEMU
# (see scripts/run-qemu.sh).
#
# Pemakaian:
#   sh ./scripts/build-rootfs.sh
#   BUSYBOX_MODE=prebuilt sh ./scripts/build-rootfs.sh   # use /bin/busybox (fast)
#   BUSYBOX_FORCE=1 JOBS=4 sh ./scripts/build-rootfs.sh  # force a rebuild
#
# Variabel:
#   DISTRO_DIR=distro        working directory (cache/, build/, rootfs/, initramfs)
#   ROOTFS=$DISTRO_DIR/rootfs
#   BB_VERSION=1.36.1        busybox source version
#   BB_SHA256=<hash>         official tarball checksum; empty to skip
#   BUSYBOX_MODE=auto        auto | source | prebuilt
#   BUSYBOX_PREBUILT=/bin/busybox   fallback static busybox (busybox-static)
#   NINIT=./ninit            binary installed as /sbin/init
#   JOBS=$(nproc)            number of make jobs
#   EXTRA_INIT_CONF=<file>   file contents appended to the resulting /etc/init.conf
#   EXTRA_FSTAB=<file>       file contents appended to the resulting /etc/fstab
#                            (both for scripts/test-integration.sh)
#
# Requires: gcc + static libc, curl, tar, bzip2, cpio; root for mknod /dev.
#
# Note: the busybox steps are requested explicitly (make defconfig, make
# LDFLAGS=-static, make install). Because busybox's defconfig does not enable
# CONFIG_STATIC, the script also sets it so the result is guaranteed static even
# if some link stage ignores LDFLAGS. CONFIG_TC is disabled: tc.c still uses CBQ
# definitions that no longer exist in recent kernel headers, and that applet is
# not used by this rootfs. With BUSYBOX_MODE=auto, a failure of the source build
# (download, compile, install) drops the script back to the fallback busybox;
# BUSYBOX_MODE=source demands success.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

DISTRO_DIR=${DISTRO_DIR:-$REPO_ROOT/distro}
CACHE_DIR=${CACHE_DIR:-$DISTRO_DIR/cache}
BUILD_DIR=${BUILD_DIR:-$DISTRO_DIR/build}
ROOTFS=${ROOTFS:-$DISTRO_DIR/rootfs}
INITRAMFS=${INITRAMFS:-$DISTRO_DIR/initramfs.cpio.gz}
PKG_INSTALL=$BUILD_DIR/busybox-install

BB_VERSION=${BB_VERSION:-1.36.1}
BB_URL=${BB_URL:-https://busybox.net/downloads/busybox-$BB_VERSION.tar.bz2}
BB_SHA256=${BB_SHA256:-b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314}
BUSYBOX_MODE=${BUSYBOX_MODE:-auto}
BUSYBOX_PREBUILT=${BUSYBOX_PREBUILT:-/bin/busybox}
BUSYBOX_FORCE=${BUSYBOX_FORCE:-0}
NINIT=${NINIT:-$REPO_ROOT/ninit}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}
HOSTNAME_NAME=${HOSTNAME_NAME:-S.A.N.E}

log()  { printf '== %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# A failure inside build_busybox_source(): reported as-is and then returns 1,
# so BUSYBOX_MODE=auto can still fall back to the fallback busybox.
# BUSYBOX_MODE=source demands it hard (see resolve_busybox).
bb_fail() { printf '   busybox source build failed: %s\n' "$1" >&2; return 1; }
need() {
	command -v "$1" >/dev/null 2>&1 || die "tool '$1' not found${2:+ ($2)}"
}
is_static() {
	# A static binary has no INTERP segment (it needs a dynamic loader).
	! readelf -l "$1" 2>/dev/null | grep -q INTERP
}

download() { # $1 = url, $2 = destination
	mkdir -p "$(dirname -- "$2")"
	if [ -s "$2" ] && [ "$BUSYBOX_FORCE" != 1 ]; then
		info "using existing file: $2"
		return 0
	fi
	info "download $1"
	if ! curl -fL --retry 3 --connect-timeout 15 -o "$2.part" "$1"; then
		rm -f "$2.part"
		info "download failed: $1"
		return 1
	fi
	mv "$2.part" "$2"
}

# Write one BusyBox .config option: $2 = y enables it, n disables it. Other
# options that depend on it are tidied by `make oldconfig` afterwards.
set_bb_config() { # $1 = .config file, $2 = CONFIG_*, $3 = y | n
	sed -i -e "/^$2=y\$/d" -e "/^# $2 is not set\$/d" "$1"
	if [ "$3" = y ]; then
		printf '%s=y\n' "$2" >> "$1"
	else
		printf '# %s is not set\n' "$2" >> "$1"
	fi
}

# --------------------------------------------------------------- busybox
build_busybox_source() {
	src=$BUILD_DIR/busybox-$BB_VERSION
	tarball=$CACHE_DIR/busybox-$BB_VERSION.tar.bz2

	download "$BB_URL" "$tarball" || return 1
	if [ -n "$BB_SHA256" ]; then
		actual=$(sha256sum "$tarball" | cut -d' ' -f1)
		[ "$actual" = "$BB_SHA256" ] || die "busybox checksum mismatch:
  expected $BB_SHA256
  got      $actual"
		info "tarball checksum matches (sha256)"
	else
		info "checksum verification skipped (BB_SHA256 empty)"
	fi

	if [ ! -d "$src" ] || [ "$BUSYBOX_FORCE" = 1 ]; then
		mkdir -p "$BUILD_DIR"
		rm -rf "$src"
		info "extracting tarball into $BUILD_DIR"
		tar -xjf "$tarball" -C "$BUILD_DIR" || { bb_fail "tarball extraction failed"; return 1; }
	fi

	if [ ! -f "$src/.config" ]; then
		info "make defconfig"
		( cd "$src" && make defconfig >/dev/null ) || { bb_fail "make defconfig failed"; return 1; }
	fi

	# This option is written on every run, not only when .config is created, so a
	# rebuild from a previous run's tree is fixed too.
	# - CONFIG_STATIC: defconfig does not enable it; without this the result is dynamic.
	# - CONFIG_TC is disabled because networking/tc.c still uses CBQ definitions
	#   (TCA_CBQ_*, struct tc_cbq_*) that no longer exist in recent kernel headers;
	#   on Ubuntu 24.04 the defconfig build fails completely because of this. The
	#   `tc` applet is not used by this rootfs.
	[ -f "$src/.config" ] || { bb_fail "make defconfig did not produce a .config"; return 1; }
	set_bb_config "$src/.config" CONFIG_STATIC y
	set_bb_config "$src/.config" CONFIG_TC n
	( cd "$src" && make oldconfig >/dev/null 2>&1 </dev/null ) || true
	grep -q '^CONFIG_STATIC=y' "$src/.config" \
		|| { bb_fail "CONFIG_STATIC could not be enabled in the busybox .config"; return 1; }

	info "compiling busybox $BB_VERSION statically with $JOBS jobs (1-3 minutes)..."
	( cd "$src" && make -j"$JOBS" LDFLAGS="-static" ) \
		|| { bb_fail "busybox compilation failed (see the make output above)"; return 1; }
	[ -x "$src/busybox" ] || { bb_fail "busybox binary was not produced"; return 1; }

	if ! is_static "$src/busybox"; then
		info "WARNING: the compiled busybox is not static"
		return 1
	fi

	info "make install -> $PKG_INSTALL"
	rm -rf "$PKG_INSTALL"
	( cd "$src" && make CONFIG_PREFIX="$PKG_INSTALL" install >/dev/null ) \
		|| { bb_fail "make install busybox failed"; return 1; }
	BUSYBOX_BIN=$src/busybox
	return 0
}

use_prebuilt_busybox() {
	[ -x "$BUSYBOX_PREBUILT" ] || die "fallback busybox '$BUSYBOX_PREBUILT' not found"
	is_static "$BUSYBOX_PREBUILT" \
		|| die "fallback busybox '$BUSYBOX_PREBUILT' is not static (install the busybox-static package)"
	# A previous run's `make install` tree is not part of the fallback busybox.
	# Without this, install_busybox() would silently install the stale source build
	# in $BUILD_DIR even though this run uses BUSYBOX_PREBUILT.
	PKG_INSTALL=
	BUSYBOX_BIN=$BUSYBOX_PREBUILT
	info "using existing static busybox: $BUSYBOX_BIN"
}

resolve_busybox() {
	case $BUSYBOX_MODE in
	source)
		build_busybox_source \
			|| die "BUSYBOX_MODE=source: the source build failed and there is no fallback" ;;
	prebuilt)
		use_prebuilt_busybox ;;
	auto)
		if build_busybox_source; then :; else
			info "source build failed, falling back to the prebuilt busybox"
			use_prebuilt_busybox
		fi ;;
	*)
		die "BUSYBOX_MODE='$BUSYBOX_MODE' unknown (auto|source|prebuilt)" ;;
	esac
	info "busybox: $BUSYBOX_BIN ($(du -h "$BUSYBOX_BIN" | cut -f1))"
}

install_busybox() {
	if [ -n "${PKG_INSTALL:-}" ] && [ -d "$PKG_INSTALL" ]; then
		# Result of `make install`: a complete bin/sbin/usr tree with applet symlinks.
		cp -a "$PKG_INSTALL"/. "$ROOTFS"/
	else
		cp "$BUSYBOX_BIN" "$ROOTFS/bin/busybox"
	fi
	[ -x "$ROOTFS/bin/busybox" ] || die "/bin/busybox is not installed in the rootfs"
	APPLET_LIST=$("$ROOTFS/bin/busybox" --list 2>/dev/null || true)

	# Standard symlinks that must exist; skip applets that were not compiled.
	for a in sh ash cat chmod chown cp cut date dd df dirname dmesg \
	         du echo env expr false find grep head hostname id kill \
	         ln ls mkdir mknod more mount mv od printf ps pwd readlink \
	         realpath rm rmdir sed seq sleep sort stat sync tail tar tee \
	         touch tr true umount uname uniq wc wget xargs; do
		link_applet bin "$a"
	done
	for a in fdisk getty halt ifconfig ip login mdev mkswap modprobe \
	         insmod lsmod poweroff reboot route switch_root sysctl udhcpc; do
		link_applet sbin "$a"
	done
	# /bin/sh is required: ninit executes every service command through /bin/sh -c.
	[ -e "$ROOTFS/bin/sh" ] || ln -s /bin/busybox "$ROOTFS/bin/sh"
	[ -x "$ROOTFS/bin/sh" ] || die "/bin/sh is missing from the rootfs"
}

link_applet() { # $1 = bin|sbin, $2 = applet name
	d=$ROOTFS/$1
	a=$2
	[ -e "$d/$a" ] && return 0
	if [ -n "${APPLET_LIST:-}" ] \
	   && ! printf '%s\n' "$APPLET_LIST" | grep -qx "$a"; then
		return 0   # applet is absent from this build
	fi
	ln -s /bin/busybox "$d/$a"
}

# --------------------------------------------------------------- rootfs
make_dirs() {
	log "preparing the rootfs directory structure"
	mkdir -p "$ROOTFS/bin" "$ROOTFS/sbin" "$ROOTFS/etc" \
	         "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" \
	         "$ROOTFS/tmp" "$ROOTFS/var/log" \
	         "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin"
	# /run is required: ninit mounts its tmpfs there and creates the control FIFOs.
	# /root is only for the root user's home directory in /etc/passwd.
	chmod 1777 "$ROOTFS/tmp"
	mkdir -p "$ROOTFS/run" "$ROOTFS/root"
}

make_dev_nodes() {
	if [ "$(id -u)" != 0 ]; then
		info "not root: /dev/{console,null,tty} skipped (devtmpfs is still mounted by ninit)"
		return 0
	fi
	# Initial nodes so the kernel console and ninit have /dev/console from the very
	# first second, before setup_pseudo_fs() mounts devtmpfs.
	[ -e "$ROOTFS/dev/console" ] || mknod -m 0600 "$ROOTFS/dev/console" c 5 1
	[ -e "$ROOTFS/dev/null" ]    || mknod -m 0666 "$ROOTFS/dev/null"    c 1 3
	[ -e "$ROOTFS/dev/tty" ]     || mknod -m 0666 "$ROOTFS/dev/tty"     c 5 0
}

install_wrappers() {
	log "installing /sbin/{poweroff,reboot,halt} wrappers -> /run/initctl"
	# IMPORTANT: in the rootfs, /sbin/poweroff (and reboot/halt) is a SYMLINK to
	# ../bin/busybox. Without an rm -f first, `cat > file` would write THROUGH
	# that symlink and corrupt the busybox binary. Remove the symlink first, then
	# write the real file.
	for a in poweroff reboot halt; do
		rm -f "$ROOTFS/sbin/$a"
	done

	# The BusyBox applet sends SIGUSR1/SIGUSR2/SIGTERM, while ninit's signal table
	# maps SIGUSR2 -> force reboot. So BusyBox's built-in `poweroff` actually
	# reboots the machine. This wrapper goes through the official /run/initctl path
	# so the semantics match the command name.
	cat > "$ROOTFS/sbin/poweroff" <<'EOF'
#!/bin/sh
# Shut the machine down cleanly (5 second grace) through /run/initctl.
echo poweroff > /run/initctl
EOF

	cat > "$ROOTFS/sbin/reboot" <<'EOF'
#!/bin/sh
# Reboot the machine cleanly through /run/initctl.
echo reboot > /run/initctl
EOF

	cat > "$ROOTFS/sbin/halt" <<'EOF'
#!/bin/sh
# Stop the machine immediately (force poweroff, services are SIGKILLed at once).
echo force-poweroff > /run/initctl
EOF

	chmod 0755 "$ROOTFS/sbin/poweroff" "$ROOTFS/sbin/reboot" "$ROOTFS/sbin/halt"
	for a in poweroff reboot halt; do
		[ -x "$ROOTFS/sbin/$a" ] || die "wrapper /sbin/$a is not executable"
	done

	# BusyBox applet aliases in other PATH directories would win over the /sbin
	# wrapper if the PATH order changed: remove them so only the wrapper is used.
	for d in bin usr/bin usr/sbin; do
		for a in poweroff reboot halt; do
			if [ -e "$ROOTFS/$d/$a" ]; then
				info "removing busybox alias $d/$a (replaced by the /sbin/$a wrapper)"
				rm -f "$ROOTFS/$d/$a"
			fi
		done
	done
	info "poweroff -> poweroff | reboot -> reboot | halt -> force-poweroff"
}

install_ninit() {
	log "installing ninit as /sbin/init"
	[ -x "$NINIT" ] || ( cd "$REPO_ROOT" && make ) \
		|| die "the ninit binary is missing and the build failed (run: make)"
	[ -x "$NINIT" ] || die "'$NINIT' is not executable"
	install -m 0755 "$NINIT" "$ROOTFS/sbin/init"
	if ! is_static "$NINIT"; then
		info "WARNING: $NINIT is not static; in an initramfs it needs a dynamic loader"
	fi
}

write_etc() {
	log "writing /etc (init.conf, passwd, group, hostname, fstab)"
	# Important note: ninit starts services with stdin = /dev/null and
	# stdout/stderr = /run/log.fifo (see spawn_service() in ninit.c). So a plain
	# `shell:respawn:/bin/sh` immediately hits EOF and respawns every 2 seconds
	# instead of becoming a console shell. Because every command runs through
	# `/bin/sh -c`, the redirections below attach the shell to the console and
	# route its stdout/stderr there as well:
	#   <> /dev/console   open the console read-write as stdin
	#   >&0 2>&0          stdout & stderr follow stdin (the console)
	cat > "$ROOTFS/etc/init.conf" <<'EOF'
# /etc/init.conf -- S.A.N.E distro rootfs
#
# Services run through `/bin/sh -c` with stdin /dev/null and
# stdout/stderr on /run/log.fifo (ninit defaults). The literal
# `console:respawn:/bin/sh` is not an option: without redirection, stdin /dev/null
# = immediate EOF -> the shell exits and is respawned forever.
#
# cttyhack: ninit calls setsid() in the child (no controlling tty), so an
# interactive shell would complain "can't access tty; job control turned off".
# cttyhack opens /dev/console, makes it the controlling tty (TIOCSCTTY), then
# hands control to the shell so job control (Ctrl-C, jobs, fg) works normally.
console:respawn:cttyhack /bin/sh -i
EOF

	cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

	cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF

	printf '%s\n' "$HOSTNAME_NAME" > "$ROOTFS/etc/hostname"

	# Comments only: ninit already mounts proc/sysfs/devtmpfs/tmpfs itself, so no
	# fstab entries are needed. This file exists so the boot console does not show
	# "fstab: /etc/fstab does not exist, skipped".
	cat > "$ROOTFS/etc/fstab" <<'EOF'
# /etc/fstab -- intentionally empty.
# proc /proc proc defaults
# sysfs /sys sysfs defaults
EOF

	# Integration test hook (scripts/test-integration.sh): extra files are appended
	# verbatim. Empty by default = the build behavior is unchanged.
	if [ -n "${EXTRA_INIT_CONF:-}" ]; then
		[ -r "$EXTRA_INIT_CONF" ] || die "EXTRA_INIT_CONF '$EXTRA_INIT_CONF' is not readable"
		printf '# --- EXTRA_INIT_CONF ---\n' >> "$ROOTFS/etc/init.conf"
		cat "$EXTRA_INIT_CONF" >> "$ROOTFS/etc/init.conf"
	fi
	if [ -n "${EXTRA_FSTAB:-}" ]; then
		[ -r "$EXTRA_FSTAB" ] || die "EXTRA_FSTAB '$EXTRA_FSTAB' is not readable"
		printf '# --- EXTRA_FSTAB ---\n' >> "$ROOTFS/etc/fstab"
		cat "$EXTRA_FSTAB" >> "$ROOTFS/etc/fstab"
	fi
}

pack_initramfs() {
	log "packing the rootfs into an initramfs ($INITRAMFS)"
	mkdir -p "$(dirname -- "$INITRAMFS")"
	if command -v cpio >/dev/null 2>&1; then
		CPIO_CMD="cpio"
	else
		CPIO_CMD="$ROOTFS/bin/busybox cpio"
	fi
	# shellcheck disable=SC2016
	CPIO_OWNER=
	if [ "$CPIO_CMD" = "cpio" ] && cpio --help 2>&1 | grep -q -- --owner; then
		CPIO_OWNER="--owner=+0:+0"
	fi
	( cd "$ROOTFS" && find . -print | $CPIO_CMD -o -H newc $CPIO_OWNER --quiet ) \
		| gzip -9 > "$INITRAMFS" || die "initramfs creation failed"
	[ -s "$INITRAMFS" ] || die "initramfs is empty"
}

summary() {
	log "done"
	info "rootfs     : $ROOTFS"
	info "initramfs  : $INITRAMFS ($(du -h "$INITRAMFS" | cut -f1), sha256 $(sha256sum "$INITRAMFS" | cut -c1-16)…)"
	info "busybox    : $(du -h "$ROOTFS/bin/busybox" | cut -f1) statis, $(printf '%s\n' "${APPLET_LIST:-}" | grep -c . ) applet"
	info "init       : $(ls -l "$ROOTFS/sbin/init" | awk '{print $5" bytes"}') (ninit v1.1.0)"
	info "init.conf  : $(grep -v '^#' "$ROOTFS/etc/init.conf" | grep . | head -n 1)"
	info "boot in QEMU: sh ./scripts/run-qemu.sh"
}

if [ "$BUSYBOX_MODE" != prebuilt ]; then
	need gcc "build-essential"
	need make "build-essential"
	need curl
elif [ ! -x "$NINIT" ]; then
	need gcc "build-essential"
	need make "build-essential"
fi
need tar
need sha256sum "coreutils"
need readelf "binutils"
need gzip
need du "coreutils"
need install "coreutils"
if [ "$BUSYBOX_MODE" != prebuilt ]; then
	command -v bzip2 >/dev/null 2>&1 || need bzip2 "for .tar.bz2 tarballs"
fi

mkdir -p "$CACHE_DIR" "$BUILD_DIR"
log "distro dir : $DISTRO_DIR"
log "mode       : BUSYBOX_MODE=$BUSYBOX_MODE, JOBS=$JOBS"

resolve_busybox

# The rootfs is always rebuilt from scratch so its contents are deterministic,
# except for the busybox build in build/ and the download cache.
log "clearing the old rootfs"
rm -rf "$ROOTFS"
make_dirs
install_busybox
install_wrappers
make_dev_nodes
install_ninit
write_etc
pack_initramfs
summary
