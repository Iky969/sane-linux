# ninit -- minimal init system (PID 1)
#
#   make            build static binary ./ninit  (gcc -static -O2 -Wall)
#   make ninit-test build the test binary (production flags + -DNINIT_TESTING)
#   make test       test PID 1 in temporary chroot with ./ninit-test: smoke test
#                   + SIGTERM test + config test + spawn failure paths + cgroup v2
#                   limits + respawn cleanup / generation counter reset + state
#                   machine (requires root/sudo), then run-qemu.sh harness
#                   verification via log fixtures (without root/QEMU)
#   make rootfs     build minimal distro rootfs + initramfs (static busybox,
#                   ninit as /sbin/init; see doc/distro-builder.md)
#   make qemu       boot rootfs in QEMU (requires qemu-system-x86)
#   make integration  cross-layer integration test fstab<->kernel<->services
#                   via one real QEMU boot (requires root + qemu-system-x86)
#   make test-panic  kernel-panic regression suite (QEMU; requires root + qemu)
#   make fuzz       ASan+UBSan fuzz harness for config/fstab/initctl parsers
#   make lint       run python linter on log patterns, markers, and format specifiers
#   make packages   build all base S.A.N.E distro packages (.spm.tar.xz)
#   make test-pkg   run package builder test suite
#   make clean      remove built binary
#   make clean-distro remove distro build artifacts
#
# Requires: build-essential + busybox-static (busybox used as /bin/sh in test rootfs).
# On distros without static glibc (e.g. Alpine):  make CC=musl-gcc
# Note: -Werror is omitted from default CFLAGS for compatibility across compiler toolchains;
# CI overrides CFLAGS with -Werror to enforce the zero-warning gate.

CC     = gcc
CFLAGS ?= -static -O2 -Wall -fstack-protector-strong
BIN    ?= ninit
TESTBIN ?= ninit-test
SRC    ?= ninit.c

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

# Test binary. -DNINIT_TESTING compiles in the NINIT_CGROUP_BASE override so each
# suite can isolate its cgroups in a per-run subtree instead of the host's
# /sys/fs/cgroup/ninit. The override is deliberately ABSENT from the production
# binary ($(BIN)): an exported environment variable must not be able to redirect
# PID 1's cgroup operations. Every suite run by `make test` therefore uses this
# binary via BIN=./$(TESTBIN); a suite handed the production binary would lose
# isolation, which the cgroup guard at the end of `test` catches.
$(TESTBIN): $(SRC)
	$(CC) $(CFLAGS) -DNINIT_TESTING -o $@ $<

TEST_SCRIPTS := scripts/smoke-test.sh scripts/test-sigterm.sh scripts/test-config.sh \
                scripts/test-qemu-report.sh scripts/test-spawn-failure.sh \
                scripts/test-cgroup-limits.sh scripts/test-respawn-cleanup.sh \
                scripts/test-state-machine.sh

test: $(TESTBIN)
	@PRE_CGROUPS=$$(ls -d /sys/fs/cgroup/ninit* 2>/dev/null || true); \
	for t in $(TEST_SCRIPTS); do BIN=./$(TESTBIN) sh ./$$t || exit 1; done; \
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

test-panic: $(BIN)
	@rc=0; sh ./scripts/test-kernel-panic-specific.sh || rc=$$?; \
	if [ $$rc -eq 77 ]; then echo "SKIP: test-panic (no QEMU/kernel/initramfs)"; exit 0; fi; \
	exit $$rc

fuzz test-fuzz:
	@rc=0; sh ./scripts/fuzz-parsers.sh || rc=$$?; \
	if [ $$rc -eq 77 ]; then echo "SKIP: fuzz-parsers (sanitizer unsupported)"; exit 0; fi; \
	exit $$rc

clean:
	rm -f $(BIN) $(TESTBIN)

clean-distro:
	rm -rf distro/rootfs distro/build distro/cache distro/packages distro/initramfs.cpio.gz \
	       distro/qemu-console.log distro/qemu.log

lint:
	python3 ./scripts/lint-log-patterns.py
	python3 ./scripts/verify-format-strings.py

packages: $(BIN)
	bash ./packages/build-all.sh

test-pkg:
	bash ./scripts/test-build-package.sh

test-spm:
	bash ./scripts/test-spm.sh

.PHONY: all test test-panic fuzz rootfs qemu integration clean clean-distro lint packages test-pkg test-spm
