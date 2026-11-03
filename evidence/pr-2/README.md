# Bukti verifikasi PR #2 (2026-11-03)

Enam tangkapan layar sesi terminal nyata (xterm di Xvfb) yang menjalankan
perintah sungguhan pada head PR `6af0ed3`:

| berkas | isi |
|---|---|
| `01-chroot-smoke.png` | `scripts/smoke-test.sh` — ninit sebagai PID 1 di chroot + namespace |
| `02-sigterm-sane01.png` | `scripts/test-sigterm.sh` — 3 skenario, termasuk regresi SANE-01 |
| `03-config-sane03.png` | `scripts/test-config.sh` — 9 skenario, termasuk penolakan config panjang |
| `04-proot-distro.png` | baterai distro penuh di **proot** pada rootfs pristine (12/12 LULUS) |
| `05-ab-mount-sane02.png` | harness A/B SANE-02: biner pra-PR vs pasca-PR pada `/etc/fstab` yang sama |
| `06-qemu-distro-shutdown.png` | boot distro penuh di **QEMU**: laporan `[DISTRO]`, fstab, garis waktu shutdown SANE-01 |

Gambar adalah output mentah dari perintah di atas, hanya difilter agar muat di
layar terminal; tidak ada yang direkayasa.

## Ronde 2 — commit `94499b8` (perluasan klasifikasi opsi fstab)

| berkas | isi |
|---|---|
| `round2/10-head-info.png` | head, md5 biner uji, md5 `/sbin/init` di rootfs, lingkungan |
| `round2/11-suite-bawaan.png` | smoke-test + test-sigterm (skenario 3 dengan pelacakan PID anak) |
| `round2/12-config-skenario-10-11.png` | skenario baru: klasifikasi opsi fstab + batas baris di EOF |
| `round2/13-probe-fstab-10-kasus.png` | probe mandiri 10 kasus opsi fstab, biner pra- vs pasca-`94499b8` |
| `round2/14-proot-distro.png` | baterai distro di proot (12/12) |
| `round2/15-qemu-distro-shutdown.png` | boot distro di QEMU: laporan guest + garis waktu shutdown |
| `round2/16-gap-yang-ditemukan.png` | gap yang masih tersisa (`exec/suid/dev`, implikasi `user`) |
