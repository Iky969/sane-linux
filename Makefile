# ninit -- init system minimal (PID 1)
#
#   make            bangun biner statis ./ninit  (gcc -static -O2 -Wall)
#   make test       smoke test PID 1 di chroot sementara (butuh root/sudo)
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

clean:
	rm -f $(BIN)

.PHONY: all test clean
