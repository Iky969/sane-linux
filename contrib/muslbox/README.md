# contrib/muslbox

Two reusable pieces from the independent MUSLBOX build, offered to S.A.N.E as
reviewable contributions. Nothing here modifies `scripts/spm`: S.A.N.E's shell
package manager already has its own tar-slip, symlink, parity and SHA-256
guards. These are additions, not replacements.

## 1. `safe_path()` module

`safe_path.h` + `safe_path.c` is the path guard extracted from MUSLBOX's
`src/mbpm.c`, where it protects package extraction from traversal. Rules:

- reject empty or absolute paths,
- reject any `..` component,
- allow only `[A-Za-z0-9._/-+]`.

It mattered in practice: `mbpm install` writes through destination symlinks
with `cp -a`, so a package that installs `/sbin/init` over busybox's
`/sbin/init -> ../bin/busybox` link will clobber `/bin/busybox` unless the
destination is removed first. MUSLBOX now removes every manifest-listed
destination before copying; `safe_path()` is the first half of that defence.

Verify:

```sh
cd contrib/muslbox
cc -Wall -Wextra -Werror safe_path.c test-safe-path.c -o /tmp/t && /tmp/t
```

## 2. Static `httpsget` recipe

`httpsget/` builds a dependency-free HTTPS GET client with musl-gcc and
mbedTLS 3.6.8, pinned by URL + SHA256. It produces one static ELF (no
`PT_INTERP`), suitable for a minimal initramfs where there is no dynamic
loader and no shared libraries.

```sh
cd contrib/muslbox/httpsget
chmod +x build.sh
JOBS=$(nproc) ./build.sh
./httpsget https://api.github.com/zen /path/to/ca-bundle.crt
```

Verified in a QEMU guest with a 6-root / 8.3 KB CA bundle:

```
HTTP/1.1 200 OK      api.github.com/zen
HTTP/1.1 200 OK      example.com/  (body contains "Example Domain")
```

Two host details worth keeping:

- mbedTLS 3.6.8 release tarballs still ship `library/Makefile` and
  `framework/exported.make`, so `cmake` is not required; pass the private
  UAPI include dir through `CC="musl-gcc -I$DIR"` if the headers are needed,
  never through `CPPFLAGS` (that drops the build system's own `-Iinclude`).
- QEMU user-mode DNS is at `10.0.2.3` here; `10.0.2.2` is the gateway and did
  not answer musl's DNS queries.
