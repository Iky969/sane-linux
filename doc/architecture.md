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
   ->  parse_config(argv[1] atau /etc/init.conf)
   ->  sort_services()              urut topologis; siklus => rescue shell /bin/sh
   ->  setup_initctl() / run/initctl, setup_log_fifo() /run/log.fifo
   ->  spawn_service() untuk semua layanan
   ->  log "main loop siap"  ->  for (;;) event loop
```

Catatan urutan: `mount_fstab()` sengaja dipanggil **sebelum** file log dibuka,
jadi pesan fstab hanya terlihat di console dan `/dev/kmsg`.

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

    /* 2. fd siap dibaca: /run/initctl (perintah) dan /run/log.fifo (log layanan) */

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

### Dependensi (`sort_services`)

`/etc/init.conf` boleh menyatakan `:requires=a,b`. `sort_services()` melakukan
urut topologis (DFS iteratif) supaya prasyarat dijalankan lebih dulu; siklus
dilaporkan `FATAL: CYCLE DETECTED` dan init jatuh ke rescue shell (`/bin/sh`).

## Shutdown (`shutdown_all`)

| Langkah | Graceful | Force |
|---|---|---|
| Set `shutting_down = 1` | ✅ | ✅ |
| Kirim `SIGTERM` ke semua layanan | ✅ | — |
| Tunggu sampai 50 × 100 ms (maks 5 detik), `reap_zombies()` tiap iterasi | ✅ | — |
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
| `/run/log.fifo` | output layanan; dibaca loop utama dan dicetak sebagai `[service] <baris>` |

`/run` di-mount `tmpfs`, jadi FIFO (`/run/initctl`, `/run/log.fifo`, mode `0600`)
selalu dibuat ulang tiap boot.
