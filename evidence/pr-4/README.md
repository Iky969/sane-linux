# Bukti verifikasi PR #4 (2026-11-04)

Enam tangkapan layar sesi terminal nyata (xterm di Xvfb, ditangkap `import`) pada head
`ea6e14a`; pembanding dibangun dari basis `eed4f05` (main pasca PR #2). Lingkungan sama
seperti bukti PR #3 (kernel 6.8.0-1064-azure, gcc 13.3.0, BusyBox 1.36.1 statis,
QEMU 8.2.2 TCG, kernel guest Alpine v3.20 `vmlinuz-virt`).

| berkas | isi |
|---|---|
| `01-head-dan-diff.png` | head + basis, `diff --stat`, mode berkas skrip basis vs PR, `git diff --summary` (perubahan mode yang tidak diumumkan) |
| `02-sisa-identitas-lama.png` | `git grep` penyebutan `ninit-distro`/`distro ninit` di seluruh pohon PR (bersih) vs basis (masih ada), plus jumlah kemunculan nama komponen yang sengaja tidak diubah |
| `03-build-rootfs-dan-initramfs.png` | build rootfs mode prebuilt, isi `/etc/hostname`, ekstrak `initramfs.cpio.gz` dan baca `etc/hostname` dari dalamnya, override `HOSTNAME_NAME=` |
| `04-qemu-boot-hostname.png` | boot distro di QEMU: log `ninit: hostname = S.A.N.E`, lalu dari serial console `uname -n`, `cat /etc/hostname`, `ls -l /sbin/init`, shutdown rapi |
| `05-make-test-hijau-104.png` | tiga suite pada head PR #4: 6 + 14 + 84 = 104 pemeriksaan, 0 GAGAL |
| `06-bit-exec-hilang.png` | konsekuensi temuan PR4-C1: `./scripts/build-rootfs.sh` ditolak, sedangkan basis dan Makefile/CI (`sh ./scripts/...`) tidak terpengaruh |

## Kesimpulan: layak merge setelah satu baris perbaikan

Semua klaim branding terverifikasi sampai ke dalam guest yang benar-benar di-boot. Satu
perubahan tak terduga masuk ke diff dan sebaiknya dipulihkan sebelum merge.

| klaim PR #4 | hasil verifikasi |
|---|---|
| `HOSTNAME_NAME` bawaan menjadi `S.A.N.E` | LULUS — `distro/rootfs/etc/hostname` dan salinan di dalam `initramfs.cpio.gz` sama-sama berisi `S.A.N.E` (`03`) |
| override `HOSTNAME_NAME=...` tetap bisa | LULUS — build dengan `HOSTNAME_NAME=uji-override` menulis nilai itu apa adanya (`03`) |
| ninit memasangnya saat boot (`hostname = S.A.N.E`) | LULUS — baris log itu muncul dari dalam guest, dan `uname -n` di serial console menjawab `S.A.N.E` (`04`) |
| tidak ada lagi `ninit-distro` / "distro ninit" di repo | LULUS — `git grep` pada pohon PR kosong; pada basis masih ada (`02`) |
| nama komponen ninit tidak diubah | LULUS — `ninit.c`, `/sbin/init`, `/etc/init.conf`, `/var/log/ninit.log`, cgroup `ninit/` tetap utuh; `/sbin/init` di guest adalah ninit 989152 byte (`02`, `04`) |
| `make test` hijau penuh (104 pemeriksaan) | LULUS — 104/104, 0 GAGAL (`05`) |
| `doc/distro-builder.md` cocok dengan kenyataan | LULUS — contoh keluaran `hostname = S.A.N.E` dan `cat /etc/hostname` = `S.A.N.E` direproduksi persis (`04`) |
| "tidak ada perubahan perilaku selain hostname bawaan" | **TIDAK SEPENUHNYA BENAR** — lihat PR4-C1 |

## Catatan

**PR4-C1 (perlu diperbaiki sebelum merge) — bit executable dua skrip hilang.**
`git diff --summary eed4f05..ea6e14a` mencatat `mode change 100755 => 100644` untuk
`scripts/build-rootfs.sh` dan `scripts/run-qemu.sh`. Makefile dan CI memanggil
`sh ./scripts/...` sehingga semua tetap hijau, tetapi pemanggilan langsung seperti yang
terdokumentasi di kepala skrip (`./scripts/build-rootfs.sh`) kini `Permission denied`
(`06`). Ini perubahan perilaku di luar yang diumumkan PR. Perbaikan satu baris:
`git update-index --chmod=+x scripts/build-rootfs.sh scripts/run-qemu.sh`.

**PR4-C2 (nit) — "~600 baris" di README.** Kalimat yang disentuh PR ini menyebut
`ninit.c` ~600 baris; faktanya 1051 baris pada head ini. Sekalian dikoreksi agar
perkenalan S.A.N.E tidak membawa angka lama.

**PR4-C3 (nit) — mode prebuilt di sandbox.** Build lokal memakai `BUSYBOX_MODE=prebuilt`
(`/bin/busybox` statis) karena lebih cepat; CI menjalankan `BUSYBOX_MODE=auto` dari
sumber dan `rootfs-distro` LULUS (2 job pass, run 41785859228). `mknod` di lingkungan ini
bisa dijalankan sebagai root, jadi rootfs yang dibuktikan di sini memakai node `/dev`
asli — catatan "shim mknod" pada body PR tidak diperlukan di sini dan tidak memengaruhi
berkas yang di-commit.

## Verifikasi gabungan PR #3 + PR #4

Kedua PR berbasis `eed4f05` dan tidak menyentuh satu berkas pun yang sama
(`ninit.c`/`test-config.sh`/`doc/configuration.md` vs `README.md`/`doc/distro-builder.md`/
`build-rootfs.sh`/`run-qemu.sh`), sehingga merge-nya bersih tanpa konflik. Pada merge
`5606bb4`: build `-Wall -Wextra -Werror` nol warning, `test-config.sh` 84/84 LULUS
(skenario 13 ikut), dan satu boot QEMU serentak menunjukkan `hostname = S.A.N.E`
(branding PR #4) bersama mount rekursif fstab (perbaikan PR #3). Urutan merge tidak
menentukan hasil. Bukti: `../gabungan/01-merge-pr3-pr4.png`.
