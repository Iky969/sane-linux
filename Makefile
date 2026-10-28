# ninit -- init system minimal (PID 1)
#
#   make            bangun biner statis ./ninit  (gcc -static -O2 -Wall)
#   make test       uji PID 1 di chroot sementara: smoke test + test SIGTERM
#                   + test konfigurasi (butuh root/sudo)
#   make rootfs     bangun rootfs distro minimal + initramfs (busybox statis,
#                   ninit sebagai /sbin/init; lihat doc/distro-builder.md)
#   make qemu       boot rootfs itu di QEMU (butuh qemu-system-x86)
#   make clean      hapus biner hasil build
#
# Butuh: build-essential + busybox-static (busybox dipakai sebagai /bin/sh di rootfs uji).
# Di distro tanpa libc statis glibc (mis. Alpine):  make CC=musl-gcc

CC     = gcc
CFLAGS ?= -static -O2 -Wall
BIN    ?= ninit
SRC    ?= ninit.c

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

test: $(BIN)
	sh ./scripts/smoke-test.sh
	sh ./scripts/test-sigterm.sh
	sh ./scripts/test-config.sh

rootfs:
	sh ./scripts/build-rootfs.sh

qemu: rootfs
	sh ./scripts/run-qemu.sh

clean:
	rm -f $(BIN)

clean-distro:
	rm -rf distro/rootfs distro/build distro/cache distro/initramfs.cpio.gz \
	       distro/qemu-console.log distro/qemu.log

.PHONY: all test rootfs qemu clean clean-distro
