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
make test                            # menjalankan kedua script di bawah ini
sudo sh ./scripts/smoke-test.sh      # 1) smoke test PID 1
sudo sh ./scripts/test-sigterm.sh    # 2) SIGTERM sampai ke layanan
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
| latensi `SIGTERM → berhenti < 2000 ms` | loop tidak terblokir `sleep()`/respawn |

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

## CI (`.github/workflows/ci.yml`)

Runner `ubuntu-latest`, urutannya: install `build-essential` + `busybox-static` →
`make` → cek biner statis lewat `readelf` (tidak boleh ada `INTERP`) →
`sudo sh ./scripts/smoke-test.sh` → `sudo sh ./scripts/test-sigterm.sh` →
`make CFLAGS="-static -O2 -Wall -Werror"`.

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
