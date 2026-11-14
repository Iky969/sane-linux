# ninit Configuration Reference

*[English](configuration.md) | [Bahasa Indonesia](id/configuration.md)*

## `/etc/init.conf`

Line format:

```
<name>:<mode>:<command>[:requires=<name1>,<name2>,...][:memory_max=<val>][:cpu_max=<val>][:pids_max=<val>][:timeout=<sec>]
```

| Field | Rules & Behavior |
|---|---|
| `<name>` | Max 127 characters. Longer entries are **rejected** (`Parse err: service name too long ... entry rejected`) rather than silently truncated. Must not contain `/` (as the name maps to a cgroup leaf directory). Used in log prefixes and cgroup leaf paths `/sys/fs/cgroup/ninit/<name>`. |
| `<mode>` | `respawn` (re-spawned automatically on termination) or `once` (executed once). Unknown modes trigger a warning and default to `once`. |
| `<command>` | Max 511 characters. Longer commands are **rejected** rather than truncated. Executed via `/bin/sh -c`. May contain colons (split at the earliest recognized option tag). |
| `:requires=` | Optional. Comma-separated list of service dependencies (max 255 characters; longer entries are rejected). `once` services must succeed (`exit 0`) before dependent services execute. `respawn` services only need to be running (`pid > 0`). If a `respawn` dependency crash-loops to `SVC_STATE_FAILED`, or a `once` dependency fails/times out, dependent services are automatically cancelled (`SVC_STATE_FAILED`). |
| `:memory_max=` | Optional. Service memory limit (max 63 characters). Written to cgroup v2 leaf `/sys/fs/cgroup/ninit/<name>/memory.max`. Valid values: `max` or a positive integer with an optional unit suffix (`K`/`k`, `M`/`m`, `G`/`g`, or plain bytes; e.g. `16M`, `256M`, `1G`, `max`). Exceeding limits deterministically triggers the kernel OOM killer (`SIGKILL`, exit `0x9`). Malformed formats (negative values, multi-character units like `64MB`, random text, or zero) are rejected gracefully (ignored with a warning). |
| `:cpu_max=` | Optional. CFS CPU bandwidth quota (max 63 characters). Written to `/sys/fs/cgroup/ninit/<name>/cpu.max`. Valid format: `<quota> <period>` consisting of two positive integers separated by exactly one space (e.g. `50000 100000` for 50% CPU quota per 100ms period). Malformed formats (non-numeric, multiple spaces, zero/negative values, missing period) are rejected gracefully (ignored with a warning). |
| `:pids_max=` | Optional. Maximum number of processes permitted in the service's cgroup (max 63 characters). Written to `/sys/fs/cgroup/ninit/<name>/pids.max`. Valid format: `max` or a positive integer (e.g. `5`, `50`, `max`). Non-numeric, zero, or negative values are rejected gracefully (ignored with a warning). `fork()` attempts exceeding this limit are rejected by the kernel with `EAGAIN` (`Resource temporarily unavailable`). |
| `:timeout=` | Optional (exclusive to `once` services, max 10 characters). Execution timeout in seconds (e.g. `:timeout=60`, `:timeout=120`). Default: 30 seconds (`ONCE_START_TIMEOUT`). If exceeded, the service is forcefully terminated (`SIGKILL`), marked `SVC_STATE_FAILED`, and all dependents are cancelled. Specifying `0`, `none`, or `infinity` disables the timeout. **Warning**: disabling timeouts risks hanging dependent services indefinitely if the command deadlocks. Out-of-range values (outside 1–86400s) default to 30 seconds. |

### General Syntax Rules

- Lines starting with `#` (optional leading whitespace) and empty lines are ignored.
- Lines exceeding 1023 characters are rejected in full (`Parse err: line exceeds MAX_LINE ...`); subsequent lines continue to be processed. The same rule applies to `/etc/fstab`.
- Lines missing the first or second `:` delimiter are logged as `Parse err: ...` and skipped.
- Option tags (`:requires=`, `:memory_max=`, `:cpu_max=`, `:pids_max=`, `:timeout=`) may appear in any order following `<command>`.
- Cgroup resource limits are applied to the leaf `/sys/fs/cgroup/ninit/<name>/` before the child PID is added to `cgroup.procs`. Writing controller masks (`+memory +cpu +pids`) to `/sys/fs/cgroup/cgroup.subtree_control` tolerates partial failures in nested/container environments without failing boot.
- Graceful error handling: malformed resource limit values are ignored with a warning (`Parse err: ... invalid on service '...', limit ignored`), running the service unconstrained without crashing init or triggering a rescue shell.
- Lifecycle orphan cleanup:
  - `respawn` services: when the leader exits, `cgroup_kill_service` terminates lingering child processes via `cgroup.kill` (with fallback PID scanning on pre-5.14 kernels) during `RESPAWN_DELAY` (2s). Cleanup is repeated before a new PID is assigned.
  - `once` services: upon exit (`SVC_STATE_DONE` or `SVC_STATE_FAILED`), `cgroup_kill_service` cleans up orphan processes before `cleanup_cgroup` removes the leaf directory via `rmdir` (polling up to 20 times for `EBUSY` to accommodate kernel reference release latencies).
- **Cgroup Fail-Open Behavior**: When cgroup v2 is unavailable, services run unconstrained. If resource limits were requested, a warning is emitted: `Warning: resource limits ignored on service '<name>' because cgroup unavailable`.
- Unreadable or missing configuration files trigger `Config failed to read/parse!` and route to the emergency rescue shell.
- Maximum capacity: **64 services** (`MAX_SERVICES`); excess services are ignored with a warning.
- Circular dependencies trigger `FATAL: CYCLE DETECTED` and route to the rescue shell.
- Missing dependencies trigger `FATAL: Dependency '<dep>' for '<service>' not found` and route to the rescue shell.
- Configuration paths can be overridden via the first command-line argument (`/sbin/init /path/init.conf`); defaults to `/etc/init.conf`.

Example:

```
# /etc/init.conf
shell:respawn:/bin/sh
logger:once:/bin/sh -c 'echo boot ok > /dev/console'
net:once:/bin/sh -c 'ip link set lo up':requires=logger
web:respawn:/bin/httpd -p 8080:requires=net,logger:memory_max=256M:cpu_max=50000 100000:pids_max=50
worker:respawn:/usr/bin/worker:memory_max=128M:pids_max=20
```

### Cgroup v2 Resource Limits & Semantic Validation

`ninit` manages process resource limits using Cgroup v2 (*unified hierarchy*) on leaf nodes under `/sys/fs/cgroup/ninit/<name>/`.

#### 1. Semantic Validation Rules

The `/etc/init.conf` parser validates options before writing to sysfs:

- **`cpu_max=<quota> <period>`**:
  - **Valid Format**: Two positive integers separated by a single space (`' '`), e.g. `50000 100000` (50% CPU quota over a 100,000 µs period).
  - **Rules**: Quota > 0, period > 0, digits (`0-9`) only with one separating space, within integer range (`ERANGE`).
  - **Invalid/Rejected**: Non-numeric text (`invalid 100000`), double spaces (`50000  100000`), missing period (`50000`), zero or negative values (`-50000 100000`).

- **`memory_max=<value>`**:
  - **Valid Format**: String literal `"max"` or a positive integer with an optional single unit suffix: `K`/`k` (kibibytes), `M`/`m` (mebibytes), `G`/`g` (gibibytes), or raw bytes. Examples: `16M`, `256M`, `1G`, `max`.
  - **Rules**: Numeric digits preceding the unit must be > 0 and within range. Suffix must be a single character.
  - **Invalid/Rejected**: Multi-character units (`64MB`, `256MiB`), non-numeric text (`corrupted!@#`), negative values (`-100M`), or zero (`0`).

- **`pids_max=<value>`**:
  - **Valid Format**: String literal `"max"` or a positive integer: `5`, `25`, `50`, `max`.
  - **Rules**: Plain digits (`0-9`) > 0 without signs, within integer range.
  - **Invalid/Rejected**: Negative values (`-5`), zero (`0`), non-numeric strings (`invalid`).

#### 2. Graceful Error Handling

When malformed limit values are encountered:
1. `ninit` does **not** abort overall configuration parsing.
2. `ninit` does **not** crash or drop into rescue mode.
3. An informative warning is logged:
   ```
   [YYYY-MM-DD HH:MM:SS] ninit: Parse err: invalid <tag> '<value>' on service '<name>', limit ignored
   ```
4. The malformed limit is discarded, and the service starts unconstrained.

#### 3. Cgroup Lifecycle & Orphan Cleanup

To prevent orphaned processes when service leaders terminate:
- **Subtree Root Enablement**: During boot, `ninit` enables `+memory +cpu +pids` on `/sys/fs/cgroup/cgroup.subtree_control` and `/sys/fs/cgroup/ninit/cgroup.subtree_control`. If writing fails, individual controllers are attempted with `(nested/container tolerant)` or `(partial tolerance)` logs.
- **Respawn Cleanup**: When a `respawn` service leader exits, `cgroup_kill_service` executes `cgroup.kill` to sweep child processes during `RESPAWN_DELAY` (2s). Cleanup repeats before a new generation PID is attached.
- **Once Cleanup**: When a `once` service terminates (`SVC_STATE_DONE` or `SVC_STATE_FAILED`), `cgroup_kill_service` sweeps child processes before `cleanup_cgroup` is called.
- **Leaf `rmdir` Polling**: `cleanup_cgroup` invokes `cgroup_kill_service` and attempts `rmdir` on `/sys/fs/cgroup/ninit/<name>`. If the kernel returns `EBUSY`, it polls up to 20 times with 5 ms intervals (`usleep(5000)`, 100 ms max). Upon success, it logs `cgroup: cleaned up '<name>'`.

#### 4. Fail-Open Fallback Contract

When cgroup v2 is unavailable:
1. **Guaranteed Availability**: Services continue running normally unconstrained without halting boot.
2. **Explicit Logging**:
   ```
   [YYYY-MM-DD HH:MM:SS] ninit: cgroup: fail-open active for '<name>' (cgroup unavailable)
   ```
3. **Resource Limit Warning**:
   ```
   [YYYY-MM-DD HH:MM:SS] ninit: Warning: resource limits ignored on service '<name>' because cgroup unavailable
   ```
4. **Deadlock-Free Unblocking**: The pre-exec synchronization pipe unblocks child execution regardless of cgroup setup status.

## `/etc/fstab`

Mounted once during boot, immediately following pseudo-filesystem mounts (`proc`, `sysfs`, `devtmpfs`, `tmpfs`). Standard 5- or 6-column format:

```
<device> <mountpoint> <fstype> <options> [dump] [pass]
```

### Options Processing

Options are processed **left-to-right**, with later tokens overriding earlier ones:

| Option | Handling |
|---|---|
| `ro`, `noexec`, `nosuid`, `nodev`, `sync`, `dirsync`, `remount` | Flags: `MS_RDONLY`, `MS_NOEXEC`, `MS_NOSUID`, `MS_NODEV`, `MS_SYNCHRONOUS`, `MS_DIRSYNC`, `MS_REMOUNT` |
| `noatime`, `relatime`, `strictatime` | Atime mode flags; mutually exclusive (last token wins) |
| `nodiratime`, `lazytime` | Flags: `MS_NODIRATIME`, `MS_LAZYTIME` |
| `rw`, `async`, `atime`, `diratime`, `exec`, `suid`, `dev` | Negating tokens: clears opposing flag bits (e.g. `ro,rw` yields `rw`) |
| `user`, `users` | Applies `mount(8)` defaults: `noexec,nosuid,nodev` |
| `owner`, `group` | Applies `mount(8)` defaults: `nosuid,nodev` |
| `defaults` | Discarded completely (a `mount(8)` placeholder rejected by the kernel as `EINVAL`) |
| `auto`, `nouser`, `_netdev`, `nofail`, `x-*`, `comment=*` | Userspace-only options: logged as ignored, not forwarded to kernel |
| `noauto` | Entry skipped entirely (like `mount -a`); mountpoint is **not** created |
| `bind`, `rbind` | **Unsupported**: entry skipped with an explicit log message; directory not created |
| Other options (`size=`, `uid=`, `mode=`, ...) | **Forwarded as the 5th argument to `mount()`** (`data` parameter) |

Flag tokens are never forwarded as `data`, preventing filesystem parsers (ext4, tmpfs) from rejecting unknown data options with `EINVAL`.

### Mountpoint Rules

- Octal escapes in `device` and `mountpoint` (`\040` for space, `\011` for tab, `\012` for newline, `\134` for backslash) are **decoded** prior to processing. Traversal components (`\056\056` -> `..`) are rejected.
- **Duplicate Mountpoints**: Mountpoints already mounted earlier in the same run are skipped with a log entry (`duplicate mountpoint, already mounted by previous entry`), preserving earlier options (e.g. `nosuid`). Trailing slashes are normalized (`/mnt/x/` == `/mnt/x`).
- Created **recursively** (`mkdir -p` equivalent) with `0755` permissions for new directories, independent of inherited umask.
- Must be an absolute path. Existing path components must be directories; dangling symlinks or regular files are rejected.
- Traversal components (`.` and `..`) are rejected.
- Skipped entries (`noauto`, `bind`) do not create directories.
- Default path is `/etc/fstab`, overridable at build time via `-DFSTAB_PATH="\"/path/fstab\""`.

Example:

```
# Minimal /etc/fstab suitable for test chroots
proc   /proc   proc    defaults                   0 0
tmpfs  /tmp    tmpfs   size=64m,mode=1777          0 0
tmpfs  /data   tmpfs   defaults,size=32m,uid=1000 0 0
```

## Signals

| Signal | Action |
|---|---|
| `SIGTERM` | Graceful shutdown → `RB_POWER_OFF` (power off) |
| `SIGINT` | Graceful shutdown → `RB_AUTOBOOT` (reboot) |
| `SIGUSR1` | Force shutdown → `RB_POWER_OFF` (immediate `SIGKILL` to all services) |
| `SIGUSR2` | Force shutdown → `RB_AUTOBOOT` (immediate `SIGKILL` + reboot) |
| `SIGCHLD` | Child process reaping (internal event loop trigger) |

```bash
kill -TERM 1      # Orderly poweroff
kill -USR2 1      # Force immediate reboot
```

## `/run/initctl`

Line-based control FIFO (mode `0600`):

| Command | Effect |
|---|---|
| `poweroff` | Graceful shutdown (`RB_POWER_OFF`) |
| `reboot` | Graceful shutdown (`RB_AUTOBOOT`) |
| `force-poweroff` | Force immediate shutdown |
| `force-reboot` | Force immediate reboot |

```bash
echo reboot > /run/initctl
```

Commands are read **line-by-line**, allowing multi-line writes:

```bash
printf 'poweroff\nreboot\n' > /run/initctl   # First command executes immediately
```

> [!NOTE]
> `/run/initctl` is a streaming line-buffered FIFO. Commands **must be newline-terminated** (e.g. `echo poweroff > /run/initctl` or `printf "poweroff\n" > /run/initctl`). Writing raw bytes without a trailing newline (e.g. `printf "poweroff" > /run/initctl`) will hold the data in the input buffer awaiting a delimiter, and will not take effect until a newline is delivered or the buffer limit (255 bytes) is reached.

Empty lines and trailing whitespace/`\r` are ignored. Unrecognized commands are logged.

## Hostname

If `/etc/hostname` exists, the first line is read and applied via `sethostname()`.

## Filesystem Paths Used by ninit

| Path | Purpose |
|---|---|
| `/etc/init.conf` | Service list (default; overridable via `argv[1]`) |
| `/etc/fstab` | Additional filesystem mount table |
| `/etc/hostname` | Hostname configuration |
| `/proc`, `/sys`, `/dev`, `/run`, `/tmp` | Pseudo-filesystems mounted automatically at boot |
| `/sys/fs/cgroup` | Cgroup v2 root (mounted if not already present) |
| `/sys/fs/cgroup/ninit/<name>` | Per-service leaf cgroups |
| `/var/log/ninit.log` | Primary init log file |
| `/run/initctl`, `/run/log.fifo` | Control and service log FIFOs |
| `/bin/sh` | Command interpreter for service execution |
| `/dev/kmsg`, `/dev/console` | Log output targets |
