# LAPORAN CODER 1 (Sesi 25) — Phase 1: T11, T10, T13

**Repo:** `/home/ubuntu/workspace/sane-linux/`
**Branch:** `feat/phase1-init-hardening`
**Commit:** `47857f4` — `feat(init): T11 fork EAGAIN retry, T10 state machine enum, T13 SIGTERM grace escalation`
**Commit di atas:** `17f4ea4` (Coder 2 / Sesi 26 — T12/T14/T14B)
**Author commit:** `Rzy <168882072+Iky969@users.noreply.github.com>`
**File diubah:** `ninit.c` SAJA (+322 / -51). Makefile dan test scripts TIDAK disentuh.

---

## 1. Ringkasan Perubahan

### T11 — Fork EAGAIN Retry + Exponential Backoff
`spawn_service()`: `fork()` tunggal → loop terbatas di dalam satu pemanggilan.

- Percobaan: 1 `fork()` awal + maksimal `MAX_SPAWN_RETRY` (=3) retry → **maks 4 `fork()`**, tidak pernah lebih.
- Backoff `nanosleep()`: 100 ms → 200 ms → 400 ms (`SPAWN_RETRY_BASE_MS << (attempt-1)`), total ≤ 700 ms.
- Retry hanya untuk `errno == EAGAIN`; errno lain (ENOMEM dsb.) langsung terminal — menunggu tidak akan menyelesaikannya.
- Exhausted: sync pipe dilepas, `errno` di-capture sebelum logging, log + state FAILED (terminal, `need_respawn=0`):
  - `spawn: fork() EAGAIN for '<name>', retrying in 100|200|400ms (retry N/3)` (per retry)
  - `fork EAGAIN after 3 retries for <name>: <strerror>` (terminal)
  - `fork <name>: <strerror> (<attempts> attempts, service marked failed)` (telemetri terminal lama dipertahankan — harness `test-spawn-failure.sh` meng-assert string ini dan `grep -c 'fork boot'` ≤ 3)
- Tidak ada busy-loop: `nanosleep` di antara retry, jumlah `fork()` terbatas.

### T10 — State Machine Formalization
- Enum: `STOPPED=0, STARTING=1, RUNNING=2, STOPPING=3, DONE=4, FAILED=5`
  (urutan relatif state lama `STOPPED < RUNNING < DONE < FAILED` dipertahankan; `STARTING`/`STOPPING` disisipkan di posisi kanonik 1 dan 3. Tidak ada kode yang membandingkan state secara numerik — sudah dicek: `grep 'state *[<>]'` kosong.)
- `svc_set_state(service_t*, svc_state_t)`: satu-satunya titik assignment (`svc->state = X` hanya ada di dalam fungsi ini).
  - Validasi lewat tabel invarian `svc_transition_allowed()`.
  - Illegal transition: **log warning lalu tetap diterapkan** (fail-open untuk log — state machine tidak boleh membekukan PID 1).
  - Log transisi: `[ninit] <name>: state <OLD> -> <NEW>`.
  - `state == new_state` → no-op (tanpa log, tanpa I/O) supaya tidak ada log sampah.
- Publikasi state: `/run/ninit-<name>.state` berisi NAMA state (`RUNNING`, `STOPPED`, …), ditulis `O_TRUNC|O_CLOEXEC` 0644, best-effort (gagal = warning, bukan abort). Ini memberi `scripts/test-state-machine.sh` (milik Coder 2) interface file selain grep log.
- Semua assignment langsung lama sudah dikonversi: parse_config, 2 jalur pipe/CLOEXEC, fork terminal, spawn sukses, reap_zombies (DONE/FAILED/STOPPED/crash-loop), spawn_eligible, respawn_services, cancel_dependents, enforce_once_timeout, shutdown.
- Transisi baru yang nyata dipakai: `STARTING` diset sebelum pipe setup/fork, `STOPPING` diset saat shutdown (graceful + force) dan saat once-timeout (`RUNNING -> STOPPING -> FAILED`).

### T13 — SIGTERM → Grace → SIGKILL Escalation
- Fase 1: `SIGTERM` ke setiap service hidup melalui **dua jalur**: `kill(-pgid, SIGTERM)` (menjangkau proses yang keluar dari cgroup) **dan** sweep `/sys/fs/cgroup/ninit-<name>/cgroup.procs` (`cgroup_signal_service()` — menjangkau proses yang `setsid()`/`setpgid()` dan lewat dari `kill(-pgid)`, SANE-01). State → `STOPPING` per service.
- Fase 2: grace window **per service**: `:grace=N` (0–3600s, default `SIGTERM_GRACE_SECS`=5, `grace=0` = eskalasi langsung). Polling 100 ms pakai `nanosleep` dengan deadline `CLOCK_MONOTONIC`. Total tunggu dibatasi grace **terpanjang**, bukan jumlah service (bukan O(N × grace)).
- Masih hidup saat deadline-nya lewat → `kill(-pgid, SIGKILL)` + `cgroup.kill`, log `[ninit] <name>: grace expired, SIGKILL` **tepat sekali** (`sigkill_sent` men-suppress SIGKILL/skip-log ganda di sweep akhir).
- Sweep SIGKILL akhir dipertahankan apa adanya; service yang sudah dieskalasi tidak lagi dilaporkan `process group already dead, SIGKILL skipped` (assertion `absent` di `test-sigterm.sh` scenario 4 harus tetap hijau; sekarang hijau).
- Parsing `:grace=N` mengikuti pola tag yang ada (`:memory_max=`, `:timeout=`, …): masuk perhitungan `first_tag`, validasi digit + rentang, fallback default + log Parse err.

---

## 2. Bukti Eksekusi (semua nyata, exit code dicek)

| Verifikasi | Perintah | Hasil |
|---|---|---|
| Build default | `make` | exit 0, tanpa warning |
| **Zero-warning gate** | `gcc -static -O2 -Wall -Wextra -Werror -o ninit ninit.c` | exit 0, 0 warning |
| Suite penuh (post-commit) | `sudo make test` | **exit 0, 7/7 suite `RESULT: PASS`**, tidak ada `FAIL:`, tidak ada `make Error`, guard cgroup bersih |
| Lint CI | `make lint` | PASS (log pattern + format specifier, `-Wformat=2` clean) |
| Harness fitur baru (post-commit, biner target) | `sudo sh verify-coder1-t10-t11-t13.sh /home/ubuntu/workspace/sane-linux/ninit` | **exit 0, 24/24 check OK** |

Verifikasi fitur BARU yang tidak di-assert suite existing (harness terpisah, di scratch — tidak masuk repo):
`/home/ubuntu/.hermes/cache/scratch/verify-coder1-t10-t11-t13.sh`

- T10: `STOPPED -> STARTING`, `STARTING -> RUNNING`, `RUNNING -> STOPPING`, `STOPPING -> STOPPED`, nol `illegal state transition`, `/run/ninit-stateful.state` = `RUNNING`, `/run/ninit-stopper.state` = `RUNNING`.
- T11: retry 1/3 100 ms, 2/3 200 ms, 3/3 400 ms, `fork EAGAIN after 3 retries for boot: Resource temporarily unavailable`, `boot: state STARTING -> FAILED`, dependent `dep` cancelled (tidak menggantung), `main loop ready` tetap tercapai, **tepat 3 baris retry** (bukti no-busy-loop), `grep -c 'fork boot'` = 2 (≤ 3, kontrak harness).
- T13: `stub: grace expired, SIGKILL` tepat 1× dan shutdown selesai **3038 ms** dengan `:grace=2` (default 5s akan > 6300 ms) → override benar-benar dipakai.

Log: `maketest-target.log`, `maketest-postcommit.log`, `verify-postcommit-target.log` (semua di `/home/ubuntu/.hermes/cache/scratch/`).
Patch: `coder1-t10-t11-t13.patch` sha256 `9252a8eee5e813470f4f24d27509255e06a95cc2c5519e6ea7dca582cdca4059`; `sha256(ninit.c)` = `a24529652c599eecaa65234fab317fa4a2d30f01a9f00b03bc6c8d44048eec7a` (identik antara scratch dan target).

---

## 3. Catatan / Deviasi yang Harus Dilihat Auditor

1. **Koreksi spesifikasi `cgroup.kill` untuk SIGTERM (T13).** Instruksi dispatch menulis "tulis 1 ke `cgroup.kill` JIKA tersedia, ATAU `kill(-pgid, SIGTERM)`". `cgroup.kill` **hanya** mengimplementasikan SIGKILL — menulis `1` ke sana membunuh dengan SIGKILL, bukan SIGTERM, dan akan melewati seluruh grace window. Kalau diikuti harfiah, `test-sigterm.sh` scenario 1 (service wajib menerima SIGTERM dan exit 0 lewat trap) langsung gagal. Implementasi: SIGTERM via pgid + sweep `cgroup.procs` (satu-satunya cara benar mengirim sinyal non-fatal ke seluruh cgroup); `cgroup.kill` tetap dipakai untuk SIGKILL.
2. **EAGAIN exhausted untuk service `respawn` sekarang terminal FAILED** (perilaku lama: retry tak terbatas lewat timer respawn). Ini mengikuti TODOS.md T11 ("If exhausted: transition service to `SVC_STATE_FAILED`") dan dispatch. Konsekuensi: service respawn yang kena starvation PID akan berhenti permanen dan dependent-nya di-cancel — fail-closed, tapi ini perubahan perilaku; idealnya diputuskan Lead/Auditor kalau ingin respawn tetap punya jalur pemulihan saat EAGAIN.
3. **Enum: `DONE=4`, `FAILED=5`.** Plan menulis `FAILED=4` (enum contoh tanpa `DONE`), tapi `DONE` dipakai luas (`deps_satisfied`, `reap_zombies`, `spawn_eligible_services`). Saya pertahankan `DONE` dan urutan relatif state lama; `STARTING=1`/`STOPPING=3` sesuai spesifikasi. Tidak ada state tersimpan secara numerik (file state menyimpan nama), jadi tidak ada dampak kompatibilitas.
4. **Tidak ada perintah "stop service" di initctl.** T13 "shutdown atau stop command": `initctl` hanya punya `poweroff`/`reboot`/`force-*`, jadi eskalasi berlaku di jalur shutdown (graceful dan force). Kalau mau per-service stop command, itu tiket terpisah.
5. **`scripts/test-state-machine.sh` belum ada** — sesuai PLAN-PHASE1-DISPATCH itu file Coder 2 (Sesi 26); catatan Lead di Sesi 1 menyebut masih menunggu konfirmasi PIC. Logic `ninit.c` sudah expose dua interface: log transisi dan `/run/ninit-<name>.state`.
6. `usleep()` lama di jalur shutdown/cleanup cgroup TIDAK saya ubah (no refactoring sprawl); semua delay **baru** (backoff T11, poll grace T13) memakai `nanosleep` lewat helper `sleep_ms()` yang EINTR-safe.
7. `sigkill_sent`/`grace` di-reset pada spawn sukses dan saat registrasi config; `ninit.c` tetap compile bersih tanpa `-Wextra` (dipakai `test-spawn-failure.sh` scenario 4 yang meng-compile ulang sumber dengan `-DCRASH_LIMIT=2 -DBACKOFF_MAX=1`).
