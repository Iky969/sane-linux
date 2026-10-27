#!/bin/sh
# Smoke test ninit: jalankan sebagai PID 1 di dalam PID + mount namespace baru
# dengan rootfs chroot sementara, tunggu sampai "main loop siap", kirim SIGTERM,
# lalu periksa shutdown berjalan bersih (tanpa respawn setelah shutdown).
#
# Pemakaian:
#   sudo sh ./scripts/smoke-test.sh      # atau: make test
#
# Variabel lingkungan:
#   BIN=./ninit              biner yang diuji
#   BUSYBOX=/bin/busybox     busybox statis (apt-get install busybox-static)
#   READY_TIMEOUT=10         detik maksimum menunggu ninit siap
#
# Catatan: script ini sengaja TIDAK memakai `unshare --mount-proc=<dir>`.
# Pada sebagian kernel (termasuk sandbox CI tertentu) perubahan mount
# propagation ditolak dengan EINVAL; varian --mount --propagation private +
# `mount -t proc` manual efeknya sama dan lebih portabel.

set -eu

BIN=${BIN:-./ninit}
BUSYBOX=${BUSYBOX:-/bin/busybox}
READY_TIMEOUT=${READY_TIMEOUT:-10}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "biner '$BIN' tidak ditemukan/tidak executable (jalankan: make)"
[ -f "$BUSYBOX" ] || fail "busybox statis tidak ada di '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout ps mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "perkakas '$t' tidak ditemukan"
done
$SUDO true 2>/dev/null || fail "butuh root atau sudo tanpa password (unshare + chroot)"

ROOT=$(mktemp -d /tmp/ninit-smoke.XXXXXX)
LOG=$(mktemp /tmp/ninit-smoke-log.XXXXXX)
cleanup() {
	# proc hidup di dalam mount namespace, tapi bersihkan kalau ada yang bocor
	$SUDO umount "$ROOT/proc" 2>/dev/null || true
	rm -rf "$ROOT" "$LOG"
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
cp "$BIN" "$ROOT/ninit"
cp "$BUSYBOX" "$ROOT/bin/sh"
printf 'shell:respawn:/bin/sh\n' > "$ROOT/etc/init.conf"

printf '== rootfs uji : %s\n' "$ROOT"
printf '== biner uji  : %s\n' "$BIN"

find_init_pid() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x ninit 2>/dev/null | head -n 1
	else
		ps -eo pid,args 2>/dev/null | awk '$2 == "/ninit" { print $1; exit }'
	fi
}

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT/proc' && exec chroot '$ROOT' /ninit" \
		>"$LOG" 2>&1
) &
job=$!

i=0
pid=""
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	pid=$(find_init_pid || true)
	if [ -n "${pid:-}" ] && grep -q 'main loop siap' "$LOG" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done
if [ -z "${pid:-}" ]; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak berjalan dalam ${READY_TIMEOUT}s"
fi

t0=$(date +%s%N)
$SUDO kill -TERM "$pid" || true
wait "$job" || true
t1=$(date +%s%N)
latency_ms=$(( (t1 - t0) / 1000000 ))

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
check() { if grep -q "$2" "$LOG"; then ok "$1"; else bad "$1"; fi; }

printf '\n== pemeriksaan ==\n'
check "banner 'ninit start (PID 1)'"          'ninit start (PID 1)'
check "event loop masuk ('main loop siap')"   'main loop siap'
check "layanan dijalankan ('started shell')"  'started shell'
check "SIGTERM diproses ('graceful shutdown')" 'graceful shutdown'

after=$(awk '/graceful shutdown/ { f = 1 } f && /started shell/ { c++ } END { print c + 0 }' "$LOG")
if [ "$after" -eq 0 ]; then
	ok "tidak ada respawn setelah shutdown"
else
	bad "ada $after respawn setelah shutdown"
fi

if [ "$latency_ms" -lt 2000 ]; then
	ok "latensi SIGTERM -> berhenti: ${latency_ms}ms"
else
	bad "latensi SIGTERM -> berhenti: ${latency_ms}ms (layanan respawn-cepat harus < 2000ms)"
fi

printf '\n== log ninit ==\n'
sed 's/^/  | /' "$LOG"

if [ "$fail_count" -eq 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	exit 1
fi
