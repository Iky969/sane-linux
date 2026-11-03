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
# Skenario 3 mengunci audit SANE-01: leader layanan yang patuh SIGTERM dan
# keluar lebih dulu TIDAK boleh membuat init mengira seluruh grup sudah mati.
# Anak dalam grup yang mengabaikan SIGTERM harus tetap ditunggu sampai
# jendela grace habis, lalu dibunuh SIGKILL lewat pgid yang disimpan init.
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

ROOTS=""
LOGS=""
init_pid=""
init_pid2=""
init_pid3=""
cleanup() {
	[ -n "${init_pid:-}" ] && $SUDO kill -KILL "$init_pid" 2>/dev/null || true
	[ -n "${init_pid2:-}" ] && $SUDO kill -KILL "$init_pid2" 2>/dev/null || true
	[ -n "${init_pid3:-}" ] && $SUDO kill -KILL "$init_pid3" 2>/dev/null || true
	for d in ${ROOTS:-}; do
		$SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d"
	done
	for f in ${LOGS:-}; do rm -f "$f"; done
}
trap cleanup EXIT INT TERM

ROOT=$(mktemp -d /tmp/ninit-sigterm.XXXXXX)
LOG=$(mktemp /tmp/ninit-sigterm-log.XXXXXX)
ROOTS="$ROOTS $ROOT"
LOGS="$LOGS $LOG"

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

# -------------------------------------------------------------- Skenario 2
printf '\n== Skenario 2: shutdown pipeline (kill(-pid)) ==\n'
ROOT2=$(mktemp -d /tmp/ninit-sigterm-pipe.XXXXXX)
LOG2=$(mktemp /tmp/ninit-sigterm-pipe-log.XXXXXX)
ROOTS="$ROOTS $ROOT2"
LOGS="$LOGS $LOG2"

mkdir -p "$ROOT2/proc" "$ROOT2/sys" "$ROOT2/dev" "$ROOT2/run" "$ROOT2/tmp" \
         "$ROOT2/etc" "$ROOT2/var/log" "$ROOT2/bin"
cp "$BIN" "$ROOT2/ninit"
cp "$BUSYBOX" "$ROOT2/bin/sh"
cp "$BUSYBOX" "$ROOT2/bin/sleep"

printf 'pipe-svc:once:/bin/sh -c "/bin/sleep 50 | /bin/sleep 50"\n' > "$ROOT2/etc/init.conf"

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT2/proc' && exec chroot '$ROOT2' /ninit" \
		>"$LOG2" 2>&1
) &
job2=$!

i=0
init_pid2=""
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	init_pid2=$(find_init_pid || true)
	if [ -n "${init_pid2:-}" ] && grep -q 'main loop siap' "$LOG2" 2>/dev/null \
	   && grep -q 'started pipe-svc' "$LOG2" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done

if [ -z "${init_pid2:-}" ]; then
	sed 's/^/  | /' "$LOG2"
	fail "ninit skenario 2 tidak berjalan dalam ${READY_TIMEOUT}s"
fi

# Beri jeda agar kedua proses sleep dalam pipeline siap
sleep 0.5

# Pastikan proses sleep hidup sebelum shutdown
pipe_procs_before=$(ps -eo args 2>/dev/null | grep '/bin/sleep 50' | grep -v grep | wc -l || true)
if [ "$pipe_procs_before" -ge 2 ]; then
	ok "proses pipeline berjalan ($pipe_procs_before proses sleep aktif)"
else
	bad "proses pipeline tidak aktif sebelum shutdown (ditemukan $pipe_procs_before proses sleep)"
fi

# Kirim SIGTERM ke init
$SUDO kill -TERM "$init_pid2" || true

i=0
while [ "$i" -lt 60 ]; do
	kill -0 "$job2" 2>/dev/null || break
	sleep 0.1
	i=$((i + 1))
done
wait "$job2" 2>/dev/null || true

# Verifikasi tidak ada proses sleep 50 yang tertinggal
pipe_procs_after=$(ps -eo args 2>/dev/null | grep '/bin/sleep 50' | grep -v grep | wc -l || true)
if [ "$pipe_procs_after" -eq 0 ]; then
	ok "seluruh proses dalam pipeline mati setelah shutdown (group kill -pid)"
else
	bad "ada $pipe_procs_after proses pipeline tertinggal setelah shutdown"
fi

printf '\n== log ninit skenario 2 ==\n'
sed 's/^/  | /' "$LOG2"

# -------------------------------------------------------------- Skenario 3
printf '\n== Skenario 3: anak bandel dalam grup proses (audit SANE-01) ==\n'
ROOT3=$(mktemp -d /tmp/ninit-sigterm-stubborn.XXXXXX)
LOG3=$(mktemp /tmp/ninit-sigterm-stubborn-log.XXXXXX)
ROOTS="$ROOTS $ROOT3"
LOGS="$LOGS $LOG3"

mkdir -p "$ROOT3/proc" "$ROOT3/sys" "$ROOT3/dev" "$ROOT3/run" "$ROOT3/tmp" \
         "$ROOT3/etc" "$ROOT3/var/log" "$ROOT3/bin"
cp "$BIN" "$ROOT3/ninit"
cp "$BUSYBOX" "$ROOT3/bin/sh"
cp "$BUSYBOX" "$ROOT3/bin/sleep"

# Leader menuruti SIGTERM dan keluar 0, tetapi lebih dulu menelurkan anak
# dalam grup proses yang sama yang MENGABAIKAN SIGTERM (sleep 47). Init lama
# terkecoh: leader mati -> pid di-nol-kan -> shutdown mengira layanan sudah
# mati -> grup lolos dari SIGKILL dan hanya mati oleh teardown namespace.
# Placeholder /dev/null berupa berkas biasa: ash membuka /dev/null untuk
# stdin job latar, dan rootfs uji memang tidak punya device node (harness
# menghindari mknod). Berkas kosong cukup — yang penting open()-nya berhasil;
# anak bandel tidak pernah membaca stdin.
: > "$ROOT3/dev/null"
cat > "$ROOT3/stubborn-service.sh" <<'EOSVC'
#!/bin/sh
( trap '' TERM; exec sleep 47 ) &
echo "stubborn-service: leader jalan (pid $$), anak bandel sleep 47"
trap 'echo "leader menerima SIGTERM, bye!"; exit 0' TERM
while true; do sleep 1; done
EOSVC
chmod 0755 "$ROOT3/stubborn-service.sh"
printf 'stubborn-svc:once:/stubborn-service.sh\n' > "$ROOT3/etc/init.conf"

(
	$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private \
		sh -c "mount -t proc proc '$ROOT3/proc' && exec chroot '$ROOT3' /ninit" \
		>"$LOG3" 2>&1
) &
job3=$!

i=0
init_pid3=""
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	init_pid3=$(find_init_pid || true)
	if [ -n "${init_pid3:-}" ] && grep -q 'main loop siap' "$LOG3" 2>/dev/null \
	   && grep -q 'started stubborn-svc' "$LOG3" 2>/dev/null; then
		break
	fi
	sleep 0.2
	i=$((i + 1))
done

if [ -z "${init_pid3:-}" ]; then
	sed 's/^/  | /' "$LOG3"
	fail "ninit skenario 3 tidak berjalan dalam ${READY_TIMEOUT}s"
fi

sleep 0.5

count_sleep47() { ps -eo args 2>/dev/null | grep 'sleep 47' | grep -v grep | wc -l || true; }

stubborn_before=$(count_sleep47)
if [ "$stubborn_before" -ge 1 ]; then
	ok "anak bandel berjalan sebelum shutdown ($stubborn_before proses sleep 47)"
else
	bad "anak bandel tidak aktif sebelum shutdown (ditemukan $stubborn_before)"
fi

t0=$(date +%s)
$SUDO kill -TERM "$init_pid3" || true

# Tunggu leader keluar lewat trap-nya (exit status tercatat di log).
i=0
while [ "$i" -lt $((ACK_TIMEOUT * 20)) ]; do
	grep -q 'stubborn-svc (pid .*) exit status=' "$LOG3" 2>/dev/null && break
	sleep 0.05
	i=$((i + 1))
done

# 2 detik setelah leader mati, anak bandel harus MASIH hidup: init yang
# benar masih menunggu grupnya (grace), bukan langsung reboot.
sleep 2
stubborn_mid=$(count_sleep47)

i=0
while [ "$i" -lt 150 ]; do
	kill -0 "$job3" 2>/dev/null || break
	sleep 0.1
	i=$((i + 1))
done
wait "$job3" 2>/dev/null || true
shutdown_secs=$(( $(date +%s) - t0 ))

stubborn_after=$(count_sleep47)

if grep -q 'leader menerima SIGTERM, bye!' "$LOG3"; then
	ok "leader keluar sendiri lewat trap SIGTERM"
else
	bad "leader tidak menjalankan trap SIGTERM"
fi

if grep -qE 'stubborn-svc \(pid [0-9]+\) exit status=0x0' "$LOG3"; then
	ok "leader exit status=0x0 (graceful)"
else
	bad "leader tidak exit dengan status 0x0"
fi

if [ "$stubborn_mid" -ge 1 ]; then
	ok "anak bandel masih hidup 2 detik setelah leader mati (init menunggu grup, tidak terkecoh)"
else
	bad "anak bandel sudah hilang 2 detik setelah leader mati (init terkecoh: grup lolos dari grace+SIGKILL)"
fi

if [ "$shutdown_secs" -ge 4 ]; then
	ok "shutdown menunggu jendela grace penuh untuk grup bandel: ${shutdown_secs}s (grace = 5s)"
else
	bad "shutdown selesai hanya dalam ${shutdown_secs}s (jendela grace tidak dipakai untuk grup bandel)"
fi

if [ "$stubborn_after" -eq 0 ]; then
	ok "tidak ada proses sleep 47 tertinggal setelah shutdown"
else
	bad "ada $stubborn_after proses sleep 47 tertinggal setelah shutdown"
fi

printf '\n== log ninit skenario 3 ==\n'
sed 's/^/  | /' "$LOG3"

if [ "$fail_count" -eq 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	exit 1
fi
