# ninit -- minimal init system (PID 1)
#
#   make            build static binary ./ninit  (gcc -static -O2 -Wall)
#   make test       test PID 1 in temporary chroot: smoke test + SIGTERM test
#                   + config test + spawn failure paths + cgroup v2 limits
#                   + respawn cleanup / generation counter reset
#                   (requires root/sudo), then run-qemu.sh
#                   harness verification via log fixtures (without root/QEMU)
#   make rootfs     build minimal distro rootfs + initramfs (static busybox,
#                   ninit as /sbin/init; see doc/distro-builder.md)
#   make qemu       boot rootfs in QEMU (requires qemu-system-x86)
#   make integration  cross-layer integration test fstab<->kernel<->services
#                   via one real QEMU boot (requires root + qemu-system-x86)
#   make lint       run python linter on log patterns, markers, and format specifiers
#   make clean      remove built binary
#   make clean-distro remove distro build artifacts
#
# Requires: build-essential + busybox-static (busybox used as /bin/sh in test rootfs).
# On distros without static glibc (e.g. Alpine):  make CC=musl-gcc
# Note: -Werror is omitted from default CFLAGS for compatibility across compiler toolchains;
# CI overrides CFLAGS with -Werror to enforce the zero-warning gate.

CC     = gcc
CFLAGS ?= -static -O2 -Wall
BIN    ?= ninit
SRC    ?= ninit.c

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

TEST_SCRIPTS := scripts/smoke-test.sh scripts/test-sigterm.sh scripts/test-config.sh \
                scripts/test-qemu-report.sh scripts/test-spawn-failure.sh \
                scripts/test-cgroup-limits.sh scripts/test-respawn-cleanup.sh

test: $(BIN)
	@PRE_CGROUPS=$$(ls -d /sys/fs/cgroup/ninit* 2>/dev/null || true); \
	for t in $(TEST_SCRIPTS); do sh ./$$t || exit 1; done; \
	POST_CGROUPS=$$(ls -d /sys/fs/cgroup/ninit* 2>/dev/null || true); \
	if [ "$$PRE_CGROUPS" != "$$POST_CGROUPS" ]; then \
		echo "FAIL: new lingering cgroups detected in /sys/fs/cgroup/ninit*:" >&2; \
		echo "Before: $$PRE_CGROUPS" >&2; \
		echo "After : $$POST_CGROUPS" >&2; \
		exit 1; \
	fi

rootfs:
	sh ./scripts/build-rootfs.sh

qemu: rootfs
	sh ./scripts/run-qemu.sh

integration: $(BIN)
	sh ./scripts/test-integration.sh

clean:
	rm -f $(BIN)

clean-distro:
	rm -rf distro/rootfs distro/build distro/cache distro/initramfs.cpio.gz \
	       distro/qemu-console.log distro/qemu.log

lint:
	python3 ./scripts/lint-log-patterns.py
	python3 ./scripts/verify-format-strings.py

.PHONY: all test rootfs qemu integration clean clean-distro lint
