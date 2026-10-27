#!/bin/sh
# Test konfigurasi + IPC initctl: mengunci tiga perbaikan reliabilitas.
#
#   1a. urut topologis `:requires=` benar untuk bentuk berlian (a butuh b,c ;
#       b butuh c -> urutan c, b, a).
#   1b. konfigurasi padat tepat 64 layanan (root butuh semua s2..s64, s63 butuh
#       dua saudara) selesai tanpa stack overflow.
#       Regresi lama: layanan yang masih "pending" di stack di-push berulang,
#       sehingga stack_top melewati MAX_SERVICES -> stack-buffer-overflow di
#       sort_services() (terbukti dengan AddressSanitizer pada versi lama).
#   2.  dependensi hilang (web:requires=db) -> "FATAL: Dependensi ... tidak
#       ditemukan" + rescue shell, BUKAN boot setengah jalan.
#   3a. dua perintah dalam satu penulisan ke /run/initctl (poweroff + reboot):
#       hanya baris pertama yang dieksekusi.
#   3b. perintah tak dikenal di baris pertama (status + poweroff): perintah di
#       baris kedua TIDAK hilang tanpa jejak (regresi parsing lama).
#   4a. config tidak bisa dibuka -> rescue shell sungguhan (regresi lama: hanya
#       di-log, lalu init "sukses" boot dengan nol layanan).
#   4b. siklus dependensi -> rescue shell, dan shell itu mewarisi signal mask
#       KOSONG sehingga SIGINT (Ctrl+C) berfungsi (regresi lama: mask ppoll PID 1
#       terbawa ke shell darurat).
#
# Pemakaian:
#   sudo sh ./scripts/test-config.sh      # atau: make test
#
# Variabel lingkungan:
#   BIN=./ninit              biner yang diuji
#   BUSYBOX=/bin/busybox     busybox statis (apt-get install busybox-static)
#   READY_TIMEOUT=10         detik maksimum menunggu ninit siap/bereaksi
#
# Catatan: sama seperti scripts/smoke-test.sh, script ini sengaja TIDAK memakai
# `unshare --mount-proc=<dir>` (sebagian kernel menolak perubahan mount
# propagation dengan EINVAL), dan stdin ninit diarahkan ke /dev/null supaya
# rescue shell langsung mendapat EOF dan tidak menggantung di CI. Pengecualian:
# skenario 4b memberi stdin fifo yang ditahan `sleep` agar shell darurat cukup
# lama hidup untuk dibaca /proc/<pid>/status-nya.

set -eu

BIN=${BIN:-./ninit}
BUSYBOX=${BUSYBOX:-/bin/busybox}
READY_TIMEOUT=${READY_TIMEOUT:-10}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
check() { if grep -q "$2" "$LOG"; then ok "$1"; else bad "$1"; fi; }
check_absent() { if grep -q "$2" "$LOG"; then bad "$1"; else ok "$1"; fi; }

[ -x "$BIN" ] || fail "biner '$BIN' tidak ditemukan/tidak executable (jalankan: make)"
[ -f "$BUSYBOX" ] || fail "busybox statis tidak ada di '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout ps mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "perkakas '$t' tidak ditemukan"
done
$SUDO true 2>/dev/null || fail "butuh root atau sudo tanpa password (unshare + chroot)"

ROOTS=""
LOGS=""
JOB=""
INIT_PID=""
HOLDER=""
INIT_STDIN=/dev/null
cleanup() {
	[ -n "${HOLDER:-}" ] && kill "$HOLDER" 2>/dev/null || true
	[ -n "${INIT_PID:-}" ] && $SUDO kill -KILL "$INIT_PID" 2>/dev/null || true
	for d in ${ROOTS:-}; do
		$SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d"
	done
	for f in ${LOGS:-}; do rm -f "$f"; done
}
trap cleanup EXIT INT TERM

# Siapkan rootfs uji terpisah untuk tiap skenario ($1 = nama/tag uji).
start_root() {
	ROOT=$(mktemp -d "/tmp/ninit-$1.XXXXXX")
	LOG=$(mktemp "/tmp/ninit-$1-log.XXXXXX")
	ROOTS="$ROOTS $ROOT"
	LOGS="$LOGS $LOG"
	mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp" \
	         "$ROOT/etc" "$ROOT/var/log" "$ROOT/bin"
	cp "$BIN" "$ROOT/ninit"
	cp "$BUSYBOX" "$ROOT/bin/sh"
}

# Jalankan ninit sebagai PID 1 di PID + mount namespace baru.
run_init() {
	(
		$SUDO timeout -k 5 30 unshare --pid --fork --kill-child=SIGKILL \
			--mount --propagation private \
			sh -c "mount -t proc proc '$ROOT/proc' && exec chroot '$ROOT' /ninit ${INIT_ARGS:-}" \
			>"$LOG" 2>&1 <"$INIT_STDIN"
	) &
	JOB=$!
	INIT_PID=""
}

find_init_pid() {
	if command -v pgrep >/dev/null 2>&1; then
		pgrep -x ninit 2>/dev/null | head -n 1
	else
		ps -eo pid,args 2>/dev/null | awk '$2 == "/ninit" { print $1; exit }'
	fi
}

# Tunggu sampai pola muncul di log. 0 = ketemu, 1 = timeout.
wait_for() {
	i=0
	while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
		if grep -q "$1" "$LOG" 2>/dev/null; then return 0; fi
		sleep 0.2
		i=$((i + 1))
	done
	return 1
}

stop_init() {
	if [ -n "${INIT_PID:-}" ]; then $SUDO kill -KILL "$INIT_PID" 2>/dev/null || true; fi
	wait "$JOB" 2>/dev/null || true
	INIT_PID=""
}

printf '== biner uji  : %s\n' "$BIN"
printf '== busybox    : %s\n' "$BUSYBOX"

# -------------------------------------------------------------- skenario 1a
printf '\n== 1a. urut dependensi: bentuk berlian ==\n'
start_root topo
LOG1="$LOG"
cat > "$ROOT/etc/init.conf" <<'EOCFG'
# bentuk berlian -> dua layanan butuh satu layanan yang sama (bukan cycle)
a:once:echo svc-a:requires=b,c
b:once:echo svc-b:requires=c
c:once:echo svc-c
EOCFG

run_init
if ! wait_for 'ninit: started a (pid'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak selesai menjalankan layanan berlian dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "event loop jalan ('main loop siap')" 'main loop siap'
check "layanan berdaftar dependensi dijalankan ('started a')" 'ninit: started a (pid'
check "layanan tanpa dependensi jalan lebih dulu ('started c')" 'ninit: started c (pid'
check_absent "berlian tidak salah dianggap cycle" 'CYCLE DETECTED'

# Urutan spawn harus mengikuti urut topologis: c -> b -> a.
order=$(sed -n 's/.*ninit: started \([abc]\) (pid.*/\1/p' "$LOG" | tr -d '\n')
if [ "$order" = "cba" ]; then
	ok "urut topologis benar: c -> b -> a (dapat: $order)"
else
	bad "urut topologis salah (harap cba, dapat: '$order')"
fi

# -------------------------------------------------------------- skenario 1b
printf '\n== 1b. konfigurasi padat 64 layanan (regresi stack overflow) ==\n'
start_root dense
LOG2="$LOG"
{
	printf '# root butuh semua s2..s64 (63 dependensi) dan s63 butuh dua saudara\n'
	printf 'root:once:::requires='
	i=2; sep=""
	while [ "$i" -le 64 ]; do
		printf '%s%s' "$sep" "s$i"
		sep=","
		i=$((i + 1))
	done
	printf '\n'
	printf 's63:once:::requires=s62,s61\n'
	i=2
	while [ "$i" -le 64 ]; do
		if [ "$i" -ne 63 ]; then printf 's%d:once::\n' "$i"; fi
		i=$((i + 1))
	done
} > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'ninit: started root (pid'; then
	sed 's/^/  | /' "$LOG" | grep -vE 'started s[0-9]+ \(pid'
	fail "ninit tidak menyelesaikan spawn konfigurasi padat dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

dense_started=$(grep -cE 'ninit: started (s[0-9]+|root) \(pid' "$LOG" || true)
if [ "$dense_started" -eq 64 ]; then
	ok "konfigurasi padat: 64/64 layanan dijalankan tanpa stack overflow"
else
	bad "konfigurasi padat: hanya $dense_started/64 layanan dijalankan"
fi
check "event loop jalan ('main loop siap')" 'main loop siap'
check_absent "tidak ada FATAL (stack overflow/cycle) pada konfigurasi valid" 'FATAL'

# --------------------------------------------------------------- skenario 2
printf '\n== 2. dependensi hilang -> rescue shell ==\n'
start_root missing
LOG3="$LOG"
printf 'web:once:echo web:requires=db\n' > "$ROOT/etc/init.conf"

run_init
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "ninit tidak melaporkan rescue mode untuk dependensi hilang"
fi

check "dependensi hilang dilaporkan FATAL" "FATAL: Dependensi 'db' untuk 'web' tidak ditemukan"
check "init masuk rescue mode (shell)" 'Masuk rescue mode (shell)'
check_absent "boot tidak dilanjutkan (tanpa 'main loop siap')" 'main loop siap'
check_absent "layanan bermasalah tidak dijalankan" 'ninit: started web'

i=0
while [ "$i" -lt 50 ]; do
	if ! kill -0 "$JOB" 2>/dev/null; then break; fi
	sleep 0.1
	i=$((i + 1))
done
if kill -0 "$JOB" 2>/dev/null; then
	bad "PID 1 tidak digantikan rescue shell (proses masih hidup)"
else
	ok "PID 1 digantikan rescue shell /bin/sh (execl mengganti proses init)"
fi
stop_init

# --------------------------------------------------------------- skenario 3
# $1 = tag uji, $2 = isi printf yang dikirim layanan ke /run/initctl
#      (mis. 'poweroff\nreboot\n')
run_cmdtest() {
	start_root "$1"
	cat > "$ROOT/send-cmd.sh" <<EOSVC
#!/bin/sh
sleep 1
printf '$2' > /run/initctl
EOSVC
	chmod 0755 "$ROOT/send-cmd.sh"
	printf 'sender:once:/send-cmd.sh\n' > "$ROOT/etc/init.conf"

	run_init
	init_pid=$(find_init_pid || true)
	INIT_PID="${init_pid:-}"
	if ! wait_for 'graceful shutdown'; then
		sed 's/^/  | /' "$LOG"
		bad "$1: ninit tidak bereaksi terhadap perintah di /run/initctl"
	fi
	stop_init
}

printf '\n== 3a. dua perintah dalam satu penulisan: poweroff + reboot ==\n'
run_cmdtest ipc 'poweroff\nreboot\n'
LOG4="$LOG"
check "baris pertama dieksekusi" "initctl cmd: 'poweroff'"
check_absent "baris kedua tidak dieksekusi (poweroff mematikan sistem)" "initctl cmd: 'reboot'"
check "shutdown dari /run/initctl berjalan rapi" 'graceful shutdown'

printf '\n== 3b. perintah tak dikenal di baris pertama: status + poweroff ==\n'
run_cmdtest ipc2 'status\npoweroff\n'
LOG5="$LOG"
check "baris tak dikenal tetap dicatat" "initctl cmd: 'status'"
check "perintah di baris kedua TIDAK hilang" "initctl cmd: 'poweroff'"
check "perintah baris kedua benar-benar dieksekusi" 'graceful shutdown'

# --------------------------------------------------------------- skenario 4a
# parse_config() gagal (file tidak ada) HARUS masuk rescue shell, bukan lanjut
# boot dengan nol layanan lalu mengaku "main loop siap".
printf '\n== 4a. config tidak terbaca -> rescue shell ==\n'
start_root badconf
LOG6="$LOG"
# sengaja tidak membuat /etc/init.conf
INIT_ARGS=/etc/init.conf.tidak-ada
INIT_STDIN=/dev/null
run_init
INIT_ARGS=""
if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "config tidak terbaca tidak memicu rescue mode"
fi

check "config gagal dilaporkan" 'Config gagal dibaca/di-parse!'
check "init masuk rescue mode (shell)" 'Masuk rescue mode (shell)'
check_absent "boot tidak dilanjutkan (tanpa 'main loop siap')" 'main loop siap'

i=0
while [ "$i" -lt 50 ]; do
	if ! kill -0 "$JOB" 2>/dev/null; then break; fi
	sleep 0.1
	i=$((i + 1))
done
if kill -0 "$JOB" 2>/dev/null; then
	bad "4a: PID 1 tidak digantikan rescue shell (proses masih hidup)"
else
	ok "4a: PID 1 digantikan rescue shell /bin/sh"
fi
stop_init

# --------------------------------------------------------------- skenario 4b
# Siklus dependensi => rescue shell. Shell ini harus mewarisi signal mask
# KOSONG; kalau tidak, Ctrl+C tidak akan pernah sampai ke shell darurat.
# stdin-nya fifo yang ditahan `sleep` supaya shell tidak langsung EOF dan kita
# sempat membaca /proc/<pid>/status.
printf '\n== 4b. siklus dependensi -> rescue shell + signal mask kosong ==\n'
start_root cycle
LOG7="$LOG"
printf 'a:once:echo svc-a:requires=b\nb:once:echo svc-b:requires=a\n' > "$ROOT/etc/init.conf"
mkfifo "$ROOT/rescue.stdin"
sleep 15 > "$ROOT/rescue.stdin" &
HOLDER=$!
INIT_STDIN="$ROOT/rescue.stdin"
INIT_ARGS=""
run_init

if ! wait_for 'rescue mode'; then
	sed 's/^/  | /' "$LOG"
	bad "siklus dependensi tidak memicu rescue mode"
fi
check "siklus dilaporkan FATAL" 'FATAL: CYCLE DETECTED'
check "init masuk rescue mode (shell)" 'Masuk rescue mode (shell)'
check_absent "boot tidak dilanjutkan (tanpa 'main loop siap')" 'main loop siap'

# Cari proses rescue shell: proses yang root filesystem-nya $ROOT dan argv[0]-nya
# "sh" (setelah execl, PID 1 yang sama kini menjalankan busybox sh).
find_rescue_pid() {
	for s in /proc/[0-9]*/status; do
		p=${s#/proc/}; p=${p%/status}
		r=$(readlink "/proc/$p/root" 2>/dev/null) || continue
		[ "$r" = "$ROOT" ] || continue
		c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
		[ "$c" = "sh " ] || continue
		printf '%s\n' "$p"; return 0
	done
	return 1
}

rescue_pid=""
i=0
while [ "$i" -lt 50 ]; do
	rescue_pid=$(find_rescue_pid || true)
	[ -n "$rescue_pid" ] && break
	sleep 0.1
	i=$((i + 1))
done

if [ -z "$rescue_pid" ]; then
	bad "rescue shell tidak ditemukan (tidak bisa memeriksa signal mask)"
else
	sigblk=$(awk '/^SigBlk/ { print $2; exit }' "/proc/$rescue_pid/status" 2>/dev/null || true)
	mask_nonzero=$(printf '%s' "${sigblk:-0}" | sed 's/^0*//')
	if [ -z "$mask_nonzero" ]; then
		ok "signal mask rescue shell kosong (SigBlk=0, Ctrl+C berfungsi)"
	else
		bad "rescue shell mewarisi signal mask (SigBlk=$sigblk) -> Ctrl+C tidak sampai"
	fi
	$SUDO kill -KILL "$rescue_pid" 2>/dev/null || true
fi

kill "$HOLDER" 2>/dev/null || true
HOLDER=""
INIT_STDIN=/dev/null
stop_init

# --------------------------------------------------------------- ringkasan
printf '\n== log 1a (urut dependensi) ==\n'
sed 's/^/  | /' "$LOG1"
printf '\n== log 1b (konfigurasi padat; 63 baris layanan s2..s64 disembunyikan) ==\n'
grep -vE "ninit: (started s[0-9]+ \(pid|cgroup: 's[0-9]+'|s[0-9]+ \(pid [0-9]+\) exit)" \
	"$LOG2" | sed 's/^/  | /'
printf '\n== log 2 (dependensi hilang) ==\n'
sed 's/^/  | /' "$LOG3"
printf '\n== log 3a (/run/initctl: poweroff + reboot) ==\n'
sed 's/^/  | /' "$LOG4"
printf '\n== log 3b (/run/initctl: status + poweroff) ==\n'
sed 's/^/  | /' "$LOG5"
printf '\n== log 4a (config tidak terbaca) ==\n'
sed 's/^/  | /' "$LOG6"
printf '\n== log 4b (siklus dependensi) ==\n'
sed 's/^/  | /' "$LOG7"

if [ "$fail_count" -eq 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	exit 1
fi
