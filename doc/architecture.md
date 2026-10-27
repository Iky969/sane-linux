# Arsitektur ninit

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
   ->  pasang handler sigaction (SIGCHLD/SIGTERM/SIGINT/SIGUSR1/SIGUSR2)
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
3. `execl("/bin/sh", "sh", NULL)` menggantikan PID 1; bila gagal, `_exit(1)`.

Helper ini tidak pernah kembali, jadi tidak ada jalur boot yang berlanjut dengan
state setengah jadi (dulu `parse_config()` gagal hanya di-log dan boot lanjut
dengan nol layanan). Diuji oleh bagian 4 `scripts/test-config.sh`.

## Event loop

```c
for (;;) {
    struct timespec ts = { 0, 100 * 1000 * 1000 };
    struct timespec *pto = respawn_pending() ? &ts : NULL;   /* timer hanya bila perlu */
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

    /* 3. selalu terakhir: respawn_services() — juga terpanggil saat ppoll timeout */
    respawn_services();
}
```

Poin penting:

- `ppoll` memakai `orig` hasil `sigemptyset()`, bukan mask warisan. Ini memastikan
  **semua** sinyal (termasuk `SIGTERM`) benar-benar di-unblock saat menunggu,
  tanpa tergantung mask yang diwarisi dari proses induk/kernel.
- Kalau tidak ada respawn yang tertunda, `ppoll` dipanggil dengan timeout `NULL`
  (tidur sampai ada sinyal/fd). Tidak ada busy-loop, dan saat ada timer hanya
  terbangun 10× per detik.
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
3. `fork()`; di anak: `setsid()`, **kosongkan signal mask yang diwarisi dari
   PID 1** (`sigprocmask(SIG_SETMASK, &empty, NULL)` — tanpa ini layanan tidak
   pernah menerima `SIGTERM` dan mati lewat `SIGKILL`), reset semua handler ke
   `SIG_DFL`, stdin ← `/dev/null`, stdout/stderr ← `/run/log.fifo`
   (`O_NONBLOCK`, fallback `/dev/console`), lalu `execl("/bin/sh", "sh", "-c", cmd)`.
4. Di induk: simpan pid, log `started <nama> (pid N)`, pindahkan ke cgroup v2.

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
| `sync()` → `reboot(cmd)` → `while(1) pause()` | ✅ | ✅ |

`cmd` adalah `RB_POWER_OFF` (SIGTERM/USR1) atau `RB_AUTOBOOT` (SIGINT/USR2).
Bila `reboot()` gagal (umum di container/sandbox), kegagalan di-log dan init tetap
berhenti di `pause()`.

## Cgroups v2

- Mount dicek lebih dulu di `setup_pseudo_fs()` via
  `/sys/fs/cgroup/cgroup.controllers`; kalau belum ada, `cgroup2` di-mount ke
  `/sys/fs/cgroup`.
- `setup_cgroup(nama, pid)` membuat `/sys/fs/cgroup/ninit` dan
  `/sys/fs/cgroup/ninit/<nama>` (cgroup v2 tidak membuat parent otomatis), lalu
  menulis PID ke `cgroup.procs`.
- Saat namespace/container mati, isi `cgroup.procs` kembali kosong; direktori
  `ninit` bisa di-`rmdir` agar uji berikutnya bersih.
- Belum ada pengaturan limit (hanya pemindahan).

## Logging

| Tujuan | Isi |
|---|---|
| `/dev/kmsg` | `ninit: <pesan>` — masuk ring buffer kernel |
| stderr (console) | `[YYYY-mm-dd HH:MM:SS] ninit: <pesan>` |
| `/var/log/ninit.log` | format sama dengan console (dibuka setelah fstab) |
| `/run/log.fifo` | output layanan; di-drain `drain_log_fifo()` dari loop utama **dan** dari loop grace `shutdown_all()`, dicetak sebagai `[service] <baris>` |

`/run` di-mount `tmpfs`, jadi FIFO (`/run/initctl`, `/run/log.fifo`, mode `0600`)
selalu dibuat ulang tiap boot.
