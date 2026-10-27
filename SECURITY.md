# Kebijakan Keamanan

`ninit` adalah **init system (PID 1) eksperimental** untuk eksperimen build
distro/OS sendiri. Ia berjalan dengan hak penuh root, jadi bug di sini bisa
berakibat fatal pada sistem yang memakainya. Dokumen ini menjelaskan cara
melaporkan masalah keamanan dan apa saja yang termasuk/ tidak termasuk cakupan.

## Versi yang didukung

| Versi | Didukung |
|---|---|
| `main` (rilis terbaru: **v1.0.0**) | ✅ |
| Commit/tag lama | ❌ (silakan uji ulang di `main` dulu) |

v1.0.0 adalah rilis pertama yang diberi nomor versi. Perbaikan keamanan hanya
diterapkan pada `main`.

## Melaporkan kerentanan

**Jangan** buka issue publik untuk masalah keamanan. Gunakan salah satu jalur privat:

1. **GitHub Private Vulnerability Reporting** (disarankan):
   tab **Security → Report a vulnerability** di
   <https://github.com/Iky969/build-distros/security/advisories/new>.
2. **Email:** `ryuzarza@gmail.com` dengan subjek `[SECURITY] ninit: <ringkas>`.

Sertakan bila ada:

- versi/commit yang diuji (`git rev-parse HEAD`) dan cara build (`make` + versi gcc),
- lingkungan: distro, kernel (`uname -a`), apakah diuji sebagai PID 1 asli atau
  di dalam `unshare`/`chroot`/container,
- isi `/etc/init.conf` dan/atau `/etc/fstab` minimal yang memicu masalah,
- langkah reproduksi + bukti (log, `readelf`, `strace`, core dump),
- dampak yang mungkin (DoS boot, eksekusi perintah sebagai root, kebocoran mount, dll).

Ini proyek hobi tanpa SLA; saya berusaha membalas dalam beberapa hari dan akan
mencantumkan kredit pelapor di advisory bila diinginkan.

## Cakupan

**Termasuk cakupan** (bug yang ingin saya ketahui):

- Parsing `/etc/init.conf` (mode, `:requires=`, batas panjang) dan `/etc/fstab`
  (opsi/data yang diteruskan ke `mount()`): salah parse, buffer overflow,
  pembacaan di luar batas, opsi yang naik menjadi flag `mount()` tak terduga.
- Pemrosesan sinyal & event loop: race, sinyal hilang, deadlock, respawn tak
  terkendali, sistem yang tak bisa dimatikan.
- Manajemen proses: kebocoran pid/zombie, `execl` dengan argumen tak terduga.
- Jalur `/run/initctl` dan `/run/log.fifo`: pembacaan yang memblokir init,
  akses oleh non-root, kebocoran isi memori.
- Penulisan cgroup (`/sys/fs/cgroup/ninit/<nama>`): path traversal lewat nama
  layanan, salah target cgroup.

**Di luar cakupan:**

- Kernel, busybox, glibc/musl, atau bug sistem operasi induk.
- Pelarian dari sandbox/container/namespace, akses fisik, cold-boot attack.
- Konfigurasi yang memang ditulis root: siapa pun yang bisa menulis
  `/etc/init.conf` atau `/etc/fstab` sudah punya kendali penuh atas sistem.
- Masalah keamanan operasional, mis. `/bin/sh` di rootfs yang tidak dipercaya,
  sistem tidak di-`chmod`, kata sandi root lemah.
- Fitur pengerasan yang memang belum ada (seccomp, MAC/SELinux, user namespace
  separation, verifikasi tanda tangan service). Ini keterbatasan yang diketahui,
  bukan kerentanan — silakan usulkan sebagai fitur di issue biasa.
- DoS oleh layanan yang ditulis root, mis. layanan yang sengaja spam respawn.

## Model ancaman & catatan operasional

- `ninit` berjalan sebagai PID 1 dengan UID 0 dan **tanpa** pemisahan hak.
  Setiap perintah di `/etc/init.conf` dijalankan sebagai `root` via
  `/bin/sh -c` — konfigurasi init diperlakukan sebagai *trusted input*.
- `/run` di-mount sebagai `tmpfs` dan FIFO dibuat dengan mode `0600` milik root;
  hanya root yang bisa mengirim perintah ke `/run/initctl`.
- Output layanan dibaca dari `/run/log.fifo` dengan mode non-blocking, sehingga
  layanan tidak bisa memblokir init lewat FD penuh (tetap ada batas buffer
  kernel — laporan bila hal ini bisa menggantungkan sistem).
- `/dev/kmsg` ditulis oleh init; pada sistem nyata ini berarti log boot masuk ke
  kernel ring buffer dan bisa terekam di journal/dmesg.
- Sebelum dipakai di mesin penting: uji dulu di VM/container, siapkan akses serial
  atau jalur pemulihan, dan jangan menaruh ninit sebagai `/sbin/init` pada mesin
  produksi.
