# Distro Builder: Minimal Rootfs + QEMU Boot

*[English](distro-builder.md) | [Bahasa Indonesia](id/distro-builder.md)*

This milestone demonstrates that `ninit` operates as a real **PID 1 inside a complete system**, rather than merely inside a `chroot` or container namespace: a rootfs is built from scratch, packaged into an initramfs, and booted by QEMU with a serial console.

```bash
make rootfs          # scripts/build-rootfs.sh -> distro/rootfs + distro/initramfs.cpio.gz
make qemu            # scripts/run-qemu.sh     -> interactive boot (Ctrl-A X to exit)
SECS=5 make qemu     # automated 5-second boot + milestone checks + console report
```

## Workflow Summary

| Stage | Script | Output |
|---|---|---|
| 1 | `scripts/build-rootfs.sh` | Downloads & compiles static BusyBox, populates `distro/rootfs/`, installs `ninit` as `/sbin/init`, packages into `distro/initramfs.cpio.gz` |
| 2 | `scripts/run-qemu.sh` | Resolves kernel (host kernel or Alpine `vmlinuz-virt`), boots QEMU, verifies boot milestones on serial console |

## Rootfs Structure

| Path | Contents | Notes |
|---|---|---|
| `/bin/busybox` | Static BusyBox 1.36.1 (`gcc -static`, 401 applets) + applet symlinks | Built with `make defconfig` + `CONFIG_STATIC=y` with `CONFIG_TC` disabled + `make LDFLAGS=-static` + `make install` |
| `/bin/sh` | Symlink to `busybox` | Required: `ninit` executes all service commands via `/bin/sh -c` |
| `/sbin/init` | Compiled `ninit` binary (static) | Real PID 1 inside the guest |
| `/sbin/{poweroff,reboot,halt}` | Wrapper scripts writing to `/run/initctl` | Overrides BusyBox applets that send different signals than ninit expects |
| `/etc/init.conf` | `console:respawn:cttyhack /bin/sh -i` | Interactive shell on serial console, named `console` |
| `/etc/passwd`, `/etc/group` | `root:x:0:0`, `root:x:0:` | Minimal user/group tables |
| `/etc/hostname` | `S.A.N.E` | Read by `set_hostname()` during boot |
| `/etc/fstab` | Commented placeholder | Avoids `fstab: ... does not exist, skipped` warning |
| `/dev/{console,null,tty}` | Initial device nodes (`mknod`) | Ensures kernel console functions immediately before devtmpfs mounts |
| `/proc /sys /dev /run /tmp` | Empty mountpoint directories | Mounted automatically by `setup_pseudo_fs()` |
| `/var/log` | Directory | Destination for `ninit.log` |

Working directories (all `.gitignore`d): `distro/cache/` (tarballs & downloaded kernels), `distro/build/` (BusyBox source + `make install` tree), `distro/rootfs/`, `distro/initramfs.cpio.gz`, `distro/qemu-console.log`.

## Kernel Resolution

`scripts/run-qemu.sh` resolves the kernel in the following order:

1. `KERNEL=/path/vmlinuz` when specified explicitly.
2. `KERNEL_MODE=host` → `/boot/vmlinuz-$(uname -r)` (often absent in containers/sandboxes).
3. `KERNEL_MODE=auto` (default) → Host kernel if available; otherwise downloads Alpine `vmlinuz-virt` (`ALPINE_BRANCH=v3.20`, `ALPINE_FLAVOR=virt`). SHA-256 checksums are verified against `distro/cache/vmlinuz-*.sha256`.

## QEMU Invocations

```bash
qemu-system-x86_64 -m 256 -no-reboot \
  -kernel distro/cache/vmlinuz-virt-v3.20 \
  -initrd distro/initramfs.cpio.gz \
  -append "console=ttyS0 rdinit=/sbin/init init=/sbin/init panic=-1 loglevel=7"
```

- **Interactive Mode**: `-nographic` (multiplexes serial console and QEMU monitor on stdio).
- **Automated Mode** (`SECS=<seconds>`): `-display none -serial file:distro/qemu-console.log` captures the guest console cleanly without TTY allocation, bounded by `timeout`. Post-boot, `report()` validates:

  | Check | Rationale |
  |---|---|
  | `ninit start (PID 1)` appears | Init is running as PID 1 |
  | `main loop ready` appears (with latency) | Configuration parsed and initial services spawned |
  | `started console` appears | Service spawned according to `init.conf` |
  | **Exactly one unique PID** for `started console (pid N)` | Console did not crash-loop or respawn unexpectedly |
  | **No `console (pid N) exit status`** | Console remained active throughout the boot window |
  | **No `respawn delayed`** | No failing respawn services |
  | No `Kernel panic` | Kernel booted and ran stably |

  The last four checks are essential because `started console` is logged at `fork()` time before `exec()` succeeds: without them, an invalid command like `console:respawn:/bin/does-not-exist` would falsely pass (tested in `scripts/test-qemu-report.sh` scenario 2).
- `-enable-kvm -cpu host` is added automatically if `/dev/kvm` is writable.

## Boot Evidence (Real Sandbox Execution, TCG without KVM)

```
[    1.256959] Run /sbin/init as init process
[2026-10-27 23:55:18] ninit: cgroup2: /sys/fs/cgroup mounted
[2026-10-27 23:55:18] ninit: === ninit start (PID 1) v1.0.0 ===
[2026-10-27 23:55:18] ninit: hostname = S.A.N.E
[2026-10-27 23:55:18] ninit: started console (pid 403)
~ #
[2026-10-27 23:55:18] ninit: cgroup: 'console' (pid 403) -> /sys/fs/cgroup/ninit/console
[2026-10-27 23:55:18] ninit: main loop ready
```

`main loop ready` appears **~2.0–2.1 seconds** after QEMU starts (TCG emulation).

Interactive session on the serial console:

```
~ # echo HELLO-FROM-GUEST
HELLO-FROM-GUEST
~ # cat /etc/hostname
S.A.N.E
~ # kill -TERM 1
[2026-10-27 23:56:51] ninit: graceful shutdown (cmd=1126301404)
[   10.500910] ACPI: PM: Preparing to enter system sleep state S5
[   10.502328] reboot: Power down
```

`1126301404` (`0x4321FEDC` = `RB_POWER_OFF`): `ninit`'s graceful shutdown executes inside the virtual machine, terminating QEMU cleanly.

## Integration Insights

1. **Services receive `/dev/null` on `stdin`.** `spawn_service()` starts children with `stdin=/dev/null` and `stdout/stderr=/run/log.fifo`. Thus, a bare `shell:respawn:/bin/sh` immediately encounters EOF, exits, and respawns every 2 seconds. Because commands run via `/bin/sh -c`, internal redirection connects the interactive console to the TTY: `<> /dev/console >&0 2>&0`.
2. **`cttyhack` for job control.** `ninit` calls `setsid()` in child processes, detaching controlling terminals and causing `sh -i` to warn `can't access tty; job control turned off`. `cttyhack` opens `/dev/console`, establishes it as the controlling terminal (`TIOCSCTTY`), and hands control to the shell.
3. **BusyBox signal table mismatch handled via wrappers.**
   BusyBox `halt`/`poweroff`/`reboot` applets send `SIGUSR1`/`SIGUSR2`/`SIGTERM` to PID 1, whereas `ninit` maps `SIGUSR2` to *force reboot*: typing `poweroff` inside the guest previously caused a reboot. `scripts/build-rootfs.sh` resolves this by installing `/sbin` wrappers that communicate via `/run/initctl`:

   | Guest Command | Wrapper Action | ninit Behavior |
   |---|---|---|
   | `/sbin/poweroff` | `echo poweroff > /run/initctl` | Graceful → `RB_POWER_OFF` (power down) |
   | `/sbin/reboot` | `echo reboot > /run/initctl` | Graceful → `RB_AUTOBOOT` (reboot) |
   | `/sbin/halt` | `echo force-poweroff > /run/initctl` | Force → `RB_POWER_OFF` (immediate power down) |

   Key implementation caveats: (a) `/sbin/poweroff` in rootfs is a **symlink to `../bin/busybox`**, requiring `rm -f` prior to creating the wrapper (overwriting without removal corrupts the BusyBox binary); (b) BusyBox applet aliases in other PATH directories are removed so wrappers take precedence. Raw signals remain available: `kill -TERM 1` (clean shutdown), `kill -USR1 1` / `kill -USR2 1` (force poweroff / force reboot).
4. **Early serial input before shell readiness can be dropped.** Piping keystrokes into QEMU at t=0 (e.g. `printf ... | run-qemu.sh`) is timing-sensitive: early bytes can be dropped before the console shell finishes startup. Introduce a delay (`sleep 6`) or type directly into an interactive session.

## Verification: Poweroff vs Reboot in QEMU

Commands executed on the serial console after shell readiness:

| Guest Command | ninit Log | Kernel | Result |
|---|---|---|---|
| `command -v poweroff` | — | — | `/sbin/poweroff` (PATH `/sbin:/usr/sbin:/bin:/usr/bin`) |
| `poweroff` | `initctl cmd: 'poweroff'` → `graceful shutdown (cmd=1126301404)` | `reboot: Power down` | Machine powers off, 1x ninit boot, QEMU terminates |
| `reboot` | `initctl cmd: 'reboot'` → `graceful shutdown (cmd=19088743)` | `Restarting system` → `machine restart` | Machine restarts: second ninit boot appears |
| `echo poweroff > /run/initctl` | `initctl cmd: 'poweroff'` → `graceful shutdown` | `reboot: Power down` | Machine powers off |
| `halt` | `initctl cmd: 'force-poweroff'` → `FORCE shutdown (cmd=1126301404)` | `reboot: Power down` | Immediate power down without waiting for grace period |

`1126301404` (`0x4321FEDC` = `RB_POWER_OFF`), `19088743` (`0x01234567` = `RB_AUTOBOOT`). `reboot` verification requires `NO_REBOOT=0` so QEMU resets instead of exiting on guest reboot.

## Environment Variables

### `scripts/build-rootfs.sh`

| Variable | Default | Description |
|---|---|---|
| `DISTRO_DIR` | `distro` | Build working directory |
| `BB_VERSION` / `BB_URL` / `BB_SHA256` | `1.36.1` / busybox.net / official hash | BusyBox source details (clear `BB_SHA256` to skip hash verification) |
| `BUSYBOX_MODE` | `auto` | `auto` \| `source` (enforce source build) \| `prebuilt` (use static `/bin/busybox`). In `auto`, source build failure falls back to prebuilt binary. |
| `BUSYBOX_PREBUILT` | `/bin/busybox` | Fallback binary if source build fails |
| `BUSYBOX_FORCE` | `0` | `1` = force clean re-download and re-compilation |
| `NINIT` | `./ninit` | Binary installed as `/sbin/init` |
| `JOBS` | `nproc` | Parallel `make` compilation jobs |
| `EXTRA_INIT_CONF` | *(empty)* | Path to extra config appended to `/etc/init.conf` (used by `scripts/test-integration.sh`) |
| `EXTRA_FSTAB` | *(empty)* | Path to extra entries appended to `/etc/fstab` (used by `scripts/test-integration.sh`) |

### `scripts/run-qemu.sh`

| Variable | Default | Description |
|---|---|---|
| `SECS` | *(empty)* | Automated boot timeout in seconds; interactive if omitted |
| `KERNEL` / `KERNEL_MODE` | — / `auto` | Kernel selection |
| `ALPINE_BRANCH` / `ALPINE_FLAVOR` | `v3.20` / `virt` | Alpine kernel download source |
| `MEM` | `256` | Guest RAM allocation (MB) |
| `NO_REBOOT` | `1` | `0` = omit `-no-reboot` so guest reboots reset the VM |
| `REBUILD` | `0` | `1` = rebuild rootfs prior to booting |
| `CONSOLE_LOG` | `distro/qemu-console.log` | Serial console log destination |
| `REPORT_ONLY` | `0` | `1` = do not boot; execute `report()` on existing `CONSOLE_LOG` (used by `scripts/test-qemu-report.sh`) |

## Known Limitations

- **Early serial input (t=0) timing**: Piped input sent before the guest shell finishes initialization can be dropped. Use a ~6 second delay or interact via live terminal.
- **No `getty`/`login` authentication**: Boots directly into a root console shell (`console:respawn:cttyhack /bin/sh -i`).
- **Transient RAM disk**: Executes from initramfs; changes do not persist across reboot cycles.
- **Kernel source**: Defaults to host kernel or precompiled Alpine `vmlinuz-virt` (v3.20) rather than a custom-built minimal kernel.
- BusyBox is built with `defconfig` minus the `tc` applet (401 applets), avoiding legacy CBQ header compatibility issues on modern kernels.
