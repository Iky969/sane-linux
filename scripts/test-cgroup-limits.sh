#!/bin/sh
# test-cgroup-limits.sh -- pengujian cgroup v2 resource limits (memory, cpu, pids)
# dan pembersihan siklus hidup orphan saat respawn layanan.
#
# Kenapa suite ini ada: Requirement R4 menuntut suite pengujian otomatis untuk
# memverifikasi bahwa:
#   1. memory_max membatasi alokasi berlebih dan memicu OOM kill deterministik
#      (exit status 0x9 / 137).
#   2. pids_max membatasi fork berlebih dan menolak proses baru deterministik
#      dengan EAGAIN (Resource temporarily unavailable).
#   3. cgroup_kill_service membersihkan proses anak/orphan yang ditinggalkan
#      oleh pemimpin layanan respawn sebelum generasi baru dihidupkan.
#   4. Konfigurasi leaf cgroup (memory.max, cpu.max, pids.max) tertulis dengan
#      benar ke hierarki cgroup v2 layanan dan mendukung urutan opsi bebas.
#   5. Validasi parser menerima format limit valid dan menolak format rusak
#      (malformed) dengan log peringatan informatif tanpa crash PID 1.
#   6. Penulisan subtree control mentoleransi environment nested/container
#      dan partial subtree control tanpa menggagalkan boot.
#   7. Interaksi PR #9: layanan once dengan pids_max=1 yang mengalami fork EAGAIN
#      mencoba ulang hingga batas MAX_SPAWN_RETRY (3x), transisi ke FAILED,
#      dan membatalkan layanan dependen deterministik.
#   8. Pembersihan siklus hidup orphan pada layanan once (cgroup_kill_service
#      sebelum rmdir) menyapu bersih proses anak orphan sebelum rmdir leaf cgroup.
#
# Pemakaian:
#   sudo sh ./scripts/test-cgroup-limits.sh      # atau: make test
#
# Variabel lingkungan:
#   BIN=./ninit              biner yang diuji
#   BUSYBOX=/bin/busybox     busybox statis (apt-get install busybox-static)
#   WAIT1..WAIT8             jendela waktu observasi tiap skenario (detik)
#
# Catatan: suite ini menggunakan unshare dengan `--mount --propagation private`
# dan `mount -t proc` manual (bukan `--mount-proc`), konsisten dengan konvensi
# repo untuk menghindari penolakan EINVAL pada kernel tertentu.

set -eu

BIN=${BIN:-./ninit}
BUSYBOX=${BUSYBOX:-/bin/busybox}
WAIT1=${WAIT1:-6}
WAIT2=${WAIT2:-6}
WAIT3=${WAIT3:-8}
WAIT4=${WAIT4:-6}
WAIT5=${WAIT5:-6}
WAIT6=${WAIT6:-6}
WAIT7=${WAIT7:-8}
WAIT8=${WAIT8:-6}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "biner '$BIN' tidak ditemukan/tidak executable (jalankan: make)"
[ -f "$BUSYBOX" ] || fail "busybox statis tidak ada di '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout grep mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "perkakas '$t' tidak ditemukan"
done
$SUDO true 2>/dev/null || fail "butuh root atau sudo tanpa password (unshare + chroot)"

CG_CONTROLLERS="/sys/fs/cgroup/cgroup.controllers"
has_cg2=0
has_mem=0
has_pids=0
has_cpu=0
if [ -r "$CG_CONTROLLERS" ]; then
	has_cg2=1
	$SUDO grep -qw memory "$CG_CONTROLLERS" 2>/dev/null && has_mem=1 || true
	$SUDO grep -qw pids "$CG_CONTROLLERS" 2>/dev/null && has_pids=1 || true
	$SUDO grep -qw cpu "$CG_CONTROLLERS" 2>/dev/null && has_cpu=1 || true
fi

ROOTS=""
LOGS=""
HELPERS=""
CG_DYNAMIC=""
INNER=$(mktemp /tmp/ninit-cginner.XXXXXX)
cleanup() {
	for d in ${ROOTS:-}; do
		$SUDO umount -R "$d" 2>/dev/null || $SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d"
	done
	for f in ${LOGS:-}; do rm -f "$f"; done
	for h in ${HELPERS:-}; do rm -f "$h"; done
	$SUDO rm -f "$INNER" 2>/dev/null || true

	# Bersihkan cgroup ninit dan leaf cgroups yang tertinggal pada host
	if [ -d "/sys/fs/cgroup/ninit" ]; then
		for leaf in /sys/fs/cgroup/ninit/*; do
			[ -d "$leaf" ] || continue
			if [ -f "$leaf/cgroup.kill" ]; then
				echo 1 | $SUDO tee "$leaf/cgroup.kill" >/dev/null 2>&1 || true
			fi
			$SUDO rmdir "$leaf" 2>/dev/null || {
				sleep 0.1
				$SUDO rmdir "$leaf" 2>/dev/null || true
			}
		done
		$SUDO rmdir /sys/fs/cgroup/ninit 2>/dev/null || true
	fi

	# Bersihkan cgroup dinamis/ephemeral yang dibuat selama pengujian
	for cg in ${CG_DYNAMIC:-}; do
		if [ -d "$cg" ]; then
			if [ -f "$cg/cgroup.kill" ]; then
				echo 1 | $SUDO tee "$cg/cgroup.kill" >/dev/null 2>&1 || true
			fi
			$SUDO rmdir "$cg" 2>/dev/null || {
				sleep 0.1
				$SUDO rmdir "$cg" 2>/dev/null || true
			}
		fi
	done
}
trap cleanup EXIT INT TERM

fail_count=0
ok()   { printf '  [ OK ]   %s\n' "$1"; }
bad()  { printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  [ -- ]   %s\n' "$1"; }
check_in()  { if grep -q "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
absent_in() { if grep -q "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi; }

new_root() {
	d=$(mktemp -d /tmp/ninit-cgtest.XXXXXX)
	mkdir -p "$d/proc" "$d/sys" "$d/dev" "$d/run" "$d/tmp" "$d/etc" \
	         "$d/var/log" "$d/bin"
	cp "$BIN" "$d/ninit"
	cp "$BUSYBOX" "$d/bin/sh"
	for a in "$@"; do cp "$BUSYBOX" "$d/bin/$a"; done
	: > "$d/dev/null"
	printf '%s\n' "$d"
}

new_log() {
	mktemp /tmp/ninit-cgtest-log.XXXXXX
}

boot_guest() {
	root=$1; secs=$2; cg=${3:-}; extra_setup=${4:-}
	if [ -n "$cg" ]; then
		move="echo \$\$ > $cg/cgroup.procs;"
	else
		move=""
	fi
	cat > "$INNER" <<EOI
#!/bin/sh
mount -t proc proc $root/proc
$move
$extra_setup
exec chroot $root /ninit
EOI
	$SUDO chmod 755 "$INNER"
	$SUDO sh -c "timeout -s KILL $((secs + 3)) unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh $INNER" || true
}

# Siapkan biner bantuan statis untuk alokasi memori berlebih dan pengujian fork
HOG_BIN=""
FORK_BIN=""
if command -v gcc >/dev/null 2>&1; then
	HOG_SRC=$(mktemp /tmp/ninit-hog.XXXXXX.c)
	HOG_BIN=$(mktemp /tmp/ninit-hog-bin.XXXXXX)
	FORK_SRC=$(mktemp /tmp/ninit-fork.XXXXXX.c)
	FORK_BIN=$(mktemp /tmp/ninit-fork-bin.XXXXXX)
	HELPERS="$HELPERS $HOG_SRC $HOG_BIN $FORK_SRC $FORK_BIN"

	cat > "$HOG_SRC" << 'EOF'
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    /* Alokasikan secara agresif tanpa jeda agar melampaui batas memory.max
       (16M) dan langsung memicu OOM killer secara deterministik */
    for (int i = 0; i < 256; i++) {
        void *p = malloc(1024 * 1024);
        if (!p) return 1;
        memset(p, 0x55, 1024 * 1024);
    }
    return 0;
}
EOF
	gcc -static -O2 "$HOG_SRC" -o "$HOG_BIN" 2>/dev/null || HOG_BIN=""

	cat > "$FORK_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
int main(void) {
    pid_t pids[10]; int count = 0;
    int eagain = 0;
    for (int i = 0; i < 10; i++) {
        pid_t p = fork();
        if (p < 0) {
            if (errno == EAGAIN) eagain = 1;
            break;
        } else if (p == 0) {
            sleep(2);
            _exit(0);
        } else {
            pids[count++] = p;
        }
    }
    FILE *f = fopen("/var/pids_audit.txt", "w");
    if (f) {
        if (eagain) fprintf(f, "EAGAIN_CONFIRMED count=%d\n", count);
        else fprintf(f, "FAILED_WITHOUT_EAGAIN\n");
        fclose(f);
    }
    for (int i = 0; i < count; i++) waitpid(pids[i], NULL, 0);
    return 0;
}
EOF
	gcc -static -O2 "$FORK_SRC" -o "$FORK_BIN" 2>/dev/null || FORK_BIN=""
fi

printf '== biner uji : %s\n' "$BIN"

# ------------------------------------------------------------- Skenario 1
# Batas Memori (memory.max) & Deterministic OOM Killer
# Layanan dibatasi memory_max=16M. Workload mengalokasikan dan menyentuh memori
# hingga melebihi batas. Kernel cgroup v2 memicu OOM killer (SIGKILL, exit 0x9).
# Init PID 1 menangani exit status=0x9 tanpa crash dan membersihkan leaf cgroup.
printf '\n== Skenario 1: Batas memori (memory_max=16M) & deterministic OOM ==\n'
if [ "$has_cg2" -ne 1 ] || [ "$has_mem" -ne 1 ] || [ -z "$HOG_BIN" ]; then
	skip "skenario 1 dilewati: cgroup v2 + controller memory tidak tersedia atau gcc tidak ada"
else
	R1=$(new_root sleep)
	L1=$(new_log)
	ROOTS="$ROOTS $R1"
	LOGS="$LOGS $L1"
	cp "$HOG_BIN" "$R1/bin/mem_hog"
	printf 'mem_test:once:/bin/mem_hog:memory_max=16M\nstopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl"\n' \
		> "$R1/etc/init.conf"
	boot_guest "$R1" "$WAIT1" >"$L1" 2>&1

	check_in  "konfigurasi limit memory.max diterapkan" "$L1" \
		"cgroup: 'mem_test' memory.max = 16M"
	check_in  "layanan mem_test dihentikan deterministik oleh OOM (exit status=0x9)" "$L1" \
		'mem_test (pid .* exit status=0x9'
	check_in  "leaf cgroup dibersihkan setelah OOM" "$L1" \
		"cgroup: dibersihkan 'mem_test'"
	check_in  "event loop tetap jalan dan shutdown bersih" "$L1" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Skenario 2
# Batas PIDs (pids.max) & Deterministic Fork EAGAIN
# Layanan dibatasi pids_max=5. Proses induk melakukan loop fork anak proses.
# Setelah proses di dalam cgroup mencapai 5, panggilan fork() berikutnya
# deterministik ditolak dengan EAGAIN (Resource temporarily unavailable).
printf '\n== Skenario 2: Batas proses (pids_max=5) & deterministic fork EAGAIN ==\n'
if [ "$has_cg2" -ne 1 ] || [ "$has_pids" -ne 1 ] || [ -z "$FORK_BIN" ]; then
	skip "skenario 2 dilewati: cgroup v2 + controller pids tidak tersedia atau gcc tidak ada"
else
	R2=$(new_root sleep)
	L2=$(new_log)
	ROOTS="$ROOTS $R2"
	LOGS="$LOGS $L2"
	cp "$FORK_BIN" "$R2/bin/fork_test"
	printf 'pids_test:once:/bin/fork_test:pids_max=5\nstopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl"\n' \
		> "$R2/etc/init.conf"
	boot_guest "$R2" "$WAIT2" >"$L2" 2>&1

	check_in  "konfigurasi limit pids.max diterapkan" "$L2" \
		"cgroup: 'pids_test' pids.max = 5"
	check_in  "fork melebihi batas ditolak deterministik dengan EAGAIN" "$R2/var/pids_audit.txt" \
		'EAGAIN_CONFIRMED count=4'
	check_in  "leaf cgroup dibersihkan setelah selesai" "$L2" \
		"cgroup: dibersihkan 'pids_test'"
	check_in  "event loop tetap jalan dan shutdown bersih" "$L2" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Skenario 3
# Pembersihan Siklus Hidup saat Respawn (Lifecycle Orphan Clean Sweep)
# Layanan respawn membuat proses anak di background (`sleep 300 &`) lalu
# pemimpin keluar. `cgroup_kill_service` harus menyapu bersih seluruh proses
# anak/orphan sebelum generasi baru dihidupkan pada jeda RESPAWN_DELAY.
printf '\n== Skenario 3: Pembersihan orphan saat respawn (cgroup_kill_service) ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "skenario 3 dilewati: cgroup v2 tidak tersedia"
else
	R3=$(new_root sleep)
	L3=$(new_log)
	ROOTS="$ROOTS $R3"
	LOGS="$LOGS $L3"
	cat > "$R3/bin/leak.sh" << 'EOF'
#!/bin/sh
if [ ! -f /var/gen1_started ]; then
    touch /var/gen1_started
    /bin/sleep 300 &
    /bin/sleep 300 &
    /bin/sleep 0.2
    exit 0
else
    # Generasi 2: periksa apakah ada proses sleep orphan dari Gen 1 yang bertahan
    touch /var/gen2_started
    lingering=0
    for d in /proc/[0-9]*; do
        if [ -f "$d/comm" ] && [ "$(cat "$d/comm" 2>/dev/null)" = "sleep" ]; then
            lingering=$((lingering + 1))
        fi
    done
    echo "LINGERING_ORPHANS=$lingering" > /var/leak_audit.txt
    echo poweroff > /run/initctl
    exit 0
fi
EOF
	chmod 0755 "$R3/bin/leak.sh"
	printf 'leak:respawn:/bin/sh /bin/leak.sh\n' > "$R3/etc/init.conf"
	boot_guest "$R3" "$WAIT3" >"$L3" 2>&1

	check_in  "layanan leak generasi 1 dijalankan" "$L3" \
		"started leak (pid "
	check_in  "respawn generasi 1 ditunda timer" "$L3" \
		'leak: respawn ditunda'
	if [ -f "$R3/var/gen2_started" ]; then
		ok "layanan leak generasi 2 berhasil dijalankan kembali"
	else
		bad "layanan leak generasi 2 berhasil dijalankan kembali"
	fi
	check_in  "orphan generasi 1 disapu bersih tanpa sisa (LINGERING_ORPHANS=0)" "$R3/var/leak_audit.txt" \
		'LINGERING_ORPHANS=0'
	check_in  "leaf cgroup dibersihkan saat shutdown" "$L3" \
		"cgroup: dibersihkan 'leak'"
fi

# ------------------------------------------------------------- Skenario 4
# Verifikasi Leaf Cgroup (memory.max, cpu.max, pids.max) & Urutan Opsi Bebas
# Memverifikasi bahwa nilai konfigurasi tertulis langsung ke filesystem cgroup
# pada leaf node layanan, dan opsi konfigurasi diproses secara benar meskipun
# urutan tag dibalik (:pids_max=...:cpu_max=...:memory_max=...).
printf '\n== Skenario 4: Verifikasi nilai leaf cgroup & urutan opsi bebas ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "skenario 4 dilewati: cgroup v2 tidak tersedia"
else
	R4=$(new_root cat sleep)
	L4=$(new_log)
	ROOTS="$ROOTS $R4"
	LOGS="$LOGS $L4"
	printf 'limits_audit:once:/bin/sh -c "cat /sys/fs/cgroup/ninit/limits_audit/memory.max > /var/mem.val && cat /sys/fs/cgroup/ninit/limits_audit/cpu.max > /var/cpu.val && cat /sys/fs/cgroup/ninit/limits_audit/pids.max > /var/pids.val && echo poweroff > /run/initctl":pids_max=20:cpu_max=50000 100000:memory_max=32M\n' \
		> "$R4/etc/init.conf"
	boot_guest "$R4" "$WAIT4" >"$L4" 2>&1

	check_in "konfigurasi memory.max tercatat di log" "$L4" \
		"cgroup: 'limits_audit' memory.max = 32M"
	check_in "konfigurasi cpu.max tercatat di log" "$L4" \
		"cgroup: 'limits_audit' cpu.max = 50000 100000"
	check_in "konfigurasi pids.max tercatat di log" "$L4" \
		"cgroup: 'limits_audit' pids.max = 20"
	if [ "$has_mem" -eq 1 ]; then
		check_in "nilai leaf memory.max terbaca 32M (33554432 byte)" "$R4/var/mem.val" \
			'33554432'
	else
		skip "pembacaan leaf memory.max dilewati: controller memory tidak aktif"
	fi
	if [ "$has_cpu" -eq 1 ]; then
		check_in "nilai leaf cpu.max terbaca 50000 100000" "$R4/var/cpu.val" \
			'50000 100000'
	else
		skip "pembacaan leaf cpu.max dilewati: controller cpu tidak aktif"
	fi
	if [ "$has_pids" -eq 1 ]; then
		check_in "nilai leaf pids.max terbaca 20" "$R4/var/pids.val" \
			'20'
	else
		skip "pembacaan leaf pids.max dilewati: controller pids tidak aktif"
	fi
	check_in "leaf cgroup dibersihkan setelah selesai" "$L4" \
		"cgroup: dibersihkan 'limits_audit'"
fi

# ------------------------------------------------------------- Skenario 5
# Validasi Parser Limit Resource (Valid vs Invalid/Malformed)
# Memverifikasi bahwa parser menerima format limit yang valid (memory_max,
# cpu_max, pids_max) dan menolak nilai rusak/malformed dengan log peringatan
# tanpa menyebabkan crash pada PID 1.
printf '\n== Skenario 5: Validasi parser batas resource (valid vs malformed) ==\n'
R5=$(new_root sleep true)
L5=$(new_log)
ROOTS="$ROOTS $R5"
LOGS="$LOGS $L5"

cat > "$R5/etc/init.conf" << 'EOF'
# Layanan dengan opsi valid
valid_svc:once:/bin/sh -c "echo VALID_OK > /var/valid.txt":memory_max=64M:cpu_max=50000 100000:pids_max=25
# Layanan dengan opsi memory_max rusak (suffix invalid, huruf acak, angka negatif)
bad_mem1:once:/bin/true:memory_max=64MB
bad_mem2:once:/bin/true:memory_max=-100M
bad_mem3:once:/bin/true:memory_max=corrupted!@#
# Layanan dengan opsi cpu_max rusak (non-numerik, spasi berlebih, format token salah)
bad_cpu1:once:/bin/true:cpu_max=invalid 100000
bad_cpu2:once:/bin/true:cpu_max=50000  100000
bad_cpu3:once:/bin/true:cpu_max=50000
# Layanan dengan opsi pids_max rusak (angka negatif, karakter non-numerik, nol)
bad_pid1:once:/bin/true:pids_max=-5
bad_pid2:once:/bin/true:pids_max=invalid
bad_pid3:once:/bin/true:pids_max=0
# Stopper
stopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl":requires=valid_svc
EOF

boot_guest "$R5" "$WAIT5" >"$L5" 2>&1

check_in  "peringatan memory_max invalid dicatat di log" "$L5" \
	"memory_max '64MB' tidak valid"
check_in  "peringatan cpu_max invalid dicatat di log" "$L5" \
	"cpu_max 'invalid 100000' tidak valid"
check_in  "peringatan pids_max invalid dicatat di log" "$L5" \
	"pids_max '-5' tidak valid"
check_in  "layanan dengan limit valid tetap berjalan normal" "$R5/var/valid.txt" \
	'VALID_OK'
check_in  "limit valid diterapkan ke leaf cgroup" "$L5" \
	"cgroup: 'valid_svc' memory.max = 64M"
absent_in "limit memory_max rusak TIDAK pernah diterapkan" "$L5" \
	"memory.max = 64MB"
absent_in "limit cpu_max rusak TIDAK pernah diterapkan" "$L5" \
	"cpu.max = invalid"
absent_in "limit pids_max rusak TIDAK pernah diterapkan" "$L5" \
	"pids.max = -5"
check_in  "event loop tetap berjalan stabil dan shutdown bersih" "$L5" \
	'graceful shutdown'

# ------------------------------------------------------------- Skenario 6
# Toleransi Environment Subtree Cgroup (Nested / Partial Subtree Control)
# Memverifikasi bahwa penulisan subtree control yang gagal atau berstatus
# partial di environment nested/container tidak menggagalkan booting ninit.
printf '\n== Skenario 6: Toleransi environment root cgroup (nested / partial) ==\n'
R6=$(new_root sleep)
L6=$(new_log)
ROOTS="$ROOTS $R6"
LOGS="$LOGS $L6"

cat > "$R6/etc/init.conf" << 'EOF'
svc_nested:once:/bin/sh -c "echo NESTED_OK > /var/nested.txt && echo poweroff > /run/initctl":pids_max=10
EOF

# Siapkan lingkungan nested cgroup tiruan dengan subtree_control read-only pada tmpfs
setup_r6="mount -t sysfs sysfs $R6/sys; mkdir -p $R6/sys/fs/cgroup; mount -t tmpfs tmpfs $R6/sys/fs/cgroup; touch $R6/sys/fs/cgroup/cgroup.controllers; echo pids > $R6/sys/fs/cgroup/cgroup.controllers; touch $R6/sys/fs/cgroup/cgroup.subtree_control; mount -o remount,ro $R6/sys/fs/cgroup;"

boot_guest "$R6" "$WAIT6" "" "$setup_r6" >"$L6" 2>&1

check_in  "kegagalan buka/tulis subtree_control ditoleransi dengan log" "$L6" \
	'cgroup:'
check_in  "toleransi nested/container tercatat di log" "$L6" \
	'toleransi nested/container'
check_in  "layanan berhasil di-spawn meskipun subtree_control terhambat" "$R6/var/nested.txt" \
	'NESTED_OK'
check_in  "sistem masuk ke main loop dan shutdown bersih" "$L6" \
	'graceful shutdown'

# ------------------------------------------------------------- Skenario 7
# Interaksi PR #9: Layanan 'once' dengan pids_max=1 fork EAGAIN -> FAILED -> Batalkan Dependen
# Memverifikasi bahwa cgroup resource exhaustion pada proses init memicu fork EAGAIN
# deterministik, layanan tipe 'once' mencoba ulang hingga MAX_SPAWN_RETRY (3x),
# lalu bertransisi ke state FAILED, dan membatalkan layanan dependen deterministik.
printf '\n== Skenario 7: Interaksi PR #9 (once + pids.max=1 fork EAGAIN -> FAILED) ==\n'
CG_PR9=""
pids_available=0
if [ "$has_cg2" -eq 1 ] && [ "$has_pids" -eq 1 ]; then
	CG_PR9=$($SUDO mktemp -d /sys/fs/cgroup/ninit-cg-pr9.XXXXXX)
	CG_DYNAMIC="$CG_DYNAMIC $CG_PR9"
	if [ -e "$CG_PR9/pids.max" ] && printf '1\n' | $SUDO tee "$CG_PR9/pids.max" >/dev/null 2>&1; then
		pids_available=1
	fi
fi

if [ "$pids_available" -ne 1 ]; then
	skip "skenario 7 dilewati: cgroup v2 + controller pids tidak tersedia atau gagal disiapkan"
else
	R7=$(new_root)
	L7=$(new_log)
	ROOTS="$ROOTS $R7"
	LOGS="$LOGS $L7"

	printf 'boot_pr9:once:exit 0\napp_dep:respawn:exit 0:requires=boot_pr9\n' > "$R7/etc/init.conf"
	boot_guest "$R7" "$WAIT7" "$CG_PR9" >"$L7" 2>&1

	check_in  "event loop tetap masuk dan responsif" "$L7" 'main loop siap'
	check_in  "kegagalan fork() terdeteksi karena cgroup pids habis" "$L7" \
		'fork boot_pr9: Resource temporarily unavailable'
	check_in  "layanan once mencoba ulang hingga batas lalu dinyatakan gagal" "$L7" \
		'percobaan, layanan dinyatakan gagal'
	check_in  "layanan dependen dibatalkan deterministik" "$L7" \
		"layanan 'app_dep' dibatalkan: dependensi 'boot_pr9' gagal"
	absent_in "boot_pr9 tidak pernah berhasil di-spawn" "$L7" 'started boot_pr9'
	absent_in "app_dep tidak pernah di-spawn saat dependensi gagal" "$L7" 'fork app_dep'
	nfork=$(grep -c 'fork boot_pr9' "$L7" 2>/dev/null || true)
	if [ "${nfork:-0}" -le 3 ]; then
		ok "jumlah percobaan fork() boot_pr9 terbatas: $nfork (maks 3, tanpa busy-loop)"
	else
		bad "percobaan fork() boot_pr9 tidak terbatas: $nfork baris (dugaan busy-loop)"
	fi
fi

# ------------------------------------------------------------- Skenario 8
# Pembersihan Siklus Hidup Orphan pada Layanan 'once' (cgroup_kill_service sebelum rmdir)
# Memverifikasi bahwa proses anak/orphan yang ditinggalkan layanan 'once' disapu bersih
# via cgroup.kill sebelum pemanggilan rmdir leaf cgroup.
printf '\n== Skenario 8: Pembersihan orphan pada layanan once sebelum rmdir ==\n'
if [ "$has_cg2" -ne 1 ]; then
	skip "skenario 8 dilewati: cgroup v2 tidak tersedia"
else
	R8=$(new_root sleep)
	L8=$(new_log)
	ROOTS="$ROOTS $R8"
	LOGS="$LOGS $L8"

	cat > "$R8/bin/once_fork.sh" << 'EOF'
#!/bin/sh
/bin/sleep 300 &
/bin/sleep 300 &
/bin/sleep 0.2
exit 0
EOF
	chmod 0755 "$R8/bin/once_fork.sh"

	cat > "$R8/etc/init.conf" << 'EOF'
orphan_maker:once:/bin/sh /bin/once_fork.sh
checker:once:/bin/sh -c "/bin/sleep 1 && echo poweroff > /run/initctl":requires=orphan_maker
EOF

	boot_guest "$R8" "$WAIT8" >"$L8" 2>&1

	check_in  "layanan orphan_maker dijalankan" "$L8" \
		'started orphan_maker'
	check_in  "leaf cgroup orphan_maker berhasil dibersihkan tanpa EBUSY" "$L8" \
		"cgroup: dibersihkan 'orphan_maker'"
	absent_in "tidak ada kegagalan rmdir leaf cgroup" "$L8" \
		"Device or resource busy"
	check_in  "event loop tetap jalan dan shutdown bersih" "$L8" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Ringkasan
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
