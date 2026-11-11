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
#   9. Descendant escape test dengan fast double-fork + setsid daemonize
#      workload, memastikan seluruh proses turunan berada di leaf cgroup.procs
#      via T1 handshake dan cgroup_kill_service menyapu bersih seluruh pohon
#      proses tanpa sisa (LINGERING_ESCAPE_ORPHANS=0). Pembersihan juga
#      diverifikasi dari sisi cgroup: cgroup.events (populated 0) dan
#      cgroup.procs kosong SEBELUM rmdir leaf.
#  10. Batas resource bertingkat (multi-tier hierarchical limits):
#      - 10A: Hierarchical pids.max nested fork rejection with EAGAIN
#             (NESTED_EAGAIN_CONFIRMED depth=3).
#      - 10B: Cumulative parallel memory.max deterministic OOM: leader
#             mengorkestrasi 3 worker x 12MB (36MB > limit 32MB) sehingga
#             OOM killer mematikan worker; kontrol 2 worker x 12MB (24MB)
#             lolos tanpa OOM. Leader tidak mengalokasi besar dan tidak
#             memanggil raise(SIGKILL).
#  11. Fallback fail-open saat cgroup v2 tidak tersedia:
#      - Deteksi kegagalan mount /sys/fs/cgroup dan pencatatan log fail-open aktif.
#      - Peringatan batas resource yang diabaikan.
#      - Eksekusi layanan tetap berjalan normal melalui handshake pre-exec.
#      - Fallback kill(-pgid) pada layanan once saat leader mati, memastikan
#        proses latar belakang (orphan) disapu bersih saat cgroup tidak aktif.
#
# Pemakaian:
#   sudo sh ./scripts/test-cgroup-limits.sh      # atau: make test
#
# Variabel lingkungan:
#   BIN=./ninit              biner yang diuji
#   BUSYBOX=/bin/busybox     busybox statis (apt-get install busybox-static)
#   WAIT1..WAIT11            jendela waktu observasi tiap skenario (detik)
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
WAIT7=${WAIT7:-12}
WAIT8=${WAIT8:-6}
WAIT9=${WAIT9:-8}
WAIT10A=${WAIT10A:-6}
WAIT10B=${WAIT10B:-8}
WAIT11=${WAIT11:-6}


if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "biner '$BIN' tidak ditemukan/tidak executable (jalankan: make)"
[ -f "$BUSYBOX" ] || fail "busybox statis tidak ada di '$BUSYBOX' (apt-get install busybox-static)"
for t in unshare chroot timeout grep mktemp; do
	command -v "$t" >/dev/null 2>&1 || fail "perkakas '$t' tidak ditemukan"
done
$SUDO true 2>/dev/null || fail "butuh root atau sudo tanpa password (unshare + chroot)"

# Safety guard: suite ini menulis cgroup.kill dan rmdir di /sys/fs/cgroup/ninit.
# Jika PID 1 host adalah ninit, suite ini akan membunuh inisialisasi host
# (kernel panic). Abort sebelum menyentuh cgroup host apa pun.
pid1_comm=$(cat /proc/1/comm 2>/dev/null || true)
if [ "$pid1_comm" = "ninit" ]; then
	fail "PID 1 host adalah 'ninit' -- suite dilarang dijalankan pada host hidup (guard isolasi host)"
fi

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

# Snapshot keberadaan /sys/fs/cgroup/ninit di host sebelum pengujian dimulai
HOST_NINIT_PREEXISTED=0
[ -d /sys/fs/cgroup/ninit ] && HOST_NINIT_PREEXISTED=1

# Sentinel Guard: cgroup eksternal independen di host untuk membuktikan
# secara deterministik bahwa test suite TIDAK PERNAH menyentuh cgroup di luar RUN_CG.
EXTERNAL_GUARD_CG="/sys/fs/cgroup/ninit-ext-guard-$$"
if [ -e "$EXTERNAL_GUARD_CG" ]; then
	fail "sentinel guard cgroup '$EXTERNAL_GUARD_CG' sudah ada (collision)"
fi
$SUDO mkdir "$EXTERNAL_GUARD_CG" || fail "gagal membuat sentinel guard cgroup"

# -----------------------------------------------------------------------------
# 1. Isolasi $RUN_CG (Root Eksklusif Test) & Verifikasi Identitas Inode
# -----------------------------------------------------------------------------
RUN_ID="ninit-test-$$-$(date +%s%N 2>/dev/null || date +%s)"
RUN_CG="/sys/fs/cgroup/$RUN_ID"
RUN_CG_BASE="$RUN_CG/ninit"
NINIT_BASE="$RUN_CG_BASE"
TEST_TRACKED_LEAVES=""

# Poin 8: TEST_LEAVES murni sebagai daftar ekspektasi assertion (bukan sweep host)
TEST_LEAVES="mem_test pids_test leak limits_audit valid_svc bad_mem1 bad_mem2 bad_mem3
bad_cpu1 bad_cpu2 bad_cpu3 bad_pid1 bad_pid2 bad_pid3 stopper svc_nested boot_pr9 app_dep
orphan_maker checker escape_svc pids_tree mem_cumul failopen_svc"

# Poin 2: Strict mkdir tanpa -p, abort on collision
if [ -e "$RUN_CG" ]; then
	fail "cgroup collision: path '$RUN_CG' sudah ada sebelum test dimulai (abort)"
fi

$SUDO mkdir "$RUN_CG" || fail "gagal membuat isolasi root cgroup '$RUN_CG'"

# Poin 3: Catat identitas dev:ino tepat setelah pembuatan untuk proteksi TOCTOU/symlink
RUN_CG_DEV_INO=$($SUDO stat -c '%d:%i' "$RUN_CG" 2>/dev/null || true)
[ -n "$RUN_CG_DEV_INO" ] || fail "gagal membaca dev:ino untuk '$RUN_CG'"

# Aktifkan controller memory, pids, cpu di $RUN_CG
for c in memory pids cpu; do
	if grep -qw "$c" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		echo "+$c" | $SUDO tee "$RUN_CG/cgroup.subtree_control" >/dev/null 2>&1 || true
	fi
done

# Buat base cgroup layanan ninit di bawah $RUN_CG
$SUDO mkdir "$RUN_CG_BASE" || fail "gagal membuat base cgroup '$RUN_CG_BASE'"
for c in memory pids cpu; do
	if grep -qw "$c" /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		echo "+$c" | $SUDO tee "$RUN_CG_BASE/cgroup.subtree_control" >/dev/null 2>&1 || true
	fi
done

INNER=$(mktemp /tmp/ninit-cginner.XXXXXX)

# Verifikasi kepemilikan proses: membuktikan apakah proses dengan PID $1
# berjalan di dalam cgroup isolasi test ($RUN_CG) DAN di dalam salah satu
# root guest test ($ROOTS). Fail-closed: PID yang mati/tidak ada, cgroup
# di luar RUN_CG, atau root di luar $ROOTS semuanya DITOLAK (return 1).
is_test_process() {
	p=$1
	# PID reuse guard: /proc/$p yang hilang TIDAK BOLEH dianggap milik test.
	# Kondisi ini return 1 (fail-closed), bukan return 0.
	[ -n "$p" ] && [ -d "/proc/$p" ] || return 1

	# Verifikasi cgroup membership (cgroup v2, format "0::$path"):
	# /sys/fs/cgroup$path harus berada di dalam atau turunan dari $RUN_CG.
	if [ -n "${RUN_CG:-}" ] && [ -d "$RUN_CG" ]; then
		p_cg_path=""
		if [ -r "/proc/$p/cgroup" ]; then
			p_cg_path=$(sed -n 's/^0::\([^[:space:]]*\).*$/\1/p' "/proc/$p/cgroup" 2>/dev/null | head -n 1)
		fi
		[ -n "$p_cg_path" ] || return 1
		case "/sys/fs/cgroup$p_cg_path" in
			"$RUN_CG"|"$RUN_CG"/*)
				;;
			*)
				return 1
				;;
		esac
		[ -d "/sys/fs/cgroup$p_cg_path" ] || return 1
	else
		return 1
	fi

	# Verifikasi chroot root: /proc/$p/root harus di bawah salah satu $ROOTS.
	p_root=$($SUDO readlink /proc/"$p"/root 2>/dev/null || true)
	[ -n "$p_root" ] || return 1
	for r in ${ROOTS:-}; do
		case "$p_root" in
			"$r"|"$r"/*|"$r (deleted)"|"$r/"*|"/tmp/ninit-cgtest."*)
				return 0
				;;
		esac
	done
	return 1
}

# Poin 5 & 6: Cleanup parent-first cgroup.kill, lalu depth-first rmdir
clean_run_cgroup() {
	# Poin 4: Guard ${RUN_CG:-} dan ${RUN_CG_DEV_INO:-} aman pada semua fase setup
	[ -n "${RUN_CG:-}" ] || return 0
	[ -n "${RUN_CG_DEV_INO:-}" ] || return 0
	[ -d "$RUN_CG" ] || return 0

	# Poin 1 & 3: Pastikan path bukan symlink dan identitas inode tidak berubah
	if [ -L "$RUN_CG" ]; then
		printf 'SECURITY: %s adalah symlink! Operasi pembersihan dibatalkan.\n' "$RUN_CG" >&2
		return 1
	fi
	cur_dev_ino=$($SUDO stat -c '%d:%i' "$RUN_CG" 2>/dev/null || true)
	if [ "$cur_dev_ino" != "$RUN_CG_DEV_INO" ]; then
		printf 'SECURITY: dev:ino %s berubah (awal: %s, sekarang: %s)! Operasi dibatalkan.\n' 			"$RUN_CG" "$RUN_CG_DEV_INO" "$cur_dev_ino" >&2
		return 1
	fi

	# Poin 5: Jalur cgroup.kill (kernel >= 5.14) -- bunuh SEMUA proses di
	# seluruh subtree $RUN_CG sekaligus. Jika cgroup.kill tersedia DAN berhasil
	# mengosongkan cgroup.procs di bawah $RUN_CG, pemindaian fallback manual
	# TIDAK PERNAH dijalankan.
	kill_ok=0
	if [ -f "$RUN_CG/cgroup.kill" ]; then
		echo 1 | $SUDO tee "$RUN_CG/cgroup.kill" >/dev/null 2>&1 || true
		# Tunggu cgroup.procs di bawah $RUN_CG menjadi kosong (polling <= ~1s).
		waited=0
		while [ "$waited" -lt 20 ]; do
			remaining=0
			for pfile in $(find "$RUN_CG" -type f -name "cgroup.procs" 2>/dev/null); do
				procs=$($SUDO cat "$pfile" 2>/dev/null || true)
				for p in $procs; do
					[ -n "$p" ] && remaining=$((remaining + 1))
				done
			done
			[ "$remaining" -eq 0 ] && { kill_ok=1; break; }
			sleep 0.05
			waited=$((waited + 1))
		done
	fi

	# Fallback (kernel < 5.14 atau cgroup.kill gagal mengosongkan proses):
	# telusuri cgroup.procs di bawah $RUN_CG dan bunuh hanya proses milik test.
	if [ "$kill_ok" -ne 1 ]; then
		for pfile in $(find "$RUN_CG" -type f -name "cgroup.procs" 2>/dev/null); do
			procs=$($SUDO cat "$pfile" 2>/dev/null || true)
			for p in $procs; do
				if is_test_process "$p"; then
					$SUDO kill -9 "$p" 2>/dev/null || true
				fi
			done
		done
	fi

	# Poin 6: rmdir depth-first strictly di dalam batasan $RUN_CG
	find "$RUN_CG" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || {
		sleep 0.1
		find "$RUN_CG" -depth -mindepth 1 -type d -exec $SUDO rmdir {} + 2>/dev/null || true
	}

	$SUDO rmdir "$RUN_CG" 2>/dev/null || {
		sleep 0.1
		$SUDO rmdir "$RUN_CG" 2>/dev/null || true
	}
}

cleanup() {
	# 1. Bersihkan hierarki cgroup isolasi test.
	# Trap safety: kegagalan dev:ino / inode TIDAK BOLEH membatalkan seluruh
	# trap via set -e. Tahap pembersihan resource lain tetap dieksekusi.
	clean_run_cgroup || printf 'WARN: clean_run_cgroup gagal (status %d), melanjutkan pembersihan resource lain...\n' $? >&2

	# 2. Unmount dan bersihkan direktori guest test
	for d in ${ROOTS:-}; do
		$SUDO umount -R "$d" 2>/dev/null || $SUDO umount "$d/proc" 2>/dev/null || true
		rm -rf "$d" 2>/dev/null || true
	done
	for f in ${LOGS:-}; do rm -f "$f" 2>/dev/null || true; done
	for h in ${HELPERS:-}; do rm -f "$h" 2>/dev/null || true; done
	$SUDO rm -f "$INNER" 2>/dev/null || true

	# 3. Bersihkan cgroup dinamis/ephemeral tambahan
	for cg in ${CG_DYNAMIC:-}; do
		if [ -d "$cg" ] && [ ! -L "$cg" ]; then
			if [ -f "$cg/cgroup.kill" ]; then
				echo 1 | $SUDO tee "$cg/cgroup.kill" >/dev/null 2>&1 || true
			fi
			$SUDO rmdir "$cg" 2>/dev/null || true
		fi
	done

	# 4. Bersihkan sentinel guard jika masih ada
	if [ -n "${EXTERNAL_GUARD_CG:-}" ] && [ -d "$EXTERNAL_GUARD_CG" ] && [ ! -L "$EXTERNAL_GUARD_CG" ]; then
		$SUDO rmdir "$EXTERNAL_GUARD_CG" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

fail_count=0
ok()   { printf '  [ OK ]   %s\n' "$1"; }
bad()  { printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  [ -- ]   %s\n' "$1"; }
check_in()  { if grep -q "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi; }
absent_in() { if grep -q "$3" "$2" 2>/dev/null; then bad "$1"; else ok "$1"; fi; }
before_in() {
	desc=$1; file=$2; first=$3; second=$4
	if awk -v a="$first" -v b="$second" '$0 ~ a {seen=1} seen && $0 ~ b {found=1; exit} END {exit !(seen && found)}' "$file" 2>/dev/null; then
		ok "$desc"
	else
		bad "$desc"
	fi
}

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

	# Daftarkan leaf cgroup dari init.conf ke TEST_TRACKED_LEAVES
	if [ -f "$root/etc/init.conf" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			case "$line" in
				\#*|"") continue ;;
			esac
			svc_name=$(printf '%s\n' "$line" | cut -d: -f1)
			[ -n "$svc_name" ] || continue
			case " ${TEST_TRACKED_LEAVES:-} " in
				*" $svc_name "*) ;;
				*) TEST_TRACKED_LEAVES="${TEST_TRACKED_LEAVES:-} $svc_name" ;;
			esac
		done < "$root/etc/init.conf"
	fi

	if [ -n "$cg" ]; then
		move="echo \$\$ > $cg/cgroup.procs;"
	else
		move=""
	fi
	cat > "$INNER" <<EOI
#!/bin/sh
mount -t proc proc $root/proc
export NINIT_CGROUP_BASE="$RUN_CG_BASE"
$move
$extra_setup
exec chroot $root /ninit
EOI
	$SUDO chmod 755 "$INNER"
	$SUDO sh -c "timeout -s KILL $((secs + 4)) unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh $INNER" || true
}

# Siapkan biner bantuan statis untuk alokasi memori berlebih dan pengujian fork
HOG_BIN=""
FORK_BIN=""
ESCAPE_BIN=""
FORK_TREE_BIN=""
CUMUL_MEM_BIN=""
if command -v gcc >/dev/null 2>&1; then
	HOG_SRC=$(mktemp /tmp/ninit-hog.XXXXXX.c)
	HOG_BIN=$(mktemp /tmp/ninit-hog-bin.XXXXXX)
	FORK_SRC=$(mktemp /tmp/ninit-fork.XXXXXX.c)
	FORK_BIN=$(mktemp /tmp/ninit-fork-bin.XXXXXX)
	ESCAPE_SRC=$(mktemp /tmp/ninit-escape.XXXXXX.c)
	ESCAPE_BIN=$(mktemp /tmp/ninit-escape-bin.XXXXXX)
	FORK_TREE_SRC=$(mktemp /tmp/ninit-forktree.XXXXXX.c)
	FORK_TREE_BIN=$(mktemp /tmp/ninit-forktree-bin.XXXXXX)
	CUMUL_MEM_SRC=$(mktemp /tmp/ninit-cumulmem.XXXXXX.c)
	CUMUL_MEM_BIN=$(mktemp /tmp/ninit-cumulmem-bin.XXXXXX)
	HELPERS="$HELPERS $HOG_SRC $HOG_BIN $FORK_SRC $FORK_BIN $ESCAPE_SRC $ESCAPE_BIN $FORK_TREE_SRC $FORK_TREE_BIN $CUMUL_MEM_SRC $CUMUL_MEM_BIN"

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

	cat > "$ESCAPE_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int main(void) {
    /* =========================================================================
     * INSTRUKSI PERTAMA (SEBELUM FORK):
     * Baca /proc/self/cgroup dan verifikasi bahwa proses SUDAH berada di leaf
     * cgroup (/ninit/... atau escape_svc).
     * Biner tanpa handshake melihat cgroup root (0::/) -> GAGAL deterministik.
     * Biner dengan handshake T1 dijamin sudah berada di leaf -> LULUS.
     * ========================================================================= */
    int in_leaf = 0;
    char cgroup_line[256] = {0};
    FILE *fcg = fopen("/proc/self/cgroup", "r");
    if (fcg) {
        while (fgets(cgroup_line, sizeof(cgroup_line), fcg)) {
            if (strstr(cgroup_line, "/ninit/") || strstr(cgroup_line, "escape_svc")) {
                in_leaf = 1;
                break;
            }
        }
        fclose(fcg);
    }

    if (!in_leaf) {
        /* Biner tanpa handshake: cgroup root / belum di leaf cgroup -> GAGAL */
        FILE *fa = fopen("/var/escape_audit.txt", "w");
        if (fa) {
            fprintf(fa, "PRE_FORK_LEAF_CGROUP=0\nFAILED_REASON=not_in_leaf_cgroup\n");
            fflush(fa);
            fclose(fa);
        }
        return 1; /* Keluar segera, tidak ada fork anak atau cucu */
    }

    pid_t leader_pid = getpid();

    /* Generation 2: Child */
    pid_t child = fork();
    if (child < 0) return 1;
    if (child > 0) {
        /* Leader: tunggu hingga cucu selesai menulis bukti audit, lalu exit 0 */
        int waited = 0;
        while (access("/var/escape_audit.txt", F_OK) != 0 && waited < 40) {
            usleep(50000);
            waited++;
        }
        usleep(50000);
        return 0;
    }

    /* Child creates new session */
    setsid();

    /* Generation 3: Grandchild daemon */
    pid_t grandchild = fork();
    if (grandchild < 0) return 1;
    if (grandchild > 0) {
        /* Child exits immediately, reparenting grandchild as orphan */
        return 0;
    }

    /* Grandchild establishes its own session */
    setsid();
    pid_t gc_pid = getpid();

    /* Verify grandchild cgroup membership via /proc/self/cgroup */
    int gc_in_leaf = 0;
    fcg = fopen("/proc/self/cgroup", "r");
    if (fcg) {
        char buf[256];
        while (fgets(buf, sizeof(buf), fcg)) {
            if (strstr(buf, "/ninit/") || strstr(buf, "escape_svc")) {
                gc_in_leaf = 1;
                break;
            }
        }
        fclose(fcg);
    }

    /* Verify grandchild PID is present in escape_svc/cgroup.procs */
    const char *cg_base = getenv("NINIT_CGROUP_BASE");
    char esc_procs_path[320];
    snprintf(esc_procs_path, sizeof(esc_procs_path), "%s/escape_svc/cgroup.procs",
             cg_base ? cg_base : "/sys/fs/cgroup/ninit");
    int in_procs = 0;
    for (int retry = 0; retry < 10 && !in_procs; retry++) {
        FILE *fp = fopen(esc_procs_path, "r");
        if (fp) {
            int p;
            while (fscanf(fp, "%d", &p) == 1) {
                if (p == gc_pid) { in_procs = 1; break; }
            }
            fclose(fp);
        }
        if (!in_procs) usleep(10000);
    }

    FILE *fa = fopen("/var/escape_audit.txt", "w");
    if (fa) {
        fprintf(fa, "LEADER=%d\nCHILD=%d\nGRANDCHILD=%d\nPRE_FORK_LEAF_CGROUP=1\nIN_LEAF_CGROUP=%d\nIN_CGROUP_PROCS=%d\nGRANDCHILD_ACTIVE=1\n",
                leader_pid, getppid(), gc_pid, gc_in_leaf, in_procs);
        fflush(fa);
        fclose(fa);
    }

    /* Grandchild daemon stays alive until killed by cgroup_kill_service */
    while (1) {
        sleep(60);
    }
    return 0;
}
EOF
	gcc -static -O2 "$ESCAPE_SRC" -o "$ESCAPE_BIN" 2>/dev/null || ESCAPE_BIN=""

	cat > "$FORK_TREE_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

int main(void) {
    pid_t p1 = getpid();
    FILE *f = fopen("/var/pids_tree_audit.txt", "w");
    if (f) { fprintf(f, "GEN1_PID=%d\n", p1); fflush(f); fclose(f); }

    /* Leader forks Child (Gen 2) */
    pid_t p2 = fork();
    if (p2 < 0) return 1;
    if (p2 == 0) {
        FILE *f2 = fopen("/var/pids_tree_audit.txt", "a");
        if (f2) { fprintf(f2, "GEN2_PID=%d\n", getpid()); fflush(f2); fclose(f2); }

        /* Child forks Grandchild (Gen 3) */
        pid_t p3 = fork();
        if (p3 < 0) return 1;
        if (p3 == 0) {
            FILE *f3 = fopen("/var/pids_tree_audit.txt", "a");
            if (f3) { fprintf(f3, "GEN3_PID=%d\n", getpid()); fflush(f3); fclose(f3); }

            /* Kuota cgroup pids_max=3.
               Saat ini ada 3 proses: p1 (leader), p2 (child), p3 (grandchild).
               Grandchild (depth 3) mencoba fork Great-grandchild (Gen 4). */
            errno = 0;
            pid_t p4 = fork();
            FILE *f4 = fopen("/var/pids_tree_audit.txt", "a");
            if (p4 < 0) {
                if (errno == EAGAIN) {
                    if (f4) fprintf(f4, "NESTED_EAGAIN_CONFIRMED depth=3 errno=%d\n", errno);
                } else {
                    if (f4) fprintf(f4, "NESTED_FORK_FAILED_OTHER errno=%d\n", errno);
                }
            } else if (p4 == 0) {
                _exit(0);
            } else {
                if (f4) fprintf(f4, "UNEXPECTED_FORK_SUCCESS pid=%d\n", p4);
                waitpid(p4, NULL, 0);
            }
            if (f4) { fflush(f4); fclose(f4); }
            _exit(0);
        }
        waitpid(p3, NULL, 0);
        _exit(0);
    }
    waitpid(p2, NULL, 0);
    return 0;
}
EOF
	gcc -static -O2 "$FORK_TREE_SRC" -o "$FORK_TREE_BIN" 2>/dev/null || FORK_TREE_BIN=""

	cat > "$CUMUL_MEM_SRC" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/wait.h>

#define WORKER_MB   12
#define AUDIT_PATH  "/var/cumul_mem_audit.txt"

static void audit_msg(const char *msg) {
    int fd = open(AUDIT_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t unused = write(fd, msg, strlen(msg));
    (void)unused;
    close(fd);
}

static void auditf(const char *fmt, ...) {
    char buf[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    audit_msg(buf);
}

/* Fork seorang worker yang mengalokasi dan MENYENTUH WORKER_MB MB.
   Penulisan volatile per halaman wajib: tanpa itu gcc -O2 mengubah
   malloc+memset menjadi alokasi lazim (calloc) yang tidak pernah menagih
   halaman, sehingga batas kumulatif tidak pernah terlampaui.
   adj menaikkan oom_score_adj worker supaya kernel memilih worker
   (bukan leader) sebagai korban OOM saat kuota terlampaui. */
static pid_t spawn_worker(int id, const char *tag, int adj) {
    pid_t p = fork();
    if (p < 0) return -1;
    if (p == 0) {
        int fd = open("/proc/self/oom_score_adj", O_WRONLY);
        if (fd >= 0) {
            dprintf(fd, "%d\n", adj);
            close(fd);
        }
        size_t sz = (size_t)WORKER_MB * 1024 * 1024;
        volatile unsigned char *m = malloc(sz);
        if (m) {
            for (size_t i = 0; i < sz; i += 4096) m[i] = 0x5A;
            m[sz - 1] = 0x5A;
        }
        auditf("%s_WORKER%d_ALLOCATED_12M\n", tag, id);
        /* Tahan memori sampai OOM killer atau leader menghentikan worker. */
        for (;;) sleep(60);
        _exit(0);
    }
    return p;
}

static int read_audit(char *buf, size_t sz) {
    int fd = open(AUDIT_PATH, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sz - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    return 1;
}

static int wait_for_marker(const char *marker, int timeout_ms) {
    char buf[4096];
    for (int i = 0; i < timeout_ms / 20; i++) {
        if (read_audit(buf, sizeof(buf)) && strstr(buf, marker)) return 1;
        usleep(20000);
    }
    return 0;
}

static int child_alive(pid_t pid) {
    if (pid <= 0) return 0;
    int st;
    return waitpid(pid, &st, WNOHANG) == 0;
}

int main(void) {
    /* Lindungi leader agar tidak menjadi korban OOM killer kernel.
       Hanya proses worker anak yang boleh dipilih sebagai target OOM. */
    int oom_fd = open("/proc/self/oom_score_adj", O_WRONLY);
    if (oom_fd >= 0) {
        dprintf(oom_fd, "-1000\n");
        close(oom_fd);
    }

    /* ---- Fase kontrol (anti-hampa): 2 worker x 12MB = 24MB < 32MB.
       Keduanya harus bertahan tanpa OOM killer. ---- */
    pid_t c1 = spawn_worker(1, "CONTROL", 1000);
    pid_t c2 = spawn_worker(2, "CONTROL", 1000);
    int c1_ok = wait_for_marker("CONTROL_WORKER1_ALLOCATED_12M", 2000);
    int c2_ok = wait_for_marker("CONTROL_WORKER2_ALLOCATED_12M", 2000);
    usleep(500000); /* jendela pengamatan: OOM killer tidak boleh menembak */
    int c1_alive = child_alive(c1);
    int c2_alive = child_alive(c2);
    if (c1_ok && c2_ok && c1_alive && c2_alive)
        audit_msg("CONTROL_2_WORKERS_NO_OOM=1\n");
    else
        audit_msg("CONTROL_2_WORKERS_NO_OOM=0\n");

    /* Bersihkan worker kontrol sebelum fase uji. */
    if (c1 > 0) { kill(c1, SIGKILL); waitpid(c1, NULL, 0); }
    if (c2 > 0) { kill(c2, SIGKILL); waitpid(c2, NULL, 0); }
    usleep(100000); /* beri jeda waktu kernel me-reclaim halaman cgroup */

    /* ---- Fase uji: 3 worker x 12MB = 36MB > 32MB.
       Spawn worker 1 & 2 secara bertahap untuk memastikan keduanya memegang
       24MB secara paralel tanpa OOM sebelum worker 3 mendorong akumulasi
       melampaui kuota 32MB. OOM killer kernel harus mematikan worker;
       leader TIDAK mengalokasi memori besar dan TIDAK memanggil raise(SIGKILL). ---- */
    audit_msg("TEST_WORKERS_FORKED=3\n");
    pid_t w[3];
    w[0] = spawn_worker(1, "TEST", 1000);
    wait_for_marker("TEST_WORKER1_ALLOCATED_12M", 3000);
    w[1] = spawn_worker(2, "TEST", 1000);
    wait_for_marker("TEST_WORKER2_ALLOCATED_12M", 3000);
    w[2] = spawn_worker(3, "TEST", 1000);

    char buf[4096];
    int seen1 = 0, seen2 = 0, seen3 = 0, oom_kills = 0, st;
    for (int i = 0; i < 300; i++) {
        if (read_audit(buf, sizeof(buf))) {
            if (strstr(buf, "TEST_WORKER1_ALLOCATED_12M")) seen1 = 1;
            if (strstr(buf, "TEST_WORKER2_ALLOCATED_12M")) seen2 = 1;
            if (strstr(buf, "TEST_WORKER3_ALLOCATED_12M")) seen3 = 1;
        }
        pid_t p = waitpid(-1, &st, WNOHANG);
        if (p > 0 && WIFSIGNALED(st) && WTERMSIG(st) == SIGKILL)
            oom_kills++;
        if (oom_kills > 0) break;
        usleep(20000);
    }
    auditf("TEST_WORKERS_ALLOCATED=%d\n", seen1 + seen2 + seen3);
    auditf("WORKER_KILLED_BY_OOM=%d\n", oom_kills > 0);
    auditf("OOM_KILLED_WORKERS=%d\n", oom_kills);

    /* Sapu bersih sisa worker sebelum leader keluar (leader bertahan hidup). */
    for (int i = 0; i < 3; i++) {
        if (w[i] > 0) {
            if (waitpid(w[i], &st, WNOHANG) == 0)
                kill(w[i], SIGKILL);
            waitpid(w[i], NULL, 0);
        }
    }
    audit_msg("LEADER_SURVIVED=1\n");
    return 0;
}
EOF
	gcc -static -O2 "$CUMUL_MEM_SRC" -o "$CUMUL_MEM_BIN" 2>/dev/null || CUMUL_MEM_BIN=""
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
	printf 'limits_audit:once:/bin/sh -c "cat %s/limits_audit/memory.max > /var/mem.val && cat %s/limits_audit/cpu.max > /var/cpu.val && cat %s/limits_audit/pids.max > /var/pids.val && echo poweroff > /run/initctl":pids_max=20:cpu_max=50000 100000:memory_max=32M\n' \
		"$RUN_CG_BASE" "$RUN_CG_BASE" "$RUN_CG_BASE" > "$R4/etc/init.conf"
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
	'buka .*subtree_control gagal'
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
	CG_PR9=$($SUDO mktemp -d "$RUN_CG/ninit-cg-pr9.XXXXXX")
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
	R8=$(new_root sleep grep)
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

	cat > "$R8/bin/check_orphans.sh" << 'EOF'
#!/bin/sh
/bin/sleep 0.5
lingering=0
for cmd in /proc/[0-9]*/cmdline; do
    [ -f "$cmd" ] || continue
    if grep -q "300" "$cmd" 2>/dev/null; then
        lingering=$((lingering + 1))
    fi
done
echo "LINGERING_ONCE_ORPHANS=$lingering" > /var/once_orphan_audit.txt
echo poweroff > /run/initctl
exit 0
EOF
	chmod 0755 "$R8/bin/check_orphans.sh"

	cat > "$R8/etc/init.conf" << 'EOF'
orphan_maker:once:/bin/sh /bin/once_fork.sh
checker:once:/bin/sh /bin/check_orphans.sh:requires=orphan_maker
EOF

	boot_guest "$R8" "$WAIT8" >"$L8" 2>&1

	check_in  "layanan orphan_maker dijalankan" "$L8" \
		'started orphan_maker'
	check_in  "leaf cgroup orphan_maker berhasil dibersihkan tanpa EBUSY" "$L8" \
		"cgroup: dibersihkan 'orphan_maker'"
	absent_in "tidak ada kegagalan rmdir leaf cgroup" "$L8" \
		"Device or resource busy"
	check_in  "orphan dari layanan once disapu bersih sebelum checker (LINGERING_ONCE_ORPHANS=0)" \
		"$R8/var/once_orphan_audit.txt" 'LINGERING_ONCE_ORPHANS=0'
	before_in "leaf cgroup orphan_maker dibersihkan sebelum graceful shutdown" "$L8" \
		"cgroup: dibersihkan 'orphan_maker'" 'graceful shutdown'
	check_in  "event loop tetap jalan dan shutdown bersih" "$L8" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Skenario 9
# Descendant Escape Test (Pre-exec Pipe Handshake Synchronization)
# Workload adversarial melakukan fast double-fork dan setsid untuk mencoba
# melepaskan diri dari leaf cgroup.
# Verifikasi bahwa handshake sinkronisasi parent-child T1 menjamin seluruh
# proses turunan (anak, cucu, orphan) berada di leaf cgroup.procs yang tepat,
# dan cgroup_kill_service menyapu bersih seluruh pohon proses (LINGERING_ESCAPE_ORPHANS=0).
# Pembersihan diverifikasi dua sisi: (a) cgroup.events populated 0 dan
# cgroup.procs kosong SEBELUM rmdir leaf, (b) scan /proc cmdline tanpa sisa.
printf '\n== Skenario 9: Descendant escape test & handshake sinkronisasi ==\n'
if [ "$has_cg2" -ne 1 ] || [ -z "$ESCAPE_BIN" ]; then
	skip "skenario 9 dilewati: cgroup v2 tidak tersedia atau gcc tidak ada"
else
	R9=$(new_root sleep grep cut cat awk wc)
	L9=$(new_log)
	ROOTS="$ROOTS $R9"
	LOGS="$LOGS $L9"

	cp "$ESCAPE_BIN" "$R9/bin/escape_workload"

	# -----------------------------------------------------------------
	# Phase 1: Negative Control Test (Biner Tanpa Handshake -> GAGAL)
	# -----------------------------------------------------------------
	# Jalankan biner secara langsung di lingkungan root cgroup tanpa handshake T1.
	# Biner harus mendeteksi ketiadaan leaf cgroup pada instruksi pertama dan exit 1.
	neg_ret=0
	$SUDO timeout -s KILL 5 unshare --pid --fork --kill-child=SIGKILL \
		--mount --propagation private /bin/sh -c \
		"mount -t proc proc '$R9/proc' && chroot '$R9' /bin/escape_workload" >/dev/null 2>&1 || neg_ret=$?

	if [ "$neg_ret" -ne 0 ] && [ -f "$R9/var/escape_audit.txt" ]; then
		check_in  "uji anti-hampa negatif: biner tanpa handshake melihat cgroup root dan GAGAL deterministik" \
			"$R9/var/escape_audit.txt" 'PRE_FORK_LEAF_CGROUP=0'
		absent_in "uji anti-hampa negatif: biner tanpa handshake tidak pernah spawn cucu" \
			"$R9/var/escape_audit.txt" 'GRANDCHILD_ACTIVE=1'
	else
		bad "uji anti-hampa negatif: biner tanpa handshake seharusnya gagal, namun lolos (exit=$neg_ret)"
	fi
	rm -f "$R9/var/escape_audit.txt"

	# -----------------------------------------------------------------
	# Phase 2: Positive Test (Dengan T1 Handshake di Bawah ninit -> LULUS)
	# -----------------------------------------------------------------
	cat > "$R9/bin/check_escape.sh" << 'EOF'
#!/bin/sh
# Verifikasi pembersihan dari dua sisi:
#   (a) cgroup: cgroup.events (populated 0) dan cgroup.procs kosong SEBELUM
#       rmdir leaf. Leaf sengaja dibiarkan hidup (escape_svc respawn) supaya
#       state pasca-cgroup_kill_service bisa diamati sebelum ninit menghapusnya
#       saat shutdown.
#   (b) /proc: tidak ada proses escape_workload yang masih berjalan.
CG="${NINIT_CGROUP_BASE:-/sys/fs/cgroup/ninit}/escape_svc"

# Tunggu workload adversarial menulis bukti audit (cucu sudah aktif).
waited=0
while [ ! -f /var/escape_audit.txt ] && [ "$waited" -lt 100 ]; do
    /bin/sleep 0.05
    waited=$((waited + 1))
done

gc_pid=""
if [ -f /var/escape_audit.txt ]; then
    gc_pid=$(grep '^GRANDCHILD=' /var/escape_audit.txt 2>/dev/null | cut -d= -f2)
fi

# Tunggu cgroup_kill_service menyapu leaf: populated 0 DAN cgroup.procs kosong.
populated="unknown"
nprocs="unknown"
waited=0
while [ "$waited" -lt 100 ]; do
    if [ -d "$CG" ] && [ -f "$CG/cgroup.events" ]; then
        p=$(awk '/^populated /{print $2}' "$CG/cgroup.events" 2>/dev/null)
        n=$(wc -l < "$CG/cgroup.procs" 2>/dev/null || echo unknown)
        if [ "$p" = "0" ] && [ "$n" = "0" ]; then
            populated=0
            nprocs=0
            break
        fi
    fi
    /bin/sleep 0.05
    waited=$((waited + 1))
done

# Scan /proc: pastikan tidak ada sisa proses turunan yang lolos.
lingering=0
if [ -n "$gc_pid" ] && [ -d "/proc/$gc_pid" ]; then
    lingering=$((lingering + 1))
fi

for cmd in /proc/[0-9]*/cmdline; do
    [ -f "$cmd" ] || continue
    if grep -q "escape_workload" "$cmd" 2>/dev/null; then
        lingering=$((lingering + 1))
    fi
done

echo "POPULATED=$populated" > /var/escape_clean_audit.txt
echo "CGROUP_PROCS=$nprocs" >> /var/escape_clean_audit.txt
echo "LINGERING_ESCAPE_ORPHANS=$lingering" >> /var/escape_clean_audit.txt
echo poweroff > /run/initctl
exit 0
EOF
	chmod 0755 "$R9/bin/check_escape.sh"

	cat > "$R9/etc/init.conf" << 'EOF'
# escape_svc sengaja 'respawn': saat leader exit, ninit memanggil
# cgroup_kill_service tetapi BELUM rmdir leaf, sehingga checker bisa
# memverifikasi cgroup.events (populated 0) dan cgroup.procs kosong
# SEBELUM rmdir (rmdir leaf terjadi saat shutdown).
escape_svc:respawn:/bin/escape_workload
checker:once:/bin/sh /bin/check_escape.sh
EOF

	boot_guest "$R9" "$WAIT9" >"$L9" 2>&1

	check_in  "instruksi pertama proses anak memvalidasi keberadaan di leaf cgroup (/ninit/...)" \
		"$R9/var/escape_audit.txt" 'PRE_FORK_LEAF_CGROUP=1'
	check_in  "adversary berhasil spawn cucu orphan berkat handshake T1 (anti-hampa positif)" \
		"$R9/var/escape_audit.txt" 'GRANDCHILD_ACTIVE=1'
	check_in  "cucu orphan berada di leaf cgroup.procs berkat handshake T1" \
		"$R9/var/escape_audit.txt" 'IN_CGROUP_PROCS=1'
	check_in  "cgroup membership cucu berada di leaf escape_svc" \
		"$R9/var/escape_audit.txt" 'IN_LEAF_CGROUP=1'
	check_in  "cgroup_kill_service menyapu bersih seluruh pohon proses turunan (LINGERING_ESCAPE_ORPHANS=0)" \
		"$R9/var/escape_clean_audit.txt" 'LINGERING_ESCAPE_ORPHANS=0'
	check_in  "cgroup.events leaf escape_svc populated 0 sebelum rmdir" \
		"$R9/var/escape_clean_audit.txt" 'POPULATED=0'
	check_in  "cgroup.procs leaf escape_svc kosong sebelum rmdir" \
		"$R9/var/escape_clean_audit.txt" 'CGROUP_PROCS=0'
	check_in  "leaf cgroup escape_svc dibersihkan setelah sweep" "$L9" \
		"cgroup: dibersihkan 'escape_svc'"
	absent_in "tidak ada kegagalan rmdir leaf cgroup (EBUSY)" "$L9" \
		"Device or resource busy"
	check_in  "event loop tetap jalan dan shutdown bersih" "$L9" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Skenario 10
# Batas Resource Workload Bertingkat (Multi-tier Hierarchical Limits)
# Memverifikasi bahwa batas hierarkis cgroup v2 mengikat seluruh subtree:
# Part 10A: Hierarchical pids.max (leader -> child -> grandchild -> fork ke-4 ditolak EAGAIN)
# Part 10B: Cumulative parallel memory.max -- leader mengorkestrasi 3 worker x 12MB
#           (total 36MB > limit 32MB) sehingga OOM killer mematikan worker, plus
#           kontrol anti-hampa 2 worker x 12MB (24MB) yang lolos tanpa OOM.
printf '\n== Skenario 10: Batas resource workload bertingkat (hierarki cgroup v2) ==\n'

# 10A: Hierarchical PIDs
if [ "$has_cg2" -ne 1 ] || [ "$has_pids" -ne 1 ] || [ -z "$FORK_TREE_BIN" ]; then
	skip "skenario 10A dilewati: cgroup v2 + controller pids tidak tersedia atau gcc tidak ada"
else
	R10A=$(new_root sleep)
	L10A=$(new_log)
	ROOTS="$ROOTS $R10A"
	LOGS="$LOGS $L10A"

	cp "$FORK_TREE_BIN" "$R10A/bin/fork_tree"
	cat > "$R10A/etc/init.conf" << 'EOF'
pids_tree:once:/bin/fork_tree:pids_max=3
stopper:once:/bin/sh -c "/bin/sleep 2 && echo poweroff > /run/initctl":requires=pids_tree
EOF

	boot_guest "$R10A" "$WAIT10A" >"$L10A" 2>&1

	check_in  "konfigurasi limit pids.max diterapkan pada hierarki" "$L10A" \
		"cgroup: 'pids_tree' pids.max = 3"
	check_in  "fork cucu ditolak deterministik dengan EAGAIN saat kuota hierarki habis" \
		"$R10A/var/pids_tree_audit.txt" 'NESTED_EAGAIN_CONFIRMED depth=3'
	absent_in "tidak ada fork yang lolos melebihi batas pids.max" \
		"$R10A/var/pids_tree_audit.txt" 'UNEXPECTED_FORK_SUCCESS'
	check_in  "leaf cgroup dibersihkan setelah selesai" "$L10A" \
		"cgroup: dibersihkan 'pids_tree'"
	check_in  "event loop tetap jalan dan shutdown bersih" "$L10A" \
		'graceful shutdown'
fi

# 10B: Cumulative Parallel Memory OOM
if [ "$has_cg2" -ne 1 ] || [ "$has_mem" -ne 1 ] || [ -z "$CUMUL_MEM_BIN" ]; then
	skip "skenario 10B dilewati: cgroup v2 + controller memory tidak tersedia atau gcc tidak ada"
else
	R10B=$(new_root sleep)
	L10B=$(new_log)
	ROOTS="$ROOTS $R10B"
	LOGS="$LOGS $L10B"

	cp "$CUMUL_MEM_BIN" "$R10B/bin/cumul_mem"
	cat > "$R10B/etc/init.conf" << 'EOF'
mem_cumul:once:/bin/cumul_mem:memory_max=32M
stopper:once:/bin/sh -c "/bin/sleep 3 && echo poweroff > /run/initctl"
EOF

	boot_guest "$R10B" "$WAIT10B" >"$L10B" 2>&1

	check_in  "konfigurasi limit memory.max kumulatif diterapkan" "$L10B" \
		"cgroup: 'mem_cumul' memory.max = 32M"
	check_in  "kontrol anti-hampa: 2 worker x 12M (24M) lolos tanpa OOM" \
		"$R10B/var/cumul_mem_audit.txt" 'CONTROL_2_WORKERS_NO_OOM=1'
	check_in  "leader mengorkestrasi 3 worker pada fase uji (total 36M > 32M)" \
		"$R10B/var/cumul_mem_audit.txt" 'TEST_WORKERS_FORKED=3'
	check_in  "minimal 2 worker mengalokasi 12M (akumulasi paralel nyata)" \
		"$R10B/var/cumul_mem_audit.txt" 'TEST_WORKERS_ALLOCATED=[23]'
	check_in  "OOM killer mematikan worker (bukti waitpid SIGKILL, bukan self-kill)" \
		"$R10B/var/cumul_mem_audit.txt" 'WORKER_KILLED_BY_OOM=1'
	check_in  "leader bertahan hidup dan melaporkan (tidak ada raise(SIGKILL))" \
		"$R10B/var/cumul_mem_audit.txt" 'LEADER_SURVIVED=1'
	absent_in "tidak ada exit status=0x9 palsu pada leader mem_cumul" "$L10B" \
		'mem_cumul (pid .* exit status=0x9'
	check_in  "leaf cgroup dibersihkan setelah OOM kumulatif" "$L10B" \
		"cgroup: dibersihkan 'mem_cumul'"
	check_in  "event loop tetap jalan dan shutdown bersih" "$L10B" \
		'graceful shutdown'
fi

# ------------------------------------------------------------- Skenario 11
# Fallback Fail-Open saat Cgroup v2 Tidak Tersedia (Mount Cgroup Gagal)
# Memverifikasi bahwa ketika hierarki cgroup v2 tidak dapat di-mount atau disiapkan:
# 1. Init mencatat baris fail-open aktif: "cgroup: fail-open aktif untuk ..."
# 2. Init mencatat warning pengabaian limit: "Warning: batas resource diabaikan pada layanan '...' karena cgroup tidak tersedia"
# 3. Layanan tetap dieksekusi dengan normal melalui handshake T1
# 4. Fallback kill(-pgid) pada layanan once membersihkan proses anak orphan di background saat leader mati
# 5. Init PID 1 melakukan shutdown bersih (graceful shutdown) tanpa crash atau orphan hang
printf '\n== Skenario 11: Fallback fail-open saat cgroup v2 tidak tersedia ==\n'
R11=$(new_root sleep grep)
L11=$(new_log)
ROOTS="$ROOTS $R11"
LOGS="$LOGS $L11"

cat > "$R11/bin/check_failopen.sh" << 'EOF'
#!/bin/sh
# Verifikasi bahwa background orphan (sleep 300) telah disapu bersih oleh fallback kill(-pgid)
lingering=0
for cmd in /proc/[0-9]*/cmdline; do
    [ -f "$cmd" ] || continue
    if grep -q "300" "$cmd" 2>/dev/null; then
        lingering=$((lingering + 1))
    fi
done
echo "LINGERING_FAILOPEN_ORPHANS=$lingering" > /var/failopen_clean_audit.txt
echo poweroff > /run/initctl
exit 0
EOF
chmod 0755 "$R11/bin/check_failopen.sh"

cat > "$R11/etc/init.conf" << 'EOF'
failopen_svc:once:/bin/sh -c "/bin/sleep 300 & echo FAILOPEN_EXECUTED > /var/failopen_audit.txt":memory_max=32M:pids_max=10
checker:once:/bin/sh /bin/check_failopen.sh:requires=failopen_svc
EOF

# Siapkan lingkungan tiruan di mana /sys/fs/cgroup berupa berkas biasa pada tmpfs,
# sehingga pemanggilan mount("cgroup2", "/sys/fs/cgroup", ...) gagal deterministik dengan ENOTDIR
setup_r11="mount -t sysfs sysfs $R11/sys; mkdir -p $R11/sys/fs; mount -t tmpfs tmpfs $R11/sys/fs; touch $R11/sys/fs/cgroup;"

boot_guest "$R11" "$WAIT11" "" "$setup_r11" >"$L11" 2>&1

check_in  "kegagalan mount cgroup v2 tercatat di log" "$L11" \
	'cgroup2: mount /sys/fs/cgroup gagal'
check_in  "fallback fail-open aktif tercatat di log" "$L11" \
	"cgroup: fail-open aktif untuk 'failopen_svc'"
check_in  "warning batas resource diabaikan tercatat di log" "$L11" \
	"Warning: batas resource diabaikan pada layanan 'failopen_svc' karena cgroup tidak tersedia"
check_in  "layanan tetap berhasil dieksekusi normal saat cgroup tidak tersedia" \
	"$R11/var/failopen_audit.txt" 'FAILOPEN_EXECUTED'
check_in  "orphan sleep 300 disapu bersih via fallback kill(-pgid) saat fail-open (LINGERING_FAILOPEN_ORPHANS=0)" \
	"$R11/var/failopen_clean_audit.txt" 'LINGERING_FAILOPEN_ORPHANS=0'
check_in  "event loop tetap berjalan stabil dan shutdown bersih" "$L11" \
	'graceful shutdown'

# ------------------------------------------------------------- Verifikasi Guard & Kasus Ekstrem
printf '\n== Verifikasi Guard Isolasi & Kasus Ekstrem ==\n'

# 1. Assertion TEST_LEAVES: seluruh leaf test di $RUN_CG_BASE tidak bocor
leaked=""
for leaf in $TEST_LEAVES; do
	if [ -d "$RUN_CG_BASE/$leaf" ]; then
		leaked="$leaked $leaf"
	fi
done
if [ -n "$leaked" ]; then
	bad "kebocoran leaf cgroup milik test:$leaked"
else
	ok "assertion TEST_LEAVES: seluruh leaf test di $RUN_CG_BASE ter-reap bersih"
fi

# 2. Perlindungan cgroup eksternal host (sentinel guard)
if [ -d "$EXTERNAL_GUARD_CG" ]; then
	ok "cgroup host eksternal ($EXTERNAL_GUARD_CG) 100% utuh dan tidak tersentuh"
	$SUDO rmdir "$EXTERNAL_GUARD_CG" 2>/dev/null || true
else
	bad "cgroup host eksternal terganggu atau hilang!"
fi

# 3. Host /sys/fs/cgroup/ninit tidak pernah disentuh
if [ "$HOST_NINIT_PREEXISTED" -eq 0 ]; then
	if [ -d /sys/fs/cgroup/ninit ]; then
		bad "/sys/fs/cgroup/ninit muncul di host (isolasi jebol)"
	else
		ok "/sys/fs/cgroup/ninit host tidak pernah dibuat/disentuh (isolasi 100% di $RUN_CG)"
	fi
fi

# 4. Collision rejection test
collision_code=0
(
	mkdir "$RUN_CG" 2>/dev/null
) || collision_code=$?
if [ "$collision_code" -ne 0 ]; then
	ok "guard collision: strict mkdir menolak tabrakan cgroup eksisting (exit=$collision_code)"
else
	bad "guard collision: strict mkdir seharusnya gagal jika direktori sudah ada!"
fi

# 5. Trap safety pada partial setup (RUN_CG kosong / belum dibuat)
partial_trap_ok=1
(
	RUN_CG=""
	RUN_CG_DEV_INO=""
	clean_run_cgroup || exit 1
) || partial_trap_ok=0
if [ "$partial_trap_ok" -eq 1 ]; then
	ok "guard trap safety: clean_run_cgroup aman dieksekusi saat RUN_CG belum diinisialisasi"
else
	bad "guard trap safety: clean_run_cgroup melempar error saat setup parsial"
fi

# 6. Inode identity / symlink tampering detection
tamper_detected=0
(
	temp_d=$(mktemp -d /tmp/cg-tamper.XXXXXX)
	fake_ino="0:0"
	(
		RUN_CG="$temp_d"
		RUN_CG_DEV_INO="$fake_ino"
		if clean_run_cgroup 2>/dev/null; then
			exit 0
		else
			exit 1
		fi
	) || tamper_detected=1
	rmdir "$temp_d" 2>/dev/null || true
	exit "$tamper_detected"
) || tamper_detected=1
if [ "$tamper_detected" -eq 1 ]; then
	ok "guard integritas inode: clean_run_cgroup menolak operasi saat dev:ino berubah"
else
	bad "guard integritas inode: clean_run_cgroup lolos saat dev:ino tidak cocok"
fi

# 7. Assertion guard PID reuse: PID non-eksisten HARUS ditolak (fail-closed).
pid_reuse_guard=0
dead_pid=9999999
if [ -r /proc/sys/kernel/pid_max ]; then
	dead_pid=$(($(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 4194304) + 1))
fi
is_test_process "$dead_pid" 2>/dev/null && pid_reuse_guard=1
if [ "$pid_reuse_guard" -ne 1 ]; then
	ok "guard PID reuse: is_test_process $dead_pid (PID non-eksisten) ditolak fail-closed (status 1)"
else
	bad "guard PID reuse: is_test_process $dead_pid (PID non-eksisten) dianggap milik test!"
fi

# 8. Assertion guard proses eksternal host: proses di luar cgroup/chroot test
#    HARUS ditolak DAN TIDAK PERNAH dibunuh oleh clean_run_cgroup.
ext_pid=""
if command -v sleep >/dev/null 2>&1; then
	sleep 60 &
	ext_pid=$!
fi
if [ -n "$ext_pid" ] && kill -0 "$ext_pid" 2>/dev/null; then
	ext_rej=0
	if is_test_process "$ext_pid" 2>/dev/null; then
		ext_rej=1
	fi
	if [ "$ext_rej" -ne 1 ]; then
		ok "guard proses eksternal: is_test_process $ext_pid (proses host di luar cgroup/chroot test) ditolak"
	else
		bad "guard proses eksternal: is_test_process $ext_pid keliru menganggap proses host eksternal milik test!"
	fi

	# clean_run_cgroup TIDAK BOLEH membunuh proses host eksternal.
	clean_run_cgroup >/dev/null 2>&1 || true
	sleep 0.3
	if kill -0 "$ext_pid" 2>/dev/null; then
		ok "guard proses eksternal: clean_run_cgroup tidak membunuh proses host eksternal (pid $ext_pid)"
	else
		bad "guard proses eksternal: clean_run_cgroup MEMBUNUH proses host eksternal (pid $ext_pid)!"
	fi

	# Hentikan sleep dummy (bukan bagian dari pembersihan test).
	kill "$ext_pid" 2>/dev/null || true
	wait "$ext_pid" 2>/dev/null || true
else
	skip "guard proses eksternal dilewati: tidak dapat menjalankan proses dummy host"
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
