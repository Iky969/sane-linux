# Third-Party Components and License Notices

S.A.N.E Linux ships binaries produced by upstream projects. The project's own
source is MIT-licensed ([LICENSE](LICENSE)); the components below keep their
upstream licenses. This notice accompanies distributed rootfs, initramfs and
raw disk images. Full license texts are available at the upstream source URLs.

| Component | S.A.N.E package version | License | Upstream source |
|---|---|---|---|
| BusyBox | 1.36.1 | GPL-2.0-only | <https://busybox.net/downloads/busybox-1.36.1.tar.bz2> (see upstream `LICENSE`) |
| Linux kernel (`bzImage`/`vmlinuz-virt`) | 6.6.134 | GPL-2.0-only | <https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.134.tar.xz>; binary from Alpine v3.20.10 netboot, patches in <https://git.alpinelinux.org/aports/> |
| LibreSSL | 3.9.2 | ISC (includes OpenSSL-derived code) | <https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-3.9.2.tar.gz> |
| curl | 8.11.0 | curl license (MIT/X derivative) | <https://curl.se/download/curl-8.11.0.tar.xz>, <https://curl.se/docs/copyright.html> |
| wpa_supplicant | 2.10 | BSD-3-Clause (GPL-2.0 alternative) | <https://w1.fi/releases/wpa_supplicant-2.10.tar.gz> |
| musl libc (headers and static objects) | 1.2.5 | MIT | <https://musl.libc.org/releases/musl-1.2.5.tar.gz> |
| doas (OpenDoas) | 6.8.2 | ISC | <https://github.com/Duncaen/OpenDoas/releases/download/v6.8.2/opendoas-6.8.2.tar.gz> |
| Limine bootloader (BIOS/UEFI payloads) | 12.9.6 | BSD-2-Clause | <https://github.com/Limine-Bootloader/Limine/releases/download/v12.9.6/limine-binary.tar.xz> (license in upstream `COPYING`) |
| ca-certificates bundle | 2024.11 (S.A.N.E package; upstream bundle varies by build host, e.g. `20250419+deb13u1`) | Individual CA terms; Debian `ca-certificates` packaging GPL-2.0+ | <https://salsa.debian.org/debian/ca-certificates> |
| disk-tools (`sgdisk`, `mke2fs`, `mkfs.fat`) | 1.0.0 (S.A.N.E package; upstream tool versions vary by build host) | GPL-2.0 (gptfdisk, e2fsprogs), GPL-3.0 (dosfstools) | <https://sourceforge.net/projects/gptfdisk/>, <https://e2fsprogs.sourceforge.net/>, <https://github.com/dosfstools/dosfstools> |

Notes:

- BusyBox contains a few files under other permissive licenses; the upstream
  `LICENSE` file shipped with the exact source revision is authoritative.
- Packages named `clawrza-*` are maintained by this project's author in
  <https://github.com/Iky969/clawrza-glibc-selfhost> and are not third-party to
  S.A.N.E Linux. They are built from upstream toolchain sources whose licenses
  (GPL-3.0 with exceptions for GCC, LGPL-2.1 for glibc, GPL-3.0 for binutils)
  apply to those toolchain packages when redistributed separately.
- `ninit`, `spm`, the installer and the account/network/reliability scripts are
  original MIT-licensed code in this repository.
- If you redistribute an image, include this notice together with `LICENSE`
  and make the corresponding upstream source available as required by each
  license above.
