### Audit PR #32 — `Reliability & recovery update`

Repository: Iky969/sane-linux · Base: `main` · Head: `483b14f`

PR ini menggabungkan enam commit dengan cakupan cukup besar: validasi kebijakan `doas`, penguatan restore dan symlink containment, lock untuk operasi reliability, pemulihan crash window, perlindungan self-state saat upgrade, serta integrasi recovery ke boot.

Status awal: PR terbuka dan GitHub melaporkan `mergeable: true`. Lima workflow yang terkait dengan commit head berstatus sukses. Itu sinyal positif, tetapi belum cukup untuk menyimpulkan tidak ada bug.

### Temuan

P1 · Don't merge

### 1\. Restore dapat merusak eksklusivitas state lock

Lokasi: `scripts/sane-reliability`

* Baris 611–612 — `cmd_backup()` mengarsipkan seluruh `var/lib/sane/reliability`, termasuk direktori `lock/` dan `lock/pid`.

* Baris 680–683 — `cmd_restore()` menyalin seluruh isi arsip kembali ke `$STATE`.

* Baris 789–792 — lock aktif dimiliki oleh PID proses restore dan dilepas melalui EXIT trap.

Masalahnya: arsip backup membawa PID proses backup yang sudah selesai. Ketika restore menyalin arsip tersebut, `lock/pid` milik proses restore dapat tertimpa PID lama.

Akibatnya, mutator lain dapat menganggap lock sedang stale, mengambil alih lock, lalu mengubah state ketika restore masih berlangsung.

Ini membatalkan jaminan serialisasi yang justru menjadi salah satu fitur utama PR ini.

Perbaikan:

* Jangan masukkan `lock/` ke dalam backup.

* Tolak atau abaikan entri `lock/` saat restore.

* Tambahkan regresi: backup → restore → pastikan PID lock tetap milik proses restore → proses mutator kedua harus gagal menembus lock sampai restore selesai.

P2 · Perlu diperbaiki

### 2\. Rollback tidak mempertahankan tipe file symlink

Lokasi: `scripts/sane-reliability`, baris 259–263 dan 274–276.

PR mengizinkan symlink yang tetap berada di dalam target root. Namun, saat snapshot:

```sh
[ -f "$src" ] || continue
cp -p "$src" "$ds_tmp/$rel"
```

`cp -p` mengikuti symlink pada sumber dan menyimpan isi file target sebagai file biasa.

Kemudian upgrade mengganti symlink tersebut dengan file payload. Saat rollback, file biasa hasil snapshot dipasang kembali.

Dampak: konten file mungkin kembali benar, tetapi symlink aslinya hilang. Struktur filesystem tidak kembali ke keadaan sebelum upgrade.

Perbaikan:

* Simpan metadata tipe file dan target symlink dalam snapshot, lalu pulihkan keduanya.

* Alternatif yang lebih sederhana: tolak payload yang menargetkan final-component symlink.

* Tambahkan tes upgrade dan rollback terhadap symlink internal-root, termasuk pemeriksaan bahwa tipe dan target symlink tetap sama.

P2 · Perlu diperbaiki

### 3\. Pemindaian `nopass` terlalu luas dan dapat memicu recovery yang tidak diperlukan

Lokasi: `scripts/sane-accounts`, sekitar baris 494–500.

Pemindaian sekarang memeriksa setiap token setelah `permit`:

```awk
$1 == "permit" {
    for (i = 2; i <= NF; i++)
        if ($i == "nopass") bad = 1
}
```

Masalahnya, token setelah `cmd` dapat merupakan argumen perintah, bukan opsi doas.

Contoh aturan dengan argumen `nopass`:

```text
permit :wheel cmd /usr/bin/echo nopass
```

Pemindaian ini akan menganggapnya sebagai pemberian akses tanpa password.

Dampaknya lebih besar daripada sekadar false positive: `sane-account-recovery` menjalankan `validate`, lalu melakukan rebuild ketika validasi gagal. Konfigurasi `doas.conf` yang sebenarnya valid berpotensi tertimpa baseline.

Perbaikan: buat pemindaian memahami batas bagian opsi dan bagian `cmd`/`as`, bukan memeriksa semua token secara global. Tambahkan tes yang membuktikan argumen perintah bernama `nopass` tidak dianggap sebagai opsi.

### Hal positif yang sudah diperiksa

* Perlindungan self-state upgrade sekarang mencakup variasi path non-kanonik seperti `var/./lib/...` dan `usr/bin//...`.

* Pemeriksaan symlink chain memiliki batas hop dan pengujian untuk chain internal maupun yang keluar dari root.

* Restore tidak lagi mempercayai journal arsip dan memaksanya kembali ke `idle`.

* Lock menggunakan `mkdir` atomik, mendukung nested call, dan mempunyai stale-lock handling.

* Integrasi `reliability:once` terlihat konsisten pada ketiga builder yang diperiksa.

* Pengujian baru mencakup banyak kasus yang sebelumnya tidak diuji.

### Status verifikasi

| Pemeriksaan                          | Hasil                           |
| ------------------------------------ | ------------------------------- |
| PR state                             | Open                            |
| Mergeable menurut GitHub             | Ya                              |
| Workflow terkait commit head         | 5/5 sukses                      |
| Test reliability                     | 315 passed, 0 failed — klaim PR |
| Test accounts                        | 165 passed, 0 failed — klaim PR |
| Pengujian ulang independen oleh saya | Tidak dilakukan                 |

CI sukses tidak meniadakan tiga temuan di atas. Audit ini merupakan pemeriksaan statis terhadap source pada head `483b14f2ad195f5c973ce28d098f3958f800623d`, bukan hasil eksekusi ulang test suite.

### Verdict

Don't merge

PR #32 membawa perbaikan yang cukup matang dan cakupannya terarah, tetapi masalah lock pada backup/restore merupakan blocker serius. Dua temuan lainnya juga perlu diselesaikan sebelum dianggap aman untuk integrasi.

Urutan prioritas perbaikan yang kusarankan:

* P1: keluarkan lock dari backup dan lindungi lock aktif selama restore.

* P2: pertahankan tipe symlink saat snapshot dan rollback.

* P2: perbaiki pemindaian `nopass` agar tidak salah mengidentifikasi argumen command.

* Tambahkan regresi untuk ketiganya, lalu jalankan ulang CI.

