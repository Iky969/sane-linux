# Changelog

All notable changes to the `sane-linux` init system (`ninit`) and distro build harness are documented in this file.

The project adheres to [Semantic Versioning](https://semver.org/).

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
