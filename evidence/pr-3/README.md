# Bukti verifikasi PR #3 (2026-11-04)

Tujuh tangkapan layar sesi terminal nyata (xterm di Xvfb, ditangkap `import`) yang
menjalankan perintah sungguhan pada head `f5f23b4`; pembanding A/B dibangun dari
basis `eed4f05` (main pasca PR #2). Gambar adalah output mentah perintah di atas,
hanya difilter agar muat di layar; tidak ada yang direkayasa.

Lingkungan: kernel 6.8.0-1064-azure, gcc 13.3.0, biner statis (`readelf -l`: 0 INTERP),
BusyBox 1.36.1 statis, QEMU 8.2.2 mode TCG (tanpa `/dev/kvm`), kernel guest Alpine
v3.20 `vmlinuz-virt`.

| berkas | isi |
|---|---|
| `01-head-dan-build.png` | head + basis, lingkungan, build `-static -O2 -Wall -Wextra -Werror` nol warning, md5 biner PR dan biner basis |
| `02-suite-smoke-sigterm.png` | `smoke-test.sh` + `test-sigterm.sh` (3 skenario, termasuk regresi SANE-01) dengan sudo |
| `03-config-skenario-13.png` | `test-config.sh` penuh: 26 pemeriksaan skenario 13 + ringkasan 84/84 LULUS |
| `04-ab-biner-basis-vs-pr3.png` | A/B non-vacuous: skrip PR #3 pada biner basis `eed4f05` vs biner PR, plus baris log fstab biner basis |
| `05-qemu-probe-tambahan-pid1.png` | probe independen di luar skenario 13, dijalankan `ninit` sebagai PID 1 sungguhan di QEMU |
| `06-probe-slash-ganda-dan-root.png` | probe slash ganda/trailing dan mountpoint `/` pada kedua biner (harness namespace test-config) |
| `07-probe-mode-direktori-lama.png` | probe mode: mountpoint 0700 yang sudah ada tidak di-chmod ulang, hanya direktori baru menjadi 0755 |

Lihat juga `../gabungan/01-merge-pr3-pr4.png` (PR #3 dan PR #4 digabung dan di-boot
bersama).

## Kesimpulan: layak merge

Semua klaim PR terverifikasi, dan dua temuan baru (non-blocking) ditemukan oleh probe
independen di butir *Catatan* di bawah.

| klaim PR #3 | hasil verifikasi |
|---|---|
| build bersih `-Wall -Werror` | LULUS — nol warning bahkan dengan `-Wextra` (`01`) |
| `make test` hijau penuh | LULUS — 104 pemeriksaan (6 smoke + 14 sigterm + 84 config), 0 GAGAL (`02`, `03`) |
| skenario 13 baru, 26 pemeriksaan | LULUS semua, termasuk bukti sisi host dan `/proc/mounts` guest (`03`) |
| A/B non-vacuous: biner basis "GAGAL 10 pemeriksaan" | LULUS — biner basis `eed4f05` GAGAL **13** pemeriksaan skenario 13 di lingkungan ini; biner PR lulus 26/26 (`04`) |
| mkdir rekursif + mode 0755 bebas umask | LULUS — jalur 25 tingkat `/a/b/.../aa/bb` dibuat dan di-mount oleh PID 1; mode 0755 bertahan dengan umask guest 077 (`03`, `05`) |
| bind/rbind ditolak sebelum mountpoint dibuat | LULUS — `bind` dan `rbind` menghasilkan `dilewati (bind/rbind tidak didukung)` dan `/var/lib/tidakada` tidak pernah ada di guest (`05`) |
| `.`/`..` ditolak tanpa direktori hantu | LULUS — `/root/../evil` ditolak pra-pindai; `ls -d /evil` tidak ada (`05`) |
| keputusan flag vs data terpisah benar | LULUS — `size=1M,ro,nosuid` menghasilkan `ro,nosuid` di `/proc/mounts` dan hanya `size=1M` yang dikirim sebagai data (`05`) |
| doc sinkron dengan kode | LULUS — tabel opsi, implikasi `user`/`owner`, mountpoint rekursif, dan *Batasan yang diketahui* cocok dengan perilaku teramati |
| (di luar klaim PR) slash ganda, trailing slash, mountpoint `/` | LULUS — `/mnt//data//dup` dibuat dan ter-mount `rw,size=1M` sedangkan biner basis gagal `ENOENT` pada baris yang sama; mountpoint `/` tidak membuat apa pun dan `mount()` ditolak `EINVAL` tanpa efek samping (`06`) |

## Catatan (temuan baru, tidak memblokir merge)

**PR3-C1 (sedang) — escape oktal fstab tidak didekode.** `mount(8)` menafsirkan `\040`
dan `\011` di kolom mountpoint sebagai spasi dan tab. ninit memperlakukannya sebagai
harfiah: baris `tmpfs /mnt/t\040spaced tmpfs size=1M` membuat direktori bernama
`t\040spaced` dan **mount succeeds** di path yang bukan dimaksud penulis fstab (lihat
`ls /mnt` pada `05`). Bukan eskalasi hak (`/etc/fstab` milik root), tapi hasil diam-diam
berbeda dari `mount -a`. Pilihan murah: dekode `\040 \011 \012 \134` di tokenizer, atau
tulis di `doc/configuration.md` bahwa escape tidak didukung dan karakter itu ditolak.

**PR3-C2 (sedang) — mountpoint duplikat ditumpuk tanpa peringatan.** Dua baris fstab
dengan mountpoint sama keduanya `ok`; mount kedua (`rw,size=2M`) menutupi yang pertama
(`ro,nosuid,size=1M`) sehingga proteksi baris pertama hilang diam-diam — `/proc/mounts`
guest pada `05` menampilkan dua entri dan yang aktif adalah `rw`. `mount -a` melewatkan
yang sudah ter-mount. Saran: lewati mountpoint yang sudah ada di `/proc/mounts`, atau
catat tabrakan itu di log.

**PR3-C3 (nit) — angka "104 pemeriksaan test-config".** `test-config.sh` sendiri berisi
84 pemeriksaan; 104 adalah total tiga suite (6 + 14 + 84). Totalnya tereproduksi persis,
hanya labelnya.

**PR3-C4 (nit) — suite butuh sudo penuh.** Dijalankan tanpa root, `test-config.sh`
skenario 4b dan dua pemeriksaan `test-sigterm.sh` skenario 3 GAGAL karena `kill -0` dan
pembacaan `/proc/<pid>/status` proses milik root. Ini bukan regresi PR: biner basis
`eed4f05` gagal identik pada pemeriksaan yang sama. CI sudah memakai `sudo sh ./scripts/...`.

## Tinjauan kode `mkdir_p()` / `parse_mount_flags()`

- Batas buffer aman: baris fstab dibatasi `MAX_LINE` (1024) sehingga token mountpoint
  paling panjang 1023 karakter — `len >= sizeof(buf)` tidak pernah menolak path sah,
  dan `memcpy(buf, path, len + 1)` pas mengisi.
- `chmod(0755)` hanya untuk direktori yang BARU dibuat; kegagalan chmod menggagalkan
  entri. Komponen yang sudah ada diverifikasi `stat()` (mengikuti symlink).
- Pra-pindai `.`/`..` terjadi sebelum `mkdir` pertama, jadi penolakan tidak meninggalkan
  direktori induk.
- Keputusan `SKIP_NOAUTO`/`SKIP_BIND` dievaluasi pemanggil sebelum mountpoint dibuat;
  `noauto` menang atas `bind` bila keduanya muncul (dijelaskan dan diuji di f4b).
- Satu-satunya sisa direktori hantu yang mungkin: `mount()` gagal setelah direktori
  berhasil dibuat — sudah didokumentasikan eksplisit di `doc/configuration.md`.
- Slash ganda, trailing slash, dan mountpoint `/` ditangani jalur EEXIST + stat (`06`).
  Dites terpisah: direktori yang sudah ada TIDAK di-chmod ulang — mountpoint 0700 dan
  0755 yang sudah ada sebelum boot tetap pada mode aslinya, hanya direktori baru yang
  menjadi 0755.
