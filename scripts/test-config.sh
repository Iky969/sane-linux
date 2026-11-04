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
			sh -c "umask ${TEST_UMASK:-0022}; mount -t proc proc '$ROOT/proc' && exec chroot '$ROOT' /ninit ${INIT_ARGS:-}" \
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

# Layanan once harus benar-benar selesai (exit status) sebelum dependensinya jalan
seq_c_exit=$(grep -nE 'ninit: c \(pid [0-9]+\) exit status=0x0' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_b_start=$(grep -nE 'ninit: started b \(pid' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_b_exit=$(grep -nE 'ninit: b \(pid [0-9]+\) exit status=0x0' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_a_start=$(grep -nE 'ninit: started a \(pid' "$LOG" | head -n 1 | cut -d: -f1 || true)

if [ -n "$seq_c_exit" ] && [ -n "$seq_b_start" ] && [ "$seq_c_exit" -lt "$seq_b_start" ] && \
   [ -n "$seq_b_exit" ] && [ -n "$seq_a_start" ] && [ "$seq_b_exit" -lt "$seq_a_start" ]; then
	ok "layanan once selesai sebelum dependensinya jalan (c exit -> b start -> b exit -> a start)"
else
	bad "layanan once tidak menunggu selesai sebelum dependensi jalan (c_exit=$seq_c_exit b_start=$seq_b_start b_exit=$seq_b_exit a_start=$seq_a_start)"
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

# -------------------------------------------------------------- skenario 5
printf '\n== 5. penolakan string terlalu panjang (nama, perintah, dependensi) ==\n'
start_root trunc
LOG8="$LOG"

long_name=$(printf 'longname_%.0s' $(seq 1 15))
long_cmd=$(printf 'echo hello_%.0s' $(seq 1 48))
long_deps="dep,"$(printf 'd%02d,' $(seq 1 63))
cat > "$ROOT/etc/init.conf" <<EOCFG
dep:once:true
${long_name}:once:${long_cmd}:requires=${long_deps}
EOCFG

run_init
if ! wait_for 'entri ditolak'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak mencatat penolakan string terlalu panjang dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "nama terlalu panjang ditolak" 'Parse err: nama layanan terlalu panjang'
check "perintah terlalu panjang ditolak" 'Parse err: perintah layanan'
check "dependensi terlalu panjang ditolak" 'Parse err: dependensi layanan'
check "layanan sehat tetap jalan ('started dep')" 'ninit: started dep (pid'
check_absent "layanan terlalu panjang TIDAK dijalankan" 'started longname'

# -------------------------------------------------------------- skenario 6
printf '\n== 6. layanan ke-65 melebihi batas MAX_SERVICES ==\n'
start_root maxsvc
LOG9="$LOG"

{
	i=1
	while [ "$i" -le 65 ]; do
		printf 'svc%02d:once::\n' "$i"
		i=$((i + 1))
	done
} > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop siap'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak selesai boot dalam ${READY_TIMEOUT}s pada uji layanan ke-65"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "peringatan batas 64 layanan tercapai" 'Peringatan: batas 64 layanan tercapai'
check_absent "layanan ke-65 tidak dijalankan" 'started svc65'

# -------------------------------------------------------------- skenario 7
printf '\n== 7. urutan dependensi yang dijanjikan README (logd once -> net once) ==\n'
start_root readmedep
LOG10="$LOG"

cat > "$ROOT/etc/init.conf" <<'EOCFG'
logd:once:/bin/sh -c 'sleep 0.3 && echo logd-ready'
net:once:echo net-started:requires=logd
EOCFG

run_init
if ! wait_for 'net-started'; then
	sed 's/^/  | /' "$LOG"
	fail "net tidak berjalan dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

seq_logd=$(grep -n '\[service\] logd-ready' "$LOG" | head -n 1 | cut -d: -f1 || true)
seq_net=$(grep -n 'ninit: started net' "$LOG" | head -n 1 | cut -d: -f1 || true)

if [ -n "$seq_logd" ] && [ -n "$seq_net" ] && [ "$seq_logd" -lt "$seq_net" ]; then
	ok "net baru berjalan SETELAH logd selesai ('logd-ready' sebelum 'started net')"
else
	bad "urutan dependensi README salah (posisi logd_ready=$seq_logd net_started=$seq_net)"
fi

# -------------------------------------------------------------- skenario 8
printf '\n== 8. validasi nama layanan tidak boleh mengandung / ==\n'
start_root slashname
LOG11="$LOG"

cat > "$ROOT/etc/init.conf" <<'EOCFG'
good_svc:once:true
bad/svc:once:true
EOCFG

run_init
if ! wait_for 'main loop siap'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak boot dalam ${READY_TIMEOUT}s pada uji nama dengan slash"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "error nama mengandung slash dicatat" 'Parse err: nama layanan'
check_absent "layanan dengan slash tidak dijalankan" 'started bad/svc'

# -------------------------------------------------------------- skenario 8
printf '\n== 9. baris config melebihi MAX_LINE ditolak utuh (audit SANE-03) ==\n'
start_root longline
LOG11="$LOG"

pad=$(printf 'x%.0s' $(seq 1 1200))
cat > "$ROOT/etc/init.conf" <<EOCFG
ghost:once:echo boo${pad}
realsvc:once:true
EOCFG

run_init
if ! wait_for 'main loop siap'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak mencapai main loop pada skenario baris panjang dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "baris terlalu panjang dicatat sebagai ditolak" 'melebihi MAX_LINE'
check "layanan sesudah baris panjang tetap terdaftar ('started realsvc')" 'ninit: started realsvc (pid'
check_absent "tidak ada layanan hantu dari potongan baris ('started ghost')" 'started ghost'

# ------------------------------------------------------------- skenario 10
printf '\n== 10. klasifikasi opsi fstab: flag VFS vs userspace vs data (audit SANE-02) ==\n'
start_root fstab
LOG12="$LOG"
mkdir -p "$ROOT/mnt"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/a tmpfs ro,nosuid,noatime,size=4M 0 0
tmpfs /mnt/b tmpfs noauto,mode=700 0 0
tmpfs /mnt/c tmpfs _netdev,x-custom,relatime,mode=755 0 0
EOFSTAB
printf 'fstabprobe:once:true\n' > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop siap'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak mencapai main loop pada skenario fstab dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "fstab a: flag VFS dipisah, data hanya opsi filesystem, mount ok" '\[data: size=4M\] ok'
check "fstab b: entri noauto dilewati" 'dilewati (opsi noauto)'
check_absent "fstab b: entri noauto TIDAK di-mount" 'mount tmpfs -> /mnt/b'
check "fstab c: opsi userspace dicatat sebagai diabaikan" 'khusus userspace, diabaikan'
check "fstab c: mount ok, data hanya mode=755" '\[data: mode=755\] ok'
check_absent "tidak ada mount fstab yang gagal" 'fstab: mount .* gagal'

# ------------------------------------------------------------- skenario 11
printf '\n== 11. batas baris di EOF: tepat MAX_LINE-1 diterima, MAX_LINE ditolak ==\n'
start_root eolbound
LOG13="$LOG"

# Baris komentar dipakai supaya yang diuji murni batas BARIS (MAX_LINE),
# bukan batas bidang nama/cmd/deps yang punya penolakan sendiri.
{ printf 'first:once:true\n'; printf '#%s' "$(printf 'x%.0s' $(seq 1 1022))"; } > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop siap'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak mencapai main loop pada skenario batas EOF dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "layanan normal tetap jalan pada skenario batas EOF" 'ninit: started first (pid'
check_absent "baris EOF tepat MAX_LINE-1 (1023) TIDAK ditolak" 'melebihi MAX_LINE'

start_root eolover
LOG14="$LOG"

{ printf 'first:once:true\n'; printf '#%s' "$(printf 'x%.0s' $(seq 1 1023))"; } > "$ROOT/etc/init.conf"

run_init
if ! wait_for 'main loop siap'; then
	sed 's/^/  | /' "$LOG"
	fail "ninit tidak mencapai main loop pada skenario batas EOF+1 dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "baris EOF MAX_LINE (1024) ditolak walau tanpa newline" 'melebihi MAX_LINE'
check "layanan normal tetap jalan setelah baris EOF ditolak" 'ninit: started first (pid'

# ------------------------------------------------------------- skenario 12
printf '\n== 12. fstab: exec/suid/dev, implikasi user, override kiri-ke-kanan (review PR #2) ==\n'
start_root fstabflags
LOG15="$LOG"
mkdir -p "$ROOT/mnt"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/e1 tmpfs exec,suid,dev,size=1M 0 0
tmpfs /mnt/e2 tmpfs user,size=1M 0 0
tmpfs /mnt/e3 tmpfs user,exec,size=1M 0 0
tmpfs /mnt/e4 tmpfs ro,rw,size=1M 0 0
EOFSTAB
printf 'dumpro:once:cat /proc/mounts > /var/mounts.txt\n' > "$ROOT/etc/init.conf"

run_init
i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	[ -s "$ROOT/var/mounts.txt" ] && break
	sleep 0.2
	i=$((i + 1))
done
if [ ! -s "$ROOT/var/mounts.txt" ]; then
	sed 's/^/  | /' "$LOG"
	fail "dumpro tidak menulis /var/mounts.txt dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "fstab e1: exec/suid/dev terkonsumsi (bukan data), mount ok" 'mount tmpfs -> /mnt/e1 (tmpfs) \[data: size=1M\] ok'
check "fstab e2: user dicatat menerapkan implikasinya" "opsi 'user' menerapkan noexec,nosuid,nodev"
check_absent "tidak ada mount fstab yang gagal" 'fstab: mount .* gagal'

# Bukti dari /proc/mounts di dalam guest: flag yang BENAR-BENAR terpakai,
# bukan sekadar mount() yang tidak error.
mount_opts() { awk -v m="$1" '$2 == m { print $4 }' "$ROOT/var/mounts.txt"; }
has_opt() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

e1_opts=$(mount_opts /mnt/e1)
if ! has_opt noexec "$e1_opts" && ! has_opt nosuid "$e1_opts" && ! has_opt nodev "$e1_opts"; then
	ok "fstab e1: /proc/mounts tanpa noexec/nosuid/nodev ($e1_opts)"
else
	bad "fstab e1: opts mengandung peniada yang tidak diminta ($e1_opts)"
fi

e2_opts=$(mount_opts /mnt/e2)
if has_opt noexec "$e2_opts" && has_opt nosuid "$e2_opts" && has_opt nodev "$e2_opts"; then
	ok "fstab e2: /proc/mounts membuktikan user -> noexec,nosuid,nodev ($e2_opts)"
else
	bad "fstab e2: implikasi user tidak terpakai (opts: '$e2_opts')"
fi

e3_opts=$(mount_opts /mnt/e3)
if has_opt nosuid "$e3_opts" && has_opt nodev "$e3_opts" && ! has_opt noexec "$e3_opts"; then
	ok "fstab e3: user,exec -> exec membatalkan noexec saja ($e3_opts)"
else
	bad "fstab e3: override user,exec salah (opts: '$e3_opts')"
fi

e4_opts=$(mount_opts /mnt/e4)
if has_opt rw "$e4_opts" && ! has_opt ro "$e4_opts"; then
	ok "fstab e4: ro,rw -> berakhir rw ($e4_opts)"
else
	bad "fstab e4: override ro,rw salah (opts: '$e4_opts')"
fi

# ------------------------------------------------------------- skenario 13
printf '\n== 13. fstab: mkdir rekursif, bind ditolak, skip sebelum mkdir (PR lanjutan) ==\n'
start_root fstabdeep
LOG16="$LOG"
# /mnt dibuat sebagai induk kontrol; yang diuji adalah level DI BAWAHNYA
# yang tidak dibuat dari luar (skenario 10/12 selalu menyiapkan jalurnya).
mkdir -p "$ROOT/mnt" "$ROOT/var/realdir"
touch "$ROOT/mnt/blocked" "$ROOT/var/afile"
ln -s /var/realdir "$ROOT/mnt/linkdir"
ln -s /var/afile "$ROOT/mnt/filelink"
ln -s /var/tidak-ada "$ROOT/mnt/dangle"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/deep/nested tmpfs size=1M 0 0
tmpfs /mnt/trail/ tmpfs size=1M 0 0
tmpfs /mnt/noauto-dir tmpfs noauto,size=1M 0 0
/sumber /mnt/bind-dir none bind 0 0
/sumber2 /mnt/nobind-dir none bind,noauto 0 0
tmpfs /mnt/filelink/x tmpfs size=1M 0 0
tmpfs /mnt/blocked/x tmpfs size=1M 0 0
tmpfs /mnt/./evil tmpfs size=1M 0 0
tmpfs /mnt/ghostdir/../evil tmpfs size=1M 0 0
tmpfs /mnt/dangle/x tmpfs size=1M 0 0
tmpfs /mnt/linkdir/deep tmpfs size=1M 0 0
tmpfs /mnt/after tmpfs size=1M 0 0
EOFSTAB
printf 'dumpro:once:cat /proc/mounts > /var/mounts.txt\n' > "$ROOT/etc/init.conf"

# umask ketat di guest: mountpoint hasil mkdir_p harus TETAP 0755 berkat
# chmod eksplisit, bukan 0700 warisan umask.
TEST_UMASK=077
run_init
i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	[ -s "$ROOT/var/mounts.txt" ] && break
	sleep 0.2
	i=$((i + 1))
done
if [ ! -s "$ROOT/var/mounts.txt" ]; then
	sed 's/^/  | /' "$LOG"
	fail "dumpro tidak menulis /var/mounts.txt pada skenario 13 dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init
TEST_UMASK=""

check "fstab f1: mountpoint bertingkat dibuat rekursif, mount ok" 'mount tmpfs -> /mnt/deep/nested (tmpfs) \[data: size=1M\] ok'
check "fstab f2: trailing slash ditangani, mount ok" 'mount tmpfs -> /mnt/trail/ (tmpfs) \[data: size=1M\] ok'
check "fstab f3: entri noauto dilewati" 'tmpfs -> /mnt/noauto-dir dilewati (opsi noauto)'
check "fstab f4: entri bind ditolak eksplisit" '/sumber -> /mnt/bind-dir dilewati (bind/rbind tidak didukung)'
check_absent "fstab f4: bind TIDAK ter-mount" 'mount /sumber -> /mnt/bind-dir'
check "fstab f4b: bind+noauto -> alasan pertama (noauto) yang dicatat" '/sumber2 -> /mnt/nobind-dir dilewati (opsi noauto)'
check_absent "fstab f4b: bind+noauto TIDAK dicatat sebagai bind" 'nobind-dir dilewati (bind'
check "fstab f5: komponen symlink-ke-file ditolak jelas" "komponen '/mnt/filelink' dari mountpoint '/mnt/filelink/x' bukan direktori"
check "fstab f6: komponen file biasa ditolak jelas" "komponen '/mnt/blocked' dari mountpoint '/mnt/blocked/x' bukan direktori"
check "fstab f7: komponen '.' ditolak" "memuat komponen '.', ditolak"
check "fstab f7b: komponen '..' ditolak oleh pra-pindai" "memuat komponen '..', ditolak"
check "fstab f7c: symlink menggantung ditolak jelas" "stat '/mnt/dangle' gagal"
check "fstab f8: symlink-ke-direktori diikuti, mount ok" 'mount tmpfs -> /mnt/linkdir/deep (tmpfs) \[data: size=1M\] ok'

# Bukti sisi host: direktori yang benar-benar dibuat / tidak dibuat.
if [ -d "$ROOT/mnt/deep/nested" ]; then ok "host: /mnt/deep/nested benar-benar dibuat"; else bad "host: /mnt/deep/nested tidak dibuat"; fi
if [ "$(stat -c %a "$ROOT/mnt/deep")" = "755" ] && [ "$(stat -c %a "$ROOT/mnt/deep/nested")" = "755" ]; then ok "host: mountpoint tetap 0755 walau umask guest 077 (chmod eksplisit)"; else bad "host: mode mountpoint bukan 0755 (deep=$(stat -c %a "$ROOT/mnt/deep" 2>/dev/null), nested=$(stat -c %a "$ROOT/mnt/deep/nested" 2>/dev/null))"; fi
if [ ! -e "$ROOT/mnt/noauto-dir" ]; then ok "host: entri noauto TIDAK meninggalkan direktori hantu"; else bad "host: entri noauto meninggalkan direktori hantu"; fi
if [ ! -e "$ROOT/mnt/bind-dir" ]; then ok "host: entri bind TIDAK meninggalkan direktori hantu"; else bad "host: entri bind meninggalkan direktori hantu"; fi
if [ ! -e "$ROOT/mnt/nobind-dir" ]; then ok "host: entri bind+noauto TIDAK meninggalkan direktori hantu"; else bad "host: entri bind+noauto meninggalkan direktori hantu"; fi
if [ ! -e "$ROOT/mnt/ghostdir" ]; then ok "host: pra-pindai '..' TIDAK meninggalkan direktori induk hantu"; else bad "host: pra-pindai '..' meninggalkan direktori induk hantu"; fi
if [ -d "$ROOT/var/realdir/deep" ]; then ok "host: mkdir lewat symlink membuat direktori di target aslinya"; else bad "host: direktori di target symlink tidak dibuat"; fi
if [ ! -e "$ROOT/mnt/evil" ]; then ok "host: path dengan '.' TIDAK dibuat"; else bad "host: path dengan '.' dibuat"; fi

# Bukti /proc/mounts guest: yang ter-mount dan isolasi kegagalan per entri.
if [ -n "$(mount_opts /mnt/deep/nested)" ]; then ok "guest: /mnt/deep/nested ter-mount"; else bad "guest: /mnt/deep/nested tidak ter-mount"; fi
if [ -n "$(mount_opts /mnt/trail)" ]; then ok "guest: /mnt/trail ter-mount (tanpa slash)"; else bad "guest: /mnt/trail tidak ter-mount"; fi
if [ -n "$(mount_opts /mnt/after)" ]; then ok "guest: entri sesudah yang gagal tetap ter-mount (isolasi per entri)"; else bad "guest: entri sesudah yang gagal TIDAK ter-mount"; fi
if [ -z "$(mount_opts /mnt/bind-dir)" ]; then ok "guest: /mnt/bind-dir tidak ter-mount"; else bad "guest: /mnt/bind-dir ter-mount"; fi
if [ -z "$(mount_opts /mnt/blocked/x)" ]; then ok "guest: /mnt/blocked/x tidak ter-mount"; else bad "guest: /mnt/blocked/x ter-mount"; fi

# ------------------------------------------------------------- skenario 14
printf '\n== 14. fstab: escape oktal didekode + mountpoint duplikat dilewati (PR3-C1/C2) ==\n'
start_root fstabesc
LOG17="$LOG"
mkdir -p "$ROOT/mnt"
cat > "$ROOT/etc/fstab" <<'EOFSTAB'
tmpfs /mnt/spa\040ce tmpfs size=1M 0 0
tmpfs /mnt/dup tmpfs nosuid,size=1M 0 0
tmpfs /mnt/dup tmpfs size=2M 0 0
tmpfs /mnt/\056\056/evil tmpfs size=1M 0 0
tmpfs /mnt/plain tmpfs size=1M 0 0
EOFSTAB
printf 'dumpro:once:cat /proc/mounts > /var/mounts.txt\n' > "$ROOT/etc/init.conf"

run_init
i=0
while [ "$i" -lt $((READY_TIMEOUT * 5)) ]; do
	[ -s "$ROOT/var/mounts.txt" ] && break
	sleep 0.2
	i=$((i + 1))
done
if [ ! -s "$ROOT/var/mounts.txt" ]; then
	sed 's/^/  | /' "$LOG"
	fail "dumpro tidak menulis /var/mounts.txt pada skenario 14 dalam ${READY_TIMEOUT}s"
fi
init_pid=$(find_init_pid || true)
INIT_PID="${init_pid:-}"
stop_init

check "fstab g1: escape oktal didekode, mount ke path berisi spasi ok" 'mount tmpfs -> /mnt/spa ce (tmpfs) \[data: size=1M\] ok'
check_absent "fstab g1: TIDAK ada mount ke nama harfiah backslash" 'mount tmpfs -> /mnt/spa\\040ce'
check "fstab g2: entri duplikat dilewati dengan catatan" 'tmpfs -> /mnt/dup dilewati (mountpoint duplikat'
check "fstab g3: escape terdekode menjadi '..' lalu ditolak pra-pindai" "memuat komponen '..', ditolak"
check "fstab g4: entri normal sesudahnya tetap diproses" 'mount tmpfs -> /mnt/plain (tmpfs) \[data: size=1M\] ok'

# Bukti sisi host: direktori yang benar-benar dibuat / tidak dibuat.
if [ -d "$ROOT/mnt/spa ce" ]; then ok "host: direktori 'spa ce' (spasi asli) benar-benar dibuat"; else bad "host: direktori 'spa ce' tidak dibuat"; fi
if [ ! -e "$ROOT/mnt/spa\040ce" ]; then ok "host: TIDAK ada direktori bernama harfiah 'spa\\040ce'"; else bad "host: ada direktori bernama harfiah backslash"; fi
if [ ! -e "$ROOT/mnt/evil" ]; then ok "host: escape '..' TIDAK meloloskan path"; else bad "host: escape '..' meloloskan path"; fi

# Bukti /proc/mounts guest: duplikat tidak menumpuk, proteksi entri
# pertama tidak tertutupi, dan path spasi tercatat (kernel menulis
# spasi sebagai \040 di /proc/mounts).
if [ "$(grep -c ' /mnt/dup ' "$ROOT/var/mounts.txt")" = "1" ]; then ok "guest: /mnt/dup ter-mount TEPAT satu kali"; else bad "guest: /mnt/dup ter-mount bukan satu kali"; fi
dup_opts=$(mount_opts /mnt/dup)
if has_opt nosuid "$dup_opts"; then ok "guest: proteksi entri pertama (nosuid) TIDAK tertutupi duplikat ($dup_opts)"; else bad "guest: nosuid entri pertama hilang (opts: '$dup_opts')"; fi
if grep -qF ' /mnt/spa\040ce ' "$ROOT/var/mounts.txt"; then ok "guest: mount path berisi spasi tercatat di /proc/mounts"; else bad "guest: mount path berisi spasi tidak tercatat"; fi

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
printf '\n== log 5 (penolakan string panjang) ==\n'
sed 's/^/  | /' "$LOG8"
printf '\n== log 6 (layanan ke-65) ==\n'
sed 's/^/  | /' "$LOG9"
printf '\n== log 7 (dependensi README: logd -> net) ==\n'
sed 's/^/  | /' "$LOG10"
printf '\n== log 9 (baris melebihi MAX_LINE) ==\n'
sed 's/^/  | /' "$LOG11"
printf '\n== log 10 (klasifikasi opsi fstab) ==\n'
sed 's/^/  | /' "$LOG12"
printf '\n== log 11 (batas EOF MAX_LINE) ==\n'
sed 's/^/  | /' "$LOG13"
printf '\n== log 11b (batas EOF MAX_LINE+1) ==\n'
sed 's/^/  | /' "$LOG14"
printf '\n== log 12 (fstab: exec/suid/dev + implikasi user) ==\n'
sed 's/^/  | /' "$LOG15"
printf '\n== log 13 (fstab: mkdir rekursif + bind ditolak) ==\n'
sed 's/^/  | /' "$LOG16"
printf '\n== log 14 (fstab: escape oktal + duplikat) ==\n'
sed 's/^/  | /' "$LOG17"

if [ "$fail_count" -eq 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	exit 1
fi
