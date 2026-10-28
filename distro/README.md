# distro/ — hasil *distro builder*

Folder ini adalah direktori kerja `scripts/build-rootfs.sh` dan
`scripts/run-qemu.sh`. Isinya **dihasilkan** (tidak di-commit; lihat
`.gitignore`):

```
cache/              tarball BusyBox + kernel Alpine unduhan (+ .sha256)
build/              sumber BusyBox yang sudah dikompilasi + hasil `make install`
rootfs/             rootfs jadi: busybox statis, /sbin/init (ninit), /etc, /dev, …
initramfs.cpio.gz   rootfs terbungkus (yang di-boot QEMU)
qemu-console.log    rekaman konsol serial guest dari `SECS=… make qemu`
qemu.log            keluaran QEMU sendiri (bukan guest)
```

```bash
make rootfs          # bangun ulang isi folder ini
SECS=5 make qemu     # boot 5 detik + pemeriksaan penanda boot
make clean-distro    # hapus semua artefak di atas
```

Penjelasan lengkap: [../doc/distro-builder.md](../doc/distro-builder.md).
