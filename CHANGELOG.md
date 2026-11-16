# Changelog

All notable changes to the `sane-linux` init system (`ninit`) and distro build harness are documented in this file.

The project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Core Init System (`ninit`) Lifecycle & IPC Hardening**:
  - **State Machine Telemetry (T10)**: Strict lifecycle state enum (`STOPPED`, `STARTING`, `RUNNING`, `STOPPING`, `DONE`, `FAILED`) exposed via `/run/ninit-<service>.state` telemetry files.
  - **Non-Blocking Fork EAGAIN Retry (T11)**: Exponential backoff with up to 3 retry attempts on fork failures (`EAGAIN`), preventing boot deadlock while bounded by loop timer.
  - **Respawn Cleanup & Crash Counter Reset (T12)**: Explicit counter reset upon clean state transitions and pre-respawn orphan cleanup.
  - **Stop Grace Timeout & SIGKILL Escalation (T13)**: Monotonic timestamp tracking (`stop_t0`) during shutdown/stop with automatic escalation to `SIGKILL` and cgroup purge after grace timeout expires.
  - **Deterministic Leaf Cgroup Hygiene (T14 / T14B)**: Deep cgroup hierarchy cleanup ensuring zero leaking child cgroup directories upon service death.
  - **Supervised Rescue Mode (T15)**: Forked emergency shell keeping PID 1 alive and listening to `/run/initctl` rather than replacing PID 1 via `exec`.
  - **Interactive cttyhack Console**: Console allocation with `cttyhack /bin/sh -i` on `/dev/console` preventing EOF crash loops.
  - **Fail-Closed Privilege Drop Parser**: Parsing and enforcement of `:user=` and `:group=` directives in service configs with fail-closed credentials resolution.
  - **`sane-ctl` IPC Control**: Command-line control utility communicating via `/run/initctl` FIFO (`start`, `stop`, `restart`, `status`, `reboot`, `poweroff`) with fail-closed exit codes and polling timeout verification.
  - **`sane-net` Utility**: Standalone network configuration tool for link setup and address assignments.

- **S.A.N.E Package Manager (`spm`) & Deterministic Builder**:
  - **POSIX sh Implementation**: Clean port to POSIX `/bin/sh` without bash dependency for ultra-minimal initramfs environments.
  - **Atomic Staging & Deployment**: Staging directory execution (`/var/lib/spm/staging/tx-*`) with atomic replacement via `rename(2)` (`mv -f`), avoiding Linux `ETXTBSY` when upgrading active binaries.
  - **Base Package Protection**: Guarding `base=true` core system packages against accidental deletion without explicit `--force`.
  - **Reverse Dependency Tracking**: Dependency registry (`/var/lib/spm/rdeps/`) preventing removal of required packages by active dependents.
  - **Archive Security Hardening**:
    - Rejection of hardlink members (`tar -tvf` starting with `h`).
    - Rejection of setuid and setgid permissions (`04000`/`02000`) before and after extraction.
    - Rejection of duplicate archive members and duplicate manifest entries.
    - Strict regex validation for dependency names (`^[a-zA-Z0-9_-]+$`).
  - **Power-Cut Journal Recovery**: Automatic detection and clean rollback of interrupted staging transactions on startup.
  - **Deterministic Package Builder (`build-package.sh`)**: Reproducible tarball generation (`.spm.tar.xz` / `.spm.tar.gz`) with strict metadata auto-generation (`.META/files`, `.META/sha256`).

- **Distribution Image & Live Installer**:
  - **Host Image Builder (`make-image.sh`)**: Automated raw GPT image creation with hybrid Limine BIOS and UEFI ESP FAT32 dual-boot.
  - **Guest Offline Live Installer (`sane-install.sh`)**: Offline installer targeting block devices with GPT layout, Limine bootloader installation, and safety preflight checks.
  - **PARTUUID Root Resolver**: Deterministic root device resolution via GPT `PARTUUID` in initramfs instead of hardcoded block device paths.
  - **CPIO Ownership Normalization**: Enforced `root:root` (0:0) ownership on `initramfs.cpio.gz` across GNU and BusyBox cpio tools.
  - **Immutable Toolchain Pinning**: Pinned Alpine netboot kernel and modloop to release `netboot-3.20.10` with verified SHA-256 hashes.
  - **Mount Cleanup Safety**: Guarded mountpoint cleanup using `rmdir` after unmount rather than recursive `rm -rf`.

- **Comprehensive Test Suites**:
  - Expanded SPM adversarial test suite to 26 passing scenarios (`scripts/test-spm.sh`).
  - Automated package builder verification (`scripts/test-build-package.sh`, 12 tests).
  - Headless QEMU live installer test harness (`scripts/test-installer.sh`, 17 tests).
  - State machine formalization test suite (`scripts/test-state-machine.sh`).
  - ASan+UBSan parser fuzz harness (`scripts/fuzz-parsers.sh`).

## [v1.1.0] - 2026-11-11

### Added
- **Cgroup v2 Pre-Exec Synchronization Handshake (T1)**:
  - Parent-child synchronization via `pipe2(O_CLOEXEC)` (or fallback `pipe()` with fail-closed `FD_CLOEXEC`) before child executes `execl()`.
  - Guarantees child and all descendant processes are contained within the dedicated leaf cgroup (`/sys/fs/cgroup/ninit/<name>`) prior to executing user code.
  - Fail-closed handshake read/write validation (exactly 1 confirmation byte `'1'`).
- **Multi-Tier Hierarchical Resource Limits (T4)**:
  - Declarative cgroup v2 resource limits in `init.conf`: `:memory_max=`, `:cpu_max=`, and `:pids_max=`.
  - Swap isolation via `memory.swap.max=0` preventing memory quota escape to swap space.
  - Strict semantic validation of resource syntax in parser (`validate_memory_max`, `validate_cpu_max`, `validate_pids_max`).
- **Fail-Open Lifecycle & Cleanup (T2)**:
  - Graceful fail-open operation when cgroup v2 controller is unavailable or unmounted.
  - Runtime orphan cleanup fallback via `kill(-pgid, SIGKILL)` in `reap_zombies()` for systems without cgroups.
- **Process Group Tracking & Security Hardening (SANE-01, SANE-06-01)**:
  - Service process group (`pgid`) preserved across process leader death, ensuring child process groups outliving their leaders are cleanly terminated during shutdown.
  - PID 1 control plane file descriptor hygiene: `O_CLOEXEC` on `/run/initctl`, `/run/log.fifo`, and `/var/log/ninit.log`, with explicit closure in child branches before `execl()`.
- **Cgroup Path Sanitization & Anti-Traversal (SANE-06-02, SANE-06-03)**:
  - Strict cgroup base validation with configurable `NINIT_CGROUP_BASE` environment variable for hermetic test isolation.
  - Path traversal rejection preventing `.` or `..` from escaping the cgroup hierarchy.
  - Duplicate service name registration rejection in `parse_config()`.
- **Reliability & Crash Resilience (T8D)**:
  - Once service execution timeout enforcement (default 30s, configurable via `:timeout=N`).
  - Exponential respawn backoff with crash limit detection (`CRASH_LIMIT=5`, `BACKOFF_MAX=32s`) preventing respawn storms.
  - Transitive cancellation of dependent services when prerequisites fail.
- **Clean Filesystem Shutdown (T8E)**:
  - Remount root filesystem read-only (`MS_REMOUNT | MS_RDONLY`) followed by `umount2(..., MNT_DETACH)` of all mounted fstab entries before reboot or poweroff.
- **Standalone Tooling & CI (PR B3)**:
  - Standalone `make lint` target executing `scripts/lint-log-patterns.py` and `scripts/verify-format-strings.py`.
  - Added `-Wformat=2` verification and automated linting step to GitHub Actions CI workflow.
- **Internationalization (English Migration - Phase 0b)**:
  - Primary codebase documentation translated to English (`README.md`, `SECURITY.md`, `doc/*.md`), retaining Indonesian originals (`*.id.md`) with bidirectional switcher links.
  - All `init_log()` diagnostic messages, rescue shell messages, test assertions, and test scripts migrated to English.
  - All code comments in `ninit.c` translated to English while preserving SANE-01 through SANE-06 security rationale.

### Rescue & Hardening
- **Supervised Rescue Mode (T15)**: `enter_rescue_mode()` no longer `execl()`s away PID 1. PID 1 forks a supervised `/bin/sh` child, keeps running its own event loop, reaps and bounded-respawns the shell, and still serves `/run/initctl` (`poweroff`/`reboot`) so a rescue session can always be shut down cleanly. A shell exit, a missing `/bin/sh`, or an OOM-killed shell therefore cannot end PID 1 — no `Attempted to kill init!` panic.
- **Empty / fully-rejected config → rescue (T16)**: a config that yields zero services drops into rescue mode (`No services configured`) instead of parking in a zombie `main loop ready` with no shell and no services.
- **Build hardening (T20)**: `-fstack-protector-strong` added to the default `CFLAGS`; every syscall return is checked and every internal descriptor is `O_CLOEXEC`.
- **Parser fuzz harness (T20)**: `tests/fuzz/fuzz_parse.c` + `scripts/fuzz-parsers.sh` exercise the `init.conf`, fstab, and initctl parsers under ASan+UBSan over a deterministic corpus (0/1/1000 lines, raw bytes, no trailing newline, empty/`..` names, cyclic `:requires=`, stacked tags, odd fstab options, multi-line initctl) plus 2000 deterministic LCG mutations. Run with `make fuzz` / `make test-fuzz`.
- **Kernel panic regression (T21)**: `scripts/test-kernel-panic-specific.sh` is tracked, exposed as `make test-panic`, and wired into CI. It resolves a host or Alpine kernel so it also runs on CI runners, and covers real panic induction (PID 1 exit, missing init), rescue-mode anti-panic, and a clean production boot.
- **Phase 1 cgroup lifecycle hardening**: pre-exec containment handshake, hierarchical `memory`/`pids`/`cpu` limits, fail-open fallback, respawn counter reset with a pre-respawn `cgroup.kill` flush, and deterministic leaf `rmdir` after `cgroup.procs` drains.

### Changed
- Isolated all non-cgroup test suites (`smoke-test`, `test-sigterm`, `test-config`, `test-spawn-failure`) under per-run unique `NINIT_CGROUP_BASE` subtrees with depth-first cleanup traps to guarantee zero host cgroup pollution.
- Hardened cgroup limits test harness (`test-cgroup-limits.sh`) with anti-vacuous assertions for descendant escapes (Scenario 9) and cumulative multi-process memory OOM (Scenario 10).

## [v1.0.0] - 2026-10-27

### Added
- Minimal PID 1 init system (`ninit`) written in static C with zero runtime library dependencies.
- Declarative configuration file (`/etc/init.conf`) supporting `once` and `respawn` services with `:requires=` dependencies.
- Topological sorting with cycle detection and iterative DFS stack overflow protection.
- Emergency rescue shell (`enter_rescue_mode()`) with signal mask reset on boot failure.
- Rootfs generation harness (`scripts/build-rootfs.sh`) with static BusyBox assembly.
- QEMU headless validation test suite (`scripts/run-qemu.sh`, `scripts/test-integration.sh`).
- `/etc/fstab` single-pass parser with octal escape decoding (`\040`) and mount options handling.
