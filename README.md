# S.A.N.E — Minimal Linux Distribution with ninit Init System

*[English](README.md) | [Bahasa Indonesia](README.id.md)*

**S.A.N.E** is a minimal Linux distribution built from scratch in this repository.
At its core is `ninit`, a compact init system (PID 1) written in a single C file
with zero dependencies beyond libc: it parses service configurations, spawns
and supervises services, moves processes into cgroup v2 leaves, mounts
filesystems declared in `/etc/fstab`, and orchestrates clean system shutdown.

This repository contains the complete S.A.N.E Linux distribution:
- **`ninit`**: A compact, static init system (PID 1) in [`ninit.c`](ninit.c) (±3100 lines) with cgroup v2 resource limits, fail-closed privilege drop (`:user=`/`:group=`), line-by-line `/run/initctl` IPC, stop grace escalation, and supervised emergency shell.
- **`spm`**: S.A.N.E Package Manager ([`scripts/spm`](scripts/spm)), a POSIX `/bin/sh` package manager featuring atomic staging via `rename(2)` / anti-`ETXTBSY`, SHA-256 integrity verification against the checksum manifest bundled in the same archive (corruption detection, **not** signature verification — see [SECURITY.md](SECURITY.md)), power-cut journal recovery, and reverse dependency tracking.
- **Distro & Image Builder**: Automated rootfs builder (`scripts/build-rootfs.sh`), GPT disk image generator (`scripts/make-image.sh`), and offline live installer (`scripts/sane-install.sh`) supporting dual Limine BIOS and UEFI GPT boots.

The event loop is built on `ppoll`, keeping init responsive to signals even during rapid service respawn loops.

[![CI](https://github.com/Iky969/sane-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/Iky969/sane-linux/actions/workflows/ci.yml)
[![Build Image](https://github.com/Iky969/sane-linux/actions/workflows/build-image.yml/badge.svg)](https://github.com/Iky969/sane-linux/actions/workflows/build-image.yml)
[![SPM Tests](https://github.com/Iky969/sane-linux/actions/workflows/test-spm.yml/badge.svg)](https://github.com/Iky969/sane-linux/actions/workflows/test-spm.yml)
[![Image Boot](https://github.com/Iky969/sane-linux/actions/workflows/test-image-boot.yml/badge.svg)](https://github.com/Iky969/sane-linux/actions/workflows/test-image-boot.yml)
[![Installer Tests](https://github.com/Iky969/sane-linux/actions/workflows/test-installer.yml/badge.svg)](https://github.com/Iky969/sane-linux/actions/workflows/test-installer.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Features

- **PID 1 + Child Reaping**: reaps all terminated child processes, including adopted orphan processes.
- **Service Configuration (`/etc/init.conf`)**: supports `respawn` and `once` modes (unknown modes are rejected fail-closed) with `:requires=` dependencies (DFS topological sort without recursion/stack overflow, `once` services waited on until success before dependents start, cycle detection, missing dependencies, 0-service configs, and `:on_fail=rescue` trigger supervised rescue).
- **Non-blocking Respawn**: a 2-second delay is handled via 100 ms `ppoll` timers instead of blocking `sleep()`, ensuring init never misses signals.
- **Clean Shutdown**: `SIGTERM`/`SIGINT` → stop services (default 5-second grace period, configurable per service via `:grace=N`) → `sync()` → `reboot()`; force variants bypass the grace period for immediate reboot/poweroff.
- **Cgroups v2**: each service is placed into a leaf `/sys/fs/cgroup/ninit/<name>` with resource limits enforced by the kernel (`:memory_max=`, `:cpu_max=`, `:pids_max=`), swap escape prevention (`memory.swap.max=0`), and automatic orphan cleanup via `cgroup.kill`.
- **Filesystem Mounting (`/etc/fstab`)**: mounts filesystems with flags and data options (`size=`, `mode=`, `uid=`, ...) forwarded to `mount()`; `defaults` is ignored like in `mount(8)`.
- **Dual Logging**: outputs to `/dev/kmsg`, console (stderr), `/var/log/ninit.log`, plus a `/run/log.fifo` path capturing service stdout/stderr with a `[service]` prefix.
- **IPC (`/run/initctl`)**: streaming line-by-line handling (`MAX_LINE = 1024`) for `poweroff`, `reboot`, `force-poweroff`, `force-reboot`, `stop`, `start`, `restart`, and `status`, preventing dropped commands on multi-line writes.
- **Privilege Separation (`:user=`, `:group=`)**: services run as `root` by default; `:user=` drops to an unprivileged user from `/etc/passwd`. `:group=` is optional and must be paired with `:user=` (group-only is rejected fail-closed). Supplementary groups are dropped (`setgroups`). Lookup errors fail closed. A numeric `:user=`/`:group=` must exist in `/etc/passwd`/`/etc/group`, and numeric `0` is rejected -- write `:user=root` / `:group=root` instead.
- **`sane-ctl` Daemon Control**: unified CLI tool to `start`, `stop`, `restart`, and `status` daemons over `/run/initctl` FIFO with state tracking in `/run/ninit-*.state` and stop grace timeout escalation.
- **S.A.N.E Package Manager (`spm`)**: POSIX `/bin/sh` package manager supporting atomic `rename(2)` staging, binary active replacement (anti-`ETXTBSY`), reverse dependency protection, archive hardening, and power-cut journal recovery.
- **Live Installer & Dual Boot**: guest offline live installer (`sane-install.sh`) supporting dual Limine BIOS (MBR/GPT) and UEFI (ESP FAT32) with GPT `PARTUUID` root partition resolution.
- **Static Binary**: builds cleanly with `gcc -static`, requiring only libc.
- **First-boot credentials**: accounts ship locked; `/usr/bin/sane-firstboot`
  prompts for the `root` and `sane` passwords on the console before getty
  starts. No public password is distributed. See
  [doc/account-security.md](doc/account-security.md).

### Cgroup v2 — Resource Limiting Capabilities

Each service is placed in a dedicated leaf cgroup at `/sys/fs/cgroup/ninit/<name>`.
Limits are enforced by the kernel **before** the service process executes (via a pre-exec synchronization handshake):

| Controller | Cgroup v2 File | `/etc/init.conf` Option | Impact When Exceeded |
|---|---|---|---|
| memory | `memory.max` | `:memory_max=16M` | OOM killer terminates process (SIGKILL, exit `0x9`) |
| memory (swap) | `memory.swap.max` | *(automatic)* | Forced to `0` so memory limits cannot leak into swap |
| cpu | `cpu.max` | `:cpu_max=50000 100000` | CPU quota `<quota> <period>` (default period 100000 µs) |
| pids | `pids.max` | `:pids_max=50` | `fork()` rejected with `EAGAIN` |

If the cgroup v2 hierarchy is unavailable (e.g. kernel without `CONFIG_CGROUPS`, or container/chroot without controller delegation), `ninit` logs a *fail-open* fallback and services continue running without limits rather than failing boot.

## Quick Start

Requires `build-essential` and (for testing) `busybox-static`:

```bash
sudo apt-get install build-essential busybox-static python3 shellcheck

make          # Build static binary ./ninit (-Werror enabled by default)
make lint     # Pattern/format linters + ShellCheck gate on 13 production scripts
make test     # 13 suites: 8 root-required + 5 unprivileged (root/sudo for namespaces)
make rootfs   # Build minimal distro rootfs + initramfs (static BusyBox, ninit as PID 1)
make qemu     # Boot rootfs in QEMU with serial console (requires qemu-system-x86)
make clean    # Remove build artifacts
```

`make test` runs all **13** suites from `TEST_SCRIPTS` with `./ninit-test`
(`-DNINIT_TESTING` per-run cgroup isolation): **8 require root/sudo** because
they launch PID 1 in isolated namespaces and exercise cgroups, and **5 run
unprivileged** against temporary roots. The separate QEMU integration boot
(`make integration`) and lifecycle/image suites are not part of `make test`.

Root-required (8):

- **[`scripts/smoke-test.sh`](scripts/smoke-test.sh)** — Startup banner, event loop readiness (`main loop ready`), service startup, `graceful shutdown`, zero respawns after shutdown, and shutdown latency < 5000 ms.
- **[`scripts/test-sigterm.sh`](scripts/test-sigterm.sh)** — Verifies that `SIGTERM` actually reaches service processes (trap executes, `exit status=0x0` rather than `0x9`, clean child signal mask, shutdown completes before the 5-second grace window expires).
- **[`scripts/test-config.sh`](scripts/test-config.sh)** — Topological sort of `:requires=` (diamond dependencies `a→b,c ; b→c` and dense configurations up to 64 services without stack overflow), unreadable config / 0-service config / missing dependencies / cycle detection / `:on_fail=rescue` (fork-retry exhaustion & respawn `SVC_STATE_FAILED`) triggering supervised rescue (`SigBlk=0`), and streaming `/run/initctl` reading (`poweroff\nreboot` executes only `poweroff`).
- **[`scripts/test-zombie-reap-500.sh`](scripts/test-zombie-reap-500.sh)** — Boots `./ninit-test` as PID 1 inside isolated `unshare` + `chroot` + `NINIT_CGROUP_BASE`, spawns 500 short-lived orphaned children, and proves PID 1 reaps them all with 0 lingering zombies.
- **[`scripts/test-spawn-failure.sh`](scripts/test-spawn-failure.sh)** — Spawn failure paths: dependency cancellation propagation on respawn paths, fork EAGAIN retry limits on `once` services, and process group liveness probing before the final SIGKILL.
- **[`scripts/test-cgroup-limits.sh`](scripts/test-cgroup-limits.sh)** — Cgroup v2 resource limits: memory limits & deterministic OOM (`memory_max`), process limits (`pids_max`), orphan cleanup on respawn (`cgroup.kill`), and cgroup leaf lifecycle verification.
- **[`scripts/test-respawn-cleanup.sh`](scripts/test-respawn-cleanup.sh)** — Respawn cleanup and grandchild containment: orphaned process trees are killed with their cgroup leaf on respawn; generation counters reset cleanly (T12).
- **[`scripts/test-state-machine.sh`](scripts/test-state-machine.sh)** — Formal state-machine transitions and telemetry across boot, stop, respawn and shutdown (T10/T11/T13).

Unprivileged (5):

- **[`scripts/test-qemu-report.sh`](scripts/test-qemu-report.sh)** — Validates the test harness itself: console logs with crashed or respawning console services are strictly flagged as FAIL. Runs against log fixtures via `REPORT_ONLY=1` without requiring root or QEMU.
- **[`scripts/test-accounts.sh`](scripts/test-accounts.sh)** — Phase A account lifecycle and policy: `sane-accounts`, merge-based recovery, `doas` vocabulary and first-free UID allocation; runs against a temporary target root (owner checks run when invoked with `sudo`).
- **[`scripts/test-network.sh`](scripts/test-network.sh)** — Phase B networking: `sane-net`, DNS/DHCP, Wi-Fi and outbound TLS helpers.
- **[`scripts/test-network-fault.sh`](scripts/test-network-fault.sh)** — Network fault injection and recovery paths for the reconnect/TLS stack.
- **[`scripts/test-reliability.sh`](scripts/test-reliability.sh)** — Phase C: snapshots, verified rollback, staged upgrades, crash-window recovery, backup and restore.

Separately, **[`scripts/test-integration.sh`](scripts/test-integration.sh)** performs the cross-layer `fstab` ↔ kernel ↔ services check in one real QEMU boot (`make integration`), and `make test-lifecycle` drives the **9** QEMU lifecycle scenarios (`scripts/qemu_lifecycle.py`).

Detailed outputs and test explanations are available in [doc/build-and-test.md](doc/build-and-test.md).

### Distro Boot Verification in QEMU

`make rootfs` builds a minimal rootfs from scratch (static BusyBox + `ninit` as `/sbin/init`), and `make qemu` boots it in `qemu-system-x86_64` with a serial console:

```bash
make rootfs               # Assemble distro/rootfs and package initramfs
SECS=5 make qemu          # Automated 5-second boot, verifies milestones & console liveness
make qemu                 # Interactive console session (exit with: Ctrl-A X)
```

In sandbox environments (TCG emulation without KVM), the banner `=== ninit start (PID 1) v1.2.0 ===` and `main loop ready` appear on the serial console within **~1.9–2.1 seconds**, a shell starts on the console (`console:respawn:cttyhack /bin/sh -i`), and within the guest `poweroff` cleanly powers off the virtual machine (`reboot: Power down`) while `reboot` restarts cleanly. BusyBox applets are mapped via `/sbin/{poweroff,reboot,halt}` wrappers writing to `/run/initctl`.

See [doc/distro-builder.md](doc/distro-builder.md) for architectural details, signals, and known limitations.

### Boot and Lifecycle Testing

`make test-lifecycle` boots a persistent disk image in QEMU and drives the console through **9** lifecycle scenarios covering account setup, crash recovery, and fail-closed rescue: first boot with no default credentials, interrupted setup, reboot before setup completes, a rejected password followed by a successful retry, normal login, repeated reboots without repeating setup, recovery after a corrupted account configuration, reliability recovery across reboot, and `:on_fail=rescue` transitioning to PID 1's rescue shell.

```bash
make image            # required once: builds distro/sane.img
make test-lifecycle   # 9 QEMU scenarios; fails loudly under CI=true without prerequisites/image, skips (77) locally
LIFECYCLE_LOGDIR=/tmp/my-logs make test-lifecycle
```

Each boot writes its serial transcript to `LIFECYCLE_LOGDIR` (default `/tmp/sane-lifecycle-logs`). The suite requires root or passwordless `sudo` for loop devices and `util-linux` (`losetup`) to inspect and repair the image between boots. It never opens a PR by itself.

The recovery path is part of the image: `recovery:once:/usr/bin/sane-account-recovery` runs before `firstboot` and `getty`. A damaged `passwd`, `group`, `shadow`, or `doas.conf` is rebuilt from the baseline; if no valid password hash survives, the first-boot marker is removed so setup runs again instead of leaving the console locked.

Boot-time reliability recovery is fail-closed with an accessible recovery shell: `reliability:once`, `recovery:once`, and `firstboot:once` carry `:on_fail=rescue`, so a nonzero failure (or spawn failure/timeout) stops downstream services (`firstboot` and `getty` do not start on an unrepaired filesystem) **and** transitions PID 1 into the supervised rescue shell (`/bin/sh` with cleared signal mask and `/run/initctl` active), alongside invalid dependency/config errors.

### Manual Testing (chroot)

```bash
mkdir -p /tmp/myrootfs/{proc,sys,dev,run,tmp,etc,var/log,bin}
cp ninit /tmp/myrootfs/
cp /bin/busybox /tmp/myrootfs/bin/sh
printf 'shell:respawn:/bin/sh\n' > /tmp/myrootfs/etc/init.conf

sudo timeout -k 5 8 unshare --pid --fork --kill-child=SIGKILL \
     --mount --propagation private \
     sh -c 'mount -t proc proc /tmp/myrootfs/proc && exec chroot /tmp/myrootfs /ninit'
```

The `--mount --propagation private` + manual `mount -t proc` approach ensures portability across kernels where `unshare --mount-proc` is rejected with `EINVAL`.

## Configuration

### `/etc/init.conf`
One service per line: `name:mode:command[:requires=a,b][:memory_max=16M][:cpu_max=50000 100000][:pids_max=50][:timeout=60]`

```
# Essential service: run once, do not respawn
logd:once:/bin/sh -c 'exec >/var/log/logd.log 2>&1; ...'

# Network service: respawn on exit, depends on logd, memory capped at 32M
net:respawn:/sbin/dhcpcd -B eth0:requires=logd:memory_max=32M

# Application daemon: 50% CPU quota and maximum 20 processes
app:respawn:/usr/bin/myapp:cpu_max=50000 100000:pids_max=20

# All options combined: 64M memory, 50% CPU quota, max 25 processes
db:respawn:/usr/bin/db:requires=logd:memory_max=64M:cpu_max=50000 100000:pids_max=25

# Emergency shell
tty1:respawn:/bin/sh
```

`memory.swap.max` does not need to be specified: `ninit` automatically writes `0` to the leaf cgroup of any service configured with `:memory_max=`, preventing memory limit leaks into swap.

### `/etc/fstab`
Columns: `device mountpoint type options` (`dump`/`pass` optional, `#` comments ignored):

```
proc     /proc  proc   rw,nosuid,nodev,noexec
tmpfs    /run   tmpfs  rw,nosuid,nodev,mode=0755,size=16m
tmpfs    /tmp   tmpfs  rw,nosuid,nodev,mode=1777,size=64m
```

Full details (grammar, option tables, signals, and the 64-service limit) are documented in [doc/configuration.md](doc/configuration.md).

## Repository Structure

```
ninit.c                       Complete init system (single C file)
Makefile                      make / make test / make lint / make clean
scripts/smoke-test.sh         Automated PID 1 test in isolated chroot + unshare
scripts/test-sigterm.sh       Verifies SIGTERM delivery to services (not SIGKILL)
scripts/test-config.sh        Verifies dependency sorting, rescue mode, :on_fail=rescue, initctl
scripts/test-zombie-reap-500.sh Proves PID 1 reaps 500 orphaned children with 0 zombies
scripts/test-qemu-report.sh   Validates run-qemu.sh report() logic against log fixtures
scripts/test-spawn-failure.sh Tests respawn dependency cancellation & fork retry limits
scripts/test-cgroup-limits.sh Tests cgroup v2 limits (memory, cpu, pids) & lifecycle
scripts/test-respawn-cleanup.sh Tests respawn orphan cleanup & grandchild containment
scripts/test-state-machine.sh Tests service state-machine transitions & :grace= telemetry
scripts/test-accounts.sh      Tests Phase A account lifecycle, doas policy & recovery
scripts/test-network.sh       Tests Phase B networking (sane-net, DNS/DHCP, TLS)
scripts/test-network-fault.sh Tests Phase B network fault injection & recovery
scripts/test-reliability.sh   Tests Phase C snapshots, rollback, staged upgrades & recovery
scripts/test-integration.sh   Cross-layer fstab <-> kernel <-> services test via real QEMU boot
scripts/test-boot-lifecycle.sh Runs 9 QEMU lifecycle scenarios (via scripts/qemu_lifecycle.py)
scripts/build-rootfs.sh       Assembles minimal distro rootfs (static BusyBox + ninit)
scripts/run-qemu.sh           Boots rootfs in QEMU: serial console & milestone verification
scripts/lint-log-patterns.py  Linter for log strings, assertions, and legacy markers
scripts/verify-format-strings.py Linter for printf format specifier safety (-Wformat=2)
distro/                       Distro builder outputs (rootfs/, cache/, initramfs) - gitignored
doc/                          Technical documentation (see below)
.github/workflows/ci.yml      CI workflow: static build, linting, tests, QEMU boot
SECURITY.md                   Security policy and vulnerability disclosure instructions
LICENSE                       MIT License
```

## Documentation

| Document | Contents |
|---|---|
| [doc/architecture.md](doc/architecture.md) | Internal architecture: boot sequence, event loop, signals, respawn, shutdown, cgroup, logging |
| [doc/account-security.md](doc/account-security.md) | Phase A: default accounts, password policy, `sane-accounts` lifecycle CLI, and `doas` escalation policy |
| [doc/configuration.md](doc/configuration.md) | Syntax and semantics of `/etc/init.conf`, `/etc/fstab`, `/run/initctl`, and log paths |
| [doc/build-and-test.md](doc/build-and-test.md) | Static build, test harnesses, CI workflow, manual chroot testing, troubleshooting |
| [doc/distro-builder.md](doc/distro-builder.md) | Rootfs assembly, initramfs packaging, QEMU headless validation |
| [doc/glossary-i18n.md](doc/glossary-i18n.md) | Internationalization glossary, terminology mapping, and log string tables |
| [doc/networking.md](doc/networking.md) | Phase B: `sane-net`, DNS/DHCP, Wi-Fi, reconnect, and outbound TLS |
| [doc/reliability.md](doc/reliability.md) | Phase C: snapshots, verified rollback, staged upgrades, recovery, logging, backup and restore |
| [doc/README.md](doc/README.md) | Documentation index, project status, and architectural roadmap |
| [SECURITY.md](SECURITY.md) | Threat model, operational security boundaries, and vulnerability reporting |

## Status

Current release: **v1.2.0** (See full release details in [RELEASE-NOTES-v1.2.0.md](RELEASE-NOTES-v1.2.0.md) and changelog history in [CHANGELOG.md](CHANGELOG.md)).

### Core Feature Freeze Notice (v1.3.0 Milestone)
> [!IMPORTANT]
> The core engine binaries (`ninit` PID 1 and `spm` package manager engine) are **FEATURE-FROZEN** for the v1.3.0 cycle.
> Development has pivoted from an experimental "root lab" appliance to a **Daily Terminal Workstation**, prioritizing userspace networking, outbound TLS (`ca-certificates`, `mbedtls`, `curl`), and multi-user login (`getty`, `udhcpc`, `doas`). Window manager and graphical desktop environments are deferred to v2.0/v3.0.

## Contributors

- [Iky969](https://github.com/Iky969) — maintainer, `ninit` PID 1 and core engine
- [fyxm969](https://github.com/fyxm969) — clawrza self-hosting toolchain recipes
- [fbri67](https://github.com/fbri67) — `contrib/muslbox` `safe_path()` guard and static `httpsget` recipe

## License

[MIT](LICENSE) © 2026 Iky969. Security issues: do not open public issues — please follow [SECURITY.md](SECURITY.md).
