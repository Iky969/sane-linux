# ninit Documentation

*[English](README.md) | [Bahasa Indonesia](id/README.md)*

`ninit` is a minimal init system (PID 1) in a **single C file** with zero dependencies beyond libc. Designed for experimental distribution and operating system construction: it reads service definitions, spawns and supervises them, isolates processes into cgroup v2 leaves, mounts filesystems from `/etc/fstab`, and powers down or restarts cleanly.

For a high-level overview, quick start guide, and configuration examples, see the **[main README at the repository root](../README.md)**. This directory contains detailed technical documentation:

| Document | Contents |
|---|---|
| [architecture.md](architecture.md) | Internal architecture: boot sequence, event loop, signals, respawn, shutdown, cgroups, logging |
| [configuration.md](configuration.md) | Syntax and semantics of `/etc/init.conf`, `/etc/fstab`, signal tables, `/run/initctl`, log locations |
| [build-and-test.md](build-and-test.md) | Static build, PID 1 smoke tests, CI workflow, manual `unshare`/`chroot` testing, troubleshooting |
| [distro-builder.md](distro-builder.md) | Minimal rootfs + initramfs assembly and QEMU headless validation |
| [boot-pipeline.md](boot-pipeline.md) | Boot pipeline, GPT layout, Limine bootloader, and initramfs `switch_root` handoff |
| [package-format.md](package-format.md) | S.A.N.E package manager container specification (`.spm.tar.xz`), metadata, and symlink rules |
| [glossary-i18n.md](glossary-i18n.md) | Internationalization glossary, terminology mapping, and log string tables |
| [../SECURITY.md](../SECURITY.md) | Security policy and vulnerability disclosure procedures |
| [../LICENSE](../LICENSE) | MIT License |

## Current Features

- **PID 1 + Child Reaping**: reaps all terminating child processes, including adopted orphan processes.
- **Service Configuration (`/etc/init.conf`)**: supports `respawn` and `once` modes with `:requires=` dependencies (DFS topological sort, cycle detection, missing dependencies route to a rescue shell).
- **Non-blocking Respawn**: 2-second delay handled via 100 ms `ppoll` timers instead of blocking `sleep()`, ensuring the event loop remains responsive to signals.
- **Clean Shutdown**: `SIGTERM`/`SIGINT` → stop services (5-second grace period) → `sync()` → `reboot()`; force variants available to bypass the grace window.
- **Cgroups v2**: each service is placed into a leaf cgroup at `/sys/fs/cgroup/ninit/<name>` with limits on `memory.max`, `memory.swap.max=0`, `cpu.max`, and `pids.max` enforced by the kernel (fail-open fallback when cgroups are unavailable).
- **`/etc/fstab`**: mounts filesystems with flags and data options (`size=`, `mode=`, `uid=`, ...) forwarded to `mount()`.
- **Dual Logging**: outputs to `/dev/kmsg`, console (stderr), `/var/log/ninit.log`, plus a `/run/log.fifo` path capturing service output with a `[service]` prefix.
- **IPC (`/run/initctl`)**: line-by-line reading of `poweroff`, `reboot`, `force-poweroff`, and `force-reboot` commands.
- **Static Binary**: compiles cleanly with `gcc -static` with zero compiler warnings under `-Wall -Werror`.

## Repository Structure

```
README.md                     Project overview and quickstart (GitHub landing page)
ninit.c                       Complete init system implementation (single C file)
Makefile                      make / make test / make lint / make clean
scripts/smoke-test.sh         Automated PID 1 test in isolated chroot + unshare
scripts/test-sigterm.sh       Verifies SIGTERM delivery to service processes
scripts/test-config.sh        Tests dependency sorting, rescue mode, line-by-line initctl
scripts/test-qemu-report.sh   Validates run-qemu.sh report() logic against log fixtures
scripts/test-spawn-failure.sh Tests respawn dependency cancellation & fork retry limits
scripts/test-cgroup-limits.sh Tests cgroup v2 limits (memory, cpu, pids) & lifecycle
scripts/test-integration.sh   Cross-layer fstab <-> kernel <-> services test via real QEMU boot
scripts/build-rootfs.sh       Assembles minimal distro rootfs (static BusyBox + ninit)
scripts/run-qemu.sh           Boots rootfs in QEMU: serial console & milestone verification
scripts/lint-log-patterns.py  Linter for log strings, assertions, and legacy markers
scripts/verify-format-strings.py Linter for printf format specifier safety (-Wformat=2)
distro/                       Distro builder output directory (rootfs/, cache/, initramfs) - gitignored
doc/                          Technical documentation directory
.github/workflows/ci.yml      CI workflow: static build, linting, tests, QEMU boot
SECURITY.md                   Security policy
LICENSE                       MIT License
```

## Quick Start

```bash
make          # Build static binary ./ninit
make lint     # Run pattern linter and format string verifier
make test     # Test PID 1: smoke test + SIGTERM test + config test + spawn failure + cgroup limits
```

To run `ninit` on a real system, install the compiled binary as `/sbin/init` and provide `/etc/init.conf`. For safe experimentation, use chroot + `unshare` as detailed in [build-and-test.md](build-and-test.md).

## Status

The current release is **v1.1.0**, and the boot banner reports `=== ninit start (PID 1) v1.1.0 ===`.

Recent reliability enhancements include:
- Topological sort bounded by `MAX_SERVICES` preventing stack overflow,
- `validate_dependencies()` dropping init into a rescue shell if `:requires=` references a missing service,
- Line-by-line reading on `/run/initctl`,
- Functional rescue shell with cleared signal mask (ensuring interactive Ctrl+C works).

All behaviors are verified by automated test suites in `scripts/`.

## Known Limitations

- All service commands execute via `/bin/sh -c`, requiring `/bin/sh` in the rootfs (typically provided by static BusyBox).
- `mount_fstab()` runs before `/var/log/ninit.log` is opened; early fstab mount messages appear on console/`/dev/kmsg` only.
- Non-flag fstab options are forwarded directly to `mount()`; the `defaults` placeholder keyword is stripped to prevent kernel rejection.
- No support for socket activation, event-driven service graphs, or systemd-style unit files.
