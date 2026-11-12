# LAPORAN SESI 26 (Coder 2) — Phase 1: T12, T14, T14B

**Tanggal:** 2026-11-12
**Branch:** `feat/phase1-init-hardening` (HEAD `7ccf49f`, belum di-commit — Lead yang commit)
**Repo:** `/home/ubuntu/workspace/sane-linux/`
**Status:** SELESAI — semua acceptance criteria terpenuhi, `sudo make test` 7/7 suite PASS

---

## 1. File yang Diubah

| File | Status | Ticket |
|------|--------|--------|
| `ninit.c` | modified | T12, T14 |
| `scripts/test-respawn-cleanup.sh` | **new** | T12 |
| `scripts/test-cgroup-limits.sh` | amended | T14, T14B |
| `Makefile` | modified | integrasi test |

---

## 2. T12 — Respawn Counter Reset + Grandchild Flush

### 2.1 Reset generation counter (`crash_count` + `respawn_delay`)
Helper baru `reset_respawn_counters()` (ninit.c): set `crash_count = 0` dan
`respawn_delay = RESPAWN_DELAY`, lalu log:
```
<service>: respawn counters reset (generation=0, crash_count=0, respawn_delay=2)
```
Dipanggil pada:
- `shutdown_all()` (force & graceful) → service **di-stop**
- crash-loop → `SVC_STATE_FAILED` (service **disabled**)
- dependency failure → `SVC_STATE_FAILED` (di `respawn_services`, `spawn_eligible_services`, `cancel_dependents`)
- once-timeout → `SVC_STATE_FAILED` (`enforce_once_timeout`)

### 2.2 Flush cgroup sebelum respawn timer trigger
Di `spawn_service()`, setelah delay window terlewati dan **sebelum** `fork()`:
```c
if (svc->last_start) {
    init_log("%s: flushing cgroup before respawn", svc->name);
    cgroup_kill_service(svc->name);
}
```
- `cgroup_kill_service()` menulis `1` ke `cgroup.kill` (fallback: kill per-PID via `cgroup.procs`).
- Skip di spawn pertama (`last_start == 0`) — tidak ada generasi sebelumnya.
- Kill di `setup_cgroup()` tetap ada sebagai defense-in-depth.

### 2.3 Grandchild containment
Orang tua/grandchild yang di-reparent ke PID 1 tetap mewarisi cgroup leaf
(ninit hierarchy). `cgroup_kill_service()` menyapu seluruh leaf, jadi tidak ada
proses bocor ke cgroup lain. Diverifikasi oleh test (LINGERING_GC=0).

---

## 3. T14 — Cgroup Directory Cleanup

`cleanup_cgroup()` diperkuat:
1. `cgroup_kill_service()` (cgroup.kill sweep)
2. **Bounded poll** `cgroup.procs` sampai kosong (max 50 × 10ms) — ini yang
   membuat `rmdir` deterministik (rmdir di cgroup berisi proses → EBUSY)
3. `rmdir` dengan retry EBUSY (20 × 5ms)
4. Kegagalan dilog sebagai `Warning: cgroup rmdir ... (leaf may leak)` —
   **tidak pernah crash PID 1**

---

## 4. T14B — Controller Delegation Verify

`scripts/test-cgroup-limits.sh` Scenario 4:
- Service `limits_audit` sekarang juga membaca `cgroup.controllers` leaf ke
  `/var/controllers.val`.
- Helper baru `check_controller()`: assert `memory`, `pids`, `cpu` ada di file
  tersebut. Controller yang tidak tersedia di host di-skip (deteksi dari
  `/sys/fs/cgroup/cgroup.controllers`); controller yang tersedia tapi tidak
  ter-delegasi = FAIL.

`scripts/test-cgroup-limits.sh` Scenario 8 (T14):
- `check_orphans.sh` mengecek `[ ! -d $NINIT_CGROUP_BASE/orphan_maker ]` →
  `LEAF_REMOVED=1` diassert.

---

## 5. Test Suite Baru: `scripts/test-respawn-cleanup.sh`

Deterministik (tidak ada `sleep N` integer; hanya tick `0.05` di poll loop,
pola sama dengan `test-cgroup-limits.sh`).

- **Scenario A** — respawn flush + grandchild containment:
  - service `respawn_svc` fork grandchild (`sleep 300`) lalu exit
  - assert log `flushing cgroup before respawn`
  - generasi 2 assert `LINGERING_GC=0` (via /proc scan + PID audit)
  - assert log `respawn counters reset` (shutdown)
  - assert leaf cgroup hilang, tidak ada EBUSY
- **Scenario B** — disabled service reset:
  - `dep_svc:respawn:...:requires=broken` (broken gagal) → cancelled
  - assert log `dep_svc: respawn counters reset`
- **Isolation guard** — `/sys/fs/cgroup/ninit` host tidak tersentuh, semua
  leaf bebas leak, `cgroup.procs` base kosong.

---

## 6. Verifikasi (bukti eksekusi nyata)

```
$ gcc -static -O2 -Wall -Wextra -Werror -o /tmp/ninit-werror ninit.c
WERROR BUILD OK

$ sudo make test
...
RESULT: PASS  (smoke)
RESULT: PASS  (sigterm)
RESULT: PASS  (config)
RESULT: PASS  (qemu-report)
RESULT: PASS  (spawn-failure)
RESULT: PASS  (cgroup-limits)
RESULT: PASS  (respawn-cleanup)   <-- baru
EXIT=0

$ make lint
✅ PASSED: log patterns clean
✅ Compiler format check passed (-Wformat=2 clean)

$ sudo sh ./scripts/test-respawn-cleanup.sh   (diulang 3x)
RESULT: PASS (all checks)  — deterministik, tidak flaky
```

---

## 7. Catatan / Ambiguitas untuk Lead

1. **`test-state-machine.sh` (T10)**: plan menyebut "Coder 2 menulis script-nya",
   tapi tabel tiket menetapkan T10 → Coder 1. Task dari Lead explisit
   **T12, T14, T14B** saja, jadi script itu **tidak** saya buat. Mohon
   konfirmasi PIC-nya.
2. **"stop service"**: `initctl` belum punya perintah `stop`/`disable` (hanya
   poweroff/reboot/force-*). Saya interpretasikan "stop" = shutdown
   (`shutdown_all`) dan "disabled" = `SVC_STATE_FAILED`. Jika Lead ingin
   perintah `stop` per-service, itu scope baru di luar T12.
3. **Konflik ninit.c**: Coder 1 (Sesi 25) juga mengubah `ninit.c` (T10/T11/T13).
   Kedua pekerja di branch yang sama — perlu urutan commit yang hati-hati.
4. **Belum commit**: sesuai SOUL.md, Lead adalah commit/push authority. Changes
   menunggu di working tree.
