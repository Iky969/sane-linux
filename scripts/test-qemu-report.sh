#!/bin/sh
# Test-qemu-report: membuktikan pemeriksaan report() di scripts/run-qemu.sh
# tidak longgar — log konsol di mana layanan console mati dan di-respawn ulang
# harus GAGAL, bukan LULUS.
#
# Kenapa test ini ada (catatan PR #1, "Temuan berikutnya"): 'started console'
# ditulis spawn_service() saat FORK, bukan setelah exec berhasil. Layanan
# console yang langsung mati (mis. `console:respawn:/bin/does-not-exist`)
# tetap menghasilkan baris 'started console' berulang, exit status=0x7f00, dan
# 'respawn ditunda' — sementara harness lama hanya mencocokkan tiga penanda
# ('ninit start (PID 1)', 'main loop siap', 'started console') sehingga tetap
# melaporkan HASIL: LULUS. Test ini gagal bila pelonggaran itu kembali.
#
# Cara kerja: scripts/run-qemu.sh dijalankan dengan REPORT_ONLY=1 terhadap
# fixture log konsol (tidak ada QEMU yang di-boot, tidak butuh root). Setiap
# skenario menguji kode keluar DAN baris pemeriksaan spesifik yang diharapkan,
# supaya kegagalan tidak boleh datang dari pemeriksaan yang salah sasaran.
#
# Pemakaian:
#   sh ./scripts/test-qemu-report.sh
#
# Variabel lingkungan:
#   HARNESS=./scripts/run-qemu.sh   harness yang diperiksa

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HARNESS=${HARNESS:-$SCRIPT_DIR/run-qemu.sh}

fail() { printf 'GAGAL: %s\n' "$1" >&2; exit 1; }

[ -f "$HARNESS" ] || fail "harness '$HARNESS' tidak ada"
sh -n "$HARNESS" || fail "'$HARNESS' tidak lolos sh -n"

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT INT TERM

fail_count=0
ok()  { printf '  [ OK ]   %s\n' "$1"; }
bad() { printf '  [GAGAL] %s\n' "$1"; fail_count=$((fail_count + 1)); }

expect_rc() { # $1 = skenario, $2 = rc aktual, $3 = rc yang diharapkan
	if [ "$2" = "$3" ]; then ok "$1 (exit=$2)"; else bad "$1: exit=$2, seharusnya $3"; fi
}

expect_line() { # $1 = keluaran harness, $2 = teks yang harus muncul, $3 = label
	if printf '%s' "$1" | grep -qF "$2"; then ok "$3"; else bad "$3 (tidak ditemukan: '$2')"; fi
}

expect_absent() { # $1 = keluaran harness, $2 = teks yang TIDAK boleh muncul, $3 = label
	if printf '%s' "$1" | grep -qF "$2"; then bad "$3 (muncul padahal tidak boleh: '$2')"; else ok "$3"; fi
}

run_report() { # $1 = nama fixture; menyetel RC dan OUT
	RC=0
	OUT=$(CONSOLE_LOG="$FIX/$1.log" REPORT_ONLY=1 sh "$HARNESS" 2>&1) || RC=$?
}

# ------------------------------------------------------------------ fixture
# Setiap baris ninit ditulis DUA kali (via /dev/kmsg dan stderr); fixture
# meniru itu supaya deduplikasi PID ikut teruji.
cat > "$FIX/sehat.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[2026-11-05 09:00:01] ninit: ninit start (PID 1)
[    1.200000] ninit: mount fstab: /etc/fstab tidak ada, dilewati
[    1.250000] ninit: main loop siap
[2026-11-05 09:00:01] ninit: main loop siap
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
/ # 
EOF

# Skenario pembuktian PR #1: console:respawn:/bin/does-not-exist.
# Pemeriksaan LAMA semuanya lolos; yang harus menangkap adalah pemeriksaan
# liveness baru (PID unik, exit status, respawn ditunda).
cat > "$FIX/console-mati.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[2026-11-05 09:00:01] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop siap
[2026-11-05 09:00:01] ninit: main loop siap
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
[    1.301000] ninit: console (pid 42) exit status=0x7f00
[2026-11-05 09:00:02] ninit: console (pid 42) exit status=0x7f00
[    2.300000] ninit: console: respawn ditunda (timer 2 detik, loop tidak diblokir)
[2026-11-05 09:00:03] ninit: console: respawn ditunda (timer 2 detik, loop tidak diblokir)
[    3.400000] ninit: started console (pid 51)
[2026-11-05 09:00:04] ninit: started console (pid 51)
[    3.401000] ninit: console (pid 51) exit status=0x7f00
[2026-11-05 09:00:04] ninit: console (pid 51) exit status=0x7f00
EOF

# 'started console' muncul dua kali untuk PID yang SAMA (hanya duplikasi
# kmsg/stderr) + satu exit status: respawn loop belum terjadi, tapi console
# sudah pernah keluar -> tetap harus GAGAL lewat pemeriksaan exit status.
cat > "$FIX/console-exit-satu-pid.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop siap
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
[    2.000000] ninit: console (pid 42) exit status=0x0
[2026-11-05 09:00:02] ninit: console (pid 42) exit status=0x0
EOF

cat > "$FIX/panic.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop siap
[    1.300000] ninit: started console (pid 42)
[    2.000000] Kernel panic - not syncing: Attempted to kill init!
EOF

# Konsol belum pernah start sama sekali.
cat > "$FIX/konsol-tidak-start.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop siap
EOF

# ninit tidak pernah masuk event loop.
cat > "$FIX/tanpa-main-loop.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
EOF

# Console sehat, tapi service respawn LAIN ('web') pernah menunda jendela
# respawn-nya — perilaku normal pada init.conf multi-layanan. Pemeriksaan
# 'respawn ditunda' yang di-scope ke console TIDAK boleh membuat ini GAGAL
# (regresi balik dari catatan review PR #6: pola global terlalu ketat).
cat > "$FIX/respawn-service-lain.log" <<'EOF'
[    1.100000] ninit: ninit start (PID 1)
[2026-11-05 09:00:01] ninit: ninit start (PID 1)
[    1.250000] ninit: main loop siap
[2026-11-05 09:00:01] ninit: main loop siap
[    1.300000] ninit: started console (pid 42)
[2026-11-05 09:00:01] ninit: started console (pid 42)
[    1.310000] ninit: started web (pid 43)
[2026-11-05 09:00:01] ninit: started web (pid 43)
[    4.000000] ninit: web (pid 43) exit status=0x0
[2026-11-05 09:00:04] ninit: web (pid 43) exit status=0x0
[    4.100000] ninit: web: respawn ditunda (timer 2 detik, loop tidak diblokir)
[2026-11-05 09:00:04] ninit: web: respawn ditunda (timer 2 detik, loop tidak diblokir)
[    6.200000] ninit: started web (pid 55)
[2026-11-05 09:00:06] ninit: started web (pid 55)
EOF

# ------------------------------------------------------------------ skenario
printf '\n== skenario 1: boot sehat -> LULUS ==\n'
run_report sehat
expect_rc "skenario 1: kode keluar" "$RC" 0
expect_line "$OUT" 'HASIL: LULUS' "skenario 1: laporan LULUS"
expect_line "$OUT" 'console start tepat satu PID (42)' \
	"skenario 1: baris ganda kmsg/stderr terdedup (tetap satu PID)"

printf '\n== skenario 2: console mati + respawn loop -> GAGAL (regresi PR #1) ==\n'
run_report console-mati
expect_rc "skenario 2: kode keluar" "$RC" 1
expect_line "$OUT" 'console punya 2 PID unik' \
	"skenario 2: respawn loop tertangkap lewat PID unik"
expect_line "$OUT" '[GAGAL] console tidak pernah keluar' \
	"skenario 2: exit status console tertangkap"
expect_line "$OUT" '[GAGAL] console tidak di-respawn tertunda' \
	"skenario 2: 'console: respawn ditunda' tertangkap"
expect_line "$OUT" "[ OK ]   layanan /etc/init.conf dijalankan ('started console')" \
	"skenario 2: pemeriksaan lama lolos (bukti lama: harness lama LULUS di log ini)"

printf '\n== skenario 3: console keluar, satu PID -> GAGAL ==\n'
run_report console-exit-satu-pid
expect_rc "skenario 3: kode keluar" "$RC" 1
expect_line "$OUT" '[GAGAL] console tidak pernah keluar' \
	"skenario 3: exit status tertangkap walau PID tunggal"

printf '\n== skenario 4: kernel panic -> GAGAL ==\n'
run_report panic
expect_rc "skenario 4: kode keluar" "$RC" 1
expect_line "$OUT" '[GAGAL] tidak ada kernel panic' "skenario 4: panic tertangkap"

printf '\n== skenario 5: layanan console tidak pernah start -> GAGAL ==\n'
run_report konsol-tidak-start
expect_rc "skenario 5: kode keluar" "$RC" 1
expect_line "$OUT" "[GAGAL] layanan /etc/init.conf dijalankan" \
	"skenario 5: 'started console' yang hilang tertangkap"
expect_line "$OUT" 'console punya 0 PID unik' \
	"skenario 5: hitungan PID unik 0"

printf '\n== skenario 6: main loop tidak muncul -> GAGAL ==\n'
run_report tanpa-main-loop
expect_rc "skenario 6: kode keluar" "$RC" 1
expect_line "$OUT" 'tidak muncul dalam' "skenario 6: ketiadaan 'main loop siap' tertangkap"

printf '\n== skenario 7: service lain di-respawn, console sehat -> LULUS ==\n'
run_report respawn-service-lain
expect_rc "skenario 7: kode keluar" "$RC" 0
expect_line "$OUT" 'HASIL: LULUS' \
	"skenario 7: 'web: respawn ditunda' tidak menyeret harness (check ter-scope)"
expect_line "$OUT" "[ OK ]   console tidak di-respawn tertunda" \
	"skenario 7: pemeriksaan respawn console tetap dieksekusi dan lolos"

printf '\n== konsol: REPORT_ONLY tanpa CONSOLE_LOG -> berhenti dengan pesan jelas ==\n'
RC=0
CONSOLE_LOG="$FIX/tidak-ada.log" REPORT_ONLY=1 sh "$HARNESS" >/dev/null 2>&1 || RC=$?
expect_rc "konfigurasi salah: kode keluar non-nol" "$RC" 1

if [ "$fail_count" -eq 0 ]; then
	printf '\nHASIL: LULUS (semua pemeriksaan)\n'
else
	printf '\nHASIL: GAGAL (%s pemeriksaan)\n' "$fail_count"
	exit 1
fi
