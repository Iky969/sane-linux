# Security Policy

*[English](SECURITY.md) | [Bahasa Indonesia](SECURITY.id.md)*

`ninit` is an **experimental init system (PID 1)** designed for research and custom Linux distribution builds. Because it executes with full root privileges, defects at this layer can have severe system-wide impacts. This document outlines vulnerability reporting procedures, supported versions, and scope boundaries.

## Supported Versions

| Version | Supported |
|---|---|
| `main` (latest release: **v1.1.0**) | ✅ |
| Older commits/tags | ❌ (please verify against `main` first) |

Security fixes are committed exclusively to the `main` branch.

## Reporting a Vulnerability

**Do not** open public GitHub issues for security vulnerabilities. Please report through private channels:

1. **GitHub Private Vulnerability Reporting** (recommended):
   Navigate to the **Security → Report a vulnerability** tab at:
   <https://github.com/Iky969/sane-linux/security/advisories/new>.
2. **Email**: Contact `ryuzarza@gmail.com` with the subject line `[SECURITY] ninit: <summary>`.

Please include the following information where available:
- Tested commit/version (`git rev-parse HEAD`) and build invocation (`make` + gcc version),
- Environment: host Linux distribution, kernel version (`uname -a`), execution context (real bare-metal/VM PID 1 vs. `unshare`/`chroot`/container),
- Minimal reproduction files: `/etc/init.conf` and/or `/etc/fstab` triggering the issue,
- Reproduction steps and diagnostic evidence (logs, `readelf`, `strace`, core dumps),
- Potential impact: boot denial of service, privilege escalation, memory disclosure, mount leaks, etc.

This is an independent open-source project without a formal SLA. Reports are typically acknowledged within a few days, and reporter credit will be attributed in release advisories upon request.

## Scope

**In-Scope** (vulnerabilities that should be reported):

- Parsing of `/etc/init.conf` (modes, `:requires=`, buffer boundaries) and `/etc/fstab` (flags, data options forwarded to `mount()`): parser bugs, buffer overflows, out-of-bounds reads, or unexpected option elevation into mount flags.
- Signal handling & event loop: race conditions, signal drop, deadlocks, uncontrolled respawn storms, or unkillable processes preventing shutdown.
- Process management: PID leaks, zombie accumulation, unintended `execl()` argument passing, or missing child process isolation.
- Control channels (`/run/initctl` and `/run/log.fifo`): blocking I/O stalling init, non-root access, memory leaks, or FIFO denial of service.
- Cgroup operations (`/sys/fs/cgroup/ninit/<name>`): path traversal through service names, target cgroup corruption, or failure to cleanup leaf hierarchies.

**Out-of-Scope**:

- Upstream defects in the Linux kernel, BusyBox, glibc, or musl libc.
- Host sandbox escape, physical hardware access, or cold-boot attacks.
- Malicious configurations authored by root: users with write access to `/etc/init.conf` or `/etc/fstab` already have root authority.
- Operational security issues, such as insecure rootfs file permissions, untrusted `/bin/sh` binaries, or weak root passwords.
- Features not yet implemented (e.g. seccomp filtering, Mandatory Access Control / SELinux labels, user namespaces, cryptographic service signature verification). These represent known architectural limitations rather than security vulnerabilities.
- Denial of service caused by root-authored services (e.g. intentional respawn flood loops).

## Threat Model & Operational Security Notes

- `ninit` runs as PID 1 with UID 0 and **without** privilege dropping. Every service command in `/etc/init.conf` is executed as `root` via `/bin/sh -c` — service configurations are treated as *trusted input*.
- `/run` is mounted as `tmpfs` and the control FIFO is created with `0600` permissions owned by root; only root processes may dispatch commands to `/run/initctl`.
- Service output is read from `/run/log.fifo` non-blockingly; runaway services cannot stall init by filling the FIFO buffer.
- **Cgroup v2 provides resource containment, not a process isolation sandbox.**
  The `memory`, `cpu`, and `pids` controllers enforce quotas, with the following caveats:
  - Resource limits **do not** isolate PID, mount, network, or filesystem namespaces; services share namespaces with PID 1 unless isolated by custom wrappers.
  - If cgroup v2 controllers are unavailable (e.g. kernels lacking `CONFIG_CGROUPS`, or unprivileged containers), `ninit` falls back to *fail-open* mode: services run without limits and warnings are logged. Fail-closed resource gating is not enforced at boot.
  - Services that drop privileges (`setuid`/`setgid`) remain within the same leaf cgroup; cgroup v2 does not enforce privilege boundaries.
- Control file descriptors (`/run/initctl`, `/run/log.fifo`, `/var/log/ninit.log`) are marked with `O_CLOEXEC` and closed explicitly in the child branch before `execl()` in `spawn_service()` and in `enter_rescue_mode()`, preventing privilege-dropped child processes from inheriting control handles (SANE-06-01).
- `/dev/kmsg` is written directly by `ninit`, routing early boot logs into the kernel ring buffer (`dmesg`).
- Before deploying on hardware: validate configurations within virtual machines or containers, ensure serial console access is available, and verify clean poweroff/reboot behavior.
