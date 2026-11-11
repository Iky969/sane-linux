# Sane-Linux English Migration Glossary & Translation Table

## Phase 0b Guidelines (Pre-v1.1.0)
1. **Language Policy**:
   - All new code, comments, commit messages, PR titles, and test scripts must be written in English.
   - Core log format transitions from mixed Indonesian/English to clean, consistent English.
   - Zero runtime i18n overhead (no gettext or locale tables in PID 1 static binary).
2. **Atomic Transition (PR A)**:
   - `ninit.c` log strings, all test assertions in `scripts/*.sh`, boot markers (`run-qemu.sh`), and fixtures (`test-qemu-report.sh`) must be updated simultaneously in one atomic commit.
   - Negative assertions (`absent_in` / `check_absent`) must be strictly verified with `scripts/lint-log-patterns.py` to prevent false greens.

---

## 1. General Terminology Glossary

| Indonesian | English Standard | Context / Example |
|---|---|---|
| layanan | service | `service '%s' marked failed` |
| dibersihkan | cleaned up | `cgroup: cleaned up '%s'` |
| dinyatakan gagal | marked failed | `service marked failed` |
| dibatalkan | cancelled | `service '%s' cancelled` |
| ditunda | delayed | `respawn delayed` |
| gagal | failed | `mount %s -> %s failed` |
| batas | limit | `service limit %d reached` |
| batas resource | resource limit | `resource limits ignored` |
| diabaikan | ignored | `limit ignored` |
| ditolak | rejected | `entry rejected` |
| dilewati | skipped | `SIGKILL skipped` |
| tidak valid | invalid | `service name '%s' invalid` |
| tidak ditemukan | not found | `Dependency '%s' for '%s' not found` |
| ter-mount | mounted | `cgroup2: /sys/fs/cgroup mounted` |
| main loop siap | main loop ready | Boot milestone marker checked by QEMU & test harnesses |
| masuk rescue mode | entering rescue mode | `Entering rescue mode (shell).` |
| Peringatan: | Warning: | Consistent warning prefix |
| percobaan | attempts | `3 attempts, service marked failed` |

---

## 2. Complete String Mapping Table (ninit.c & Tests)

| # | Indonesian / Old String in ninit.c | English / New String in ninit.c | Affected Test Pattern / Assertion |
|---|---|---|---|
| 1 | `mount %s -> %s gagal: %s` | `mount %s -> %s failed: %s` | Early mount failure |
| 2 | `cgroup: buka %s gagal: %s (toleransi nested/container)` | `cgroup: open %s failed: %s (nested/container tolerant)` | Subtree control open |
| 3 | `cgroup: controller '%s' pada %s gagal: %s (toleransi partial)` | `cgroup: controller '%s' at %s failed: %s (partial tolerance)` | Controller enablement |
| 4 | `cgroup2: /sys/fs/cgroup sudah ter-mount` | `cgroup2: /sys/fs/cgroup already mounted` | Cgroup mount check |
| 5 | `cgroup2: mount /sys/fs/cgroup gagal: %s` | `cgroup2: mount /sys/fs/cgroup failed: %s` | `cgroup2: mount /sys/fs/cgroup failed` |
| 6 | `cgroup2: /sys/fs/cgroup ter-mount` | `cgroup2: /sys/fs/cgroup mounted` | Cgroup mounted |
| 7 | `cgroup: base path di-override: %s` | `cgroup: base path overridden: %s` | Scoped test harness run |
| 8 | `cgroup: nama layanan '%s' tidak valid, operasi cgroup dibatalkan` | `cgroup: service name '%s' invalid, cgroup operation aborted` | Anti-traversal guard |
| 9 | `cgroup: tulis 1 ke %s gagal: %s` | `cgroup: write 1 to %s failed: %s` | cgroup.subtree_control |
| 10 | `cgroup: fail-open aktif untuk '%s' (cgroup tidak tersedia)` | `cgroup: fail-open active for '%s' (cgroup unavailable)` | Fail-open logging |
| 11 | `Warning: batas resource diabaikan pada layanan '%s' karena cgroup tidak tersedia` | `Warning: resource limits ignored on service '%s' because cgroup unavailable` | `resource limits ignored on service 'failopen_svc' because cgroup unavailable` |
| 12 | `cgroup: mkdir %s gagal: %s` | `cgroup: mkdir %s failed: %s` | Directory creation failure |
| 13 | `cgroup: tulis %s ke %s gagal: %s` | `cgroup: write %s to %s failed: %s` | Limit write failure |
| 14 | `Warning: batas resource memory.max diabaikan pada layanan '%s'` | `Warning: memory.max resource limit ignored on service '%s'` | Limit write fallback |
| 15 | `cgroup: buka %s gagal: %s` | `cgroup: open %s failed: %s` | File open failure |
| 16 | `Warning: batas resource cpu.max diabaikan pada layanan '%s'` | `Warning: cpu.max resource limit ignored on service '%s'` | Limit write fallback |
| 17 | `Warning: batas resource pids.max diabaikan pada layanan '%s'` | `Warning: pids.max resource limit ignored on service '%s'` | Limit write fallback |
| 18 | `cgroup: tulis pid %d ke %s gagal: %s` | `cgroup: write pid %d to %s failed: %s` | cgroup.procs write failure |
| 19 | `cgroup: dibersihkan '%s'` | `cgroup: cleaned up '%s'` | `cgroup: cleaned up 'mem_test'`, `pids_test`, etc. |
| 20 | `cgroup: rmdir %s gagal: %s` | `cgroup: rmdir %s failed: %s` | Leaf removal failure |
| 21 | `buka %s gagal: %s` | `open %s failed: %s` | Config open error |
| 22 | `Parse err: baris melebihi MAX_LINE (%d), baris ditolak` | `Parse err: line exceeds MAX_LINE (%d), line rejected` | Long config line |
| 23 | `Peringatan: batas %d layanan tercapai, '%s' diabaikan` | `Warning: limit of %d services reached, '%s' ignored` | `Warning: limit of 64 services reached` |
| 24 | `Parse err: nama layanan '%s' tidak boleh memuat '/'` | `Parse err: service name '%s' cannot contain '/'` | `Parse err: service name` |
| 25 | `Parse err: nama layanan '%s' tidak valid (kosong, '.', '..' atau memuat '..'), entri ditolak` | `Parse err: service name '%s' invalid (empty, '.', '..' or contains '..'), entry rejected` | `entry rejected` |
| 26 | `Parse err: nama layanan '%s' sudah terdaftar, entri duplikat ditolak` | `Parse err: service name '%s' already registered, duplicate entry rejected` | `duplicate entry rejected` |
| 27 | `Parse err: timeout '%s' di luar jangkauan (1-86400s) pada layanan '%s', memakai default %ds` | `Parse err: timeout '%s' out of range (1-86400s) on service '%s', using default %ds` | Timeout range check |
| 28 | `Parse err: format timeout '%s' tidak valid pada layanan '%s', memakai default %ds` | `Parse err: invalid timeout format '%s' on service '%s', using default %ds` | Timeout parse check |
| 29 | `Warning: opsi '%s' tidak dikenal pada layanan '%s'` | `Warning: unknown option '%s' on service '%s'` | Unknown option |
| 30 | `Parse err: memory_max '%s' tidak valid pada layanan '%s', batas diabaikan` | `Parse err: invalid memory_max '%s' on service '%s', limit ignored` | `invalid memory_max '64MB'` |
| 31 | `Parse err: cpu_max '%s' tidak valid pada layanan '%s', batas diabaikan` | `Parse err: invalid cpu_max '%s' on service '%s', limit ignored` | `invalid cpu_max 'invalid 100000'` |
| 32 | `Parse err: pids_max '%s' tidak valid pada layanan '%s', batas diabaikan` | `Parse err: invalid pids_max '%s' on service '%s', limit ignored` | `invalid pids_max '-5'` |
| 33 | `Warning: mode '%s' tidak dikenal untuk '%s'. Default: once` | `Warning: unknown mode '%s' for '%s'. Default: once` | Unknown mode |
| 34 | `Parse err: nama layanan terlalu panjang (panjang %zu > maks %d), entri ditolak` | `Parse err: service name too long (length %zu > max %d), entry rejected` | `Parse err: service name too long` |
| 35 | `Parse err: perintah layanan '%s' terlalu panjang (panjang %zu > maks %d), entri ditolak` | `Parse err: service command '%s' too long (length %zu > max %d), entry rejected` | `Parse err: service command` |
| 36 | `Parse err: dependensi layanan '%s' terlalu panjang (panjang %zu > maks %d), entri ditolak` | `Parse err: service dependency '%s' too long (length %zu > max %d), entry rejected` | `Parse err: service dependency` |
| 37 | `Parse err: memory_max layanan '%s' terlalu panjang (panjang %zu > maks %d), entri ditolak` | `Parse err: service memory_max '%s' too long (length %zu > max %d), entry rejected` | Long memory_max |
| 38 | `Parse err: cpu_max layanan '%s' terlalu panjang (panjang %zu > maks %d), entri ditolak` | `Parse err: service cpu_max '%s' too long (length %zu > max %d), entry rejected` | Long cpu_max |
| 39 | `Parse err: pids_max layanan '%s' terlalu panjang (panjang %zu > maks %d), entri ditolak` | `Parse err: service pids_max '%s' too long (length %zu > max %d), entry rejected` | Long pids_max |
| 40 | `FATAL: Dependensi '%s' untuk '%s' tidak ditemukan` | `FATAL: Dependency '%s' for '%s' not found` | `FATAL: Dependency 'db' for 'web' not found` |
| 41 | `FATAL: Stack overflow pada topological sort!` | `FATAL: Stack overflow in topological sort!` | Toposort recursion |
| 42 | `FATAL: CYCLE DETECTED di %s -> %s` | `FATAL: CYCLE DETECTED at %s -> %s` | Cyclic config |
| 43 | `%s: respawn ditunda (timer %d detik, loop tidak diblokir)` | `%s: respawn delayed (timer %d seconds, loop unblocked)` | `leak: respawn delayed` |
| 44 | `pipe2 %s: %s (spawn digagalkan, retry)` | `pipe2 %s: %s (spawn aborted, retry)` | Pipe error |
| 45 | `%s: gagal buat pipe %d kali, layanan dinyatakan gagal` | `%s: failed to create pipe %d times, service marked failed` | Max pipe retries |
| 46 | `fcntl CLOEXEC %s: %s (spawn digagalkan, retry)` | `fcntl CLOEXEC %s: %s (spawn aborted, retry)` | fcntl error |
| 47 | `%s: gagal pasang CLOEXEC %d kali, layanan dinyatakan gagal` | `%s: failed to set CLOEXEC %d times, service marked failed` | Max cloexec retries |
| 48 | `fork %s: %s (%d percobaan, layanan dinyatakan gagal)` | `fork %s: %s (%d attempts, service marked failed)` | `attempts, service marked failed` |
| 49 | `%s: crash-loop terdeteksi (%d kegagalan berturut-turut), layanan dinyatakan gagal` | `%s: crash-loop detected (%d consecutive failures), service marked failed` | Crash-loop trigger |
| 50 | `%s: crash-loop ke-%d, jeda respawn naik ke %d detik` | `%s: crash-loop #%d, respawn delay increased to %d seconds` | Exponential backoff |
| 51 | `layanan '%s' dibatalkan: dependensi '%s' gagal` | `service '%s' cancelled: dependency '%s' failed` | `service 'app' cancelled: dependency 'boot' failed` |
| 52 | `%s: layanan once melebihi batas waktu %d detik, dinyatakan gagal` | `%s: once service exceeded %d seconds timeout, marked failed` | `hanger: once service exceeded 2 seconds timeout, marked failed` |
| 53 | `shutdown: remount / read-only gagal: %s` | `shutdown: remount / read-only failed: %s` | Clean shutdown |
| 54 | `shutdown: umount2 %s gagal: %s` | `shutdown: umount2 %s failed: %s` | Umount fail |
| 55 | `%s: grup sudah mati, SIGKILL dilewati` | `%s: process group already dead, SIGKILL skipped` | Stubborn process kill |
| 56 | `fstab: opsi '%s' menerapkan noexec,nosuid,nodev` | `fstab: option '%s' applies noexec,nosuid,nodev` | fstab parsing |
| 57 | `fstab: opsi '%s' menerapkan nosuid,nodev` | `fstab: option '%s' applies nosuid,nodev` | fstab parsing |
| 58 | `fstab: opsi '%s' khusus userspace, diabaikan` | `fstab: option '%s' is userspace-only, ignored` | `userspace-only, ignored` |
| 59 | `fstab: opsi '%s' bukan flag, diteruskan sebagai data` | `fstab: option '%s' is not a flag, passed as data` | fstab parsing |
| 60 | `fstab: mountpoint '%s' tidak valid (harus absolut, maks %zu karakter)` | `fstab: mountpoint '%s' invalid (must be absolute, max %zu chars)` | Invalid mountpoint |
| 61 | `fstab: mountpoint '%s' memuat komponen '%.*s', ditolak` | `fstab: mountpoint '%s' contains component '%.*s', rejected` | `contains component '..'` |
| 62 | `fstab: chmod '%s' gagal: %s` | `fstab: chmod '%s' failed: %s` | Chmod error |
| 63 | `fstab: stat '%s' gagal: %s` | `fstab: stat '%s' failed: %s` | `stat '/mnt/dangle' failed` |
| 64 | `fstab: komponen '%s' dari mountpoint '%s' bukan direktori` | `fstab: component '%s' of mountpoint '%s' is not a directory` | Component check |
| 65 | `fstab: mkdir '%s' gagal: %s` | `fstab: mkdir '%s' failed: %s` | Mountpoint mkdir |
| 66 | `fstab: %s tidak ada, dilewati` | `fstab: %s does not exist, skipped` | Non-existent fstab device |
| 67 | `fstab: baris melebihi MAX_LINE (%d), dilewati` | `fstab: line exceeds MAX_LINE (%d), skipped` | Long fstab line |
| 68 | `fstab: baris tidak lengkap: '%s'` | `fstab: incomplete line: '%s'` | Malformed fstab |
| 69 | `fstab: %s -> %s dilewati (opsi noauto)` | `fstab: %s -> %s skipped (noauto option)` | `skipped (noauto option)` |
| 70 | `fstab: %s -> %s dilewati (bind/rbind tidak didukung)` | `fstab: %s -> %s skipped (bind/rbind not supported)` | `skipped (bind/rbind not supported)` |
| 71 | `fstab: %s -> %s dilewati (mountpoint duplikat, sudah di-mount entri sebelumnya)` | `fstab: %s -> %s skipped (duplicate mountpoint, already mounted by previous entry)` | `skipped (duplicate mountpoint` |
| 72 | `fstab: %s -> %s dilewati (mountpoint tidak bisa disiapkan)` | `fstab: %s -> %s skipped (mountpoint could not be prepared)` | Prep failure |
| 73 | `fstab: mount %s -> %s (%s) [data: %s] gagal: %s` | `fstab: mount %s -> %s (%s) [data: %s] failed: %s` | `fstab: mount .* failed` |
| 74 | `Peringatan: gagal mengosongkan signal mask: %s` | `Warning: failed to clear signal mask: %s` | Signal reset |
| 75 | `Masuk rescue mode (shell).` | `Entering rescue mode (shell).` | `Entering rescue mode (shell)` |
| 76 | `FATAL: execl /bin/sh gagal: %s` | `FATAL: execl /bin/sh failed: %s` | Rescue shell failure |
| 77 | `main loop siap` | `main loop ready` | `main loop ready` (All tests, QEMU runner, benchmarks) |
| 78 | `Peringatan: initctl_fd tidak valid` | `Warning: initctl_fd invalid` | IPC warning |
| 79 | `Peringatan: log_fifo_fd tidak valid` | `Warning: log_fifo_fd invalid` | FIFO warning |
| 80 | `Config gagal dibaca/di-parse!` | `Config failed to read/parse!` | `Config failed to read/parse!` |
| 81 | `Dependensi tidak valid!` | `Invalid dependencies!` | Rescue reason |
| 82 | `Cycle terdeteksi!` | `Cycle detected!` | Rescue reason |
