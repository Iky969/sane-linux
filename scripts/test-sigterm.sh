#!/bin/sh
# Test SIGTERM: membuktikan SIGTERM dari init benar-benar DIANTARKAN ke proses
# layanan, sehingga layanan bisa menutup diri dengan rapi lewat trap-nya sendiri
# (exit 0) dan bukan dibunuh paksa oleh SIGKILL setelah jendela grace habis.
#
# Kenapa test ini ada: anak hasil fork() pernah mewarisi signal mask PID 1
# (main() memblokir SIGTERM/SIGCHLD/SIGINT/SIGUSR1/SIGUSR2 untuk ppoll). Selama
# mask itu terpasang di anak, layanan tidak pernah menerima SIGTERM -> trap-nya
# tidak jalan -> shutdown_all() menunggu 5 detik lalu memakai SIGKILL.
# Test ini gagal bila regresi tersebut kembali.
#
# Pemakaian:
#   sudo sh ./scripts/test-sigterm.sh      # atau: make test
#
# Variabel lingkungan:
#   BIN=./ninit              biner yang diuji
#   BUSYBOX=/bin/busybox     busybox statis (apt-get install busybox-static)
#   READY_TIMEOUT=10         detik maksimum menunggu ninit siap
#   ACK_TIMEOUT=12           detik maksimum menunggu layanan menutup diri
#
# Catatan: script ini sengaja TIDAK memakai `unshare --mount-proc=<dir>`; pada
# sebagian kernel perubahan mount propagation ditolak dengan EINVAL, jadi dipakai
# varian --mount --propagation private + `mount -t proc` manual (sama seperti
# scripts/smoke-test.sh).

set -eu

BIN=${BIN:-./ninit}
BUSYBOX=${BUSYBOX:-/bin/busybox}
READY_TIMEOUT=${READY_TIMEOUT:-10}
ACK_TIMEOUT=${ACK_TIMEOUT:-12}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "biner '$BIN' tidak ditemukan/tidak executable (jalankan: make)"
[ -f "$BUSYBOX" ] || fail "busybox statis tidak ada di '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout ps mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "perkakas '$t' tidak ditemukan"
done
$SUDO true 2>/dev/null || fail "butuh root atau sudo tanpa password (unshare + chroot)"

ROOT=$(mktemp -d /tmp/ninit-sigterm.XXXXXX)
LOG=$(mktemp /tmp/ninit-sigterm-log.XXXXXX)
init_pid=""
cleanup() {
	[ -n "${init_pid:-}" ] && $SUDO kill -KILL "$init_pid" 2>/dev/null || true
	$SUDO umount "$ROOT/proc" 2>/dev/null || true
	rm -rf "$ROOT" "$LOG"
}
trap cleanup EXIT INT TERM

mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
cp "$BIN" "$ROOT/ninit"
cp "$BUSYBOX" "$ROOT/bin/sh"

# Layanan uji: satu-satunya tugasnya adalah menutup diri dengan rapi saat
# menerima SIGTERM. String "bye!" di bawah yang diperiksa test ini.
cat > "$ROOT/sigterm-service.sh" <<'EOSVC'
#!/bin/sh
trap 'echo "Menerima SIGTERM, bye!"; exit 0' TERM
echo "sigterm-service: jalan, menunggu SIGTERM (pid $$)"
while true; do sleep 1; done
EOSVC
chmod 0755 "$ROOT/sigterm-service.sh"
printf 'sigterm-test:once:/sigterm-service.sh\n' > "$ROOT/etc/init.conf"

printf '== rootfs uji : %s\n' "$ROOT"
printf '== biner uji  : %s\n' "$BIN"

find_init_pid() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x ninit 2>/dev/null | head -n 1
	else
		ps -eo pid,args 2>/dev/null | awk '$2 == "/ninit" { print $1; exit }'
	fi
}

find_service_pid() {
	ps -eo pid,args 2>/dev/null | awk '/sigterm-service\.sh/ && !/awk/ { print $1; exit }'
}

synblk_has_term() {
	# Argumen: isi /proc/<pid>/status. Cetak 1 bila bit SIGTERM (0x4000) terpasang.
	sigblk=$(printf '%s\n' "$1" | awk '/^SigBlk/ { print $2; exit }')
	[ -n "${sigblk:-}" ] || { echo 0; return; }
	low=$(printf '%s' "$sigblk" | cut -c9-16)
	case "$low" in *[!0-9a-fA-F]*|'') echo 0; return;; esac
	echo $(( (0x$low & 0x4000) != 0 ))
}

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT/proc' && exec chroot '$ROOT' /ninit" \
		>"$LOG" 2>&1
) &
job=$!

i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	init_pid=$(find_init_pid || true)
	if [ -n "${init_pid:-}" ] && grep -q 'main loop siap' "$LOG" 2>/dev/null \
	   && grep -q 'jalan, menunggu SIGTERM' "$LOG" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done
if [ -z "${init_pid:-}" ]; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak berjalan dalam ${READY_TIMEOUT}s"
fi

# Mask sinyal proses layanan: SIGTERM harus TIDAK diblokir di sini.
service_pid=$(find_service_pid || true)
mask_checked=0
if [ -n "${service_pid:-}" ]; then
	mask_checked=1
	service_blocked=$(synblk_has_term "$(cat "/proc/$service_pid/status" 2>/dev/null || echo '')")
fi

t0=$(date +%s%N)
$SUDO kill -TERM "$init_pid" || true

# Tunggu sampai layanan selesai menutup diri (baris exit status muncul di log).
ack_ms=""
i=0
while [ "$i" -lt $((ACK_TIMEOUT * 20)) ]; do
	if grep -q 'sigterm-test (pid .*) exit status=' "$LOG" 2>/dev/null; then
		ack_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
		break
	fi
	sleep 0.05
	i=$((i + 1))
done

# Beri kesempatan proses namespace berhenti sendiri (reboot() di ruang PID
# namespace mematikan seluruh isinya); sisanya dibersihkan oleh trap.
i=0
while [ "$i" -lt 60 ]; do
	kill -0 "$job" 2>/dev/null || break
	sleep 0.1
	i=$((i + 1))
done

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
check() { if grep -q "$2" "$LOG"; then ok "$1"; else bad "$1"; fi; }

printf '\n== pemeriksaan ==\n'
check "layanan uji berjalan ('menunggu SIGTERM')" 'jalan, menunggu SIGTERM'

if [ "$mask_checked" -eq 1 ]; then
	if [ "$service_blocked" -eq 0 ]; then
		ok "SIGTERM tidak diblokir di proses layanan (SigBlk bersih)"
	else
		bad "SIGTERM DIBLOKIR di proses layanan (mask warisan PID 1 tidak dibersihkan)"
	fi
else
	printf '  [ -- ]   mask sinyal layanan tidak diperiksa (pid layanan tidak ketemu)\n'
fi

check "layanan menerima SIGTERM ('bye!' dari trap)" 'Menerima SIGTERM, bye!'
if grep -qE 'sigterm-test \(pid [0-9]+\) exit status=0x0' "$LOG"; then
	ok "layanan keluar sendiri lewat trap (exit status=0x0)"
else
	bad "layanan tidak keluar dengan status 0x0"
fi

if grep -q 'exit status=0x9' "$LOG"; then
	bad "layanan dibunuh paksa SIGKILL (exit status=0x9)"
else
	ok "layanan tidak dibunuh paksa SIGKILL"
fi

if [ -n "$ack_ms" ] && [ "$ack_ms" -lt 4000 ]; then
	ok "shutdown layanan sebelum jendela grace: ${ack_ms}ms (grace = 5000ms)"
elif [ -n "$ack_ms" ]; then
	bad "layanan baru menutup diri setelah ${ack_ms}ms (mendekati/melewati jendela grace 5000ms)"
else
	bad "layanan tidak pernah menutup diri dalam ${ACK_TIMEOUT}s"
fi

printf '\n== log ninit ==\n'
sed 's/^/  | /' "$LOG"

if [ "$fail_count" -eq 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	exit 1
fi
