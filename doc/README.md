# Dokumentasi ninit

`ninit` adalah init system minimal (PID 1) dalam **satu file C** tanpa dependensi
selain libc. Dibuat untuk eksperimen membangun distro/OS sendiri: membaca daftar
layanan, menjalankan dan menjaganya, memindahkan proses ke cgroup v2, memasang
filesystem dari `/etc/fstab`, dan mematikan sistem dengan rapi.

Ringkasan proyek, mulai cepat, dan contoh konfigurasi ada di
**[README utama di akar repository](../README.md)**; folder ini berisi dokumen
teknis yang lebih dalam, dengan indeks di bawah.

| Dokumen | Isi |
|---|---|
| [architecture.md](architecture.md) | cara kerja internal: urutan boot, event loop, sinyal, respawn, shutdown, cgroup, logging |
| [configuration.md](configuration.md) | format `/etc/init.conf`, `/etc/fstab`, tabel sinyal, `/run/initctl`, lokasi log |
| [build-and-test.md](build-and-test.md) | build statis, smoke test PID 1, CI, uji manual dengan `unshare`/`chroot`, troubleshooting |
| [../SECURITY.md](../SECURITY.md) | kebijakan keamanan dan cara melaporkan kerentanan |
| [../LICENSE](../LICENSE) | MIT License |

## Fitur saat ini

- **PID 1 + reaping** semua anak, termasuk proses yatim (orphan) yang diadopsi.
- **Konfigurasi layanan** `/etc/init.conf` dengan mode `respawn`/`once` dan
  dependensi `:requires=` (urut topologis DFS, deteksi siklus, dependensi hilang
  → rescue shell).
- **Respawn non-blocking**: jeda 2 detik dijalankan lewat timer `ppoll` 100 ms,
  bukan `sleep()`, sehingga init tetap responsif terhadap sinyal.
- **Shutdown bersih**: `SIGTERM`/`SIGINT` → hentikan layanan (grace 5 detik) →
  `sync()` → `reboot()`; varian force untuk mem-bypass grace.
- **Cgroups v2**: tiap layanan dipindahkan ke `/sys/fs/cgroup/ninit/<nama>`.
- **`/etc/fstab`**: memasang filesystem dengan flag *dan* opsi data
  (`size=`, `mode=`, `uid=`, …) diteruskan ke `mount()`.
- **Logging ganda**: `/dev/kmsg`, console (stderr), `/var/log/ninit.log`, plus
  jalur `/run/log.fifo` agar output layanan ikut tercatat dengan prefiks
  `[service]`.
- **IPC `/run/initctl`**: perintah `poweroff`, `reboot`, `force-poweroff`,
  `force-reboot`, dibaca per baris (satu penulisan boleh memuat beberapa perintah).
- **Biner statis** (`gcc -static`), 0 warning dengan `-Wall -Werror`.

## Struktur repository

```
README.md                ringkasan proyek (landing page GitHub)
ninit.c                  seluruh init system (satu file)
Makefile                 make / make test / make clean
scripts/smoke-test.sh    uji PID 1 otomatis di chroot + unshare
scripts/test-sigterm.sh uji SIGTERM sampai ke layanan (bukan SIGKILL)
scripts/test-config.sh  uji dependensi, rescue mode (+mask sinyal), initctl per baris
doc/                     dokumentasi ini
.github/workflows/ci.yml CI: build statis, cek statis, ketiga uji, -Werror
SECURITY.md              kebijakan keamanan
LICENSE                  MIT
```

## Mulai cepat

```bash
make          # hasilkan biner statis ./ninit
make test     # uji sebagai PID 1: smoke test + test SIGTERM + test konfigurasi
              # (butuh root/sudo)
```

Menjalankannya di sistem nyata berarti memasang biner ini sebagai `/sbin/init`
dan menyediakan `/etc/init.conf`. Untuk uji aman, pakai chroot + `unshare`
seperti di [build-and-test.md](build-and-test.md).

## Status

Rilis terakhir adalah **v1.0.0** (commit
`feat: v1.0.0 release - robust topo-sort, validation, and rescue mode`), dan
banner saat boot mencetak `=== ninit start (PID 1) v1.0.0 ===`.

Putaran reliabilitas terakhir menambahkan: urut topologis yang tidak bisa
melewati `MAX_SERVICES` (dulu *stack-buffer-overflow*), `validate_dependencies()`
yang mengirim init ke rescue shell bila ada `:requires=` menunjuk layanan tak
ada, dan pembacaan `/run/initctl` per baris. v1.0.0 menutup dua lubang terakhir:
rescue mode yang sebelumnya hanya di-log (config rusak kini benar-benar masuk
shell) dan rescue shell yang mewarisi signal mask PID 1 (Ctrl+C mati). Semuanya
dijaga `scripts/test-config.sh`.

## Batasan yang diketahui

- Semua perintah layanan dijalankan lewat `/bin/sh -c`, jadi `/bin/sh` harus ada
  di rootfs (biasanya busybox statis).
- `mount_fstab()` dipanggil sebelum `/var/log/ninit.log` dibuka, sehingga pesan
  fstab hanya muncul di console/`/dev/kmsg`, tidak di file log init.
- Opsi fstab non-flag hanya diteruskan apa adanya; `defaults` dibuang (kata kunci
  `mount(8)`, ditolak kernel bila dikirim sebagai data).
- Belum ada limit resource cgroup (hanya pemindahan PID), tidak ada `PIDFile`,
  `Restart=on-failure`, dependency berbasis event, atau mount namespace per layanan.
- Tidak ada pengerasan (seccomp, MAC, user berbeda per layanan): tiap layanan
  berjalan sebagai root, sama seperti init.
- Shutdown masih memakai jendela grace tetap 5 detik; layanan yang mengabaikan
  `SIGTERM` akan di-`SIGKILL` setelahnya.
- Pada sandbox/container tertentu, `reboot()` tidak kembali ke user-space (init
  berhenti di `pause()`); ini perilaku lingkungan, bukan bug init.

## Rencana berikutnya (belum dikerjakan)

Catatan arah pengembangan, bukan janji:

- Limit cgroup v2 (`memory.max`, `pids.max`, `cpu.weight`) per layanan.
- Timeout/kill policy dan mode `restart=on-failure` yang eksplisit.
- Dukungan mount namespace per layanan + `chroot` rootfs layanan.
- Parser konfigurasi bergaya inittab SysV (`id:runlevels:action:proses`) atau
  unit file sederhana, plus dependensi berbasis event (`after=`, `wants=`).
- `make install` untuk memasang ninit ke rootfs target sebagai `/sbin/init`.
