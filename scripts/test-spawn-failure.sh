#!/bin/sh
# test-spawn-failure.sh -- jalur kegagalan spawn(): fork() gagal, dependensi
# gagal, dan dependensi yang belum terpenuhi lewat jalur respawn.
#
# Kenapa suite ini ada: audit eksternal atas main (af3388f) mengklaim bahwa
# kegagalan fork() membuat PID 1 terkunci dalam do-while tanpa pernah kembali
# ke ppoll(). Klaim itu tidak terbukti saat diuji: spawn_service() sudah
# men-set last_start SEBELUM fork(), sehingga jendela RESPAWN_DELAY membuat
# loop keluar dan event loop tetap jalan. Pengujian ulang jalur yang sama
# menemukan dua cacat nyata lainnya:
#
#   1. respawn_services() tidak membaca dependensi sama sekali. Layanan yang
#      sudah "dibatalkan" karena dependensi once-nya gagal tetap dihidupkan
#      ulang selamanya -- pesan pembatalan hanya jadi hiasan log, dan janji
#      urutan `requires=` dilanggar lewat jalur respawn.
#   2. Layanan once yang fork()-nya gagal tidak pernah punya jalur retry
#      (respawn_services hanya menangani svc->respawn) dan tidak pernah
#      berakhir di keadaan terminal: ia tertinggal di SVC_STATE_STOPPED
#      selamanya sementara dependennya menunggu tanpa pesan apa pun.
#
# Skenario 1 dan 2 mengunci perbaikan (1) dan berjalan di lingkungan mana pun
# seperti suite sejenis. Skenario 3 mengunci perbaikan (2) dengan memaksa
# fork() mengembalikan EAGAIN lewat controller cgroup v2 `pids` (root kebal
# RLIMIT_NPROC, jadi pids.max=1 adalah satu-satunya cara deterministik);
# skenario ini dilewati dengan catatan bila pids controller tidak terdelegasi.
# Skenario 4 menguji crash-loop limit pada layanan respawn yang membatalkan
# layanan dependen (transitif).
# Skenario 5 menguji penegakan batas waktu :timeout= pada layanan once yang
# mengeksekusi SIGKILL dan membatalkan layanan dependen.
#
# Pemakaian:
#   sudo sh ./scripts/test-spawn-failure.sh      # atau: make test
#
# Variabel lingkungan:
#   BIN=./ninit              biner yang diuji
#   BUSYBOX=/bin/busybox     busybox statis (apt-get install busybox-static)
#   WAIT1/WAIT2/WAIT3        jendela observasi tiap skenario (detik)
#
# Catatan: seperti smoke-test.sh, script ini memakai `--mount --propagation
# private` + `mount -t proc` manual, bukan `unshare --mount-proc`, karena
# sebagian kernel menolak perubahan mount propagation dengan EINVAL.

set -eu

BIN=${BIN:-./ninit}
BUSYBOX=${BUSYBOX:-/bin/busybox}
WAIT1=${WAIT1:-6}
WAIT2=${WAIT2:-6}
WAIT3=${WAIT3:-10}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "biner '$BIN' tidak ditemukan/tidak executable (jalankan: make)"
[ -f "$BUSYBOX" ] || fail "busybox statis tidak ada di '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout grep mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "perkakas '$t' tidak ditemukan"
done
$SUDO true 2>/dev/null || fail "butuh root atau sudo tanpa password (unshare + chroot)"

CG=/sys/fs/cgroup/ninit-spawnfail-$$
ROOTS=""
LOGS=""
HELPERS=""
INNER=$(mktemp /tmp/ninit-spawnfail-inner.XXXXXX)
cleanup() {
	for d in ${ROOTS:-}; do
		$SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d"
	done
	for f in ${LOGS:-}; do rm -f "$f"; done
	for h in ${HELPERS:-}; do rm -f "$h"; done
	$SUDO rm -f "$INNER" 2>/dev/null || true
	# Bersihkan HANYA cgroup khusus skenario 3 (nama unik per-PID). Jangan
	# pernah menyentuh /sys/fs/cgroup/ninit milik workload lain di host.
	if [ -d "$CG" ]; then
		$SUDO rmdir "$CG" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

fail_count=0
ok()   { printf '  [ OK ]   %s\n' "$1"; }
bad()  { printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  [ -- ]   %s\n' "$1"; }
check_in()  { if grep -q "$3" "$2"; then ok "$1"; else bad "$1"; fi; }
absent_in() { if grep -q "$3" "$2"; then bad "$1"; else ok "$1"; fi; }

# rootfs uji baru; argumen tambahan adalah applet busybox yang dibutuhkan.
# Pemanggil WAJIB mencatat hasilnya ke ROOTS: fungsi ini dipanggil lewat
# command substitution (subshell), jadi pengumpulan di dalam fungsi tidak
# akan pernah terlihat oleh trap cleanup di proses induk.
new_root() {
	d=$(mktemp -d /tmp/ninit-spawnfail.XXXXXX)
	mkdir -p "$d/proc" "$d/sys" "$d/dev" "$d/run" "$d/tmp" "$d/etc" \
	         "$d/var/log" "$d/bin"
	cp "$BIN" "$d/ninit"
	cp "$BUSYBOX" "$d/bin/sh"
	for a in "$@"; do cp "$BUSYBOX" "$d/bin/$a"; done
	# /dev/null berupa berkas biasa: ninit membuka /dev/null untuk stdin anak,
	# dan harness ini sengaja tidak memakai mknod.
	: > "$d/dev/null"
	printf '%s\n' "$d"
}

new_log() {
	mktemp /tmp/ninit-spawnfail-log.XXXXXX
}

# Boot ninit sebagai PID 1 di dalam pid+mount namespace selama ~$2 detik.
# Bila $3 diisi path cgroup, proses yang akan menjadi ninit memindahkan
# dirinya ke cgroup itu SEBELUM exec -- jadi slot pids.max sudah terisi saat
# ninit mencoba fork() anak layanan, dan fork() itu gagal dengan EAGAIN.
boot_guest() {
	root=$1; secs=$2; cg=${3:-}
	if [ -n "$cg" ]; then
		move="echo \$\$ > $cg/cgroup.procs;"
	else
		move=""
	fi
	cat > "$INNER" <<EOI
#!/bin/sh
mount -t proc proc $root/proc
$move
exec chroot $root /ninit
EOI
	$SUDO chmod 755 "$INNER"
	$SUDO sh -c "timeout -s KILL $((secs + 3)) unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh $INNER" || true
}

printf '== biner uji : %s\n' "$BIN"

# ------------------------------------------------------------- Skenario 1
# Dependensi once GAGAL -> layanan respawn harus dibatalkan dan tidak boleh
# pernah di-start. Regresi yang dikunci: jalur respawn lama mengabaikan
# dependensi, sehingga "dibatalkan" disusul "started app" berulang.
printf '\n== Skenario 1: dependensi gagal, layanan respawn tidak boleh di-respawn ==\n'
R1=$(new_root)
L1=$(new_log)
ROOTS="$ROOTS $R1"
LOGS="$LOGS $L1"
printf 'boot:once:exit 3\napp:respawn:exit 0:requires=boot\n' > "$R1/etc/init.conf"
boot_guest "$R1" "$WAIT1" "" >"$L1" 2>&1
check_in  "boot dijalankan lalu gagal (exit status=0x300)" "$L1" \
	'boot (pid .* exit status=0x300'
check_in  "app dibatalkan karena dependensi gagal" "$L1" \
	"layanan 'app' dibatalkan: dependensi 'boot' gagal"
absent_in "app TIDAK pernah di-start setelah dibatalkan" "$L1" 'started app'

# ------------------------------------------------------------- Skenario 2
# Dependensi once MASIH BERJALAN -> layanan respawn tidak boleh start lebih
# dulu. Bukti urutan diambil dari /var/order yang ditulis layanan dari dalam
# guest (/var, bukan /tmp: ninit menimpa /tmp dan /run dengan tmpfs di dalam
# namespace sehingga tidak terlihat dari host).
#
# Layanan `ping` sengaja ikut dipasang: tanpa dia, event loop lama akan
# memblokir di ppoll tanpa timeout sampai `slow` selesai, jadi jalur respawn
# yang salah itu tidak pernah tersentuh dan testnya jadi hampa. SIGCHLD dari
# ping yang segera keluar memaksa loop berjalan kembali SELAGI slow masih
# tidur -- persis saat jalur respawn lama mengambil keputusan yang salah.
printf '\n== Skenario 2: dependensi belum selesai, respawn tidak boleh mendahului ==\n'
R2=$(new_root sleep)
L2=$(new_log)
ROOTS="$ROOTS $R2"
LOGS="$LOGS $L2"
printf 'ping:once:echo PING-DONE >> /var/order\nslow:once:/bin/sleep 4; echo SLOW-DONE >> /var/order\napp:respawn:echo APP-START >> /var/order:requires=slow\n' \
	> "$R2/etc/init.conf"
boot_guest "$R2" "$WAIT2" "" >"$L2" 2>&1
check_in "ping dijalankan" "$L2" 'started ping'
check_in "slow dijalankan" "$L2" 'started slow'
check_in "app dijalankan"  "$L2" 'started app'
n_slow=$(grep -n -m1 'SLOW-DONE'  "$R2/var/order" 2>/dev/null | cut -d: -f1 || true)
n_app=$(grep -n -m1 'APP-START'  "$R2/var/order" 2>/dev/null | cut -d: -f1 || true)
if [ -z "${n_slow:-}" ] || [ -z "${n_app:-}" ]; then
	bad "/var/order tidak memuat SLOW-DONE dan APP-START (slow=${n_slow:-?} app=${n_app:-?})"
elif [ "$n_slow" -lt "$n_app" ]; then
	ok "app baru menulis SETELAH dependensi once selesai (SLOW-DONE baris $n_slow < APP-START baris $n_app)"
else
	bad "app mendahului dependensi once-nya (SLOW-DONE baris $n_slow, APP-START baris $n_app)"
fi

# ------------------------------------------------------------- Skenario 3
# fork() gagal terus (EAGAIN) pada layanan once -> percobaan dibatasi, lalu
# state terminal FAILED, lalu dependennya dibatalkan. Bila do-while benar-benar
# terkunci seperti dugaan audit, 'main loop siap' tidak akan pernah tercetak.
printf '\n== Skenario 3: kegagalan fork() pada layanan once (pids.max=1) ==\n'
pids_ok=0
if [ -r /sys/fs/cgroup/cgroup.controllers ] \
   && $SUDO grep -qw pids /sys/fs/cgroup/cgroup.controllers 2>/dev/null \
   && $SUDO mkdir -p "$CG" 2>/dev/null && [ -e "$CG/pids.max" ]; then
	printf '1\n' | $SUDO tee "$CG/pids.max" >/dev/null && pids_ok=1
fi

if [ "$pids_ok" -ne 1 ]; then
	skip "skenario 3 dilewati: cgroup v2 + controller pids tidak tersedia/terdelegasi"
else
	R3=$(new_root)
	L3=$(new_log)
	ROOTS="$ROOTS $R3"
	LOGS="$LOGS $L3"
	printf 'boot:once:exit 0\napp:respawn:exit 0:requires=boot\n' > "$R3/etc/init.conf"
	boot_guest "$R3" "$WAIT3" "$CG" >"$L3" 2>&1

	check_in  "event loop tetap masuk (tidak ada busy-loop)" "$L3" 'main loop siap'
	check_in  "kegagalan fork() tercatat untuk boot" "$L3" \
		'fork boot: Resource temporarily unavailable'
	check_in  "percobaan dibatasi lalu boot dinyatakan gagal" "$L3" \
		'percobaan, layanan dinyatakan gagal'
	check_in  "dependen dibatalkan bersih" "$L3" \
		"layanan 'app' dibatalkan: dependensi 'boot' gagal"
	absent_in "boot tidak pernah berhasil di-spawn" "$L3" 'started boot'
	absent_in "app tidak dicoba spawn sebelum dependensi terminal" "$L3" 'fork app'
	nfork=$(grep -c 'fork boot' "$L3" 2>/dev/null || true)
	if [ "${nfork:-0}" -le 3 ]; then
		ok "jumlah percobaan fork() boot terbatas: $nfork (maks 3, tanpa busy-loop)"
	else
		bad "percobaan fork() boot tidak terbatas: $nfork baris (dugaan busy-loop)"
	fi
fi

# ------------------------------------------------------------- Skenario 4
# Layanan respawn yang crash-loop berulang hingga FAILED membatalkan seluruh
# layanan dependennya transitif (bukan menggantung di STOPPED selamanya).
# Biner ninit dikompilasi dengan batas override -DCRASH_LIMIT=2 -DBACKOFF_MAX=1
# agar crash-loop terdeteksi cepat (<3 detik) tanpa menunggu interval 60s.
printf '\n== Skenario 4: Layanan respawn crash-loop membatalkan layanan dependen ==\n'
BIN_FAST=$(mktemp /tmp/ninit-fast-bin.XXXXXX)
HELPERS="$HELPERS $BIN_FAST"
gcc -static -O2 -Wall -DCRASH_LIMIT=2 -DBACKOFF_MAX=1 ./ninit.c -o "$BIN_FAST"

R4=$(new_root sleep)
L4=$(new_log)
ROOTS="$ROOTS $R4"
LOGS="$LOGS $L4"

# Ganti biner ninit di guest dengan biner fast-crash
cp "$BIN_FAST" "$R4/ninit"

cat > "$R4/etc/init.conf" << 'EOF'
slow:once:/bin/sleep 2
crasher:respawn:exit 1
dep:once:echo DEP_STARTED > /var/dep.txt:requires=crasher,slow
stopper:once:/bin/sh -c "/bin/sleep 4 && echo poweroff > /run/initctl"
EOF

boot_guest "$R4" 6 "" >"$L4" 2>&1

check_in  "crasher terdeteksi crash-loop dan dinyatakan gagal" "$L4" \
	'crasher: crash-loop terdeteksi'
check_in  "dependen dibatalkan karena dependensi respawn gagal" "$L4" \
	"layanan 'dep' dibatalkan: dependensi 'crasher' gagal"
absent_in "dependen tidak pernah dijalankan" "$L4" 'started dep'

# ------------------------------------------------------------- Skenario 5
# Layanan once dengan batas :timeout=2 yang tidur melebihi batas waktu di-SIGKILL
# dan seluruh dependennya dibatalkan secara transitif.
printf '\n== Skenario 5: Layanan once dengan :timeout=2 dibunuh & dependen dibatalkan ==\n'
R5=$(new_root sleep)
L5=$(new_log)
ROOTS="$ROOTS $R5"
LOGS="$LOGS $L5"

cat > "$R5/etc/init.conf" << 'EOF'
hanger:once:/bin/sleep 20:timeout=2
dep:once:echo DEP_STARTED > /var/dep.txt:requires=hanger
stopper:once:/bin/sh -c "/bin/sleep 4 && echo poweroff > /run/initctl"
EOF

boot_guest "$R5" 6 "" >"$L5" 2>&1

check_in  "hanger dibunuh karena batas waktu timeout 2 detik" "$L5" \
	'hanger: layanan once melebihi batas waktu 2 detik, dinyatakan gagal'
check_in  "hanger dimatikan paksa oleh sinyal (exit status=0x9)" "$L5" \
	'hanger (pid .* exit status=0x9'
check_in  "dependen dibatalkan saat layanan once timeout" "$L5" \
	"layanan 'dep' dibatalkan: dependensi 'hanger' gagal"
absent_in "hanger tidak selesai secara sukses" "$L5" 'hanger (pid .* exit status=0x0'
absent_in "dependen tidak pernah dijalankan" "$L5" 'started dep'

if [ "$fail_count" -eq 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	for l in ${LOGS:-}; do
		printf '\n-- ekor log %s --\n' "$l"
		tail -n 15 "$l" | sed 's/^/  | /'
	done
	exit 1
fi
