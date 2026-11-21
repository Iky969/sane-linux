# Build and Test Guide

*[English](build-and-test.md) | [Bahasa Indonesia](id/build-and-test.md)*

## Building ninit

Prerequisites: `build-essential` and `busybox-static`:

```bash
sudo apt-get update && sudo apt-get install build-essential busybox-static python3 shellcheck
make            # -> ./ninit (gcc -static -O2 -Wall)
```

- The binary must be **static** so it executes without an external dynamic loader in minimal root filesystems.
- The `main` branch builds with zero compiler warnings; verify using `-Werror`:
  `make clean && make CFLAGS="-static -O2 -Wall -Werror"`.
- On distributions without static glibc (e.g. Alpine): `make CC=musl-gcc`.
- `make clean` removes `./ninit`. Build artifacts are ignored by `.gitignore`.

## Building the Distro Rootfs

Root build leaves the rootfs root-owned so doas stays 4755 and identity files stay root-owned; only the initramfs.cpio.gz and vmlinuz* output artifacts are handed back to SUDO_USER. Non-root builds finish with an explicit ownership warning (rootfs files stay builder-owned, setuid doas is not effective) and are not deployable until rebuilt as root; clean-distro management of distro/ may need sudo.

## Automated Test Suites

```bash
make lint                              # Python pattern/format linters + ShellCheck gate (11 production scripts)
make lint-shell                        # ShellCheck gate alone (fail-closed on any warning)
make test                              # 12 suites from TEST_SCRIPTS: 7 root-required + 5 unprivileged
sudo -E BIN=./ninit-test sh ./scripts/smoke-test.sh        # 1) PID 1 smoke test (root)
sudo -E BIN=./ninit-test sh ./scripts/test-sigterm.sh      # 2) SIGTERM propagation to services (root)
sudo -E BIN=./ninit-test sh ./scripts/test-config.sh       # 3) Dependency sort + rescue mode + initctl (root)
sh ./scripts/test-qemu-report.sh                            # 4) run-qemu.sh harness fixture validation (no root)
sudo -E BIN=./ninit-test sh ./scripts/test-spawn-failure.sh # 5) Spawn failure paths (root)
sudo -E BIN=./ninit-test sh ./scripts/test-cgroup-limits.sh # 6) Cgroup v2 limits & orphan lifecycle (root)
sudo -E BIN=./ninit-test sh ./scripts/test-respawn-cleanup.sh # 7) Respawn cleanup & grandchild containment (root)
sudo -E BIN=./ninit-test sh ./scripts/test-state-machine.sh  # 8) State machine & telemetry (root)
sh ./scripts/test-accounts.sh                               # 9) Account lifecycle & policy (no root)
sh ./scripts/test-network.sh                                # 10) Networking: sane-net, DNS/DHCP, TLS (no root)
sh ./scripts/test-network-fault.sh                          # 11) Network fault injection & recovery (no root)
sh ./scripts/test-reliability.sh                            # 12) Snapshots, rollback, upgrades, recovery (no root)
# Separate, not part of make test:
make integration                       # real QEMU boot: fstab <-> kernel <-> services
make test-lifecycle                    # seven QEMU account-lifecycle scenarios
```

ShellCheck gate details: `make lint-shell` runs
`shellcheck -S warning -e SC3043,SC3013` over exactly the 11 production shell
scripts (`build-package.sh`, `build-rootfs.sh`, `make-image.sh`,
`provision-accounts.sh`, `run-qemu.sh`, `sane-account-recovery`, `sane-accounts`,
`sane-firstboot`, `sane-install.sh`, `sane-reliability`, `spm`). Test, smoke,
fuzz helpers and Python files are intentionally excluded. `SC3043` (`local`)
and `SC3013` (`-ef`) are documented exclusions: undefined in strict POSIX but
supported by all target shells (dash, ash, BusyBox sh). Info/style severities
are not gated; any warning fails the build.

### Measured suite counts (final pass)

Measured at branch head with `export PATH=/usr/sbin:/sbin:$PATH`. Privileged
suites use `sudo -n -E` and the strict `ninit-test` binary; the two package
suites run from a fresh scratch copy because `test-build-package.sh` rebuilds
BusyBox inputs (never run it in the shared checkout).

| Suite | Invocation | Measured result |
|---|---|---|
| Accounts (unprivileged) | `sh scripts/test-accounts.sh` | 237 passed, 0 failed |
| Accounts (root) | `sudo -n -E sh scripts/test-accounts.sh` | 239 passed, 0 failed |
| Reliability | `sh scripts/test-reliability.sh` | 469 passed, 0 failed |
| SPM | `bash scripts/test-spm.sh` | 36 passed, 0 failed |
| Build package | `bash scripts/test-build-package.sh` (scratch) | 13 passed, 0 failed |
| Build rootfs | `sh scripts/test-build-rootfs.sh` (scratch) | 25 passed, 0 failed |
| Config / initctl | `sudo -n -E BIN=./ninit-test sh scripts/test-config.sh` | 159 `[ OK ]`, 0 `[ FAIL ]` |
| QEMU report harness | `sh scripts/test-qemu-report.sh` | 21 `[ OK ]`, RESULT: PASS |
| Networking | `sh scripts/test-network.sh` | 60 passed, 0 failed |
| Network faults | `sh scripts/test-network-fault.sh` | 137 passed, 0 failed |

The remaining root-required suites print their own pass/fail counts; CI runs
the full 12-suite battery. Counts are re-measured at the final verification
pass rather than copied from older documentation.

### 1. PID 1 Smoke Test (`scripts/smoke-test.sh`)

Test execution workflow:
1. Creates a temporary rootfs (`mktemp -d`), copies the test binary to `<root>/ninit`, copies static BusyBox to `<root>/bin/sh`, and writes `/etc/init.conf` containing `shell:respawn:/bin/sh`.
2. Launches `ninit` as **PID 1** in isolated PID and mount namespaces:

   ```bash
   unshare --pid --fork --kill-child=SIGKILL --mount --propagation private \
       sh -c 'mount -t proc proc <root>/proc && exec chroot <root> /ninit'
   ```

3. Waits for initialization milestones (banner + `main loop ready`).
4. Sends `SIGTERM` to the namespace's PID 1 from the host, measuring shutdown latency.
5. Inspects logs and exits with non-zero status if assertions fail.

Assertions verified:

| Assertion | Significance |
|---|---|
| Startup banner `ninit start (PID 1)` | Init starts cleanly as real PID 1 |
| `main loop ready` | Configuration parsed, services spawned, event loop active |
| `started shell` | Declared service started |
| `graceful shutdown` | `SIGTERM` handled and orderly shutdown path initiated |
| No respawn after shutdown | Guard prevents respawn storms after shutdown begins |
| Latency `SIGTERM → exit < 5000 ms` | Loop not blocked by `sleep()`; overridable via `LATENCY_LIMIT_MS` |

The script invokes `sudo` if unprivileged, cleans up mounts and directories via `trap`, and prints complete logs on failure.

### 2. Service SIGTERM Propagation (`scripts/test-sigterm.sh`)

Guards against child processes inheriting the parent PID 1 **signal mask** (`main()` blocks `SIGTERM`/`SIGCHLD`/`SIGINT`/`SIGUSR1`/`SIGUSR2` for `ppoll`). If this mask is not cleared in the child, services never receive `SIGTERM`: traps do not execute, the 5-second grace window expires, and services are killed via `SIGKILL`.

The script prepares a test service in `/sigterm-service.sh`:

```sh
#!/bin/sh
trap 'echo "Received SIGTERM, bye!"; exit 0' TERM
echo "sigterm-service: running, waiting for SIGTERM (pid $$)"
while true; do sleep 1; done
```

With `/etc/init.conf` configured as `sigterm-test:once:/sigterm-service.sh`, measuring elapsed time until the `exit status` line is logged.

| Assertion | Significance |
|---|---|
| `waiting for SIGTERM` | Test service successfully spawned |
| `SIGTERM` bit (`0x4000`) absent from `SigBlk` | PID 1 signal mask was cleared in child |
| `Received SIGTERM, bye!` | Service trap executes → signal successfully delivered |
| `exit status=0x0` and no `0x9` | Service exited cleanly on its own rather than killed via `SIGKILL` |
| Ack < 4000 ms (grace period 5000 ms) | Shutdown does not rely on `SIGKILL` fallback |

Example passing log output:

```
  | [2026-01-01 00:00:00] ninit: started sigterm-test (pid 3)
  | [2026-01-01 00:00:00] [service] sigterm-service: waiting for SIGTERM (pid 3)
  | [2026-01-01 00:00:00] ninit: main loop ready
  | [2026-01-01 00:00:05] ninit: graceful shutdown (cmd=1126301404)
  | [2026-01-01 00:00:06] ninit: sigterm-test (pid 3) exit status=0x0
  | [2026-01-01 00:00:06] [service] Received SIGTERM, bye!
```

### 3. Configuration & IPC Tests (`scripts/test-config.sh`)

Validates dependency resolution, error handling, and control FIFO parsing across seven isolated runs:

| Section | Target Behavior |
|---|---|
| 1a | Diamond dependencies (`a:requires=b,c` + `b:requires=c`) run ordered as `c → b → a` without false cycle alerts |
| 1b | Dense 64-service configuration (`root` requires `s2..s64`) runs 64/64 services without stack overflow |
| 2 | Missing dependency (`web:once:echo web:requires=db`) → `FATAL: Dependency 'db' for 'web' not found` + rescue shell; `main loop ready` never logged |
| 3a | `printf 'poweroff\nreboot\n' > /run/initctl` executes only the first command (`reboot` never executes) |
| 3b | `printf 'status\npoweroff\n' > /run/initctl` logs unknown commands and processes `poweroff` on line 2 |
| 4a | Unreadable config → `Config failed to read/parse!` + rescue shell; `main loop ready` never logged |
| 4b | Circular dependency (`a:requires=b` + `b:requires=a`) → `FATAL: CYCLE DETECTED` + rescue shell with `SigBlk=0` (Ctrl+C works) |

**Why Section 1b matters**: The legacy `sort_services()` marked nodes when expanded rather than pushed, allowing pending nodes to be pushed repeatedly. On 64-service configurations, `stack_top` overflowed past 64, causing stack-buffer-overflows under AddressSanitizer:

```
==1731==ERROR: AddressSanitizer: stack-buffer-overflow ...
WRITE of size 4 ... in sort_services ninit-old.c:250
    [672, 928) 'stack' (line 228) <== Memory access at offset 928 overflows this variable
```

The current implementation marks `temp_visited[...] = 1` **before** pushing to `stack[]` and guards with `stack_top >= MAX_SERVICES`, guaranteeing each service enters the stack at most once.

### Why not `unshare --mount-proc=<dir>`?

On certain kernels (including container and VPS environments), util-linux attempts propagation changes that the kernel rejects with:

```
unshare: cannot change <dir>/proc filesystem propagation: Invalid argument
```

The `--mount --propagation private` + manual `mount -t proc` approach accomplishes identical isolation (private mount and PID namespaces) while maintaining broad portability.

### 4. Harness Verification (`scripts/test-qemu-report.sh`)

Validates the test harness itself: `run-qemu.sh` in automated mode must detect crashing console services. Because `started console` is logged at `fork()` time before `exec()` succeeds, `console:respawn:/bin/does-not-exist` causes repeated spawn loops while legacy checks falsely passed.

Executed with `REPORT_ONLY=1` against log fixtures without requiring root or QEMU:

| Scenario | Fixture Description | Expected Result |
|---|---|---|
| 1 | Healthy boot (duplicate lines from `/dev/kmsg` + stderr) | PASS; single unique PID check deduplicates lines |
| 2 | Crashing console + respawn loop | FAIL triggered by liveness assertions (unique PID, exit status, respawn delayed) |
| 3 | Single console exit | FAIL triggered by `exit status` check |
| 4 | Kernel panic | FAIL triggered by `absent Kernel panic` |
| 5 | Missing `started console` | FAIL triggered by unique PID count == 0 |
| 6 | Missing `main loop ready` | FAIL triggered by empty `ready_ms` |
| 7 | Healthy console with another service (`web`) delayed | PASS; `web: respawn delayed` does not fail the harness (scoped check) |

Liveness assertions in `report()`: unique PID count on `started console (pid N)` must be exactly 1; `console (pid N) exit status` and `console: respawn delayed` must be absent. Respawn checks are strictly scoped to the `console` service name.

### 5. Spawn Failure Paths (`scripts/test-spawn-failure.sh`)

Verifies error handling when process spawning fails:

1. `respawn_services()` respects dependency graphs: services cancelled due to failed `once` dependencies are never respawned.
2. `once` services encountering `fork()` failure retry up to limits (`MAX_SPAWN_RETRY=3`) before transitioning to `SVC_STATE_FAILED`, preventing indefinite hangs in `SVC_STATE_STOPPED`.

| Scenario | Configuration | Expected Outcome |
|---|---|---|
| 1 | `boot:once` exits 3 + `app:respawn:requires=boot` | `app` is cancelled and `started app` never appears |
| 2 | `ping:once` (SIGCHLD trigger) + `slow:once` sleeps 4s + `app:respawn:requires=slow` | `SLOW-DONE` precedes `APP-START` in `/var/order` |
| 3 | `boot:once` + `app:respawn:requires=boot`, `fork()` forced to return EAGAIN | `boot` transitions to `FAILED` after 3 attempts, `app` cancelled, `main loop ready` still reached |

Scenario 3 deterministically forces `fork()` EAGAIN via cgroup v2 `pids.max=1`. If cgroups or PID controller delegation is absent, the scenario is skipped with `[ -- ]`.

### 6. Cgroup v2 Limits, Semantic Validation & Lifecycle (`scripts/test-cgroup-limits.sh`)

Comprehensive test suite verifying memory limits (OOM), process limits (fork EAGAIN), CPU quotas, sysfs leaf value inspection, option ordering, parser validation (valid vs. malformed values), nested/container subtree tolerance, PR #9 interaction, and orphan lifecycle cleanup via `cgroup_kill_service`.

Git file permissions & host hygiene:
- `scripts/test-cgroup-limits.sh` maintains git file mode `100755` (`chmod +x`).
- Includes a robust `cleanup()` trap that unmounts namespaces (`umount -R`), cleans temporary directories, sweeps test cgroup leaves via `cgroup.kill` and `rmdir`, and leaves host cgroups clean.

| Scenario | Configuration | Expected Outcome |
|---|---|---|
| 1 | `mem_test:once:/bin/mem_hog:memory_max=16M` | Deterministic kernel OOM killer trigger (`SIGKILL`, exit status `0x9`); leaf cgroup cleaned up |
| 2 | `pids_test:once:/bin/fork_test:pids_max=5` | Process fork loop deterministically rejected with `EAGAIN` (`EAGAIN_CONFIRMED count=4`); cgroup cleaned up |
| 3 | `leak:respawn:/bin/sh /bin/leak.sh` | Orphan child processes (`sleep 300 &`) swept by `cgroup_kill_service` during `RESPAWN_DELAY` before next generation |
| 4 | `limits_audit:once:...:pids_max=20:cpu_max=50000 100000:memory_max=32M` | Limit values directly validated against sysfs files (`33554432` bytes on `memory.max`, `50000 100000` on `cpu.max`, `20` on `pids.max`) |
| 5 | `valid_svc:once:...:memory_max=64M:cpu_max=50000 100000:pids_max=25` + malformed options (`64MB`, `-100M`, `corrupted!@#`, `invalid 100000`, `50000  100000`, `50000`, `-5`, `invalid`, `0`) | Malformed values rejected with warnings (`invalid ..., limit ignored`), valid limits applied to `valid_svc`, stable event loop |
| 6 | `svc_nested:once:...:pids_max=10` on read-only subtree control | Write failure tolerated with log `(nested/container tolerant)`, service spawned successfully (`NESTED_OK`), clean shutdown |
| 7 | `boot_pr9:once:exit 0` + `app_dep:respawn:exit 0:requires=boot_pr9` in `pids.max=1` cgroup | Fork EAGAIN retried up to `MAX_SPAWN_RETRY` (3x) without busy-loop, then marked `FAILED`; dependent `app_dep` cancelled deterministically |
| 8 | `orphan_maker:once:/bin/sh /bin/once_fork.sh` (spawns `sleep 300 &`) + `checker:once:...:requires=orphan_maker` | Upon exit, `cgroup_kill_service` cleans up orphans before `rmdir` without `EBUSY`; `checker` confirms `LINGERING_ONCE_ORPHANS=0` |

### 7. Cross-Layer Integration Test (`scripts/test-integration.sh`)

Validates interactions across the filesystem, kernel, and init layers during a real QEMU boot:

1. Injects a test `fstab` (data option `size=1m`, octal escaped mountpoint `/mnt/a\040b`, duplicate mountpoint) + test `init.conf` with `mountproof:once:` reading `/proc/mounts` from inside the guest.
2. Builds the rootfs and executes a single QEMU boot via `run-qemu.sh`.
3. Asserts cross-layer behavior:

| Assertion | Significance |
|---|---|
| `fstab: mount ... [data: size=1m] ok` | Data options forwarded directly to kernel `mount()` |
| `fstab: mount tmpfs -> /mnt/a b ... ok` | Octal escape decoding functions against real kernel |
| `skipped (duplicate mountpoint` | Duplicate entries skipped rather than stacked |
| `INTEGRATION-MOUNT-VISIBLE` | Mounts visible from guest service perspective |
| Console line order | All `fstab:` activity completes before services start |
| `report()` PASS | Test fstab boot satisfies all standard harness checks |

Note on TCG CPU model: Automated mode employs `-cpu max` in the absence of `/dev/kvm`. Default QEMU `qemu64` CPUs lack modern instruction sets, causing immediate SIGILL on modern toolchains (e.g. Ubuntu x86-64-v3).

## Manual Testing in chroot

```bash
# 1. Setup temporary rootfs
mkdir -p /tmp/myrootfs/{proc,sys,dev,run,tmp,etc,var/log,bin}
cp ninit /tmp/myrootfs/
cp /bin/busybox /tmp/myrootfs/bin/sh
printf 'shell:respawn:/bin/sh\n' > /tmp/myrootfs/etc/init.conf

# 2. Launch as PID 1 in isolated namespaces
sudo timeout -k 5 8 unshare --pid --fork --kill-child=SIGKILL --mount --propagation private \
    sh -c 'mount -t proc proc /tmp/myrootfs/proc && exec chroot /tmp/myrootfs /ninit'
```

Full init logs are recorded in `/tmp/myrootfs/var/log/ninit.log`.

## CI Workflow (`.github/workflows/ci.yml`)

Runs on `ubuntu-latest` with SHA-pinned actions across five jobs:
- `security-scan`: Scans git history for secret leaks using Gitleaks (`gitleaks-action`).
- `build-and-smoke-test`: Installs dependencies (`build-essential`, `busybox-static`, `python3`, `shellcheck`, …) → `make` → verifies static binary via `readelf` (asserts no `INTERP`) → `make lint` (pattern/format + `lint-shell`) and a dedicated `make lint-shell` step → runs all 12 `make test` suites (7 privileged via `sudo -E BIN=./ninit-test`, 5 unprivileged: qemu-report, accounts, network, network-fault, reliability) → fuzz harness → rebuilds under `CFLAGS="-static -O2 -Wall -Werror -fstack-protector-strong"`.
- `rootfs-distro`: Validates distro builder and QEMU boot paths: installs dependencies → `sudo sh ./scripts/build-rootfs.sh` → boots QEMU (`sudo SECS=20 sh ./scripts/run-qemu.sh`) → runs cross-layer integration boot (`sudo SECS=40 sh ./scripts/test-integration.sh`) → panic-path regression.
- `boot-lifecycle`: Builds the disk image and runs the seven QEMU account-lifecycle scenarios (`make test-lifecycle`).
- `clawrza-packages`: Builds the three self-hosting recipe packages and installs them with `spm` into a temporary root, verifying payload checksums.

## Troubleshooting

| Symptom | Cause & Solution |
|---|---|
| `unshare: cannot change ... filesystem propagation: Invalid argument` | Kernel rejects propagation changes; use `--mount --propagation private` as shown above. |
| Test process requires `SIGKILL` (exit 137) | `shutdown_all()` observes a 5-second grace window; set `timeout -k` > 5 seconds, or send `SIGUSR1`/`SIGUSR2` for force paths. |
| Exit code 124 from `timeout` | Expected: process stopped cleanly after receiving `SIGTERM`. |
| `ninit must be run as PID 1` | Invoked outside PID 1 context; execute with `unshare --pid --fork`. |
| `cgroup: mkdir ... failed: Permission denied` | Unprivileged execution or existing host cgroup conflict. Logged as a warning; init continues in fail-open mode. |
| Service fails to spawn, `execl` fails | `/bin/sh` missing from rootfs; install static BusyBox as `/bin/sh`. |
| Service output absent | `/run` must be mounted as `tmpfs` (automated via `setup_pseudo_fs()`) and services must write to stdout/stderr. |
| Service killed with `exit status=0x9` | Service did not handle `SIGTERM`: inherited signal mask was not cleared or service ignores `SIGTERM`. Verify with `test-sigterm.sh`. |
| `collect2: cannot find -lc` | Static libc missing; install `libc6-dev` / `libc-dev` or compile with `make CC=musl-gcc`. |
| Fstab logs appear only on console | Expected architectural ordering: `mount_fstab()` executes before `/var/log/ninit.log` is opened. |
| `FATAL: Dependency '<x>' for '<y>' not found` | `:requires=` references an undeclared service. Correct `/etc/init.conf` and reboot. |
| `FATAL: CYCLE DETECTED at <x> -> <y>` | Circular dependency graph. Break cyclic `:requires=` dependencies. |
| `FATAL: Stack overflow in topological sort!` | Guard in `sort_services()`. If observed on < 64 services, report as a bug. |
