#!/bin/sh
# test-integration.sh -- uji integrasi lintas lapisan: fstab -> kernel nyata ->
# terlihat dari layanan -> urutan boot QEMU.
#
# Kenapa suite ini ada: test-config.sh menguji parser fstab di chroot dan
# test-qemu-report.sh menguji report() lewat fixture log. Keduanya tidak bisa
# menangkap inkonsistensi ANTAR lapisan — misalnya escape oktal yang benar di
# unit test tapi mount() gagal di kernel asli, atau opsi mount yang terbaca
# parser namun hilang saat rootfs di-pack ke initramfs. Suite ini melakukan
# SATU boot QEMU sungguhan dengan fstab + init.conf uji, lalu menuntut hasil
# akhirnya: mount benar-benar ada di /proc/mounts dari sudut pandang layanan,
# dan fstab ter-mount SEBELUM layanan apa pun start.
#
# Pemakaian:
#   sudo sh ./scripts/test-integration.sh
#
# Variabel:
#   SECS=40             jendela boot (TCG tanpa KVM lambat; naikkan bila perlu)
#   BUSYBOX_MODE=prebuilt  diteruskan ke build-rootfs.sh (auto|source|prebuilt)
#   DISTRO_DIR, ROOTFS, INITRAMFS, CONSOLE_LOG  seperti run-qemu.sh
#
# Butuh: sama seperti build-rootfs.sh + run-qemu.sh (qemu-system-x86, cpio,
# busybox statis, root untuk mknod/dev dan QEMU TCG).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

DISTRO_DIR=${DISTRO_DIR:-$REPO_ROOT/distro}
CONSOLE_LOG=${CONSOLE_LOG:-$DISTRO_DIR/qemu-console.log}
INITRAMFS=${INITRAMFS:-$DISTRO_DIR/initramfs.cpio.gz}
SECS=${SECS:-40}
BUSYBOX_MODE=${BUSYBOX_MODE:-prebuilt}

log()  { printf '== %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die()  { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"
$SUDO true 2>/dev/null || die "butuh root atau sudo tanpa password (mknod di build-rootfs.sh + QEMU)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# --------------------------------------------------------------- fixture
# Tiga entri fstab yang mewakili tiga perilaku berbeda:
#   1. mount sukses dengan opsi data (size=1m harus diteruskan ke mount())
#   2. escape oktal \040 di mountpoint: unit test membuktikan parser
#      mendekodenya; di sini kita buktikan kernel benar-benar me-mount
#      direktori "a b" hasil dekode (regresi PR #3-C1)
#   3. mountpoint duplikat dari entri 1: harus DILEWATI, bukan mount ganda
#      (regresi PR #3-C2)
cat > "$WORK/fstab" <<'EOF'
tmpfs /mnt/intg tmpfs size=1m 0 0
tmpfs /mnt/a\040b tmpfs defaults 0 0
tmpfs /mnt/intg tmpfs defaults 0 0
EOF

# mountproof: layanan `once` yang membaca /proc/mounts DARI DALAM guest.
# Kalau mount fstab hanya sukses di log ninit tapi tidak masuk mount table
# kernel, INTEGRATION-MOUNT-MISSING yang tercetak. Format /proc/mounts
# meng-escape spasi sebagai \040 secara harfiah, karena itu grep -F di sini
# mencocokkan teks mentah, bukan nama direktori yang sudah didekode.
cat > "$WORK/init.conf" <<'EOF'
mountproof:once:/bin/sh -c 'ok=1; grep -qF " /mnt/intg " /proc/mounts || ok=0; grep -qF " /mnt/a\040b " /proc/mounts || ok=0; [ "$ok" = 1 ] && echo INTEGRATION-MOUNT-VISIBLE || echo INTEGRATION-MOUNT-MISSING'
EOF

# --------------------------------------------------------------- build + boot
log "build ninit"
make -C "$REPO_ROOT" >/dev/null || die "make ninit gagal"

log "build rootfs + initramfs dengan fstab & init.conf uji"
$SUDO env EXTRA_FSTAB="$WORK/fstab" EXTRA_INIT_CONF="$WORK/init.conf" \
BUSYBOX_MODE="$BUSYBOX_MODE" DISTRO_DIR="$DISTRO_DIR" \
	sh "$SCRIPT_DIR/build-rootfs.sh"
[ -s "$INITRAMFS" ] || die "initramfs tidak dihasilkan"

log "boot QEMU sekali (SECS=$SECS) — report bawaan run-qemu.sh ikut menilai"
harness_rc=0
$SUDO env SECS="$SECS" CONSOLE_LOG="$CONSOLE_LOG" sh "$SCRIPT_DIR/run-qemu.sh" || harness_rc=$?
[ -r "$CONSOLE_LOG" ] || die "tidak ada konsol readable di $CONSOLE_LOG"

# --------------------------------------------------------------- pemeriksaan
fail_count=0
check()  { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [ OK ]   %s\n' "$1"; else printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); fi; }
absent() { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); else printf '  [ OK ]   %s\n' "$1"; fi; }
line_no() { grep -m1 -n "$1" "$CONSOLE_LOG" 2>/dev/null | cut -d: -f1 || true; }

printf '\n== pemeriksaan integrasi fstab <-> kernel <-> layanan ==\n'
check "entri normal ter-mount dengan opsi data (size=1m)" \
	'fstab: mount tmpfs -> /mnt/intg (tmpfs) \[data: size=1m\] ok'
check "escape oktal didekode lalu di-mount kernel apa adanya ('/mnt/a b')" \
	'fstab: mount tmpfs -> /mnt/a b (tmpfs)'
check "entri duplikat DILEWATI, bukan mount ganda" \
	'fstab: tmpfs -> /mnt/intg dilewati (mountpoint duplikat'
# Scope kegagalan mount ke HANYA path fixture: kalau nanti suite ini dipakai
# sebagai host untuk uji negatif (entri yang sengaja gagal), mount gagal di
# path lain tidak boleh membuat pemeriksaan ini ikut merah.
absent "entri fixture /mnt/intg tidak gagal mount" 'fstab: mount .* /mnt/intg .* gagal'
absent "entri fixture /mnt/a b tidak gagal mount"  'fstab: mount .* /mnt/a b .* gagal'
check "layanan mountproof start"            'started mountproof'
check "mount fstab terlihat dari /proc/mounts guest" 'INTEGRATION-MOUNT-VISIBLE'
absent "tidak ada mount yang hilang dari sudut pandang layanan" 'INTEGRATION-MOUNT-MISSING'

printf '\n== pemeriksaan urutan lintas lapisan ==\n'
# mount_fstab() didahulukan dari parse_config()/spawn di main() ninit; kalau
# suatu refactor memindahkan salah satunya, urutan di konsol ini yang menangkap.
n_first_fstab=$(line_no 'fstab: mount tmpfs -> /mnt/intg (tmpfs)')
n_last_fstab=$(grep -n 'fstab: ' "$CONSOLE_LOG" | tail -n 1 | cut -d: -f1 || true)
n_started=$(line_no 'started mountproof')
n_console=$(line_no 'started console')
n_loop=$(line_no 'main loop siap')
if [ -n "$n_first_fstab" ] && [ -n "$n_started" ] && [ "$n_first_fstab" -lt "$n_started" ]; then
	printf '  [ OK ]   fstab ter-mount sebelum layanan mountproof start\n'
else
	printf '  [GAGAL] fstab ter-mount SETELAH/ TANPA sebelum layanan start (baris %s vs %s)\n' \
		"${n_first_fstab:-?}" "${n_started:-?}"
	fail_count=$((fail_count + 1))
fi
# Catatan: mount_fstab() dijalankan SEBELUM banner 'ninit start' dicetak
# (banner ditulis setelah log file dibuka), jadi urutan yang dituntut di
# sini adalah fstab < service pertama < main loop — bukan fstab setelah banner.
if [ -n "$n_last_fstab" ] && [ -n "$n_console" ] && [ "$n_last_fstab" -lt "$n_console" ]; then
	printf '  [ OK ]   SEMUA baris fstab selesai sebelum service pertama (console) start\n'
else
	printf '  [GAGAL] masih ada baris fstab setelah service pertama start (baris %s vs %s)\n' \
		"${n_last_fstab:-?}" "${n_console:-?}"
	fail_count=$((fail_count + 1))
fi
if [ -n "$n_last_fstab" ] && [ -n "$n_loop" ] && [ "$n_last_fstab" -lt "$n_loop" ]; then
	printf '  [ OK ]   fstab selesai sebelum event loop masuk (tidak ada mount di dalam loop)\n'
else
	printf '  [GAGAL] baris fstab terakhir (baris %s) tidak mendahului main loop siap (baris %s)\n' \
		"${n_last_fstab:-?}" "${n_loop:-?}"
	fail_count=$((fail_count + 1))
fi

printf '\n== pemeriksaan harness standar atas log integrasi ==\n'
if [ "$harness_rc" = 0 ]; then
	printf '  [ OK ]   report() run-qemu.sh LULUS pada boot ber-fstab uji\n'
else
	printf '  [GAGAL] report() run-qemu.sh GAGAL (exit %s) — lihat output di atas\n' "$harness_rc"
	fail_count=$((fail_count + 1))
fi

if [ "$fail_count" = 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan integrasi)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	printf '\n-- ekor konsol guest --\n'
	tail -n 20 "$CONSOLE_LOG" | sed 's/^/  | /'
	exit 1
fi
