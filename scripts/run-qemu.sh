#!/bin/sh
# run-qemu.sh -- boot rootfs distro ninit (scripts/build-rootfs.sh) di QEMU
# dengan konsol serial, lalu periksa penanda boot ninit.
#
# Pemakaian:
#   sh ./scripts/run-qemu.sh            # interaktif; keluar dari QEMU: Ctrl-A X
#   SECS=5 sh ./scripts/run-qemu.sh     # boot 5 detik otomatis + laporan konsol
#
# Variabel:
#   KERNEL=/path/vmlinuz   kernel yang dipakai; default kernel host bila ada,
#                          kalau tidak: unduh Alpine vmlinuz-virt ke cache
#   KERNEL_MODE=auto       auto | host | alpine
#   ALPINE_BRANCH=v3.20    cabang Alpine untuk kernel unduhan
#   ALPINE_FLAVOR=virt     virt | lts
#   SECS=<detik>           mode otomatis (tanpa ini: interaktif)
#   MEM=256                RAM guest (MB)
#   NO_REBOOT=1            1 = QEMU keluar saat guest minta reboot (uji otomatis),
#                          0 = QEMU me-reset mesin sehingga restart ninit terlihat
#   REBUILD=1              bangun ulang rootfs + initramfs sebelum boot
#   CONSOLE_LOG=$DISTRO_DIR/qemu-console.log   keluaran konsol serial guest
#
# Butuh: qemu-system-x86_64 (apt-get install -y qemu-system-x86), curl, gzip.
#
# Catatan QEMU:
#   - Mode interaktif memakai `-nographic` (serial + monitor di stdio).
#   - Mode otomatis memakai `-display none -serial file:<log>` supaya keluaran
#     konsol guest terekam utuh tanpa bergantung pada TTY, dan prosesnya
#     dibatasi `timeout` selama $SECS detik.
#   - Kernel di-boot sebagai initramfs: `-kernel <vmlinuz> -initrd <cpio.gz>`
#     dengan `rdinit=/sbin/init init=/sbin/init` (dua-duanya diberikan supaya
#     init yang dipilih tidak tergantung varian kernel).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

DISTRO_DIR=${DISTRO_DIR:-$REPO_ROOT/distro}
CACHE_DIR=${CACHE_DIR:-$DISTRO_DIR/cache}
ROOTFS=${ROOTFS:-$DISTRO_DIR/rootfs}
INITRAMFS=${INITRAMFS:-$DISTRO_DIR/initramfs.cpio.gz}
CONSOLE_LOG=${CONSOLE_LOG:-$DISTRO_DIR/qemu-console.log}
QEMU_LOG=$DISTRO_DIR/qemu.log

KERNEL=${KERNEL:-}
KERNEL_MODE=${KERNEL_MODE:-auto}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.20}
ALPINE_FLAVOR=${ALPINE_FLAVOR:-virt}
SECS=${SECS:-}
MEM=${MEM:-256}
NO_REBOOT=${NO_REBOOT:-1}
REBUILD=${REBUILD:-0}
APPEND="console=ttyS0 rdinit=/sbin/init init=/sbin/init panic=-1 loglevel=7"

log()  { printf '== %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die()  { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "perkakas '$1' tidak ditemukan${2:+ ($2)}"; }

need qemu-system-x86_64 "apt-get install -y qemu-system-x86"
need timeout
need gzip
need sha256sum "coreutils"
need sleep "coreutils"

# --------------------------------------------------------------- kernel
host_kernel() {
	hk=/boot/vmlinuz-$(uname -r)
	[ -r "$hk" ] && { printf '%s' "$hk"; return 0; }
	return 1
}

resolve_kernel() {
	if [ -n "$KERNEL" ]; then
		[ -r "$KERNEL" ] || die "kernel '$KERNEL' tidak bisa dibaca"
		return 0
	fi
	case $KERNEL_MODE in
	host)
		KERNEL=$(host_kernel) || die "/boot/vmlinuz-$(uname -r) tidak ada (pakai KERNEL_MODE=alpine)"
		;;
	alpine)
		KERNEL=$CACHE_DIR/vmlinuz-$ALPINE_FLAVOR-$ALPINE_BRANCH
		;;
	auto)
		if KERNEL=$(host_kernel); then
			info "kernel host dipakai: $KERNEL"
		else
			info "kernel host (/boot/vmlinuz-$(uname -r)) tidak ada, beralih ke Alpine"
			KERNEL=$CACHE_DIR/vmlinuz-$ALPINE_FLAVOR-$ALPINE_BRANCH
		fi
		;;
	*)
		die "KERNEL_MODE='$KERNEL_MODE' tidak dikenal (auto|host|alpine)" ;;
	esac

	case $KERNEL in
	"$CACHE_DIR"/*)
		url="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/x86_64/netboot/vmlinuz-$ALPINE_FLAVOR"
		if [ ! -s "$KERNEL" ]; then
			log "mengunduh kernel Alpine ($ALPINE_BRANCH, $ALPINE_FLAVOR)"
			mkdir -p "$CACHE_DIR"
			curl -fL --retry 3 --connect-timeout 15 -o "$KERNEL.part" "$url" \
				|| die "unduhan kernel gagal: $url"
			mv "$KERNEL.part" "$KERNEL"
		fi
		size=$(wc -c < "$KERNEL")
		[ "$size" -gt 500000 ] || die "kernel hasil unduhan terlalu kecil ($size byte)"
		sha=$(sha256sum "$KERNEL" | cut -d' ' -f1)
		printf '%s  %s\n' "$sha" "$(basename "$KERNEL")" > "$KERNEL.sha256"
		info "kernel unduhan: $KERNEL ($(du -h "$KERNEL" | cut -f1), sha256 $(printf '%s' "$sha" | cut -c1-16)…)"
		;;
	esac
}

ensure_initramfs() {
	if [ "$REBUILD" = 1 ] || [ ! -s "$INITRAMFS" ]; then
		log "membangun rootfs + initramfs dulu"
		DISTRO_DIR=$DISTRO_DIR ROOTFS=$ROOTFS INITRAMFS=$INITRAMFS \
			sh "$SCRIPT_DIR/build-rootfs.sh"
	fi
	[ -s "$INITRAMFS" ] || die "initramfs '$INITRAMFS' tidak ada (jalankan: sh ./scripts/build-rootfs.sh)"
}

# --------------------------------------------------------------- QEMU
run_qemu() { # $1 = auto | interactive
	mode=$1
	if [ "$mode" = auto ]; then
		set -- -display none -serial "file:$CONSOLE_LOG"
	else
		set -- -nographic
	fi
	if [ -w /dev/kvm ] 2>/dev/null; then
		info "KVM tersedia: -enable-kvm -cpu host"
		set -- "$@" -enable-kvm -cpu host
	fi
	if [ "$NO_REBOOT" = 1 ]; then
		set -- "$@" -no-reboot
	else
		info "NO_REBOOT=0: guest reboot akan me-reset mesin (bukan keluar QEMU)"
	fi
	if [ "$mode" = auto ]; then
		exec timeout -k 2 "$SECS" qemu-system-x86_64 -m "$MEM" "$@" \
			-kernel "$KERNEL" -initrd "$INITRAMFS" -append "$APPEND"
	fi
	exec qemu-system-x86_64 -m "$MEM" "$@" \
		-kernel "$KERNEL" -initrd "$INITRAMFS" -append "$APPEND"
}

# --------------------------------------------------------------- laporan
mark_ms() { # $1 = penanda; cetak ms sejak $T0 bila ditemukan
	if grep -q "$1" "$CONSOLE_LOG" 2>/dev/null; then
		printf '%s' "$(( ($(date +%s%N) - T0) / 1000000 ))"
	else
		printf ''
	fi
}

report() {
	fail_count=0
	check()  { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [ OK ]   %s\n' "$1"; else printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); fi; }
	absent() { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); else printf '  [ OK ]   %s\n' "$1"; fi; }

	printf '\n== pemeriksaan konsol QEMU ==\n'
	check "banner 'ninit start (PID 1)' dari dalam guest" 'ninit start (PID 1)'
	check "event loop masuk ('main loop siap')"          'main loop siap'
	check "layanan /etc/init.conf dijalankan ('started console')" 'started console'
	absent "tidak ada kernel panic"                      'Kernel panic'
	if [ -n "${ready_ms:-}" ]; then
		printf '  [ OK ]   boot sampai "main loop siap" dalam %s ms (mode TCG/emulasi)\n' "$ready_ms"
	else
		printf '  [GAGAL] "main loop siap" tidak muncul dalam %s detik\n' "$SECS"
		fail_count=$((fail_count + 1))
	fi

	if [ "$fail_count" -eq 0 ]; then
		printf '\nHASIL: LULUS (semua pemeriksaan)\n'
	else
		printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
		printf '\n-- ekor log QEMU sendiri --\n'
		tail -n 15 "$QEMU_LOG" 2>/dev/null | sed 's/^/  | /'
	fi
}

# --------------------------------------------------------------- main
resolve_kernel
ensure_initramfs

log "rootfs     : $ROOTFS"
log "initramfs  : $INITRAMFS"
log "kernel     : $KERNEL"
log "append     : $APPEND"

if [ -z "$SECS" ]; then
	log "menjalankan QEMU interaktif (keluar: Ctrl-A X)"
	printf '\n'
	run_qemu interactive
	exit 0
fi

log "boot otomatis selama ${SECS}s (konsol -> $CONSOLE_LOG)"
mkdir -p "$DISTRO_DIR"
: > "$CONSOLE_LOG"
: > "$QEMU_LOG"

T0=$(date +%s%N)
run_qemu auto >>"$QEMU_LOG" 2>&1 &
qemu_pid=$!
trap 'kill -TERM "$qemu_pid" 2>/dev/null || true' EXIT INT TERM

ready_ms=''
banner_ms=''
i=0
while [ "$i" -lt $((SECS * 20)) ]; do
	[ -z "$banner_ms" ] && banner_ms=$(mark_ms 'ninit start (PID 1)')
	if [ -z "$ready_ms" ]; then
		ready_ms=$(mark_ms 'main loop siap')
		[ -n "$ready_ms" ] && break
	fi
	sleep 0.05
	i=$((i + 1))
done

wait "$qemu_pid" 2>/dev/null || true   # timeout menghentikan QEMU setelah $SECS detik
kill -TERM "$qemu_pid" 2>/dev/null || true

[ -n "$banner_ms" ] && printf '   banner ninit terdeteksi setelah %s ms\n' "$banner_ms"
[ -n "$ready_ms" ]  && printf '   "main loop siap" setelah %s ms\n' "$ready_ms"

printf '\n== konsol serial QEMU (%s) ==\n' "$CONSOLE_LOG"
sed 's/^/  | /' "$CONSOLE_LOG"

report
[ "${fail_count:-1}" -eq 0 ] || exit 1
