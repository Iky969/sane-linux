# ninit Architecture

*[English](architecture.md) | [Bahasa Indonesia](id/architecture.md)*

This document describes the internal architecture of `ninit.c`. Line references and design patterns correspond to the latest release on the `main` branch.

## Core Principles

1. **Single File, Zero Dependencies**: Relies exclusively on libc and Linux system calls. Designed for strictly static compilation to serve as `/sbin/init` in minimal root filesystems.
2. **Rejects Non-PID 1 Invocations**: Exits immediately if `getpid() != 1`, as process reaping and `reboot()` semantics are valid only when running as PID 1.
3. **Non-blocking Event Loop**: Never uses blocking `sleep()` calls in service spawn or supervision paths.
4. **Signals Take Precedence Over Services**: Shutdown and termination signals are processed before child reaping and respawn scheduling.

## Boot Sequence (`main()`)

```
Verify getpid() == 1  ->  umask(022)  ->  Block signals & initialize empty mask sigemptyset(&orig)
   ->  Install sigaction handlers (SIGCHLD/SIGTERM/SIGINT/SIGUSR1/SIGUSR2) + ignore SIGPIPE
   ->  setup_pseudo_fs()          mounts proc, sysfs, devtmpfs, tmpfs on /run & /tmp, cgroup2
   ->  mount_fstab()              mounts filesystems from /etc/fstab
   ->  Open /var/log/ninit.log, emit startup banner
   ->  set_hostname()             read from /etc/hostname
   ->  parse_config(argv[1] or /etc/init.conf)   failure => rescue shell (/bin/sh)
   ->  validate_dependencies()    missing dependency => rescue shell (/bin/sh)
   ->  sort_services()            DFS topological sort; cycles => rescue shell (/bin/sh)
   ->  setup_initctl() (/run/initctl), setup_log_fifo() (/run/log.fifo)
   ->  spawn_service() for all configured services
   ->  Log "main loop ready"  ->  for (;;) event loop
```

Ordering note: `mount_fstab()` is intentionally invoked **before** `/var/log/ninit.log` is opened. Early filesystem messages appear exclusively on the console and `/dev/kmsg`.

### Rescue Mode (`enter_rescue_mode`)

Three conditions route execution to an emergency shell:
1. Unreadable configuration (`parse_config()` failure),
2. Missing dependencies referenced in `:requires=`,
3. Dependency cycles detected during topological sort.

All paths invoke `enter_rescue_mode(reason)`:
1. Logs the failure reason and `Entering rescue mode (shell).`;
2. Clears the PID 1 signal mask (`sigprocmask(SIG_SETMASK, &empty, NULL)`), ensuring the rescue shell receives `SIGINT` (Ctrl+C works interactively);
3. Resets `SIGPIPE` disposition to `SIG_DFL`, ensuring pipeline utilities like `yes | head -n 1` function normally;
4. Closes control file descriptors (FIFO, logs) to prevent leaks to child processes (SANE-06-01);
5. Replaces the process via `execl("/bin/sh", "sh", NULL)`. If `execl()` fails, `_exit(1)` terminates the process.

This function never returns, guaranteeing that boot never proceeds in an inconsistent half-configured state. Tested in `scripts/test-config.sh` section 4.

## Event Loop

```c
for (;;) {
    struct timespec ts;
    struct timespec *pto = compute_poll_timeout(&ts);   /* housekeeping timer */
    int ret = ppoll(fds, nfds, pto, &orig);
    int perr = errno;                                   /* preserve errno immediately */
    if (ret < 0 && perr != EINTR) { log(...); continue; }

    /* 1. Signals: shutdown handling takes priority */
    SIGTERM -> shutdown_all(RB_POWER_OFF, 0)
    SIGINT  -> shutdown_all(RB_AUTOBOOT,   0)
    SIGUSR1 -> shutdown_all(RB_POWER_OFF, 1)    /* force */
    SIGUSR2 -> shutdown_all(RB_AUTOBOOT,   1)   /* force */
    SIGCHLD -> reap_zombies()

    /* 2. Ready file descriptors: /run/initctl (line-by-line) and /run/log.fifo (service logs) */

    /* 3. Housekeeping: enforce once service timeouts, then respawn_services() */
    enforce_once_timeout();
    respawn_services();
}
```

`compute_poll_timeout()` dynamically determines `ppoll` timeouts:
- **100 ms**: if any service is awaiting respawn delay (`respawn_delay`, including exponential backoff), re-evaluating respawn eligibility 10 times per second;
- **1 second**: if any `once` service with an active timeout is running, ensuring `enforce_once_timeout()` executes even if no external I/O or signals arrive;
- **`NULL`** (infinite block): when no housekeeping tasks are pending, avoiding unnecessary wakeups.

Key architectural points:
- `ppoll` utilizes `orig` (initialized with `sigemptyset()`), ensuring signals like `SIGTERM` are unblocked while awaiting events regardless of masks inherited from the kernel.
- `errno` is captured into `perr` immediately after `ppoll()` to prevent subsequent logging routines from clobbering the error state.
- Commands arriving via `/run/initctl` are processed **line-by-line** by the streaming parser `initctl_parse_stream()`. Trailing whitespace and `\r` are trimmed, and empty lines are ignored. Because `/run/initctl` uses a streaming line buffer, commands **must be newline-terminated** (e.g. `echo poweroff > /run/initctl` or `printf "poweroff\n" > /run/initctl`). Partial writes without a newline are buffered until a `\n` arrives, or discarded if the line exceeds 255 bytes (`MAX_LINE - 1`). A valid termination command triggers `shutdown_all()` immediately.

## Service Management

### Spawning Services (`spawn_service`)

1. If `shutting_down` is active, return immediately without spawning.
2. If `now - last_start < RESPAWN_DELAY` (2 seconds), set `need_respawn = 1`, log `respawn delayed`, and return without blocking `sleep()`. The main `ppoll` timer triggers subsequent spawn attempts.
3. Establish a unidirectional synchronization pipe (`int sync_pipe[2]`) prior to `fork()` using `pipe2(sync_pipe, O_CLOEXEC)` (with fallback to `pipe()` + `fcntl(FD_CLOEXEC)`). If pipe creation fails after retries, the service is marked failed.
4. Execute `fork()`. In the child process:
   - Close the write end of the synchronization pipe (`sync_pipe[1]`).
   - Call `setsid()` to establish a new session and process group.
   - Clear the inherited signal mask (`sigprocmask(SIG_SETMASK, &empty, NULL)`) and restore signal dispositions to `SIG_DFL`.
   - Setup standard descriptors: `stdin` from `/dev/null`, `stdout`/`stderr` to `/run/log.fifo` (fallback to `/dev/console`).
   - Explicitly close control file descriptors (SANE-06-01).
   - **Pre-Exec Synchronization Handshake**: The child blocks on `read(sync_pipe[0], &sync_byte, 1)`, waiting for the parent to configure cgroup limits and insert the child's PID into `cgroup.procs`. Upon receiving the synchronization byte, the child closes `sync_pipe[0]` and executes `execl("/bin/sh", "sh", "-c", cmd)`. If execution fails, `_exit(127)`.
5. In the parent process:
   - Close the read end of the pipe (`sync_pipe[0]`).
   - Record `svc->pid = pid`, `svc->pgid = pid`, `svc->state = SVC_STATE_RUNNING`, and reset `svc->spawn_tries = 0`.
   - Log `started <name> (pid N)`.
   - Invoke `setup_cgroup(svc->name, pid)`:
     - Create the leaf cgroup directory `/sys/fs/cgroup/ninit/<name>`.
     - Purge existing orphan descendant processes via `cgroup_kill_service(svc->name)`.
     - Apply configured resource limits (`memory.max`, `memory.swap.max=0`, `cpu.max`, `pids.max`).
     - Write the child's PID to `cgroup.procs`.
     - **Fail-Open Fallback Contract**: If cgroup v2 hierarchy setup fails (e.g. unmounted cgroups, read-only filesystem, controller delegation errors):
       - Log: `cgroup: fail-open active for '<name>' (cgroup unavailable)`.
       - If resource limits were requested, log a warning: `Warning: resource limits ignored on service '<name>' because cgroup unavailable`.
       - Allow the service to proceed without resource constraints.
   - **Release Synchronization Lock**: The parent writes `"1"` to `sync_pipe[1]` and closes it, unblocking the child. This write is guaranteed even on fail-open branches, preventing child deadlock.

### Pre-Exec Handshake Diagram (T1)

```
parent                                   child
------                                   -----
pipe2(O_CLOEXEC) ---------------------->  sync_pipe[0/1]
fork()
                                         close(sync_pipe[1])
                                         setsid(); clear signal mask
                                         stdin </dev/null; stdout/stderr >/run/log.fifo
                                         close PID 1 control fds (T8B)
                                         read(sync_pipe[0]) --blocks--
setup_cgroup(name, pid)
  mkdir leaf; write limits; write cgroup.procs
write(sync_pipe[1], "1")  ------------->   (read completes)
close(sync_pipe[1])                      close(sync_pipe[0])
                                         execl("/bin/sh", "sh", "-c", cmd)
```

If the handshake read fails (`nr != 1` or byte != `'1'`), the child terminates with `_exit(127)` (*fail-closed*), preventing execution outside the designated cgroup leaf.

### Child Reaping (`reap_zombies`)

Reaps terminated child processes using non-blocking `waitpid()`:

```c
while ((pid = waitpid(-1, &status, WNOHANG)) > 0) { ... }
```

`spawn_service()` is intentionally not called within this loop. If a respawning service terminates immediately (e.g. `/bin/sh` without TTY), spawning in the reaping loop would generate continuous zombies, starving the main loop and blocking shutdown signals. Respawn scheduling is decoupled and executed by `respawn_services()` in the main event loop.

### Respawn Management (`respawn_services`)

Evaluated at the end of each event loop iteration: for each service configured with `respawn` mode and `pid == 0`, invoke `spawn_service()`. The `shutting_down` guard prevents respawns once shutdown has begun.

### `once` Timeouts & `respawn` Backoff

- **`ONCE_START_TIMEOUT` (Default: 30 seconds, configurable via `:timeout=`)**:
  `enforce_once_timeout()` executes at each event loop iteration. If a `once` service exceeds its configured timeout, it is marked `SVC_STATE_FAILED`, its process group is terminated (`SIGKILL`), and all transitive dependent services are cancelled (`cancel_dependents()`). Setting `:timeout=0` or `none` disables the timeout guard.
- **Exponential Backoff & Crash-Loop Protection**:
  If a `respawn` service crashes within `RESPAWN_DELAY` (2 seconds) of starting, `crash_count` increments and `respawn_delay` increases exponentially: `min(BACKOFF_MAX=32, 2 << crash_count)` (4s, 8s, 16s, 32s). After `CRASH_LIMIT` (5) consecutive failures, the service transitions to `SVC_STATE_FAILED` and respawn attempts cease.
  `deps_satisfied()` treats `SVC_STATE_FAILED` dependencies as failures (`-1`), causing dependent services to be cancelled immediately. A stable runtime exceeding `STABLE_RUNTIME` (10 seconds) resets `crash_count` and `respawn_delay`.

### Dependency Resolution (`validate_dependencies` + `sort_services`)

Services declared in `/etc/init.conf` may specify `:requires=a,b`. Two phases execute before any service is started:

1. `validate_dependencies()`: Verifies all declared dependency names exist. Unknown dependencies trigger `FATAL: Dependency '<x>' for '<y>' not found` and drop init into the rescue shell.
2. `sort_services()`: Performs an iterative topological sort using Depth-First Search with an explicit stack. Circular dependencies trigger `FATAL: CYCLE DETECTED` and route to the rescue shell.

Implementation details:
- Nodes are marked `temp_visited[...] = 1` **before** pushing to `stack[]`, ensuring each service enters the stack at most once and eliminating stack-buffer-overflow vulnerabilities.
- Diamond dependency patterns (`a→b,c ; b→c`) are supported cleanly without false cycle detection.

## Shutdown Sequence (`shutdown_all`)

| Stage | Graceful Shutdown | Force Shutdown |
|---|---|---|
| Set `shutting_down = 1` | ✅ | ✅ |
| Send `SIGTERM` to all active services | ✅ | — |
| Wait up to 50 × 100 ms (max 5s): reap processes & drain log FIFO | ✅ | — |
| Send `SIGKILL` to remaining services | ✅ | Immediate |
| Remount `/` read-only + `umount2(MNT_DETACH)` recorded fstab entries | ✅ | ✅ |
| `sync()` → `reboot(cmd)` → `while(1) pause()` | ✅ | ✅ |

`cmd` is either `RB_POWER_OFF` (SIGTERM/USR1) or `RB_AUTOBOOT` (SIGINT/USR2). If `reboot()` fails (common in unprivileged test containers), the error is logged and init sleeps indefinitely via `pause()`.

## Cgroups v2

Status: **Fully Implemented**. Limits on `memory.max`, `memory.swap.max=0`, `cpu.max`, and `pids.max` are verified by `scripts/test-cgroup-limits.sh`. Cgroups provide resource boundaries, not a security sandbox — see [SECURITY.md](../SECURITY.md).

- Cgroup filesystem mount is checked in `setup_pseudo_fs()` via `/sys/fs/cgroup/cgroup.controllers`; mounts `cgroup2` if absent.
- `setup_cgroup(name, pid)` creates `/sys/fs/cgroup/ninit` and leaf `/sys/fs/cgroup/ninit/<name>`, then writes the PID to `cgroup.procs`.
- Orphan cleanup (`cgroup.kill` + fallback scanning) executes upon service respawn and when `once` services terminate before leaf directory removal (`rmdir`).

### Cgroup Fail-Open Fallback Contract

1. **Default Fail-Open**: If cgroup hierarchy setup or PID assignment fails, services continue running unconstrained without halting the boot process.
2. **Explicit Fallback Logging**:
   ```
   cgroup: fail-open active for '<name>' (cgroup unavailable)
   ```
3. **Resource Limit Warning**: If resource limits (`memory_max`, `cpu_max`, `pids_max`) were requested but cannot be enforced:
   ```
   Warning: resource limits ignored on service '<name>' because cgroup unavailable
   ```
4. **Deadlock-Free Unblocking**: The parent unblocks the child pre-exec handshake regardless of cgroup setup success.
5. **Process Group Fallback**: When cgroups are unavailable, process cleanup falls back to standard process group signals (`kill(-pgid, SIGTERM)` / `kill(-pgid, SIGKILL)`).

## Logging Architecture

| Destination | Format & Routing |
|---|---|
| `/dev/kmsg` | `ninit: <message>` — routed into the Linux kernel ring buffer |
| stderr (console) | `[YYYY-mm-dd HH:MM:SS] ninit: <message>` |
| `/var/log/ninit.log` | Same format as console; opened after early fstab mounts |
| `/run/log.fifo` | Captures service stdout/stderr; drained by `drain_log_fifo()` and output as `[service] <line>` |

`/run` is mounted as `tmpfs`, ensuring control FIFOs (`/run/initctl`, `/run/log.fifo`, mode `0600`) are created freshly on each boot cycle.
