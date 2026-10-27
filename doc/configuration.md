# Konfigurasi ninit

## `/etc/init.conf`

Format per baris:

```
<nama>:<mode>:<perintah>[:requires=<nama1>,<nama2>,...]
```

| Bagian | Aturan |
|---|---|
| `<nama>` | Maks 127 karakter (dipotong otomatis). Dipakai sebagai nama log dan nama cgroup `/sys/fs/cgroup/ninit/<nama>`. |
| `<mode>` | `respawn` (dijalankan ulang otomatis) atau `once` (sekali saja). Mode lain diperingatkan dan diperlakukan sebagai `once`. |
| `<perintah>` | Maks 511 karakter, dijalankan lewat `/bin/sh -c`. Boleh memuat `:` (dipisah dari `:requires=` dari kanan). |
| `:requires=` | Opsional. Daftar nama layanan (dipisah koma) yang harus diurutkan lebih dulu. Maks 255 karakter. |

Aturan umum:

- Baris komentar dimulai `#` (spasi/tab di depan diizinkan) dan baris kosong diabaikan.
- Baris tanpa `:` pertama/kedua dilaporkan `Parse err: ...` lalu dilewati.
- File config yang tidak bisa dibuka (tidak ada/tak terbaca) →
  `Config gagal dibaca/di-parse!` + rescue shell; boot tidak dilanjutkan dengan
  nol layanan.
- Maksimum **64 layanan** (`MAX_SERVICES`); baris selebihnya tidak dibaca.
- Siklus dependensi → `FATAL: CYCLE DETECTED`, init masuk rescue shell.
- Nama dependensi yang tidak ada di daftar layanan →
  `FATAL: Dependensi '<dep>' untuk '<layanan>' tidak ditemukan`, init masuk
  rescue shell (lebih baik daripada boot setengah jalan tanpa prasyaratnya).
  Pemeriksaan ini (`validate_dependencies()`) berjalan setelah parsing, sebelum
  urut topologis. Spasi di sekitar koma diizinkan (`:requires=a, b`).
- Path konfigurasi bisa diganti sebagai argumen pertama init
  (`/sbin/init /path/init.conf`); default `/etc/init.conf`.

Contoh:

```
# /etc/init.conf
shell:respawn:/bin/sh
logger:once:/bin/sh -c 'echo boot ok > /dev/console'
net:once:/bin/sh -c 'ip link set lo up':requires=logger
web:respawn:/bin/httpd -p 8080:requires=net,logger
```

## `/etc/fstab`

Dipasang sekali saat boot, tepat setelah filesystem pseudo (`proc`, `sysfs`,
`devtmpfs`, `tmpfs`) dipasang. Format lima/six kolom standar:

```
<device> <mountpoint> <fstype> <options> [dump] [pass]
```

Sikap ninit terhadap kolom `options`:

| Opsi | Perlakuan |
|---|---|
| `ro` | flag `MS_RDONLY` |
| `noexec`, `nosuid`, `nodev` | flag `MS_NOEXEC` / `MS_NOSUID` / `MS_NODEV` |
| `sync`, `dirsync`, `remount`, `bind` | flag `MS_SYNCHRONOUS` / `MS_DIRSYNC` / `MS_REMOUNT` / `MS_BIND` |
| `defaults` | dibuang seluruhnya (kata kunci `mount(8)`; bila dikirim ke kernel ditolak `EINVAL`) |
| `rw`, `relatime` | diabaikan (perilaku default kernel) |
| opsi lain (`size=`, `uid=`, `mode=`, `compress=`, …) | **diteruskan sebagai argumen ke-5 `mount()`** (parameter `data`) |

- Komentar `#` dan baris kosong diabaikan; baris dengan kolom kurang dari tiga
  dilaporkan `fstab: baris tidak lengkap`.
- Mountpoint dibuat otomatis dengan mode `0755`.
- Hasil tiap baris dicatat: `fstab: mount <dev> -> <mnt> (<fstype>) [data: <opsi>] ok|gagal: <errno>`.
- Path default `/etc/fstab`, dapat diubah saat build untuk pengujian:
  `make CFLAGS="-static -O2 -Wall -DFSTAB_PATH=\"/path/uji/fstab\""`.

Contoh:

```
# minimal, aman untuk chroot uji
proc   /proc   proc    defaults                0 0
tmpfs  /tmp    tmpfs   size=64m,mode=1777       0 0
tmpfs  /data   tmpfs   defaults,size=32m,uid=1000  0 0
```

## Sinyal

| Sinyal | Aksi |
|---|---|
| `SIGTERM` | graceful shutdown → `RB_POWER_OFF` (matikan) |
| `SIGINT` | graceful shutdown → `RB_AUTOBOOT` (reboot) |
| `SIGUSR1` | force shutdown → `RB_POWER_OFF` (langsung `SIGKILL` ke semua layanan) |
| `SIGUSR2` | force shutdown → `RB_AUTOBOOT` |
| `SIGCHLD` | reaping zombie (internal) |

Contoh dari shell atau skrip:

```bash
kill -TERM 1      # matikan dengan rapi
kill -USR2 1      # reboot paksa
```

## `/run/initctl`

FIFO (mode `0600`) berisi perintah berbasis baris:

| Perintah | Efek |
|---|---|
| `poweroff` | graceful shutdown, `RB_POWER_OFF` |
| `reboot` | graceful shutdown, `RB_AUTOBOOT` |
| `force-poweroff` | force shutdown (`SIGKILL` segera) |
| `force-reboot` | force reboot (`SIGKILL` segera) |

```bash
echo reboot > /run/initctl
```

Perintah dibaca **per baris**, jadi satu penulisan boleh memuat beberapa perintah:

```bash
printf 'poweroff\nreboot\n' > /run/initctl   # hanya baris pertama yang jalan
```

- Baris kosong dan spasi/`\r` di ujung diabaikan; perintah tak dikenal dicatat di log.
- Perintah penutup (`poweroff`, `reboot`, `force-*`) tidak pernah kembali ke event
  loop, jadi perintah penutup pertama yang sudah diproses langsung mengakhiri
  pembacaan. Perintah/baris di depannya selalu tetap dicatat dan diproses —
  perilaku lama yang memotong buffer di newline pertama tidak dipakai lagi.
- FIFO dibuat ulang tiap boot (mode `0600`, hanya root).

## Hostname

Bila `/etc/hostname` ada, baris pertamanya dipakai sebagai `sethostname()`.

## Lokasi yang dipakai ninit

| Path | Peran |
|---|---|
| `/etc/init.conf` | daftar layanan (default; dapat diganti lewat `argv[1]`) |
| `/etc/fstab` | pemasangan filesystem tambahan |
| `/etc/hostname` | nama host |
| `/proc`, `/sys`, `/dev`, `/run`, `/tmp` | filesystem pseudo yang dipasang otomatis |
| `/sys/fs/cgroup` | cgroup v2 (di-mount bila belum ada) |
| `/sys/fs/cgroup/ninit/<nama>` | cgroup per layanan |
| `/var/log/ninit.log` | file log init |
| `/run/initctl`, `/run/log.fifo` | FIFO perintah dan log layanan |
| `/bin/sh` | interpreter untuk setiap `<perintah>` layanan |
| `/dev/kmsg`, `/dev/console` | tujuan log |
