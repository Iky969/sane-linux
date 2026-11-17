# clawrza self-hosting toolchain recipes (S.A.N.E spm format)

Three source recipes that let a S.A.N.E operator stage a native C toolchain
into a separate sysroot: `clawrza-glibc-headers`, `clawrza-binutils`,
`clawrza-gcc`.

## What is actually shipped

Each `.spm` payload installs **only** a `RECIPE` and a `build.sh` under
`/usr/share/clawrza/recipes/`. No compiler binary, no `libc.so`, and no
`crt*.o` is installed into a running S.A.N.E rootfs. The live rootfs stays
musl-based; there is no collision with `musl`'s libc files.

`RECIPE` records: upstream URL, version, pinned SHA-256 of the tarball,
`build_order`, `stage`, `seed_toolchain`, and dependencies (where applicable).
`build.sh` fetches atomically, verifies the digest, then builds into a sysroot.

## Bootstrap model (host vs guest)

These recipes run on a **host** that already has a seed C toolchain
(`gcc`, `make`, `binutils`) plus `gawk`, `bison`, `python3`, `curl` and
`sha256sum`. glibc 2.41 configure hard-fails without `gawk`; `build.sh`
runs a preflight check for these tools. They bootstrap a *separate* sysroot;
they are not run inside a pristine S.A.N.E musl guest.

```
host seed toolchain
   └─ kernel headers staged manually into $DESTDIR/usr/include
        └─ build_order 1: clawrza-glibc-headers  (make install-headers ONLY)
             └─ build_order 2: clawrza-binutils (as, ld, ar)
                  └─ build_order 3: clawrza-gcc  (C only)
```

`clawrza-glibc-headers` uses `make install-headers install_root=$DESTDIR`, not
a full glibc `make install`, so it never drops `libc.so`/`crt1.o` into the
target. It then creates the empty `gnu/stubs.h` that glibc's manual header
bootstrap requires (`install-headers` does not generate it) and finishes with
a smoke compile of `#include <stdio.h>` against the resulting sysroot.

There is deliberately **no** `kernel-headers` spm package in this repo: stage kernel headers manually before running the recipe, and note that
`.META/depends` for the headers package is empty on purpose.

GCC uses `--disable-bootstrap`, so the final compiler is produced by the host's
seed compiler. This is a fast, deterministic bootstrap, not a strict
"compiler builds itself from stage-1" claim. Once installed, the toolchain is
self-hosting: the independent `Iky969/clawrza-glibc-selfhost` image proves that
`kinit` and `spkg` recompile inside QEMU with byte-identical SHA-256.
`--with-system-zlib` is intentionally omitted to avoid an undeclared host
`zlib.h`/`libz` build dependency. The gcc recipe does not hardcode an rpath;
the guest exports `LD_LIBRARY_PATH` and `GCC_EXEC_PREFIX` at boot instead.
The binutils recipe uses `--disable-shared`, keeping `ld`/`as` hermetic rather
than giving the bootstrap linker its own shared-library dependencies.

## Usage after installation

Install in dependency order (spm enforces it):

```sh
spm install /distro/packages/clawrza-glibc-headers-2.41-1-x86_64.spm.tar.xz
spm install /distro/packages/clawrza-binutils-2.44-1-x86_64.spm.tar.xz
spm install /distro/packages/clawrza-gcc-14.2.0-1-x86_64.spm.tar.xz
```

Then invoke a recipe against an **absolute** sysroot path:

```sh
DESTDIR=/opt/selfhost-sysroot \
WORK=/tmp/clawrza-gcc-build \
sh /usr/share/clawrza/recipes/gcc/build.sh "$DESTDIR"
```

`build.sh` canonicalises `DESTDIR` before any `cd`, fetches
`$TARBALL.part` with `curl -fSL --retry 3` and renames only after a successful
download, re-verifies SHA-256, then wipes stale `src/`/`build/` trees before
extracting/configuring so reruns are deterministic.

## Building the packages

```sh
make clawrza
# or: bash packages/clawrza-build-all.sh
```

They are intentionally separate from `make packages` (the musl base set).
Each package is emitted as a deterministic `.spm.tar.xz` with generated
`.META/files` and `.META/sha256` manifests via `scripts/build-package.sh`.
