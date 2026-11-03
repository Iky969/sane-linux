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
