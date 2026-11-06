# Build dan pengujian

## Build

Butuh `build-essential`:

```bash
sudo apt-get update && sudo apt-get install build-essential busybox-static
make            # -> ./ninit  (gcc -static -O2 -Wall)
```

- Biner harus **statis** agar bisa dipakai tanpa loader di rootfs minimal.
- Target `main` bebas warning; verifikasi dengan `-Werror`:
  `make clean && make CFLAGS="-static -O2 -Wall -Werror"`.
- Pada distro tanpa libc statis glibc (mis. Alpine): `make CC=musl-gcc`.
- `make clean` menghapus `./ninit`. Biner hasil build diabaikan `.gitignore`.

## Uji otomatis

```bash
make test                              # menjalankan lima script pertama (6 butuh QEMU: make integration)
sudo sh ./scripts/smoke-test.sh        # 1) smoke test PID 1
sudo sh ./scripts/test-sigterm.sh      # 2) SIGTERM sampai ke layanan
sudo sh ./scripts/test-config.sh       # 3) urut dependensi + rescue mode + initctl
sh ./scripts/test-qemu-report.sh       # 4) pemeriksaan harness run-qemu.sh (tanpa root)
sudo sh ./scripts/test-spawn-failure.sh # 5) jalur kegagalan spawn (fork EAGAIN + deps di respawn)
sudo sh ./scripts/test-integration.sh  # 6) integrasi lintas lapisan via boot QEMU (make integration)
```

### 1. Smoke test PID 1 (`scripts/smoke-test.sh`)

Cara kerja:

1. Membuat rootfs sementara (`mktemp -d`), menyalin biner uji ke `<root>/ninit`
   dan busybox statis ke `<root>/bin/sh`, lalu menulis
   `/etc/init.conf` berisi `shell:respawn:/bin/sh`.
2. Menjalankan ninit sebagai **PID 1** di PID + mount namespace baru:

   ```bash
   unshare --pid --fork --kill-child=SIGKILL --mount --propagation private \
       sh -c 'mount -t proc proc <root>/proc && exec chroot <root> /ninit'
   ```

3. Menunggu sampai ninit benar-benar jalan (banner + `main loop siap`).
4. Mengirim `SIGTERM` ke PID 1 namespace lewat `kill` dari host, mengukur latensi.
5. Memeriksa log dan keluar dengan status non-zero bila ada yang gagal.

Pemeriksaan yang dijalankan:

| Pemeriksaan | Arti |
|---|---|
| banner `ninit start (PID 1)` | init benar-benar start sebagai PID 1 |
| `main loop siap` | parsing konfigurasi + spawn awal berhasil, event loop jalan |
| `started shell` | layanan dari `init.conf` dijalankan |
| `graceful shutdown` | `SIGTERM` diproses dan jalur shutdown dieksekusi |
| tidak ada respawn setelah shutdown | regresi "respawn saat shutdown" tidak kembali |
| latensi `SIGTERM → berhenti < 5000 ms` | loop tidak terblokir `sleep()`/respawn; diukur lewat `sync()` yang fluktuatif di VPS/CI, ambang bisa dioverride lewat `LATENCY_LIMIT_MS` |

Script memakai `sudo` sendiri bila bukan root, membersihkan rootfs + proc lewat
`trap`, dan mencetak seluruh log ninit agar kegagalan bisa dibaca langsung.

### 2. Test SIGTERM ke layanan (`scripts/test-sigterm.sh`)

Uji ini menjaga satu bug halus: anak hasil `fork()` mewarisi **signal mask** PID 1
(`main()` memblokir `SIGTERM`/`SIGCHLD`/`SIGINT`/`SIGUSR1`/`SIGUSR2` untuk
`ppoll`). Bila mask itu tidak dibersihkan di anak, layanan tidak pernah menerima
`SIGTERM`: trap-nya tidak jalan, jendela grace 5 detik habis, dan init memakai
`SIGKILL` — layanan yang sebenarnya sopan pun tampak "keras kepala".

Script menyiapkan rootfs dengan satu layanan uji yang menutup diri lewat trap
(ditulis ke `/sigterm-service.sh` di dalam rootfs):

```sh
#!/bin/sh
trap 'echo "Menerima SIGTERM, bye!"; exit 0' TERM
echo "sigterm-service: jalan, menunggu SIGTERM (pid $$)"
while true; do sleep 1; done
```

dengan `/etc/init.conf` berisi `sigterm-test:once:/sigterm-service.sh`, lalu
mengukur waktu dari `SIGTERM` sampai baris `exit status` muncul di log.

| Pemeriksaan | Arti |
|---|---|
| `jalan, menunggu SIGTERM` | layanan uji benar-benar start |
| bit `SIGTERM` (`0x4000`) tidak ada di `SigBlk` proses layanan | mask warisan PID 1 sudah dibersihkan di anak |
| `Menerima SIGTERM, bye!` | trap milik layanan jalan → sinyal benar-benar diantarkan |
| `exit status=0x0` dan tidak ada `0x9` | layanan keluar sendiri, bukan dibunuh paksa `SIGKILL` |
| ack < 4000 ms (jendela grace 5000 ms) | shutdown tidak bergantung pada fallback `SIGKILL` |

Bila `ps` tidak menemukan proses layanan, pemeriksaan mask dilewati dengan
penanda `[ -- ]`; pemeriksaan lain tetap menentukan hasil. Contoh log yang lulus
(layanan busybox `sh` menunggu `sleep 1` selesai, jadi ack-nya sekitar 1 detik):

```
  | [2026-01-01 00:00:00] ninit: started sigterm-test (pid 3)
  | [2026-01-01 00:00:00] [service] sigterm-service: jalan, menunggu SIGTERM (pid 3)
  | [2026-01-01 00:00:00] ninit: main loop siap
  | [2026-01-01 00:00:05] ninit: graceful shutdown (cmd=1126301404)
  | [2026-01-01 00:00:06] ninit: sigterm-test (pid 3) exit status=0x0
  | [2026-01-01 00:00:06] [service] Menerima SIGTERM, bye!
```

### 3. Uji konfigurasi & IPC (`scripts/test-config.sh`)

Uji ini mengunci empat perbaikan reliabilitas sekaligus (tujuh run ninit
terpisah, tiap run memakai rootfs sendiri):

| Bagian | Yang diperiksa |
|---|---|
| 1a | dependensi berlian (`a:requires=b,c` + `b:requires=c`) dijalankan berurutan `c → b → a` dan **tidak** dilaporkan sebagai cycle |
| 1b | konfigurasi padat tepat 64 layanan (`root` butuh `s2..s64`, `s63` butuh `s62,s61`) → 64/64 dijalankan tanpa `FATAL` |
| 2 | `web:once:echo web:requires=db` → `FATAL: Dependensi 'db' untuk 'web' tidak ditemukan` + rescue shell; `main loop siap` tidak pernah muncul |
| 3a | `printf 'poweroff\nreboot\n' > /run/initctl` → hanya baris pertama yang dieksekusi (`reboot` tidak pernah dilaporkan) |
| 3b | `printf 'status\npoweroff\n' > /run/initctl` → baris tak dikenal tetap dicatat dan `poweroff` di baris kedua tidak hilang tanpa jejak |
| 4a | config tidak bisa dibuka → `Config gagal dibaca/di-parse!` + rescue shell; `main loop siap` tidak pernah muncul (regresi lama: hanya di-log lalu boot dengan nol layanan) |
| 4b | siklus `a:requires=b` + `b:requires=a` → `FATAL: CYCLE DETECTED` + rescue shell, dan `SigBlk` shell itu `0` (Ctrl+C berfungsi; biner lama mewarisi `0000000000014a02`) |

**Kenapa bagian 1b penting.** `sort_services()` versi lama menandai node saat
di-*expand*, bukan saat di-*push*, sehingga layanan yang masih "pending" di stack
bisa di-push berulang. Pada konfigurasi 1b `stack_top` mencapai 65 untuk
`stack[64]`. Terbukti dengan AddressSanitizer pada kode sebelum perbaikan (harness
yang memanggil `sort_services()` langsung):

```
==1731==ERROR: AddressSanitizer: stack-buffer-overflow ...
WRITE of size 4 ... in sort_services ninit-old.c:250
    [672, 928) 'stack' (line 228) <== Memory access at offset 928 overflows this variable
```

Versi sekarang menandai `temp_visited[...] = 1` **sebelum** `stack[stack_top++]`
dan menolak push saat `stack_top >= MAX_SERVICES`, jadi satu layanan hanya masuk
stack sekali. Bagian 1b juga menjaga agar konfigurasi valid selalu berakhir di
64/64 `started` tanpa `FATAL`.

**Kenapa bagian 4 penting.** Sebelum v1.0.0, `parse_config()` yang gagal hanya
menulis `config gagal, masuk rescue mode` lalu **melanjutkan boot** dengan nol
layanan, dan rescue shell (jalur dependensi/siklus) mewarisi signal mask PID 1 —
`SIGINT` tetap diblokir sehingga Ctrl+C di shell darurat tidak berfungsi.
`enter_rescue_mode()` mengosongkan mask lalu `execl("/bin/sh", "sh", NULL)`.
Bagian 4b membaca `/proc/<pid>/status` shell darurat dan menuntut `SigBlk=0`;
pada biner lama nilainya `0000000000014a02` (bit `SIGINT` + `SIGTERM` + `SIGCHLD`
+ `SIGUSR1` + `SIGUSR2` terpasang).

### Kenapa bukan `unshare --mount-proc=<dir>`?

Pada sebagian kernel (termasuk sandbox/CI tertentu) util-linux melakukan
bind-mount lalu mengubah mount propagation, dan kernelnya menolak dengan:

```
unshare: cannot change <dir>/proc filesystem propagation: Invalid argument
```

Varian `--mount --propagation private` + `mount -t proc` manual memiliki efek yang
sama (PID namespace + mount namespace + `proc` ter-mount untuk chroot) tetapi
portabel. Perintah manual asli tetap bisa dipakai di mesin yang mendukungnya:

```bash
sudo timeout 5 unshare --pid --fork --mount-proc=/tmp/myrootfs/proc chroot /tmp/myrootfs /ninit
```

### 4. Pemeriksaan harness run-qemu.sh (`scripts/test-qemu-report.sh`)

Kenapa ada: catatan PR #1 ("Temuan berikutnya") — `run-qemu.sh` mode otomatis
bisa melaporkan LULUS padahal layanan console mati. Baris `started console`
ditulis `spawn_service()` saat *fork*, bukan setelah `exec` berhasil, sehingga
`console:respawn:/bin/does-not-exist` menghasilkan `started console` berulang
(diselingi `exit status=0x7f00` dan `respawn ditunda`) sementara tiga pemeriksaan
lama tetap cocok semua.

Cara kerja: `scripts/run-qemu.sh` dijalankan dengan `REPORT_ONLY=1` terhadap
fixture log konsol — tidak ada QEMU yang di-boot, tidak butuh root. Setiap
skenario menuntut kode keluar DAN baris pemeriksaan spesifik yang diharapkan,
sehingga kegagalan tidak boleh datang dari pemeriksaan yang salah sasaran:

| Skenario | Fixture | Hasil diharapkan |
|---|---|---|
| 1 | boot sehat (tiap baris ninit dobel: `/dev/kmsg` + stderr) | LULUS; `console start tepat satu PID` membuktikan deduplikasi baris |
| 2 | console mati + respawn loop (pembuktian regresi PR #1) | GAGAL oleh 3 pemeriksaan liveness baru (PID unik, `exit status`, `respawn ditunda`) — sementara pemeriksaan lama tetap `[ OK ]`, bukti lama harness akan LULUS |
| 3 | console keluar sekali, satu PID | GAGAL oleh pemeriksaan `exit status` saja |
| 4 | kernel panic | GAGAL oleh `absent Kernel panic` |
| 5 | `started console` tidak pernah muncul | GAGAL; hitungan PID unik = 0 |
| 6 | `main loop siap` tidak pernah muncul | GAGAL; `ready_ms` kosong |
| 7 | console sehat, service respawn LAIN (`web`) tertunda | LULUS; `web: respawn ditunda` tidak menyeret harness (check ter-scope ke console) |

Pemeriksaan liveness yang dijaga (ada di `report()` `scripts/run-qemu.sh`):
jumlah PID unik pada `started console (pid N)` harus tepat satu; baris
`console (pid N) exit status` dan `console: respawn ditunda` tidak boleh muncul.
Pemeriksaan respawn **di-scope ke console** (bukan `respawn ditunda` generik):
service respawn lain yang menunda jendela respawn adalah perilaku normal pada
`init.conf` multi-layanan — pola global akan memberi GAGAL palsu (catatan
review PR #6).

Pemakaian: `sh ./scripts/test-qemu-report.sh` (sudah termasuk `make test`
dan CI).

### 5. Jalur kegagalan spawn (`scripts/test-spawn-failure.sh`)

Kenapa ada: audit eksternal atas `main` (af3388f) menuduh kegagalan `fork()`
mengunci PID 1 dalam `do ... while (progress)` sehingga tidak pernah kembali ke
`ppoll()`. Dugaan itu tidak terbukti saat direproduksi — `spawn_service()`
sudah men-set `last_start` SEBELUM `fork()`, jadi jendela `RESPAWN_DELAY`
memaksa loop keluar. Pengujian ulang jalur yang sama menemukan dua cacat nyata
yang justru tidak tercakup suite mana pun:

1. `respawn_services()` tidak membaca dependensi sama sekali, sehingga layanan
   yang sudah "dibatalkan" karena dependensi `once`-nya gagal tetap
   dihidupkan ulang selamanya — urutan `requires=` dilanggar lewat jalur respawn.
2. Layanan `once` yang `fork()`-nya gagal tidak punya jalur retry (`respawn_services()`
   hanya menangani `svc->respawn`) dan tidak pernah mencapai state terminal: ia
   tertinggal di `SVC_STATE_STOPPED` selamanya sementara dependennya menunggu
   tanpa pesan.

Cara kerja (butuh root; `sudo make test`):

| Skenario | Konfigurasi | Yang dituntut |
|---|---|---|
| 1 | `boot:once` keluar 3 + `app:respawn:requires=boot` | `app` dibatalkan dan `started app` TIDAK pernah muncul |
| 2 | `ping:once` (pemicu SIGCHLD) + `slow:once` tidur 4 s + `app:respawn:requires=slow` | baris `SLOW-DONE` mendahului `APP-START` di `/var/order` |
| 3 | `boot:once` + `app:respawn:requires=boot`, `fork()` dipaksa EAGAIN | `boot` berakhir `FAILED` setelah maks. 3 percobaan, `app` dibatalkan, `main loop siap` tetap tercetak |

Skenario 2 butuh layanan `ping`: tanpa peristiwa SIGCHLD, event loop lama
memblokir di `ppoll()` tanpa timeout sampai `slow` selesai, sehingga jalur
respawn yang salah tidak pernah dieksekusi dan testnya jadi hampa.

Skenario 3 memaksa `fork()` gagal secara deterministik lewat controller
`pids` di cgroup v2: proses yang akan menjadi ninit memindahkan dirinya ke
cgroup dengan `pids.max=1` sebelum `exec`, jadi setiap `fork()` berikutnya
mengembalikan `EAGAIN`. `RLIMIT_NPROC` (`ulimit -u`) tidak bisa dipakai karena
kernel mengecualikan uid 0 darinya. Bila cgroup v2 atau delegasi `pids` tidak
tersedia, skenario ini dicetak `[ -- ]` (dilewati) tanpa membuat suite gagal.

Pemakaian: `sudo sh ./scripts/test-spawn-failure.sh` (sudah termasuk
`make test` dan CI). Variabel: `WAIT1`/`WAIT2`/`WAIT3` jendela observasi tiap
skenario.

### 6. Uji integrasi lintas lapisan (`scripts/test-integration.sh`)

Kenapa ada: suite 1–5 menguji satu lapisan pada satu waktu (parser di chroot,
report() lewat fixture). Inkonsistensi ANTAR lapisan lolos dari semuanya —
misalnya escape oktal fstab yang benar di unit test tapi `mount()` gagal di
kernel asli, atau opsi data yang terbaca parser namun hilang saat rootfs
di-pack ke initramfs.

Cara kerja (butuh root + QEMU; `sudo make integration`):

1. Menulis fixture `fstab` (entri normal `size=1m`, mountpoint ber-escape
   oktal `/mnt/a\040b`, dan duplikat mountpoint) + `init.conf` berisi layanan
   `mountproof:once:` yang membaca `/proc/mounts` dari DALAM guest.
2. Membangun rootfs lewat hook `EXTRA_FSTAB`/`EXTRA_INIT_CONF`
   `scripts/build-rootfs.sh`, lalu SATU boot QEMU via `run-qemu.sh`.
3. Menuntut hasil lintas lapisan:

| Pemeriksaan | Arti |
|---|---|
| `fstab: mount ... [data: size=1m] ok` | opsi data fstab benar-benar diteruskan ke `mount()` kernel |
| `fstab: mount tmpfs -> /mnt/a b ... ok` | dekode escape oktal bekerja terhadap kernel nyata (regresi PR #3-C1) |
| `dilewati (mountpoint duplikat` | entri duplikat tidak di-mount dua kali (regresi PR #3-C2) |
| `INTEGRATION-MOUNT-VISIBLE` | mount fstab terlihat dari `/proc/mounts` sudut pandang layanan |
| urutan baris konsol | semua aktivitas `fstab:` mendahului service pertama dan `main loop siap` |
| `report()` LULUS | boot ber-fstab uji tetap memenuhi harness standar (bagian 4) |

Catatan TCG: mode otomatis kini memakai `-cpu max` bila `/dev/kvm` tidak ada.
Tanpa itu, CPU default `qemu64` tidak punya AVX dan toolchain host modern
(x86-64-v3, mis. Ubuntu 26.04) langsung SIGILL — kernel panic jauh sebelum
banner ninit, tanpa petunjuk penyebabnya.

Pemakaian: `sudo sh ./scripts/test-integration.sh` (CI: step terakhir job
`rootfs-distro`). Variabel: `SECS=40` (jendela boot TCG), `BUSYBOX_MODE`
diteruskan ke build-rootfs.

Catatan `BUSYBOX_MODE`: suite default memakai `prebuilt` (cepat, cocok CI).
Hook `EXTRA_FSTAB`/`EXTRA_INIT_CONF` tidak bergantung mode, tetapi **isi
rootfs bisa berbeda** antar mode — mis. set applet dari sumber (`defconfig`)
tidak selalu sama dengan `busybox-static` cadangan. Sesekali jalankan juga
dengan `BUSYBOX_MODE=auto|source` untuk memastikan fixture tetap lulus pada
rootfs hasil kompilasi sumber, bukan hanya binary cadangan.

## Uji manual di chroot (tanpa script)

```bash
# 1. rootfs dummy
mkdir -p /tmp/myrootfs/{proc,sys,dev,run,tmp,etc,var/log,bin}
cp ninit /tmp/myrootfs/
cp /bin/busybox /tmp/myrootfs/bin/sh
printf 'shell:respawn:/bin/sh\n' > /tmp/myrootfs/etc/init.conf

# 2. jalankan sebagai PID 1 di namespace baru
sudo timeout -k 5 8 unshare --pid --fork --kill-child=SIGKILL --mount --propagation private \
    sh -c 'mount -t proc proc /tmp/myrootfs/proc && exec chroot /tmp/myrootfs /ninit'
```

Log lengkap juga tersimpan di `/tmp/myrootfs/var/log/ninit.log` (di dalam chroot).

Menjalankan langsung di VM sebagai init sungguhan (uji akhir):

```bash
install -m0755 ninit /sbin/init      # pastikan /etc/init.conf sudah ada
```

Cara yang sudah otomatis ada di repo: `make rootfs && make qemu` -- rootfs
minimal (BusyBox statis) + initramfs di-boot QEMU dengan konsol serial; lihat
[distro-builder.md](distro-builder.md).

## CI (`.github/workflows/ci.yml`)

Runner `ubuntu-latest`, urutannya: install `build-essential` + `busybox-static` →
`make` → cek biner statis lewat `readelf` (tidak boleh ada `INTERP`) →
`sudo sh ./scripts/smoke-test.sh` → `sudo sh ./scripts/test-sigterm.sh` →
`sudo sh ./scripts/test-config.sh` → `sh ./scripts/test-qemu-report.sh` →
`sudo sh ./scripts/test-spawn-failure.sh` →
`make CFLAGS="-static -O2 -Wall -Werror"`.

Job kedua, `rootfs-distro`, menjaga jalur distro yang tidak dipakai script di atas:
install `bzip2` + `cpio` + `qemu-system-x86` → `sudo sh ./scripts/build-rootfs.sh`
(kompilasi BusyBox dari sumber + initramfs) → `sudo SECS=20 sh ./scripts/run-qemu.sh`
(boot initramfs dengan konsol serial; selain penanda boot, harness juga menuntut
console tetap hidup — lihat bagian 4) → `sudo SECS=40 sh ./scripts/test-integration.sh`
(satu boot kedua dengan fstab + init.conf uji — lihat bagian 6). QEMU di runner memakai TCG karena tidak ada
`/dev/kvm`; kernel guest diunduh dari Alpine netboot ke `distro/cache/`.

## Troubleshooting

| Gejala | Penyebab & solusi |
|---|---|
| `unshare: cannot change ... filesystem propagation: Invalid argument` | Kernel menolak perubahan propagation; pakai varian `--mount --propagation private` seperti di atas. |
| Proses uji perlu `SIGKILL` (exit 137) | `shutdown_all()` menunggu jendela grace 5 detik; beri `timeout -k` lebih panjang dari 5 detik, atau kirim `SIGUSR1`/`SIGUSR2` untuk jalur force. |
| Exit code 124 dari `timeout` | Normal: proses berhenti sendiri setelah `SIGTERM`. |
| `ninit harus dijalankan sebagai PID 1` | Dipanggil bukan sebagai PID 1; gunakan `unshare --pid --fork` (di dalam container juga perlu namespace PID baru). |
| `cgroup: mkdir ... gagal: Permission denied` | Tidak berjalan sebagai root, atau `/sys/fs/cgroup` sudah dikelola sistem lain. Kegagalan ini hanya di-log; init tetap jalan. |
| Layanan tidak dapat dijalankan, `execl` gagal | `/bin/sh` tidak ada di rootfs; pasang busybox statis sebagai `/bin/sh`. |
| Log layanan tidak muncul | `/run` harus ter-mount `tmpfs` (otomatis oleh `setup_pseudo_fs()`) dan layanan menulis ke stdout/stderr. |
| Layanan `exit status=0x9` (dibunuh paksa) | `SIGTERM` tidak sampai ke layanan: mask sinyal warisan PID 1 tidak dibersihkan, atau layanan memang mengabaikan `SIGTERM`. Verifikasi dengan `sudo sh ./scripts/test-sigterm.sh`. |
| `collect2: cannot find -lc` saat build | Libc statis tidak terpasang; gunakan `gcc-multilib`/`libc6-dev-static` sesuai distro atau `make CC=musl-gcc`. |
| Pesan fstab hanya di console, bukan di file log | Urutan yang disengaja: `mount_fstab()` berjalan sebelum `/var/log/ninit.log` dibuka. |
| `FATAL: Dependensi '<x>' untuk '<y>' tidak ditemukan` | `:requires=` menunjuk layanan yang tidak ada di `/etc/init.conf` (termasuk bila barisnya terpotong karena melewati batas 64 layanan). Init masuk rescue shell; perbaiki konfigurasi lalu boot ulang. |
| `FATAL: CYCLE DETECTED di <x> -> <y>` | Dependensi melingkar; pecahkan salah satu `:requires=` agar tidak ada siklus. |
| `FATAL: Stack overflow pada topological sort!` | Jaring pengaman `sort_services()`; bila muncul pada konfigurasi < 64 layanan, laporkan sebagai bug. |
