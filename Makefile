# ninit -- minimal init system (PID 1)
#
#   make            build static binary ./ninit  (gcc -static -O2 -Wall -Werror -fstack-protector-strong)
#   make ninit-test build the test binary (production flags + -DNINIT_TESTING)
#   make test       test PID 1 in temporary chroot with ./ninit-test: all 13
#                   TEST_SCRIPTS suites (8 root-required + 5 unprivileged)
#   make rootfs     build minimal distro rootfs + initramfs (static busybox,
#                   ninit as /sbin/init; see doc/distro-builder.md)
#   make qemu       boot rootfs in QEMU (requires qemu-system-x86)
#   make integration  cross-layer integration test fstab<->kernel<->services
#                   via one real QEMU boot (requires root + qemu-system-x86)
#   make test-panic  kernel-panic regression suite (QEMU; requires root + qemu)
#   make test-lifecycle  boot/account lifecycle scenarios in QEMU (requires
#                   root, QEMU, losetup and a built disk image)
#   make fuzz       ASan+UBSan fuzz harness for config/fstab/initctl parsers
#   make lint       run pattern/format linters + ShellCheck production-script gate
#                   (SC3043 local and SC3013 -ef are documented exclusions;
#                    info/style severities are not gated)
#   make packages   build all base S.A.N.E distro packages (.spm.tar.xz)
#   make test-pkg   run package builder test suite
#   make clean      remove built binary
#   make clean-distro remove distro build artifacts
#
# Requires: build-essential + busybox-static (busybox used as /bin/sh in test rootfs).
# On distros without static glibc (e.g. Alpine):  make CC=musl-gcc
# Zero-warning gate: -Werror is enabled by default alongside -Wall and -fstack-protector-strong.

CC     = gcc
CFLAGS ?= -static -O2 -Wall -Werror -fstack-protector-strong
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

# Static UBSan build. Static linking is required: the chroot-based suites copy
# this binary into a minimal rootfs that has no sanitizer runtime libraries.
# ASan cannot be used here for that reason; see scripts/test-ubsan.sh.
UBSANBIN ?= ninit-ubsan
ubsan: $(SRC)
	$(CC) -static -O1 -g -Wall -Werror -fsanitize=undefined \
		-fno-omit-frame-pointer -DNINIT_TESTING -o $(UBSANBIN) $<

TEST_SCRIPTS := scripts/smoke-test.sh scripts/test-sigterm.sh scripts/test-config.sh \
                scripts/test-qemu-report.sh scripts/test-spawn-failure.sh \
                scripts/test-cgroup-limits.sh scripts/test-respawn-cleanup.sh \
                scripts/test-state-machine.sh scripts/test-accounts.sh \
                scripts/test-network.sh scripts/test-network-fault.sh \
                scripts/test-reliability.sh scripts/test-zombie-reap-500.sh

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

test-panic: $(BIN) $(TESTBIN)
	@rc=0; BIN=./$(TESTBIN) sh ./scripts/test-kernel-panic-specific.sh || rc=$$?; \
	if [ $$rc -eq 77 ]; then \
		if [ "$${CI:-}" = "true" ] || [ "$${CI:-}" = "1" ]; then \
			echo "FAIL: test-panic skipped in CI (exit 77 forbidden)" >&2; exit 1; \
		fi; \
		echo "SKIP: test-panic (no QEMU/kernel/initramfs)"; exit 0; \
	fi; \
	exit $$rc

fuzz test-fuzz:
	@rc=0; sh ./scripts/fuzz-parsers.sh || rc=$$?; \
	if [ $$rc -eq 77 ]; then \
		if [ "$${CI:-}" = "true" ] || [ "$${CI:-}" = "1" ]; then \
			echo "FAIL: fuzz skipped in CI (exit 77 forbidden)" >&2; exit 1; \
		fi; \
		echo "SKIP: fuzz-parsers (sanitizer unsupported)"; exit 0; \
	fi; \
	exit $$rc

clean:
	rm -f $(BIN) $(TESTBIN) $(UBSANBIN)

clean-distro:
	rm -rf distro/rootfs distro/build distro/cache distro/packages distro/initramfs.cpio.gz \
	       distro/sane.img distro/qemu-console.log distro/qemu.log distro/qemu-image*.log

lint:
	python3 ./scripts/lint-log-patterns.py
	python3 ./scripts/verify-format-strings.py
	$(MAKE) lint-shell

# Real, failing gate over the 13 production shell scripts. Test, smoke, fuzz
# and Python helpers are intentionally NOT included. -S warning gates warnings
# only (info/style are not gated). SC3043 (local) and SC3013 (-ef) are excluded
# because they are undefined in strict POSIX sh yet supported by every target
# shell: dash, ash and BusyBox sh. Any other warning must fail the build.
lint-shell:
	shellcheck -S warning -e SC3043,SC3013 \
		scripts/build-package.sh scripts/build-rootfs.sh scripts/make-image.sh \
		scripts/provision-accounts.sh scripts/run-qemu.sh scripts/sane-account-recovery \
		scripts/sane-accounts scripts/sane-firstboot scripts/sane-install.sh \
		scripts/sane-reliability scripts/spm \
		packages/ninit/x/usr/bin/sane-net packages/ninit/x/usr/bin/sane-ctl

packages: $(BIN)
	bash ./packages/build-all.sh

clawrza:
	bash ./packages/clawrza-build-all.sh

test-accounts:
	sh ./scripts/test-accounts.sh

test-pkg:
	bash ./scripts/test-build-package.sh

test-network:
	sh ./scripts/test-network.sh

test-reliability:
	sh ./scripts/test-reliability.sh

test-network-fault:
	sh ./scripts/test-network-fault.sh

test-build-rootfs:
	sh ./scripts/test-build-rootfs.sh

test-spm:
	bash ./scripts/test-spm.sh

image: packages
	sudo bash ./scripts/make-image.sh

test-image:
	bash ./scripts/test-image-boot.sh

test-image-bios:
	bash ./scripts/test-image-boot.sh --bios

test-image-uefi:
	bash ./scripts/test-image-boot.sh --uefi

test-lifecycle:
	@rc=0; sh ./scripts/test-boot-lifecycle.sh || rc=$$?; \
	if [ $$rc -eq 77 ]; then \
		if [ "$${CI:-}" = "true" ] || [ "$${CI:-}" = "1" ]; then \
			echo "FAIL: test-lifecycle skipped in CI (exit 77 forbidden)" >&2; exit 1; \
		fi; \
		echo "SKIP: test-lifecycle (needs root, QEMU, losetup and 'make image')"; exit 0; \
	fi; \
	exit $$rc

test-installer installer-test: packages
	sudo bash ./scripts/test-installer.sh

.PHONY: all test test-panic fuzz rootfs qemu integration clean clean-distro lint lint-shell packages clawrza test-pkg test-spm image test-image test-image-bios test-image-uefi test-installer installer-test test-lifecycle test-accounts test-network test-network-fault test-build-rootfs test-reliability ubsan
