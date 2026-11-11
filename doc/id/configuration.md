# Konfigurasi ninit

*[Bahasa Indonesia](configuration.md) | [English](../configuration.md)*

## `/etc/init.conf`

Format per baris:

```
<nama>:<mode>:<perintah>[:requires=<nama1>,<nama2>,...][:memory_max=<nilai>][:cpu_max=<nilai>][:pids_max=<nilai>][:timeout=<detik>]
```

| Bagian | Aturan |
|---|---|
| `<nama>` | Maks 127 karakter. Lebih dari itu entri **ditolak** (`Parse err: ... entri ditolak`), bukan dipotong. Tidak boleh memuat karakter `/` (karena nama dipakai sebagai path direktori cgroup). Dipakai sebagai nama log dan nama cgroup `/sys/fs/cgroup/ninit/<nama>`. |
| `<mode>` | `respawn` (dijalankan ulang otomatis) atau `once` (sekali saja). Mode lain diperingatkan dan diperlakukan sebagai `once`. |
| `<perintah>` | Maks 511 karakter. Lebih dari itu entri **ditolak**, bukan dipotong. Dijalankan lewat `/bin/sh -c`. Boleh memuat `:` (dipisah dari tag opsi paling awal). |
| `:requires=` | Opsional. Daftar nama layanan (dipisah koma) yang harus diurutkan lebih dulu. Maks 255 karakter. Lebih dari itu entri **ditolak**, bukan dipotong. Layanan `once` harus selesai (`exit 0`) sebelum layanan yang membutuhkannya dijalankan. Layanan `respawn` cukup sudah aktif (`pid > 0`). Bila dependensi `respawn` crash berulang kali hingga `SVC_STATE_FAILED`, atau dependensi `once` gagal/timeout, layanan yang membutuhkannya otomatis dibatalkan (`SVC_STATE_FAILED`). |
| `:memory_max=` | Opsional. Batas alokasi memori layanan (maks 63 karakter). Ditulis ke leaf cgroup v2 `/sys/fs/cgroup/ninit/<nama>/memory.max`. Nilai valid: `max` atau angka desimal positif dengan akhiran satuan tunggal opsional (`K`/`k`, `M`/`m`, `G`/`g`, atau byte murni; contoh: `16M`, `256M`, `1G`, `max`). Pelanggaran batas memori memicu OOM killer kernel secara deterministik (`SIGKILL`, status `0x9`). Format rusak (huruf acak, angka negatif, satuan ganda seperti `64MB`, atau nol) ditolak secara graceful saat parsing (diabaikan dengan log peringatan). Lebih dari 63 karakter entri **ditolak**. |
| `:cpu_max=` | Opsional. Batas kuota bandwidth CPU CFS (maks 63 karakter). Ditulis ke leaf cgroup v2 `/sys/fs/cgroup/ninit/<nama>/cpu.max`. Format valid: `<kuota> <periode>` yaitu dua angka desimal positif yang dipisahkan tepat satu spasi tunggal (contoh: `50000 100000` untuk 50% kuota per periode 100ms). Format rusak (non-numerik, spasi ganda/berlebih, nilai kuota/periode nol atau negatif, tanpa spasi pemisah) ditolak secara graceful saat parsing (diabaikan dengan log peringatan). Lebih dari 63 karakter entri **ditolak**. |
| `:pids_max=` | Opsional. Batas jumlah proses maksimum dalam cgroup layanan (maks 63 karakter). Ditulis ke leaf cgroup v2 `/sys/fs/cgroup/ninit/<nama>/pids.max`. Format valid: `max` atau angka desimal positif (contoh: `5`, `50`, `max`). Nilai negatif, nol, atau karakter non-numerik ditolak secara graceful saat parsing (diabaikan dengan log peringatan). Upaya `fork()` melebihi batas ini deterministik ditolak oleh kernel dengan `EAGAIN` (`Resource temporarily unavailable`). Lebih dari 63 karakter entri **ditolak**. |
| `:timeout=` | Opsional (khusus layanan `once`, maks 10 karakter). Batas waktu berjalan layanan dalam detik (contoh: `:timeout=60`, `:timeout=120`). Default: 30 detik (`ONCE_START_TIMEOUT`). Bila layanan berjalan melebihi batas ini, ia dihentikan paksa (`SIGKILL`), ditandai `SVC_STATE_FAILED`, dan seluruh dependennya dibatalkan secara transitif. Nilai `0`, `none`, atau `infinity` menonaktifkan timeout. **Peringatan**: menonaktifkan timeout (`0` atau `none`) berisiko membuat layanan dependen menggantung selamanya bila proses layanan mengalami kebuntuan (hang/deadlock). Format di luar rentang 1–86400s ditolak secara graceful dan memakai default 30 detik. |
 
Aturan umum:
 
- Baris komentar dimulai `#` (spasi/tab di depan diizinkan) dan baris kosong diabaikan.
- Baris lebih dari 1023 karakter ditolak utuh dan dicatat (`Parse err: baris melebihi MAX_LINE ...`); baris berikutnya tetap diproses. Aturan yang sama berlaku untuk baris `/etc/fstab`.
- Baris tanpa `:` pertama/kedua dilaporkan `Parse err: ...` lalu dilewati.
- Tag opsi (`:requires=`, `:memory_max=`, `:cpu_max=`, `:pids_max=`, `:timeout=`) dapat ditulis dalam urutan bebas setelah `<perintah>`. Parser memisahkan perintah pada kemunculan tag opsi paling awal, sehingga perintah yang memuat karakter titik dua (misal URL `http://...`) tetap utuh.
- Batasan resource cgroup v2 diterapkan pada leaf node `/sys/fs/cgroup/ninit/<nama>/` sebelum PID layanan dimasukkan ke `cgroup.procs`. Penulisan controller (`+memory +cpu +pids`) ke root cgroup `/sys/fs/cgroup/cgroup.subtree_control` mentoleransi kegagalan atau status partial pada lingkungan nested/container tanpa menggagalkan booting. Bila kernel tidak mengaktifkan controller tertentu, kegagalan penulisan dicatat di log tanpa menggagalkan PID 1.
- Validasi semantik & penanganan kesalahan graceful: parser memeriksa format nilai `memory_max`, `cpu_max`, dan `pids_max` sebelum diterapkan. Bila format tidak valid/rusak (malformed), ninit mencatat pesan log peringatan informatif (`Parse err: ... tidak valid pada layanan '...', batas diabaikan`) dan mengosongkan batas tersebut. Layanan tetap dijalankan tanpa limit bersangkutan (unconstrained) tanpa membuat PID 1 crash atau masuk rescue shell.
- Pembersihan siklus hidup orphan (lifecycle orphan cleanup):
  - Layanan `respawn`: saat proses pemimpin mati, `cgroup_kill_service` segera mengeksekusi `cgroup.kill` (atau fallback scanning PIDs pada kernel pra-5.14) untuk menyapu bersih sisa proses anak/orphan selama jeda `RESPAWN_DELAY` (2 detik). Pembersihan juga dipanggil kembali sebelum PID baru dimasukkan ke leaf cgroup.
  - Layanan `once`: saat proses pemimpin selesai/exit (`SVC_STATE_DONE` atau `SVC_STATE_FAILED`), `cgroup_kill_service` menyapu bersih seluruh proses anak/orphan sebelum pemanggilan penghapusan direktori cgroup leaf (`rmdir`). Fungsi `cleanup_cgroup` juga melakukan polling `rmdir` dengan toleransi `EBUSY` (hingga 20 kali percobaan / 100ms) untuk mengantisipasi latensi pelepasan referensi proses oleh kernel, mencegah kegagalan penghapusan leaf cgroup.
- **Perilaku Fail-Open Cgroup**: Bila sistem host tidak menyediakan hierarki cgroup v2 atau inisialisasi cgroup gagal, ninit beroperasi secara fail-open — seluruh layanan tetap dijalankan secara normal tanpa batasan (*unconstrained*). Jika suatu layanan mendefinisikan batas resource (`:memory_max=`, `:cpu_max=`, atau `:pids_max=`), ninit mencatat peringatan bahwa batas resource diabaikan karena cgroup tidak tersedia (`Warning: batas resource diabaikan pada layanan '<nama>' karena cgroup tidak tersedia`) dan melanjutkan eksekusi layanan.
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
web:respawn:/bin/httpd -p 8080:requires=net,logger:memory_max=256M:cpu_max=50000 100000:pids_max=50
worker:respawn:/usr/bin/worker:memory_max=128M:pids_max=20
```

### Batasan Resource Cgroup v2 & Validasi Semantik

ninit mengelola pembatasan resource proses menggunakan Cgroup v2 (*unified hierarchy*) pada leaf node `/sys/fs/cgroup/ninit/<nama>/`.

#### 1. Aturan Validasi Semantik

Parser `/etc/init.conf` menerapkan validasi semantik yang ketat sebelum nilai batas ditulis ke sysfs cgroup:

- **`cpu_max=<kuota> <periode>`**:
  - **Format valid**: Dua bilangan desimal positif yang dipisahkan oleh tepat satu spasi tunggal (`' '`), contoh: `50000 100000` (50% CPU pada periode 100.000 µs).
  - **Aturan**: Kuota > 0, periode > 0, hanya berisi karakter digit (`0-9`) dan satu spasi pemisah, serta tidak melampaui batas representasi numerik (`ERANGE`).
  - **Nilai tidak valid / ditolak**: Karakter non-numerik (`invalid 100000`), spasi ganda (`50000  100000`), tanpa periode (`50000`), nilai nol atau negatif (`-50000 100000`, `0 100000`).

- **`memory_max=<nilai>`**:
  - **Format valid**: String literal `"max"` atau bilangan bulat positif dengan akhiran satuan opsional huruf tunggal: `K`/`k` (kibibita), `M`/`m` (mebibita), `G`/`g` (gibibita), atau angka byte murni tanpa satuan. Contoh: `16M`, `256M`, `1G`, `max`.
  - **Aturan**: Karakter angka sebelum satuan harus berupa digit murni (`0-9`) bernilai > 0 dan tidak melampaui rentang (`ERANGE`). Akhiran hanya boleh satu huruf satuan.
  - **Nilai tidak valid / ditolak**: Satuan ganda atau multi-karakter (`64MB`, `256MiB`), teks acak (`corrupted!@#`), bilangan bertanda negatif (`-100M`), atau angka nol (`0`).

- **`pids_max=<nilai>`**:
  - **Format valid**: String literal `"max"` atau bilangan desimal positif murni, contoh: `5`, `25`, `50`, `max`.
  - **Aturan**: Hanya digit murni (`0-9`) bernilai > 0 tanpa tanda plus/minus dan tidak overflow (`ERANGE`).
  - **Nilai tidak valid / ditolak**: Bilangan negatif (`-5`), nilai nol (`0`), teks non-numerik (`invalid`).

#### 2. Penanganan Kesalahan Graceful (Graceful Error Handling)

Bila suatu opsi limit resource mengandung format yang rusak atau tidak valid:
1. ninit **tidak** membatalkan parsing file konfigurasi secara keseluruhan.
2. ninit **tidak** mengalami crash ataupun memasuki rescue shell darurat.
3. Pesan kesalahan dicatat secara transparan ke log:
   ```
   [YYYY-MM-DD HH:MM:SS] ninit: Parse err: <tag> '<nilai>' tidak valid pada layanan '<nama>', batas diabaikan
   ```
4. Nilai batas yang rusak dibuang (dikosongkan), dan layanan yang bersangkutan tetap diinisialisasi serta dijalankan tanpa batas resource tersebut (*unconstrained*). Dengan demikian, kesalahan pengetikan opsi limit tidak melumpuhkan ketersediaan layanan sistem utama.

#### 3. Siklus Hidup Cgroup & Pembersihan Orphan (Lifecycle Cleanup)

Untuk mencegah kebocoran proses zombie/orphan di latar belakang saat proses utama layanan berhenti:
- **Toleransi Subtree Root & Hierarki**: Saat inisialisasi boot, ninit mengaktifkan controller `+memory +cpu +pids` pada `/sys/fs/cgroup/cgroup.subtree_control` dan `/sys/fs/cgroup/ninit/cgroup.subtree_control`. Jika penulisan multi-token gagal (misalnya salah satu controller tidak didukung kernel atau berjalan di dalam container dengan delegasi terbatas), ninit mencoba menulis setiap token satu per satu dan mencatat kegagalan dengan penanda `(toleransi nested/container)` atau `(toleransi partial)` tanpa menghentikan proses boot.
- **Pembersihan Layanan Respawn**: Ketika proses pemimpin layanan bertipe `respawn` mati, `cgroup_kill_service` segera mengeksekusi `cgroup.kill` (dengan fallback pemindaian PID melalui `/proc` untuk kernel pra-5.14) guna menghentikan semua proses turunan selama jendela `RESPAWN_DELAY` (2 detik). Pembersihan juga diulang sesaat sebelum PID generasi baru dipindahkan ke dalam cgroup leaf.
- **Pembersihan Layanan Once**: Ketika layanan bertipe `once` selesai (`exit 0` maupun keluar dengan error/sinyal), `cgroup_kill_service` menyapu bersih seluruh proses anak/orphan yang ditinggalkan sebelum memanggil `cleanup_cgroup`.
- **Polling `rmdir` pada Leaf Cgroup**: Fungsi `cleanup_cgroup` memanggil `cgroup_kill_service` dan mencoba menghapus direktori leaf cgroup `/sys/fs/cgroup/ninit/<nama>`. Bila kernel masih dalam proses merealisasikan terminasi task sehingga `rmdir` mengembalikan `EBUSY`, ninit melakukan polling hingga 20 kali dengan jeda 5 ms (`usleep(5000)`, total maksimal 100 ms). Saat berhasil, ninit mencatat `cgroup: dibersihkan '<nama>'`.

#### 4. Kontrak Fallback Fail-Open Saat Cgroup Unavailable

Bila ninit dijalankan di lingkungan di mana hierarki cgroup v2 tidak tersedia (misalnya container tanpa delegasi cgroupfs, chroot minimal tanpa mount cgroup, atau kernel legacy tanpa cgroups):

1. **Ketersediaan Layanan Terjamin (Fail-Open)**:
   Kegagalan inisialisasi cgroup tidak menggagalkan proses boot PID 1 dan tidak membatalkan eksekusi layanan. Layanan tetap di-spawn dan bertransisi ke state `SVC_STATE_RUNNING`.
2. **Pencatatan Log Fail-Open Eksplisit**:
   ninit secara transparan mencatat bahwa mekanisme fallback fail-open sedang aktif untuk layanan tersebut:
   ```
   [YYYY-MM-DD HH:MM:SS] ninit: cgroup: fail-open aktif untuk '<nama>' (cgroup tidak tersedia)
   ```
3. **Peringatan Penegakan Batas Resource**:
   Jika konfigurasi layanan menyertakan batas resource (`:memory_max=`, `:cpu_max=`, atau `:pids_max=`), batas tersebut tidak dapat ditegakkan oleh kernel. ninit mencatat peringatan eksplisit:
   ```
   [YYYY-MM-DD HH:MM:SS] ninit: Warning: batas resource diabaikan pada layanan '<nama>' karena cgroup tidak tersedia
   ```
   Layanan tetap dieksekusi tanpa pembatasan resource (*unconstrained*). Bila layanan tidak mengonfigurasi batas resource apa pun, pesan peringatan ini tidak dicetak (hanya log fail-open aktif).
4. **Jaminan Bebas Deadlock pada Handshake Pre-Exec**:
   Pada mekanisme sinkronisasi parent-child sebelum `execl()`, kegagalan cgroup langsung memicu pelepasan blokir proses anak via penulisan sinyal dan penutupan pipe sinkronisasi (`O_CLOEXEC`), memastikan proses anak tidak pernah tertahan (*hang*) atau mengalami kebuntuan (*deadlock*).

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
