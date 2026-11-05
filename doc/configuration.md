# Konfigurasi ninit

## `/etc/init.conf`

Format per baris:

```
<nama>:<mode>:<perintah>[:requires=<nama1>,<nama2>,...]
```

| Bagian | Aturan |
|---|---|
| `<nama>` | Maks 127 karakter. Lebih dari itu entri **ditolak** (`Parse err: ... entri ditolak`), bukan dipotong. Tidak boleh memuat karakter `/` (karena nama dipakai sebagai path direktori cgroup). Dipakai sebagai nama log dan nama cgroup `/sys/fs/cgroup/ninit/<nama>`. |
| `<mode>` | `respawn` (dijalankan ulang otomatis) atau `once` (sekali saja). Mode lain diperingatkan dan diperlakukan sebagai `once`. |
| `<perintah>` | Maks 511 karakter. Lebih dari itu entri **ditolak**, bukan dipotong. Dijalankan lewat `/bin/sh -c`. Boleh memuat `:` (dipisah dari `:requires=` dari kanan). |
| `:requires=` | Opsional. Daftar nama layanan (dipisah koma) yang harus diurutkan lebih dulu. Maks 255 karakter. Lebih dari itu entri **ditolak**, bukan dipotong. Layanan `once` harus selesai (`exit 0`) sebelum layanan yang membutuhkannya dijalankan. Layanan `respawn` cukup sudah aktif (`pid > 0`). |
 
Aturan umum:
 
- Baris komentar dimulai `#` (spasi/tab di depan diizinkan) dan baris kosong diabaikan.
- Baris lebih dari 1023 karakter ditolak utuh dan dicatat (`Parse err: baris melebihi MAX_LINE ...`); baris berikutnya tetap diproses. Aturan yang sama berlaku untuk baris `/etc/fstab`.
- Baris tanpa `:` pertama/kedua dilaporkan `Parse err: ...` lalu dilewati.
- File config yang tidak bisa dibuka (tidak ada/tak terbaca) →
  `Config gagal dibaca/di-parse!` + rescue shell; boot tidak dilanjutkan dengan
  nol layanan.
- Maksimum **64 layanan** (`MAX_SERVICES`); layanan ke-65 dan seterusnya dilaporkan dengan peringatan dan diabaikan.
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

Sikap ninit terhadap kolom `options` — semua token diproses **kiri ke
kanan** seperti `mount(8)`: token belakangan mengalahkan token sebelumnya.

| Opsi | Perlakuan |
|---|---|
| `ro`, `noexec`, `nosuid`, `nodev`, `sync`, `dirsync`, `remount` | flag `MS_RDONLY` / `MS_NOEXEC` / `MS_NOSUID` / `MS_NODEV` / `MS_SYNCHRONOUS` / `MS_DIRSYNC` / `MS_REMOUNT` |
| `noatime`, `relatime`, `strictatime` | flag mode atime yang bersangkutan; ketiganya saling meniadakan (yang terakhir menang) |
| `nodiratime`, `lazytime` | flag `MS_NODIRATIME` / `MS_LAZYTIME` |
| `rw`, `async`, `atime`, `diratime`, `exec`, `suid`, `dev` | token peniada: membersihkan bit lawannya (mis. `ro,rw` berakhir `rw`; `user,exec` berakhir tetap bisa dieksekusi) |
| `user`, `users` | menerapkan implikasi `mount(8)`: `noexec,nosuid,nodev` (bisa dibatalkan token `exec`/`suid`/`dev` sesudahnya) |
| `owner`, `group` | menerapkan implikasi `mount(8)`: `nosuid,nodev` |
| `defaults` | dibuang seluruhnya (kata kunci `mount(8)`; bila dikirim ke kernel ditolak `EINVAL`) |
| `auto`, `nouser`, `_netdev`, `nofail`, `x-*`, `comment=*` | opsi khusus userspace: dicatat sebagai diabaikan, tidak diteruskan ke kernel |
| `noauto` | entri dilewati seluruhnya (seperti `mount -a`); mountpoint **tidak** dibuat |
| `bind`, `rbind` (termasuk kombinasi `remount,bind`) | **tidak didukung**: entri dilewati dengan catatan eksplisit; mountpoint **tidak** dibuat — lihat *Batasan yang diketahui* |
| opsi lain (`size=`, `uid=`, `mode=`, `compress=`, …) | **diteruskan sebagai argumen ke-5 `mount()`** (parameter `data`) |

Token flag tidak pernah ikut diteruskan sebagai `data`: parser opsi
filesystem yang ketat (ext4, tmpfs) menolak opsi data tak dikenal dengan
`EINVAL`.

Mountpoint:

- Escape oktal gaya `getmntent(3)`/`mount(8)` pada kolom *device* dan
  *mountpoint* **didekode** sebelum pemrosesan lain: `\040` spasi, `\011`
  tab, `\012` newline, `\134` backslash, dan `\ooo` oktal lain. Path
  hasil dekode-lah yang divalidasi, dibuat, dan di-mount — jadi
  `\056\056` yang terdekode menjadi `..` tetap ditolak seperti `..`
  harfiah. (Kolom *options* tidak didekode — lihat *Batasan yang
  diketahui*.)
- Mountpoint yang **sudah berhasil di-mount** oleh entri sebelumnya
  dalam lintasan yang sama tidak di-mount ulang: entri duplikat
  dilewati dan dicatat (`mountpoint duplikat`), supaya opsi entri
  pertama (mis. `nosuid`) tidak tertutupi diam-diam oleh tumpukan
  mount entri berikutnya. Perbandingan mengabaikan slash di ujung
  (`/mnt/x/` sama dengan `/mnt/x`). Hanya mount yang berhasil yang
  dicatat, jadi kegagalan entri pertama tidak menghalangi entri
  berikutnya untuk mountpoint yang sama.
- Dibuat **rekursif** (seperti `mkdir -p`) dengan mode `0755` untuk tiap
  direktori yang baru dibuat; mode dipasang eksplisit sehingga tidak
  bergantung pada umask warisan PID 1.
- Mountpoint harus path absolut. Komponen yang sudah ada harus direktori:
  symlink diikuti — symlink ke direktori diterima, sedangkan komponen
  berupa file biasa, symlink ke file, atau symlink menggantung (targetnya
  tidak ada) ditolak dengan catatan jelas dan entri itu dilewati (entri
  lain tetap diproses).
- Komponen `.` dan `..` ditolak: fstab tidak dinormalisasi diam-diam ke
  path lain.
- Entri yang dilewati (`noauto`, `bind`) tidak dibuatkan direktori.
- Bila `mount()` gagal setelah direktori dibuat, direktori kosongnya
  tertinggal di rootfs.

- Komentar `#` dan baris kosong diabaikan; baris dengan kolom kurang dari tiga
  dilaporkan `fstab: baris tidak lengkap`.
- Hasil tiap baris dicatat: `fstab: mount <dev> -> <mnt> (<fstype>) [data: <opsi>] ok|gagal: <errno>`.
- Path default `/etc/fstab`, dapat diubah saat build untuk pengujian:
  `make CFLAGS="-static -O2 -Wall -DFSTAB_PATH=\"/path/uji/fstab\""`.

### Batasan yang diketahui

- **Bind mount tidak didukung.** Untuk entri bind, kolom pertama fstab
  bermakna path sumber, sedangkan ninit memperlakukan kolom pertama
  sebagai device/label filesystem; mendukung bind berarti mengubah
  semantik kolom itu dan menangani kasus sumber file vs direktori.
  Daripada gagal diam-diam, entri `bind`/`rbind` ditolak eksplisit di
  log. Kebutuhan boot dasar (`/proc`, `/sys`, `/dev`, `/run`, `/tmp`)
  semuanya mount bertipe dan tidak membutuhkan bind.
- **Escape oktal di kolom *options* tidak didekode.** Token opsi
  dipisah koma, dan koma hasil dekode (`\054`) akan mengubah makna
  pemisahan itu; nilai opsi fstab nyata praktis tidak pernah memuat
  karakter yang perlu di-escape. Escape pada *device* dan *mountpoint*
  (kasus nyata: path berisi spasi) didukung penuh.
- `/etc/fstab` dan `/etc/init.conf` diasumsikan milik root dan tepercaya;
  ninit tidak mempertahankan diri dari file konfigurasi yang sudah bisa
  ditulis penyerang (penyerang itu sudah setara root).

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
