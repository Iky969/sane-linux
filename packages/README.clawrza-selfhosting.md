# clawrza self-hosting toolchain recipes (S.A.N.E spm format)

Three source recipes that let a S.A.N.E rootfs rebuild its own native C
toolchain: `clawrza-glibc-headers`, `clawrza-binutils`, `clawrza-gcc`.

These are **recipes**, not prebuilt compiler binaries: each payload installs a
`RECIPE` (upstream URL, version, pinned SHA-256, build order, dependencies) and
a `build.sh` that fetches, verifies, configures and installs into `$DESTDIR`.

Build order:

```
linux kernel headers -> clawrza-glibc-headers -> clawrza-binutils -> clawrza-gcc
```

The GCC recipe intentionally uses `--enable-languages=c`,
`--with-native-system-header-dir=/usr/include` and
`--with-build-sysroot="$DESTDIR"`; it reproduces the toolchain that was booted
in the independent `clawrza-glibc-selfhost` QEMU image.

Build the packages:

```sh
bash packages/clawrza-build-all.sh
```

Each package is emitted as a deterministic `.spm.tar.xz` with generated
`.META/files` and `.META/sha256` manifests via `scripts/build-package.sh`.
