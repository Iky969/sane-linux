# Distro builder: rootfs minimal + boot di QEMU

Fase ini membuktikan ninit benar-benar menjadi **PID 1 di dalam mesin**, bukan
sekadar di `chroot`/namespace: rootfs dibangun dari nol, dibungkus jadi
initramfs, lalu di-boot oleh QEMU dengan konsol serial.

```bash
make rootfs          # scripts/build-rootfs.sh -> distro/rootfs + distro/initramfs.cpio.gz
make qemu            # scripts/run-qemu.sh    -> boot interaktif (Ctrl-A X untuk keluar)
SECS=5 make qemu     # boot otomatis 5 detik + pemeriksaan penanda + laporan konsol
```

## Ringkas alur

| Tahap | Script | Hasil |
|---|---|---|
| 1 | `scripts/build-rootfs.sh` | unduh + kompilasi BusyBox **statis**, susun `distro/rootfs/`, pasang `ninit` sebagai `/sbin/init`, bungkus jadi `distro/initramfs.cpio.gz` |
| 2 | `scripts/run-qemu.sh` | siapkan kernel (host, atau unduh Alpine `vmlinuz-virt`), boot QEMU, periksa penanda boot di konsol serial |

## Isi rootfs

| Path | Isi | Catatan |
|---|---|---|
| `/bin/busybox` | BusyBox 1.36.1 statis (`gcc -static`, 402 applet) + symlink applet | `make defconfig` + `CONFIG_STATIC=y` + `make LDFLAGS=-static` + `make install` |
| `/bin/sh` | symlink ke `busybox` | wajib: ninit menjalankan setiap layanan lewat `/bin/sh -c` |
| `/sbin/init` | biner `ninit` (statis) | PID 1 di dalam guest |
| `/sbin/{poweroff,reboot,halt}` | skrip wrapper → `/run/initctl` | menimpa applet BusyBox yang memakai sinyal berbeda dari tabel ninit |
| `/etc/init.conf` | `console:respawn:cttyhack /bin/sh -i` | shell interaktif di serial console, nama layanan `console` (lihat “Temuan integrasi”) |
| `/etc/passwd`, `/etc/group` | `root:x:0:0`, `root:x:0:` | minimal |
| `/etc/hostname` | `ninit-distro` | dipakai `set_hostname()` ninit |
| `/etc/fstab` | hanya komentar | menghindari log `fstab: … tidak ada, dilewati` |
| `/dev/{console,null,tty}` | node awal (`mknod`) | supaya konsol kernel hidup sejak detik pertama; devtmpfs menyusul |
| `/proc /sys /dev /run /tmp` | direktori kosong | dipasang otomatis oleh `setup_pseudo_fs()` |
| `/var/log` | direktori | tempat `ninit.log` |

Direktori kerja (semuanya di-`.gitignore`): `distro/cache/` (tarball + kernel
unduhan), `distro/build/` (sumber BusyBox + hasil `make install`),
`distro/rootfs/`, `distro/initramfs.cpio.gz`, `distro/qemu-console.log`.

## Kernel

`scripts/run-qemu.sh` memilih kernel dengan urutan:

1. `KERNEL=/path/vmlinuz` bila diberikan eksplisit.
2. `KERNEL_MODE=host` → `/boot/vmlinuz-$(uname -r)` (di sandbox/container `/boot`
   biasanya kosong).
3. `KERNEL_MODE=auto` (default) → kernel host bila ada, kalau tidak mengunduh
   Alpine `vmlinuz-virt` (`ALPINE_BRANCH=v3.20`, `ALPINE_FLAVOR=virt`).
   Checksum hasil unduhan dicatat di `distro/cache/vmlinuz-*.sha256`.

## Perintah QEMU

```bash
qemu-system-x86_64 -m 256 -no-reboot \
  -kernel distro/cache/vmlinuz-virt-v3.20 \
  -initrd distro/initramfs.cpio.gz \
  -append "console=ttyS0 rdinit=/sbin/init init=/sbin/init panic=-1 loglevel=7"
```

- Mode **interaktif**: `-nographic` (serial + monitor di stdio).
- Mode **otomatis** (`SECS=<detik>`): `-display none -serial file:distro/qemu-console.log`
  supaya konsol guest terekam utuh tanpa bergantung pada TTY, dan proses QEMU
  dibatasi `timeout`.
- `-enable-kvm -cpu host` ditambahkan otomatis bila `/dev/kvm` bisa ditulis
  (di sandbox ini tidak ada, jadi emulasi TCG murni).

## Bukti boot (hasil nyata di sandbox, TCG tanpa KVM)

```
[    1.256959] Run /sbin/init as init process
[2026-10-27 23:55:18] ninit: cgroup2: /sys/fs/cgroup ter-mount
[2026-10-27 23:55:18] ninit: === ninit start (PID 1) v1.0.0 ===
[2026-10-27 23:55:18] ninit: hostname = ninit-distro
[2026-10-27 23:55:18] ninit: started console (pid 403)
~ #
[2026-10-27 23:55:18] ninit: cgroup: 'console' (pid 403) -> /sys/fs/cgroup/ninit/console
[2026-10-27 23:55:18] ninit: main loop siap
```

`main loop siap` muncul **~2,0–2,1 detik** setelah QEMU dijalankan (emulasi TCG).

Sesi interaktif (perintah diketik ke serial console, dijalankan di dalam guest):

```
~ # echo HALO-DARI-GUEST
HALO-DARI-GUEST
~ # cat /etc/hostname
ninit-distro
~ # kill -TERM 1
[2026-10-27 23:56:51] ninit: graceful shutdown (cmd=1126301404)
[   10.500910] ACPI: PM: Preparing to enter system sleep state S5
[   10.502328] reboot: Power down
```

`1126301404` = `0x4321FEDC` = `RB_POWER_OFF`: jalur graceful shutdown ninit
bekerja di dalam mesin sungguhan dan QEMU keluar sendiri.

## Temuan integrasi (yang perlu diketahui)

1. **Layanan mendapat `stdin` `/dev/null`.** `spawn_service()` menyalakan anak
   dengan `stdin=/dev/null` dan `stdout/stderr=/run/log.fifo`. Jadi
   `shell:respawn:/bin/sh` polos akan langsung kena EOF, keluar, dan
   di-respawn setiap 2 detik — bukan menjadi shell konsol. Karena perintah
   dijalankan lewat `/bin/sh -c`, redireksi di dalam perintah menempelkan shell
   ke console: `<> /dev/console >&0 2>&0`.
2. **`cttyhack` untuk job control.** ninit memanggil `setsid()` di anak, sehingga
   tidak ada controlling tty dan `sh -i` mengeluh
   `can't access tty; job control turned off`. `cttyhack` membuka
   `/dev/console`, menjadikannya controlling tty (`TIOCSCTTY`), lalu
   meneruskan kendali ke shell.
3. **Tabel sinyal BusyBox ≠ tabel sinyal ninit — sudah diperbaiki wrapper.**
   Applet `halt`/`poweroff`/`reboot` BusyBox mengirim
   `SIGUSR1`/`SIGUSR2`/`SIGTERM` ke PID 1, sedangkan ninit memetakan `SIGUSR2`
   → *force reboot*: mengetik `poweroff` di guest justru **me-reboot** mesin.
   `scripts/build-rootfs.sh` kini memasang wrapper di `/sbin` yang memakai
   jalur resmi `/run/initctl`:

   | Perintah di guest | Isi wrapper | Perilaku ninit |
   |---|---|---|
   | `/sbin/poweroff` | `echo poweroff > /run/initctl` | graceful → `RB_POWER_OFF` (matikan) |
   | `/sbin/reboot` | `echo reboot > /run/initctl` | graceful → `RB_AUTOBOOT` (restart) |
   | `/sbin/halt` | `echo force-poweroff > /run/initctl` | force → `RB_POWER_OFF` (tanpa grace) |

   Dua detail yang mudah salah: (a) `/sbin/poweroff` di rootfs adalah **symlink
   ke `../bin/busybox`**, jadi skrip wajib `rm -f` symlink itu lebih dulu —
   `cat >` tanpa `rm` menembus symlink dan **merusak biner BusyBox**;
   (b) alias applet BusyBox di direktori PATH lain dibuang supaya wrapper selalu
   menang. Jalur sinyal mentah tetap tersedia: `kill -TERM 1` (matikan rapi),
   `kill -USR1 1` / `kill -USR2 1` (force poweroff / force reboot).

4. **Input serial yang dikirim sebelum shell siap bisa hilang.** Menyalurkan
   ketikan lewat pipe pada detik ke-0 (mis. `printf … | run-qemu.sh`) tidak
   andal: byte pertama sering termakan. Beri jeda (`sleep 6`) atau ketik
   langsung di terminal.

## Uji verifikasi: poweroff vs reboot di dalam QEMU

Perintah diketik di serial console setelah shell siap (input dialirkan dengan
jeda 6 detik; lihat *Known Limitations* soal input t=0):

| Perintah di guest | Log ninit | Kernel | Hasil |
|---|---|---|---|
| `command -v poweroff` | — | — | `/sbin/poweroff` (PATH `/sbin:/usr/sbin:/bin:/usr/bin`) |
| `poweroff` | `initctl cmd: 'poweroff'` → `graceful shutdown (cmd=1126301404)` | `reboot: Power down` | mesin **mati**, 1× boot ninit, QEMU keluar sendiri |
| `reboot` | `initctl cmd: 'reboot'` → `graceful shutdown (cmd=19088743)` | `Restarting system` → `machine restart` | mesin **restart**: boot ninit kedua muncul (`started console (pid 403)`) |
| `echo poweroff > /run/initctl` | `initctl cmd: 'poweroff'` → `graceful shutdown` | `reboot: Power down` | mesin mati |
| `halt` | `initctl cmd: 'force-poweroff'` → `FORCE shutdown (cmd=1126301404)` | `reboot: Power down` | mesin mati segera (tidak menunggu grace) |

`1126301404` = `0x4321FEDC` = `RB_POWER_OFF`, `19088743` = `0x01234567` =
`RB_AUTOBOOT`. Uji `reboot` dijalankan dengan `NO_REBOOT=0` supaya QEMU benar-
benar me-reset mesin; default `-no-reboot` membuat QEMU keluar saat guest minta
reboot (dipakai uji otomatis).

## Variabel lingkungan

`scripts/build-rootfs.sh`

| Variabel | Default | Arti |
|---|---|---|
| `DISTRO_DIR` | `distro` | direktori kerja |
| `BB_VERSION` / `BB_URL` / `BB_SHA256` | `1.36.1` / busybox.net / hash resmi | sumber BusyBox (kosongkan `BB_SHA256` untuk melewati verifikasi) |
| `BUSYBOX_MODE` | `auto` | `auto` \| `source` (wajib kompilasi) \| `prebuilt` (pakai `/bin/busybox` statis) |
| `BUSYBOX_PREBUILT` | `/bin/busybox` | cadangan bila kompilasi gagal |
| `BUSYBOX_FORCE` | `0` | `1` = unduh/kompilasi ulang |
| `NINIT` | `./ninit` | biner yang dipasang sebagai `/sbin/init` |
| `JOBS` | `nproc` | jumlah job `make` |

`scripts/run-qemu.sh`

| Variabel | Default | Arti |
|---|---|---|
| `SECS` | (kosong) | detik boot otomatis; tanpa ini QEMU interaktif |
| `KERNEL` / `KERNEL_MODE` | — / `auto` | kernel yang dipakai |
| `ALPINE_BRANCH` / `ALPINE_FLAVOR` | `v3.20` / `virt` | sumber kernel unduhan |
| `MEM` | `256` | RAM guest (MB) |
| `NO_REBOOT` | `1` | `0` = tanpa `-no-reboot`, sehingga reboot guest benar-benar me-reset mesin |
| `REBUILD` | `0` | `1` = bangun ulang rootfs dulu |
| `CONSOLE_LOG` | `distro/qemu-console.log` | rekaman konsol serial |

## Known Limitations

- **Input serial t=0 tidak andal.** Ketikan yang dialirkan lewat pipe pada detik
  ke-0 (mis. `printf … | run-qemu.sh`) sering termakan, sehingga perintah tidak
  pernah sampai ke guest. Beri jeda ~6 detik (`sleep 6`) atau ketik langsung di
  terminal.
- **Belum ada `getty`/`login`.** Yang berjalan masih shell konsol langsung
  (`console:respawn:cttyhack /bin/sh -i`) sebagai root, tanpa autentikasi.
- **Belum ada persistensi disk.** Hanya initramfs (RAM): tidak ada disk image,
  `-hda rootfs.img` belum dipakai, semua perubahan hilang saat boot ulang.
- **Kernel masih pinjam Alpine.** Kernel proyek ini belum dikompilasi sendiri;
  yang dipakai Alpine `vmlinuz-virt` (v3.20) yang diunduh ke `distro/cache/`.
- Belum ada manajer paket, jaringan, dan modul kernel; BusyBox dibangun dengan
  `defconfig` (402 applet).
- Belum ada job CI yang mem-boot QEMU (butuh `qemu-system-x86` + kernel; bisa
  ditambah sebagai job terpisah).
