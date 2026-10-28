#!/bin/sh
# build-rootfs.sh -- rootfs minimal distro ninit: busybox statis + ninit sebagai
# /sbin/init, dibungkus menjadi initramfs cpio.gz yang siap di-boot QEMU
# (lihat scripts/run-qemu.sh).
#
# Pemakaian:
#   sh ./scripts/build-rootfs.sh
#   BUSYBOX_MODE=prebuilt sh ./scripts/build-rootfs.sh   # pakai /bin/busybox (cepat)
#   BUSYBOX_FORCE=1 JOBS=4 sh ./scripts/build-rootfs.sh  # paksa kompilasi ulang
#
# Variabel:
#   DISTRO_DIR=distro        direktori kerja (cache/, build/, rootfs/, initramfs)
#   ROOTFS=$DISTRO_DIR/rootfs
#   BB_VERSION=1.36.1        versi busybox sumber
#   BB_SHA256=<hash>         checksum tarball resmi; kosongkan untuk melewati
#   BUSYBOX_MODE=auto        auto | source | prebuilt
#   BUSYBOX_PREBUILT=/bin/busybox   busybox statis cadangan (busybox-static)
#   NINIT=./ninit            biner yang dipasang sebagai /sbin/init
#   JOBS=$(nproc)            jumlah job make
#
# Butuh: gcc + libc statis, curl, tar, bzip2, cpio; root untuk mknod /dev.
#
# Catatan: langkah busybox diminta eksplisit (make defconfig, make LDFLAGS=-static,
# make install). Karena defconfig busybox tidak mengaktifkan CONFIG_STATIC,
# script juga menyetelnya supaya hasilnya dijamin statis walau LDFLAGS diabaikan
# oleh tahap link mana pun.

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
HOSTNAME_NAME=${HOSTNAME_NAME:-ninit-distro}

log()  { printf '== %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die()  { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }
need() {
	command -v "$1" >/dev/null 2>&1 || die "perkakas '$1' tidak ditemukan${2:+ ($2)}"
}
is_static() {
	# Biner statis tidak punya segmen INTERP (butuh loader dinamis).
	! readelf -l "$1" 2>/dev/null | grep -q INTERP
}

download() { # $1 = url, $2 = tujuan
	mkdir -p "$(dirname -- "$2")"
	if [ -s "$2" ] && [ "$BUSYBOX_FORCE" != 1 ]; then
		info "pakai berkas yang sudah ada: $2"
		return 0
	fi
	info "unduh $1"
	curl -fL --retry 3 --connect-timeout 15 -o "$2.part" "$1" \
		|| die "unduhan gagal: $1"
	mv "$2.part" "$2"
}

# --------------------------------------------------------------- busybox
build_busybox_source() {
	src=$BUILD_DIR/busybox-$BB_VERSION
	tarball=$CACHE_DIR/busybox-$BB_VERSION.tar.bz2

	download "$BB_URL" "$tarball"
	if [ -n "$BB_SHA256" ]; then
		actual=$(sha256sum "$tarball" | cut -d' ' -f1)
		[ "$actual" = "$BB_SHA256" ] || die "checksum busybox tidak cocok:
  diharapkan $BB_SHA256
  didapat    $actual"
		info "checksum tarball cocok (sha256)"
	else
		info "verifikasi checksum dilewati (BB_SHA256 kosong)"
	fi

	if [ ! -d "$src" ] || [ "$BUSYBOX_FORCE" = 1 ]; then
		mkdir -p "$BUILD_DIR"
		rm -rf "$src"
		info "ekstrak tarball ke $BUILD_DIR"
		tar -xjf "$tarball" -C "$BUILD_DIR" || die "ekstrak tarball gagal"
	fi

	if [ ! -f "$src/.config" ] || [ "$BUSYBOX_FORCE" = 1 ]; then
		info "make defconfig"
		( cd "$src" && make defconfig >/dev/null )
		sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' "$src/.config"
		grep -q '^CONFIG_STATIC=y' "$src/.config" \
			|| die "CONFIG_STATIC tidak bisa diaktifkan di .config busybox"
		( cd "$src" && make oldconfig >/dev/null 2>&1 </dev/null ) || true
	fi

	info "kompilasi busybox $BB_VERSION statis dengan $JOBS job (1-3 menit)..."
	( cd "$src" && make -j"$JOBS" LDFLAGS="-static" ) \
		|| die "kompilasi busybox gagal (lihat keluaran make di atas)"
	[ -x "$src/busybox" ] || die "biner busybox tidak dihasilkan"

	if ! is_static "$src/busybox"; then
		info "PERINGATAN: busybox hasil kompilasi tidak statis"
		return 1
	fi

	info "make install -> $PKG_INSTALL"
	rm -rf "$PKG_INSTALL"
	( cd "$src" && make CONFIG_PREFIX="$PKG_INSTALL" install >/dev/null ) \
		|| die "make install busybox gagal"
	BUSYBOX_BIN=$src/busybox
	return 0
}

use_prebuilt_busybox() {
	[ -x "$BUSYBOX_PREBUILT" ] || die "busybox cadangan '$BUSYBOX_PREBUILT' tidak ada"
	is_static "$BUSYBOX_PREBUILT" \
		|| die "busybox cadangan '$BUSYBOX_PREBUILT' tidak statis (pasang paket busybox-static)"
	BUSYBOX_BIN=$BUSYBOX_PREBUILT
	info "pakai busybox statis yang sudah ada: $BUSYBOX_BIN"
}

resolve_busybox() {
	case $BUSYBOX_MODE in
	source)
		build_busybox_source ;;
	prebuilt)
		use_prebuilt_busybox ;;
	auto)
		if build_busybox_source; then :; else
			info "kompilasi sumber tidak menghasilkan biner statis, beralih ke busybox cadangan"
			use_prebuilt_busybox
		fi ;;
	*)
		die "BUSYBOX_MODE='$BUSYBOX_MODE' tidak dikenal (auto|source|prebuilt)" ;;
	esac
	info "busybox: $BUSYBOX_BIN ($(du -h "$BUSYBOX_BIN" | cut -f1))"
}

install_busybox() {
	if [ -n "${PKG_INSTALL:-}" ] && [ -d "$PKG_INSTALL" ]; then
		# Hasil `make install`: pohon bin/sbin/usr lengkap dengan symlink applet.
		cp -a "$PKG_INSTALL"/. "$ROOTFS"/
	else
		cp "$BUSYBOX_BIN" "$ROOTFS/bin/busybox"
	fi
	[ -x "$ROOTFS/bin/busybox" ] || die "/bin/busybox tidak terpasang di rootfs"
	APPLET_LIST=$("$ROOTFS/bin/busybox" --list 2>/dev/null || true)

	# Symlink standar yang wajib ada; lewati applet yang tidak dikompilasi.
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
	# /bin/sh wajib: ninit mengeksekusi setiap perintah layanan lewat /bin/sh -c.
	[ -e "$ROOTFS/bin/sh" ] || ln -s /bin/busybox "$ROOTFS/bin/sh"
	[ -x "$ROOTFS/bin/sh" ] || die "/bin/sh tidak ada di rootfs"
}

link_applet() { # $1 = bin|sbin, $2 = nama applet
	d=$ROOTFS/$1
	a=$2
	[ -e "$d/$a" ] && return 0
	if [ -n "${APPLET_LIST:-}" ] \
	   && ! printf '%s\n' "$APPLET_LIST" | grep -qx "$a"; then
		return 0   # applet tidak ada di build ini
	fi
	ln -s /bin/busybox "$d/$a"
}

# --------------------------------------------------------------- rootfs
make_dirs() {
	log "menyiapkan struktur direktori rootfs"
	mkdir -p "$ROOTFS/bin" "$ROOTFS/sbin" "$ROOTFS/etc" \
	         "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" \
	         "$ROOTFS/tmp" "$ROOTFS/var/log" \
	         "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin"
	# /run wajib: tmpfs-nya dipasang ninit dan FIFO kontrol dibuat di sana.
	# /root hanya untuk direktori home user root pada /etc/passwd.
	chmod 1777 "$ROOTFS/tmp"
	mkdir -p "$ROOTFS/run" "$ROOTFS/root"
}

make_dev_nodes() {
	if [ "$(id -u)" != 0 ]; then
		info "bukan root: /dev/{console,null,tty} dilewati (devtmpfs tetap dipasang ninit)"
		return 0
	fi
	# Node awal supaya console kernel dan ninit punya /dev/console sejak detik
	# pertama, sebelum setup_pseudo_fs() memasang devtmpfs.
	[ -e "$ROOTFS/dev/console" ] || mknod -m 0600 "$ROOTFS/dev/console" c 5 1
	[ -e "$ROOTFS/dev/null" ]    || mknod -m 0666 "$ROOTFS/dev/null"    c 1 3
	[ -e "$ROOTFS/dev/tty" ]     || mknod -m 0666 "$ROOTFS/dev/tty"     c 5 0
}

install_wrappers() {
	log "memasang wrapper /sbin/{poweroff,reboot,halt} -> /run/initctl"
	# PENTING: di rootfs, /sbin/poweroff (dan reboot/halt) adalah SYMLINK ke
	# ../bin/busybox. Tanpa rm -f lebih dulu, `cat > file` akan menulis
	# MENEMBUS symlink itu dan merusak biner busybox. Hapus symlink dulu, baru
	# tulis berkas asli.
	for a in poweroff reboot halt; do
		rm -f "$ROOTFS/sbin/$a"
	done

	# Applet BusyBox mengirim SIGUSR1/SIGUSR2/SIGTERM, sedangkan tabel sinyal
	# ninit memetakan SIGUSR2 -> force reboot. Jadi `poweroff` bawaan BusyBox
	# justru me-reboot mesin. Wrapper ini lewat jalur resmi /run/initctl supaya
	# semantiknya sesuai nama perintah.
	cat > "$ROOTFS/sbin/poweroff" <<'EOF'
#!/bin/sh
# Matikan mesin dengan rapi (grace 5 detik) lewat /run/initctl.
echo poweroff > /run/initctl
EOF

	cat > "$ROOTFS/sbin/reboot" <<'EOF'
#!/bin/sh
# Reboot mesin dengan rapi lewat /run/initctl.
echo reboot > /run/initctl
EOF

	cat > "$ROOTFS/sbin/halt" <<'EOF'
#!/bin/sh
# Hentikan mesin segera (force poweroff, layanan langsung SIGKILL).
echo force-poweroff > /run/initctl
EOF

	chmod 0755 "$ROOTFS/sbin/poweroff" "$ROOTFS/sbin/reboot" "$ROOTFS/sbin/halt"
	for a in poweroff reboot halt; do
		[ -x "$ROOTFS/sbin/$a" ] || die "wrapper /sbin/$a tidak executable"
	done

	# Alias applet busybox di direktori PATH lain akan menang atas wrapper
	# /sbin bila urutan PATH berubah: buang supaya hanya wrapper yang terpakai.
	for d in bin usr/bin usr/sbin; do
		for a in poweroff reboot halt; do
			if [ -e "$ROOTFS/$d/$a" ]; then
				info "hapus alias busybox $d/$a (digantikan wrapper /sbin/$a)"
				rm -f "$ROOTFS/$d/$a"
			fi
		done
	done
	info "poweroff -> poweroff | reboot -> reboot | halt -> force-poweroff"
}

install_ninit() {
	log "memasang ninit sebagai /sbin/init"
	[ -x "$NINIT" ] || ( cd "$REPO_ROOT" && make ) \
		|| die "biner ninit belum ada dan build gagal (jalankan: make)"
	[ -x "$NINIT" ] || die "'$NINIT' tidak executable"
	install -m 0755 "$NINIT" "$ROOTFS/sbin/init"
	if ! is_static "$NINIT"; then
		info "PERINGATAN: $NINIT tidak statis; di initramfs ia butuh loader dinamis"
	fi
}

write_etc() {
	log "menulis /etc (init.conf, passwd, group, hostname, fstab)"
	# Catatan penting: ninit menyalakan layanan dengan stdin = /dev/null dan
	# stdout/stderr = /run/log.fifo (lihat spawn_service() di ninit.c). Jadi
	# `shell:respawn:/bin/sh` polos akan langsung kena EOF dan respawn tiap 2
	# detik, bukan jadi shell konsol. Karena setiap perintah dijalankan lewat
	# `/bin/sh -c`, redireksi di bawah ini menempelkan shell ke console dan
	# menyalurkan stdout/stderr-nya ke sana juga:
	#   <> /dev/console   buka console read-write sebagai stdin
	#   >&0 2>&0          stdout & stderr mengikuti stdin (console)
	cat > "$ROOTFS/etc/init.conf" <<'EOF'
# /etc/init.conf -- rootfs distro ninit
#
# Layanan dijalankan lewat `/bin/sh -c` dengan stdin /dev/null dan
# stdout/stderr /run/log.fifo (bawaan ninit). Versi harfiah
# `console:respawn:/bin/sh` bukan pilihan: tanpa redireksi, stdin /dev/null =
# EOF seketika -> shell keluar dan di-respawn terus.
#
# cttyhack: ninit memanggil setsid() di anak (tanpa controlling tty), jadi
# shell -i akan mengeluh "can't access tty; job control turned off". cttyhack
# membuka /dev/console, menjadikannya controlling tty (TIOCSCTTY), lalu
# meneruskan kendali ke shell sehingga job control (Ctrl-C, jobs, fg) normal.
console:respawn:cttyhack /bin/sh -i
EOF

	cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

	cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF

	printf '%s\n' "$HOSTNAME_NAME" > "$ROOTFS/etc/hostname"

	# Hanya komentar: ninit sendiri sudah memasang proc/sysfs/devtmpfs/tmpfs,
	# jadi tidak ada baris fstab yang diperlukan. Berkas ini ada supaya tidak
	# muncul "fstab: /etc/fstab tidak ada, dilewati" di konsol boot.
	cat > "$ROOTFS/etc/fstab" <<'EOF'
# /etc/fstab -- kosong secara sengaja.
# proc /proc proc defaults
# sysfs /sys sysfs defaults
EOF
}

pack_initramfs() {
	log "membungkus rootfs menjadi initramfs ($INITRAMFS)"
	mkdir -p "$(dirname -- "$INITRAMFS")"
	if command -v cpio >/dev/null 2>&1; then
		CPIO_CMD="cpio"
	else
		CPIO_CMD="$ROOTFS/bin/busybox cpio"
	fi
	# shellcheck disable=SC2016
	( cd "$ROOTFS" && find . -print | $CPIO_CMD -o -H newc --quiet ) \
		| gzip -9 > "$INITRAMFS" || die "pembuatan initramfs gagal"
	[ -s "$INITRAMFS" ] || die "initramfs kosong"
}

summary() {
	log "selesai"
	info "rootfs     : $ROOTFS"
	info "initramfs  : $INITRAMFS ($(du -h "$INITRAMFS" | cut -f1), sha256 $(sha256sum "$INITRAMFS" | cut -c1-16)…)"
	info "busybox    : $(du -h "$ROOTFS/bin/busybox" | cut -f1) statis, $(printf '%s\n' "${APPLET_LIST:-}" | grep -c . ) applet"
	info "init       : $(ls -l "$ROOTFS/sbin/init" | awk '{print $5" bytes"}') (ninit v1.0.0)"
	info "init.conf  : $(grep -v '^#' "$ROOTFS/etc/init.conf" | grep . | head -n 1)"
	info "boot di QEMU: sh ./scripts/run-qemu.sh"
}

need gcc "build-essential"
need make "build-essential"
need curl
need tar
need sha256sum "coreutils"
need readelf "binutils"
need gzip
need du "coreutils"
need install "coreutils"
if [ "$BUSYBOX_MODE" != prebuilt ]; then
	command -v bzip2 >/dev/null 2>&1 || need bzip2 "untuk tarball .tar.bz2"
fi

mkdir -p "$CACHE_DIR" "$BUILD_DIR"
log "distro dir : $DISTRO_DIR"
log "mode       : BUSYBOX_MODE=$BUSYBOX_MODE, JOBS=$JOBS"

resolve_busybox

# Rootfs selalu dibangun ulang dari nol supaya isinya deterministik, kecuali
# hasil kompilasi busybox di build/ dan cache unduhan.
log "mengosongkan rootfs lama"
rm -rf "$ROOTFS"
make_dirs
install_busybox
install_wrappers
make_dev_nodes
install_ninit
write_etc
pack_initramfs
summary
