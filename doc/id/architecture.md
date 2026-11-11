# Arsitektur ninit

*[Bahasa Indonesia](architecture.md) | [English](../architecture.md)*

Dokumen ini menjelaskan cara kerja internal `ninit.c`. Rujukan baris mengacu pada
versi terakhir di `main`.

## Prinsip dasar

1. **Satu file, tanpa dependensi.** Hanya libc + syscall Linux. Dimaksudkan untuk
   di-*link* statis agar bisa jadi `/sbin/init` di rootfs minimal.
2. **Menolak jalan kalau bukan PID 1** (`getpid() != 1` → keluar), karena
   `reboot()` dan reaping proses yatim hanya benar pada PID 1.
3. **Tidak pernah memblokir event loop.** Tidak ada `sleep()` di jalur spawn.
4. **Sinyal dulu, layanan kemudian.** Permintaan shutdown selalu diproses sebelum
   reaping/respawn.

## Urutan boot (`main()`)

```
cek getpid()==1  ->  umask(022)  ->  blokir sinyal + sigemptyset(&orig)
   ->  pasang handler sigaction (SIGCHLD/SIGTERM/SIGINT/SIGUSR1/SIGUSR2) + abaikan SIGPIPE
   ->  setup_pseudo_fs()            proc, sysfs, devtmpfs, tmpfs /run & /tmp, cgroup2
   ->  mount_fstab()                pasang filesystem dari /etc/fstab
   ->  buka /var/log/ninit.log, cetak banner
   ->  set_hostname()               dari /etc/hostname
   ->  parse_config(argv[1] atau /etc/init.conf)   gagal => rescue shell /bin/sh
   ->  validate_dependencies()      dependensi hilang => rescue shell /bin/sh
   ->  sort_services()              urut topologis; siklus => rescue shell /bin/sh
   ->  setup_initctl() / run/initctl, setup_log_fifo() /run/log.fifo
   ->  spawn_service() untuk semua layanan
   ->  log "main loop siap"  ->  for (;;) event loop
```

Catatan urutan: `mount_fstab()` sengaja dipanggil **sebelum** file log dibuka,
jadi pesan fstab hanya terlihat di console dan `/dev/kmsg`.

### Rescue mode (`enter_rescue_mode`)

Tiga jalur menyerahkan sistem ke shell darurat: config tidak terbaca
(`parse_config()` gagal), ada `:requires=` yang menunjuk layanan tak dikenal, dan
siklus dependensi. Semuanya lewat satu helper `enter_rescue_mode(reason)` yang:

1. menulis alasan + `Masuk rescue mode (shell).` ke log;
2. mengosongkan signal mask PID 1 (`sigprocmask(SIG_SETMASK, &empty, NULL)`) —
   `main()` memblokir `SIGINT`/`SIGTERM`/`SIGCHLD`/`SIGUSR1`/`SIGUSR2` untuk
   `ppoll`, dan tanpa reset ini rescue shell tidak akan pernah menerima Ctrl+C;
3. mereset disposisi `SIGPIPE` ke `SIG_DFL` — `main()` memasang `signal(SIGPIPE, SIG_IGN)`
   untuk PID 1, dan tanpa reset ini rescue shell mewarisi `SIG_IGN` sehingga utilitas
   pipeline shell (`yes | head -n 1`) gagal rusak;
4. `execl("/bin/sh", "sh", NULL)` menggantikan PID 1; bila gagal, `_exit(1)`.

Helper ini tidak pernah kembali, jadi tidak ada jalur boot yang berlanjut dengan
state setengah jadi (dulu `parse_config()` gagal hanya di-log dan boot lanjut
dengan nol layanan). Diuji oleh bagian 4 `scripts/test-config.sh`.

## Event loop

```c
for (;;) {
    struct timespec ts;
    struct timespec *pto = compute_poll_timeout(&ts);   /* timer housekeeping */
    int ret = ppoll(fds, nfds, pto, &orig);
    int perr = errno;                     /* simpan segera: errno mudah tertimpa */
    if (ret < 0 && perr != EINTR) { log(...); continue; }

    /* 1. sinyal — shutdown diprioritaskan */
    SIGTERM -> shutdown_all(RB_POWER_OFF, 0)
    SIGINT  -> shutdown_all(RB_AUTOBOOT,   0)
    SIGUSR1 -> shutdown_all(RB_POWER_OFF, 1)    /* force */
    SIGUSR2 -> shutdown_all(RB_AUTOBOOT,   1)   /* force */
    SIGCHLD -> reap_zombies()

    /* 2. fd siap dibaca: /run/initctl (perintah, diproses PER BARIS) dan
       /run/log.fifo (log layanan) */

    /* 3. selalu terakhir: housekeeping timeout once, lalu respawn_services()
       — juga terpanggil saat ppoll timeout */
    enforce_once_timeout();
    respawn_services();
}
```

`compute_poll_timeout()` memilih timeout ppoll:

- **100 ms** bila ada layanan yang menunggu jeda `respawn_delay` (termasuk
  backoff crash-loop) — respawn dievaluasi ulang 10× per detik;
- **1 detik** bila ada layanan `once` yang sedang berjalan, supaya
  `enforce_once_timeout()` tetap dijalankan walau ppoll akan selamanya
  blokir (tanpa sinyal/fd baru);
- **`NULL`** (blokir penuh) bila tidak ada housekeeping yang tertunda.

Poin penting:

- `ppoll` memakai `orig` hasil `sigemptyset()`, bukan mask warisan. Ini memastikan
  **semua** sinyal (termasuk `SIGTERM`) benar-benar di-unblock saat menunggu,
  tanpa tergantung mask yang diwarisi dari proses induk/kernel.
- Kalau tidak ada housekeeping yang tertunda, `ppoll` dipanggil dengan timeout
  `NULL` (tidur sampai ada sinyal/fd). Tidak ada busy-loop; saat ada timer
  respawn hanya terbangun 10× per detik, dan saat ada layanan `once` yang
  berjalan paling banyak 1× per detik (untuk timeout `once`).
- `errno` disimpan tepat setelah `ppoll` (`perr`) supaya cabang error tidak salah
  terpicu oleh `errno` yang berubah karena panggilan log.
- Perintah `/run/initctl` dibaca sekali lalu dipecah **per baris**
  (`strtok(cmd, "\n")`, spasi/`\r` di ujung dipangkas, baris kosong dilewati).
  Perintah penutup langsung memanggil `shutdown_all()` dan tidak pernah kembali ke
  loop, jadi pembacaan berhenti di situ; tetapi baris sebelum perintah penutup
  tidak lagi hilang seperti pada parser lama yang memotong buffer di newline
  pertama.

## Manajemen layanan

### Menjalankan (`spawn_service`)

1. Kalau `shutting_down` → **langsung `return`** (tanpa fork, tanpa jeda).
2. Kalau `now - last_start < RESPAWN_DELAY` (2 detik): set `need_respawn = 1`,
   catat "respawn ditunda" sekali, lalu `return` — **tanpa `sleep()`**; timer
   `ppoll` di loop utama yang akan memanggilnya lagi.
3. Siapkan pipe sinkronisasi searah (`int sync_pipe[2]`) sebelum `fork()` menggunakan
   `pipe2(sync_pipe, O_CLOEXEC)` (dengan fallback ke `pipe()` + `fcntl(FD_CLOEXEC)`).
   Bila pembuatan pipe gagal, ninit mencatat peringatan dan melanjutkan spawn
   langsung tanpa handshake sinkronisasi.
4. `fork()`; di proses anak:
   - Tutup ujung tulis pipe sinkronisasi (`sync_pipe[1]`).
   - `setsid()` untuk membentuk session baru.
   - **Kosongkan signal mask yang diwarisi dari PID 1** (`sigprocmask(SIG_SETMASK, &empty, NULL)`
     — tanpa ini layanan tidak pernah menerima `SIGTERM` dan mati lewat `SIGKILL`),
     reset semua handler ke `SIG_DFL` (termasuk `SIGPIPE`).
   - Pasang file descriptor standar: stdin ← `/dev/null`, stdout/stderr ← `/run/log.fifo`
     (buka tanpa `O_NONBLOCK` agar tidak memicu `EAGAIN`, fallback ke `/dev/console`).
   - **Handshake Sinkronisasi Pre-Exec**: Anak memblokir pembacaan pada `sync_pipe[0]`
     (`read(sync_pipe[0], &sync_byte, 1)`) menunggu konfirmasi bahwa parent telah
     selesai menyiapkan hierarki cgroup dan memasukkan PID anak ke `cgroup.procs`.
     Setelah menerima byte sinkronisasi atau mendeteksi EOF (pipe ditutup), anak menutup
     `sync_pipe[0]` dan mengeksekusi `execl("/bin/sh", "sh", "-c", cmd)`. Bila exec gagal, `_exit(127)`.
5. Di proses induk:
   - Tutup ujung baca pipe sinkronisasi (`sync_pipe[0]`).
   - Simpan `svc->pid = pid`, `svc->pgid = pid`, `svc->state = SVC_STATE_RUNNING`, reset `svc->spawn_tries = 0`.
   - Catat log `started <nama> (pid N)`.
   - Jalankan `setup_cgroup(svc->name, pid)`:
     - Buat direktori leaf `/sys/fs/cgroup/ninit/<nama>`.
     - Bersihkan proses orphan turunan lama via `cgroup_kill_service(svc->name)`.
     - Terapkan batasan resource yang dikonfigurasi (`memory.max`, `memory.swap.max=0`, `cpu.max`, `pids.max`).
     - Tuliskan PID ke leaf `cgroup.procs`.
     - **Kontrak Fail-Open Fallback**: Bila hierarki cgroup v2 tidak tersedia (mount cgroup gagal,
       direktori cgroup tidak dapat dibuat, atau penulisan `cgroup.procs` gagal), ninit mengaktifkan
       fallback fail-open:
       - Mencatat log eksplisit: `cgroup: fail-open aktif untuk '<nama>' (cgroup tidak tersedia)`.
       - Bila layanan mendefinisikan batas resource (`memory_max`, `cpu_max`, `pids_max`), mencatat log
         peringatan: `Warning: batas resource diabaikan pada layanan '<nama>' karena cgroup tidak tersedia`.
       - Layanan tetap dibiarkan berjalan tanpa pembatasan resource (*unconstrained*).
   - **Pelepasan Blokir Sinkronisasi**: Induk menuliskan byte sinyal `"1"` ke `sync_pipe[1]` lalu menutupnya,
     membuka blokir proses anak. Penulisan dan penutupan pipe ini dijamin selalu dipanggil setelah `setup_cgroup()`
     (termasuk pada cabang fail-open), menjamin eksekusi bebas deadlock (*deadlock-free*).
   - Induk mengabaikan `SIGPIPE` (`signal(SIGPIPE, SIG_IGN)` di `main()`) agar tidak mengalami crash jika proses
     anak mati sebelum penulisan sinyal sinkronisasi.

### Handshake pre-exec T1

Anak menunggu konfirmasi induk sebelum `execl()`, sehingga induk sempat
menyiapkan leaf cgroup dan memindahkan PID anak ke `cgroup.procs` **sebelum**
instruksi pertama layanan dijalankan:

```
parent                                   child
------                                   -----
pipe2(O_CLOEXEC) ---------------------->  sync_pipe[0/1]
fork()
                                         close(sync_pipe[1])
                                         setsid(); kosongkan signal mask
                                         stdin </dev/null; stdout/stderr >/run/log.fifo
                                         tutup fd kontrol PID 1 (T8B)
                                         read(sync_pipe[0]) --blokir--
setup_cgroup(name, pid)
  mkdir leaf; tulis limit; tulis cgroup.procs
write(sync_pipe[1], "1")  ------------->   (baca selesai)
close(sync_pipe[1])                      close(sync_pipe[0])
                                         execl("/bin/sh","sh","-c",cmd)
```

Baca yang gagal (`nr != 1` atau byte bukan `'1'`) membuat anak `_exit(127)`
(*fail-closed*), bukan melanjutkan eksekusi di cgroup yang salah. Induk
menjamin `write()`/penutupan pipe selalu dipanggil setelah `setup_cgroup()`
(termasuk pada jalur fail-open), sehingga anak tidak pernah deadlock.

Kegagalan `fork()`/`mount()`/cgroup hanya di-log; init tidak berhenti.

### Reaping zombie (`reap_zombies`)

Hanya mengubur anak yang mati:

```c
while ((pid = waitpid(-1, &status, WNOHANG)) > 0) { ... pid = 0; ... }
```

**`spawn_service()` tidak boleh dipanggil di dalam loop ini.** Bila layanan yang
di-respawn langsung mati lagi (mis. `/bin/sh` tanpa tty), setiap iterasi
menghasilkan zombie baru sehingga `waitpid()` tidak pernah selesai; loop utama
tidak pernah dieksekusi lagi dan sinyal shutdown tertahan selamanya. Karena itu
respawn dipisahkan ke `respawn_services()` yang dipanggil dari loop utama.

### Respawn (`respawn_services`)

Dipanggil di akhir tiap iterasi loop: untuk tiap layanan dengan `respawn = 1` dan
`pid == 0`, panggil `spawn_service()`. Guard `shutting_down` di dalamnya memastikan
tidak ada respawn setelah shutdown dimulai.

### Timeout `once` & backoff `respawn`

- **`ONCE_START_TIMEOUT` (default 30 detik, konfigurabel via `:timeout=`)**:
  `enforce_once_timeout()` dijalankan di akhir tiap iterasi loop. Default batas waktu
  layanan `once` adalah 30 detik (`ONCE_START_TIMEOUT`), atau ditentukan per-layanan
  lewat opsi `:timeout=<detik>`. Nilai `0` atau `none` menonaktifkan timeout.
  Layanan `once` yang berjalan melebihi batas waktunya dinyatakan `SVC_STATE_FAILED`,
  prosesnya dihentikan (`kill_service_group` SIGKILL), dan semua dependen transitif
  dibatalkan (`cancel_dependents()`). Housekeeping ini dijamin berjalan karena
  `compute_poll_timeout()` memasang timeout ppoll 1 detik selama ada layanan `once`
  dengan timeout aktif yang sedang berjalan.
  > **Peringatan**: menonaktifkan timeout (`:timeout=0` atau `none`) berisiko membuat
  > seluruh layanan dependen menggantung selamanya bila perintah layanan `once`
  > mengalami kebuntuan (*hang* / *deadlock*).
- **Backoff eksponensial + start-limit `respawn`**: saat layanan `respawn`
  mati kurang dari `RESPAWN_DELAY` (2 detik) setelah start, `crash_count`
  naik dan `respawn_delay` menjadi `min(BACKOFF_MAX=32, 2 << crash_count)`
  (4, 8, 16, 32, 32, …). Setelah `CRASH_LIMIT` (5) kegagalan berturut-turut,
  layanan dinyatakan `SVC_STATE_FAILED` dan respawn dihentikan.
  `deps_satisfied()` memperlakukan dependensi `respawn` yang berstatus
  `SVC_STATE_FAILED` sebagai kegagalan (`-1`), sehingga `spawn_eligible_services()`
  langsung membatalkan seluruh layanan yang bergantung padanya secara transitif.
  Hidup lebih dari `STABLE_RUNTIME` (10 detik) me-reset `crash_count` dan `respawn_delay`.

### Dependensi (`validate_dependencies` + `sort_services`)

`/etc/init.conf` boleh menyatakan `:requires=a,b`. Dua tahap dijalankan sebelum
layanan apa pun di-spawn:

1. `validate_dependencies()` — setiap nama dependensi harus benar-benar ada di
   daftar layanan. Nama tak dikenal dilaporkan
   `FATAL: Dependensi '<x>' untuk '<y>' tidak ditemukan` lalu init masuk rescue
   shell; lebih baik daripada menjalankan layanan tanpa prasyaratnya.
2. `sort_services()` — urut topologis dengan DFS **iteratif** (stack eksplisit,
   bukan rekursi) supaya prasyarat dijalankan lebih dulu. Siklus dilaporkan
   `FATAL: CYCLE DETECTED` dan init jatuh ke rescue shell (`/bin/sh`).

Detail yang penting untuk yang menyentuh fungsi ini:

- Setiap node ditandai `temp_visited[...] = 1` **sebelum** `stack[stack_top++]`,
  jadi satu layanan hanya masuk stack sekali. Versi lama menandai saat node
  di-*expand*: layanan yang masih "pending" bisa di-push berulang sampai
  `stack_top` melewati `MAX_SERVICES` dan menulis di luar array `stack[]`
  (terbukti stack-buffer-overflow dengan AddressSanitizer — lihat
  [build-and-test.md](build-and-test.md)).
- Setiap push dijaga `if (stack_top >= MAX_SERVICES)` →
  `FATAL: Stack overflow pada topological sort!` (jaring pengaman, bukan jalur
  normal; konfigurasi maksimum 64 layanan selalu muat).
- Karena dependensi diproses satu per satu dan node "abu-abu" selalu berada di
  jalur DFS yang sedang aktif, dependensi berbentuk berlian (dua layanan butuh
  satu layanan yang sama) tidak salah dianggap siklus.
- Progres baca tiap `deps_str` disimpan di `dep_off[]`; `next_dep()` membaca token
  tanpa memodifikasi string aslinya dan mengabaikan spasi di sekitar koma.

## Shutdown (`shutdown_all`)

| Langkah | Graceful | Force |
|---|---|---|
| Set `shutting_down = 1` | ✅ | ✅ |
| Kirim `SIGTERM` ke semua layanan | ✅ | — |
| Tunggu sampai 50 × 100 ms (maks 5 detik): `reap_zombies()` + `drain_log_fifo()` tiap iterasi | ✅ | — |
| `SIGKILL` ke sisa layanan | ✅ | langsung |
| Remount `/` read-only + `umount2(MNT_DETACH)` entri fstab yang dicatat | ✅ | ✅ |
| `sync()` → `reboot(cmd)` → `while(1) pause()` | ✅ | ✅ |

`cmd` adalah `RB_POWER_OFF` (SIGTERM/USR1) atau `RB_AUTOBOOT` (SIGINT/USR2).
Bila `reboot()` gagal (umum di container/sandbox), kegagalan di-log dan init tetap
berhenti di `pause()`.

## Cgroups v2

Status: **implementasi penuh** (bukan rencana). Penegakan batas `memory.max`,
`memory.swap.max=0`, `cpu.max`, dan `pids.max` dijaga oleh
`scripts/test-cgroup-limits.sh` (skenario 1, 4, 7, 9, 10). Cgroup v2 adalah
pembatasan resource, bukan sandbox isolasi proses — lihat
[SECURITY.md](../SECURITY.md).

- Mount dicek lebih dulu di `setup_pseudo_fs()` via
  `/sys/fs/cgroup/cgroup.controllers`; kalau belum ada, `cgroup2` di-mount ke
  `/sys/fs/cgroup`.
- `setup_cgroup(nama, pid)` membuat `/sys/fs/cgroup/ninit` dan
  `/sys/fs/cgroup/ninit/<nama>` (cgroup v2 tidak membuat parent otomatis), lalu
  menulis PID ke `cgroup.procs`.
- Saat namespace/container mati, isi `cgroup.procs` kembali kosong; direktori
  `ninit` bisa di-`rmdir` agar uji berikutnya bersih.
- Batasan resource cgroup v2 (`memory.max`, `memory.swap.max=0`, `cpu.max`, `pids.max`)
  diterapkan pada leaf node sebelum PID dimasukkan ke `cgroup.procs`.
- Pembersihan orphan (`cgroup.kill` + fallback scanning `cgroup.procs`) dijalankan
  saat respawn maupun saat layanan `once` exit sebelum penghapusan (`rmdir`) leaf cgroup.

### Kontrak Fallback Fail-Open Cgroup

Cgroup v2 merupakan lapisan isolasi dan pembatasan resource opsional. Ketiadaan hierarki cgroup v2 di sistem (misalnya pada kernel tanpa `CONFIG_CGROUPS`, lingkungan container/chroot tanpa hak akses mount cgroupfs, atau kegagalan filesystem sysfs) **tidak boleh menggagalkan proses booting PID 1 atau membatalkan eksekusi layanan**.

1. **Default Fail-Open**: Bila inisialisasi direktori base `/sys/fs/cgroup/ninit`, leaf cgroup `/sys/fs/cgroup/ninit/<nama>`, atau penulisan PID ke `cgroup.procs` gagal, layanan tetap diizinkan berjalan tanpa cgroup (*fail-open*). Sistem tidak panik, init tidak berhenti, dan status layanan tetap bertransisi ke `SVC_STATE_RUNNING` secara bebas batasan (*unconstrained*).
2. **Log Eksplisit Fail-Open**: ninit mencatat aktivasi fallback fail-open secara eksplisit dan transparan:
   ```
   cgroup: fail-open aktif untuk '<nama>' (cgroup tidak tersedia)
   ```
3. **Peringatan Batas Resource Tidak Ditegakkan**: Bila layanan mendefinisikan salah satu dari `:memory_max=`, `:cpu_max=`, atau `:pids_max=`, tetapi cgroup v2 tidak tersedia sehingga batas kernel tidak dapat ditegakkan, ninit mencatat log peringatan eksplisit:
   ```
   Warning: batas resource diabaikan pada layanan '<nama>' karena cgroup tidak tersedia
   ```
   Bila layanan tidak mendefinisikan batas resource apa pun (misal shell atau daemon standar), pesan peringatan ini tidak dicetak (hanya pesan aktivasi fail-open).
4. **Pelepasan Blokir Sinkronisasi Bebas Deadlock**: Parent menjamin penulisan sinyal unblock (`"1"`) dan penutupan write-end pipe sinkronisasi sesaat setelah `setup_cgroup()` selesai atau keluar lebih awal akibat kegagalan cgroup. Dengan demikian, proses anak yang sedang memblokir pada `read()` di tahap pre-exec terjamin segera melanjutkan eksekusi tanpa pernah mengalami kebuntuan (*deadlock*).
5. **Fallback Penghentian via Sinyal Grup Proses**: Bila cgroup tidak tersedia di sistem, mekanisme pembersihan berbasis `cgroup.kill` dilewati secara aman. Penghentian layanan pada graceful/force shutdown maupun cleanup lifecycle mengandalkan fallback pengiriman sinyal grup proses standar (`kill(-pgid, SIGTERM)` / `kill(-pgid, SIGKILL)` atau `kill(pid, ...)`), serta pembersihan zombie melalui loop `reap_zombies()` PID 1.

## Logging

| Tujuan | Isi |
|---|---|
| `/dev/kmsg` | `ninit: <pesan>` — masuk ring buffer kernel |
| stderr (console) | `[YYYY-mm-dd HH:MM:SS] ninit: <pesan>` |
| `/var/log/ninit.log` | format sama dengan console (dibuka setelah fstab) |
| `/run/log.fifo` | output layanan; di-drain `drain_log_fifo()` dari loop utama **dan** dari loop grace `shutdown_all()`, dicetak sebagai `[service] <baris>` |

`/run` di-mount `tmpfs`, jadi FIFO (`/run/initctl`, `/run/log.fifo`, mode `0600`)
selalu dibuat ulang tiap boot.
