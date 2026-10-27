# ninit — init system minimal (PID 1) dalam satu file C

`ninit` adalah init system kecil tanpa dependensi selain libc, dibuat untuk
eksperimen membangun distro/OS sendiri: membaca daftar layanan, menjalankan dan
menjaganya, memindahkan proses ke cgroup v2, memasang filesystem dari
`/etc/fstab`, lalu mematikan sistem dengan rapi.

Satu file sumber ([`ninit.c`](ninit.c), ~600 baris), biner statis, nol warning
dengan `-Wall -Werror`. Bonus: event loop-nya berbasis `ppoll`, jadi init tetap
responsif terhadap sinyal bahkan saat layanan respawn sangat cepat.

[![CI](https://github.com/Iky969/build-distros/actions/workflows/ci.yml/badge.svg)](https://github.com/Iky969/build-distros/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Fitur

- **PID 1 + reaping** semua anak, termasuk proses yatim (orphan) yang diadopsi.
- **Konfigurasi layanan** `/etc/init.conf` dengan mode `respawn`/`once` dan
  dependensi `:requires=` (urut topologis, deteksi siklus → rescue shell).
- **Respawn non-blocking**: jeda 2 detik dijalankan lewat timer `ppoll` 100 ms,
  bukan `sleep()`, sehingga init tidak pernah buta terhadap sinyal.
- **Shutdown bersih**: `SIGTERM`/`SIGINT` → hentikan layanan (grace 5 detik) →
  `sync()` → `reboot()`; ada varian force untuk mem-bypass grace.
- **Cgroups v2**: tiap layanan dipindahkan ke `/sys/fs/cgroup/ninit/<nama>`.
- **`/etc/fstab`**: memasang filesystem dengan flag *dan* opsi data (`size=`,
  `mode=`, `uid=`, …) diteruskan ke `mount()`; `defaults` dibuang seperti `mount(8)`.
- **Logging ganda**: `/dev/kmsg`, console, `/var/log/ninit.log`, plus jalur
  `/run/log.fifo` agar output layanan ikut tercatat dengan prefiks `[service]`.
- **IPC `/run/initctl`**: perintah `poweroff`, `reboot`, `force-poweroff`,
  `force-reboot`.
- **Biner statis** (`gcc -static`): cukup libc, tanpa library tambahan.

## Mulai cepat

Butuh `build-essential` dan (untuk uji) `busybox-static`:

```bash
sudo apt-get install build-essential busybox-static

make          # hasilkan biner statis ./ninit
make test     # uji sebagai PID 1 di chroot + unshare (butuh root/sudo)
make clean
```

`make test` menjalankan uji otomatis penuh: menyiapkan rootfs sementara dengan
busybox sebagai `/bin/sh`, menjalankan ninit sebagai PID 1 di PID + mount
namespace baru, menunggu `main loop siap`, mengirim `SIGTERM`, lalu memeriksa
banner, event loop, layanan, `graceful shutdown`, ketiadaan respawn setelah
shutdown, dan latensi shutdown (< 2000 ms). Untuk contoh output dan penjelasan
tiap pemeriksaan, lihat [doc/build-and-test.md](doc/build-and-test.md).

### Uji manual (chroot)

```bash
mkdir -p /tmp/myrootfs/{proc,sys,dev,run,tmp,etc,var/log,bin}
cp ninit /tmp/myrootfs/
cp /bin/busybox /tmp/myrootfs/bin/sh
printf 'shell:respawn:/bin/sh\n' > /tmp/myrootfs/etc/init.conf

sudo timeout -k 5 8 unshare --pid --fork --kill-child=SIGKILL \
     --mount --propagation private \
     sh -c 'mount -t proc proc /tmp/myrootfs/proc && exec chroot /tmp/myrootfs /ninit'
```

Varian `--mount --propagation private` + `mount -t proc` manual dipakai karena
`unshare --mount-proc=<dir>` ditolak dengan `EINVAL` di sebagian kernel.

## Konfigurasi

`/etc/init.conf` — satu layanan per baris, `nama:mode:perintah[:requires=a,b]`:

```
# layanan wajib: jalankan sekali, jangan respawn
logd:once:/bin/sh -c 'exec >/var/log/logd.log 2>&1; ...'

# jaringan: respawn terus, dan jalan setelah logd siap
net:respawn:/sbin/dhcpcd -B eth0:requires=logd

# shell darurat
tty1:respawn:/bin/sh
```

`/etc/fstab` — kolom `device mountpoint type options` (`dump`/`pass` opsional,
komentar `#` diabaikan):

```
proc     /proc  proc   rw,nosuid,nodev,noexec
tmpfs    /run   tmpfs  rw,nosuid,nodev,mode=0755,size=16m
tmpfs    /tmp   tmpfs  rw,nosuid,nodev,mode=1777,size=64m
```

Detail lengkap (grammar, tabel opsi, tabel sinyal, batas 64 layanan) ada di
[doc/configuration.md](doc/configuration.md).

## Struktur repository

```
ninit.c                  seluruh init system (satu file)
Makefile                 make / make test / make clean
scripts/smoke-test.sh    uji PID 1 otomatis di chroot + unshare
doc/                     dokumentasi teknis (lihat di bawah)
.github/workflows/ci.yml CI: build statis, cek statis, smoke test, -Werror
SECURITY.md              kebijakan keamanan & cara melaporkan kerentanan
LICENSE                  MIT
```

## Dokumentasi

| Dokumen | Isi |
|---|---|
| [doc/architecture.md](doc/architecture.md) | urutan boot, event loop, sinyal, respawn, shutdown, cgroup, logging |
| [doc/configuration.md](doc/configuration.md) | format `/etc/init.conf`, `/etc/fstab`, `/run/initctl`, lokasi log |
| [doc/build-and-test.md](doc/build-and-test.md) | build statis, smoke test, CI, uji manual, troubleshooting |
| [doc/README.md](doc/README.md) | indeks dokumentasi + status & roadmap |
| [SECURITY.md](SECURITY.md) | model ancaman dan cara melaporkan masalah keamanan |

## Status

Seri terakhir dilabeli **v10**. Ini proyek eksperimental untuk belajar cara kerja
init di level OS — belum siap dipakai di mesin produksi. Batasan yang diketahui:
semua layanan berjalan sebagai root (belum ada seccomp/user per layanan), belum
ada limit resource cgroup (hanya pemindahan PID), dan ini bukan pengganti
systemd. Uji selalu di VM/container, dan siapkan jalur pemulihan lebih dulu.

## Lisensi

[MIT](LICENSE) © 2026 Iky969. Masalah keamanan: jangan buka issue publik —
ikuti [SECURITY.md](SECURITY.md).
