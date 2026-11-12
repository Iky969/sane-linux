/*
 * ninit - minimal init system (PID 1)
 * Compile : gcc -static -O2 -Wall -o ninit ninit.c
 * v5 Fixes: ppoll nfds, O_RDWR FIFO, strict cycle detection, robust parser.
 * v10+    : fstab data options, cgroup v2, non-blocking respawn timer, child
 *           signal mask, dependency validation, line-by-line initctl, topo-sort
 *           without stack overflow.
 * v1.0.0  : real rescue mode via enter_rescue_mode() (broken config,
 *           missing dependencies, cycles) + signal mask cleared before
 *           execl so Ctrl+C works in emergency shell.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/reboot.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <poll.h>
#include <ctype.h>

#ifndef MAX_SERVICES
#define MAX_SERVICES    64
#endif
#ifndef MAX_LINE
#define MAX_LINE        1024
#endif
#ifndef RESPAWN_DELAY
#define RESPAWN_DELAY   2
#endif
#ifndef MAX_SPAWN_RETRY
#define MAX_SPAWN_RETRY 3   /* maximum fork() retries for once services */
#endif
#ifndef ONCE_START_TIMEOUT
#define ONCE_START_TIMEOUT 30  /* maximum runtime (seconds) for once services */
#endif
#ifndef CRASH_LIMIT
#define CRASH_LIMIT        5   /* consecutive crashes before respawn is aborted */
#endif
#ifndef BACKOFF_MAX
#define BACKOFF_MAX        32  /* upper bound for exponential respawn backoff (seconds) */
#endif
#ifndef STABLE_RUNTIME
#define STABLE_RUNTIME     10  /* seconds of stable runtime before backoff is reset */
#endif
#ifndef SIGTERM_GRACE_SECS
#define SIGTERM_GRACE_SECS 5   /* T13: default SIGTERM -> SIGKILL grace window (seconds) */
#endif
#ifndef SPAWN_RETRY_BASE_MS
#define SPAWN_RETRY_BASE_MS 100 /* T11: fork() EAGAIN backoff base: 100/200/400 ms */
#endif

/* Service lifecycle states (T10). The numeric values are part of the internal
   contract of svc_transition_allowed(); the relative order of the pre-existing
   states (STOPPED < RUNNING < DONE < FAILED) is preserved while STARTING (= 1)
   and STOPPING (= 3) are inserted at their canonical positions.
   Every write to service_t.state goes through svc_set_state(). */
typedef enum {
    SVC_STATE_STOPPED  = 0,   /* idle: never started, stopped, or waiting to respawn */
    SVC_STATE_STARTING = 1,   /* spawn sequence in progress (fork / retry backoff) */
    SVC_STATE_RUNNING  = 2,   /* spawned and tracked via pid/pgid */
    SVC_STATE_STOPPING = 3,   /* stop requested: SIGTERM sent, grace window running */
    SVC_STATE_DONE     = 4,   /* once service finished with exit status 0 */
    SVC_STATE_FAILED   = 5    /* terminal: spawn, exit, timeout, or dependency failure */
} svc_state_t;

typedef struct {
    char        name[128];
    char        cmd[512];
    pid_t       pid;
    pid_t       pgid;           /* service process group: child calls setsid() so
                                   pgid == pid at spawn. INTENTIONALLY not cleared when
                                   the leader exits — the group may outlive its
                                   leader (audit SANE-01). */
    int         respawn;
    int         need_respawn;   /* 1 = waiting for RESPAWN_DELAY window (without blocking loop) */
    int         spawn_tries;    /* consecutive fork() failures; reset to 0 on successful spawn */
    int         cgroup_fail_open; /* 1 = cgroup setup failed, orphan cleanup via kill(-pgid) */
    time_t      last_start;     /* last spawn timestamp (once timeout & respawn backoff) */
    int         crash_count;    /* consecutive crashes during respawn (start-limit) */
    int         respawn_delay;  /* current respawn delay (seconds, exponential backoff) */
    int         timeout;        /* timeout for once service (seconds); default ONCE_START_TIMEOUT; 0 = disabled */
    char        deps_str[256]; 
    svc_state_t state;
    int         grace;          /* T13: SIGTERM grace seconds (:grace=N), default SIGTERM_GRACE_SECS */
    int         sigkill_sent;   /* T13: 1 = SIGKILL already escalated (log/report once) */
    char        memory_max[64];
    char        cpu_max[64];
    char        pids_max[64];
} service_t;

static service_t services[MAX_SERVICES];
static int num_services = 0;

static int find_service(const char *name);
static void enable_cgroup_subtree(const char *path);
static void cgroup_kill_service(const char *name);
static void kill_service_group(const service_t *svc, int sig);

static volatile sig_atomic_t sigchld_flag  = 0;
static volatile sig_atomic_t sigterm_flag  = 0;
static volatile sig_atomic_t sigint_flag   = 0;
static volatile sig_atomic_t sigusr1_flag  = 0;
static volatile sig_atomic_t sigusr2_flag  = 0;

static int log_file_fd = -1;
static int g_log_fifo_fd = -1;  /* read end of /run/log.fifo; also used during shutdown */
static int initctl_fd = -1;     /* /run/initctl fd; closed before exec */
static int shutting_down = 0;   /* 1 = shutdown in progress: do not respawn services */

/* fstab mountpoints successfully mounted by mount_fstab(); used by
   shutdown_all() to unmount before reboot (T8E). */
#define MAX_SEEN_MNT 64
static char g_seen_mnt[MAX_SEEN_MNT][MAX_LINE];
static int  g_seen_cnt = 0;

/* ---------- logging ---------- */
static void init_log(const char *fmt, ...)
{
    char buf[1024];
    char time_buf[32];
    time_t now = time(NULL);
    struct tm tm_info;
    localtime_r(&now, &tm_info);
    strftime(time_buf, sizeof(time_buf), "[%Y-%m-%d %H:%M:%S]", &tm_info);

    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    /* 1. Kernel log */
    int kfd = open("/dev/kmsg", O_WRONLY);
    if (kfd >= 0) { dprintf(kfd, "ninit: %s\n", buf); close(kfd); }
    
    /* 2. Console */
    fprintf(stderr, "%s ninit: %s\n", time_buf, buf);

    /* 3. File log */
    if (log_file_fd >= 0) {
        dprintf(log_file_fd, "%s ninit: %s\n", time_buf, buf);
    }
}

/* Strip leading and trailing whitespace/tabs/CR in-place and return pointer to
   start of trimmed text. Used by /run/initctl command reader. */
static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t' || *s == '\r') s++;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r')) s[--n] = 0;
    return s;
}

/* ---------- timing helpers (T11/T13) ---------- */
/* Milliseconds from CLOCK_MONOTONIC: immune to wall-clock jumps (the grace
   window is a duration, not a date). Falls back to time(NULL) seconds if the
   monotonic clock is unavailable, keeping the window accurate to a second
   instead of failing outright. */
static long long monotonic_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
        return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    return (long long)time(NULL) * 1000;
}

/* Delay that never busy-waits: nanosleep() restarts on EINTR and reuses the
   remaining time reported back in &ts, so an interrupted sleep still completes
   in full. Used for the fork() EAGAIN backoff (T11) and the shutdown grace
   poll (T13) instead of sleep()/usleep(). */
static void sleep_ms(int ms)
{
    struct timespec ts;
    if (ms <= 0) return;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR)
        ;
}

/* ---------- service state machine (T10) ---------- */
/* "/run/ninit-" (11) + name (<= 127) + ".state" (6) + NUL fits comfortably. */
#define SVC_STATE_FILE_MAX 160

static const char *svc_state_name(svc_state_t s)
{
    switch (s) {
    case SVC_STATE_STOPPED:  return "STOPPED";
    case SVC_STATE_STARTING: return "STARTING";
    case SVC_STATE_RUNNING:  return "RUNNING";
    case SVC_STATE_STOPPING: return "STOPPING";
    case SVC_STATE_DONE:     return "DONE";
    case SVC_STATE_FAILED:   return "FAILED";
    }
    return "UNKNOWN";
}

/* Invariant table for service lifecycle edges (T10). Linear paths:
     STOPPED  -> STARTING -> RUNNING -> STOPPING -> STOPPED
     STARTING -> STOPPED            (spawn aborted, retry via ppoll timer)
     STARTING -> FAILED             (fork/pipe failure, retries exhausted)
     RUNNING  -> DONE               (once service exited with status 0)
     RUNNING  -> STOPPED            (respawn service: leader exited, timer armed)
     RUNNING  -> FAILED             (non-zero exit, crash-loop, timeout, cancelled)
     STOPPING -> STOPPED | DONE | FAILED   (stop observed by the reaper)
     STOPPED  -> FAILED             (cancelled by a failed dependency)
     STOPPED  -> STOPPING           (SANE-01: leader exited, group members survive)
   DONE and FAILED are terminal for one boot: a service never leaves them.
   Returns 1 when allowed, 0 when the edge is absent from the table — the caller
   logs a warning and still applies the new state, because an unexpected
   transition must never be able to freeze or crash PID 1. */
static int svc_transition_allowed(svc_state_t from, svc_state_t to)
{
    if (from == to) return 1;   /* idempotent re-set: no-op, no log */

    switch (from) {
    case SVC_STATE_STOPPED:
        return to == SVC_STATE_STARTING || to == SVC_STATE_STOPPING ||
               to == SVC_STATE_FAILED;
    case SVC_STATE_STARTING:
        return to == SVC_STATE_RUNNING  || to == SVC_STATE_STOPPING ||
               to == SVC_STATE_STOPPED  || to == SVC_STATE_FAILED;
    case SVC_STATE_RUNNING:
        return to == SVC_STATE_STOPPING || to == SVC_STATE_STOPPED ||
               to == SVC_STATE_DONE     || to == SVC_STATE_FAILED;
    case SVC_STATE_STOPPING:
        return to == SVC_STATE_STOPPED  || to == SVC_STATE_DONE ||
               to == SVC_STATE_FAILED;
    case SVC_STATE_DONE:
    case SVC_STATE_FAILED:
        return 0;
    }
    return 0;
}

/* Publish the current state as /run/ninit-<name>.state (T10) so tests and
   operators can read the lifecycle without parsing the log. Best effort:
   diagnostic telemetry must never abort PID 1, so failures are logged only.
   O_CLOEXEC keeps the descriptor out of every service's fd table (SANE-06-01). */
static void svc_write_state_file(const service_t *svc)
{
    char path[SVC_STATE_FILE_MAX];
    int n = snprintf(path, sizeof(path), "/run/ninit-%s.state", svc->name);
    if (n < 0 || (size_t)n >= sizeof(path)) {
        init_log("Warning: state file path for '%s' too long, not written", svc->name);
        return;
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) {
        init_log("Warning: cannot write state file %s: %s", path, strerror(errno));
        return;
    }
    if (dprintf(fd, "%s\n", svc_state_name(svc->state)) < 0)
        init_log("Warning: cannot write state file %s: %s", path, strerror(errno));
    close(fd);
}

/* The ONLY transition point for service_t.state (T10): validate the edge, log
   "[ninit] <name>: state <OLD> -> <NEW>" and publish the state file. */
static void svc_set_state(service_t *svc, svc_state_t new_state)
{
    if (!svc) return;
    if (svc->state == new_state) return;   /* no transition -> no log, no I/O */

    if (!svc_transition_allowed(svc->state, new_state))
        init_log("Warning: %s: illegal state transition %s -> %s (applied)",
                 svc->name, svc_state_name(svc->state), svc_state_name(new_state));

    init_log("%s: state %s -> %s", svc->name,
             svc_state_name(svc->state), svc_state_name(new_state));
    svc->state = new_state;
    svc_write_state_file(svc);
}

/* ---------- signal handlers ---------- */
static void on_sigchld(int s) { (void)s; sigchld_flag = 1; }
static void on_sigterm(int s) { (void)s; sigterm_flag = 1; }
static void on_sigint (int s) { (void)s; sigint_flag  = 1; }
static void on_sigusr1(int s) { (void)s; sigusr1_flag = 1; }
static void on_sigusr2(int s) { (void)s; sigusr2_flag = 1; }

/* ---------- mount helpers ---------- */
static void try_mount(const char *src, const char *tgt, const char *fstype, unsigned long flags)
{
    mkdir(tgt, 0755);
    if (mount(src, tgt, fstype, flags, NULL) < 0)
        init_log("mount %s -> %s failed: %s", src, tgt, strerror(errno));
}

static void enable_cgroup_subtree(const char *path)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0) {
        init_log("cgroup: open %s failed: %s (nested/container tolerant)", path, strerror(errno));
        return;
    }

    if (write(fd, "+memory +cpu +pids\n", 19) < 0) {
        /* If multi-token write fails (e.g. a controller is unsupported by kernel),
           attempt writing each token individually */
        const char *controllers[] = {"+memory", "+cpu", "+pids"};
        for (size_t i = 0; i < sizeof(controllers) / sizeof(controllers[0]); i++) {
            char buf[32];
            snprintf(buf, sizeof(buf), "%s\n", controllers[i]);
            if (write(fd, buf, strlen(buf)) < 0) {
                init_log("cgroup: controller '%s' at %s failed: %s (partial tolerance)",
                         controllers[i], path, strerror(errno));
            }
        }
    }
    close(fd);
}

static void setup_pseudo_fs(void)
{
    try_mount("proc",     "/proc", "proc",     0);
    try_mount("sysfs",    "/sys",  "sysfs",    0);
    try_mount("devtmpfs", "/dev",  "devtmpfs", 0);
    try_mount("tmpfs",    "/run",  "tmpfs",    0);
    try_mount("tmpfs",    "/tmp",  "tmpfs",    0);
    
    mkdir("/var", 0755);
    mkdir("/var/log", 0755);

    /* cgroup v2 (unified): mount only if not already mounted */
    {
        struct stat st;
        if (stat("/sys/fs/cgroup/cgroup.controllers", &st) == 0) {
            init_log("cgroup2: /sys/fs/cgroup already mounted");
        } else {
            mkdir("/sys/fs/cgroup", 0755);
            if (mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, NULL) < 0)
                init_log("cgroup2: mount /sys/fs/cgroup failed: %s", strerror(errno));
            else
                init_log("cgroup2: /sys/fs/cgroup mounted");
        }
        enable_cgroup_subtree("/sys/fs/cgroup/cgroup.subtree_control");
    }
}

static void set_hostname(void)
{
    FILE *f = fopen("/etc/hostname", "r");
    if (!f) return;
    char buf[256];
    if (fgets(buf, sizeof(buf), f)) {
        buf[strcspn(buf, "\n")] = 0;
        if (sethostname(buf, strlen(buf)) < 0)
            init_log("sethostname: %s", strerror(errno));
        else
            init_log("hostname = %s", buf);
    }
    fclose(f);
}

/* ---------- cgroups v2 ---------- */
/* Default base path for ninit service cgroup hierarchy. Can be overridden via
   NINIT_CGROUP_BASE environment variable so test suites can isolate cgroups
   to a dedicated per-run subtree without touching host /sys/fs/cgroup/ninit.
   Strict validation: path MUST begin with "/sys/fs/cgroup/" and must NOT
   contain ".." to prevent path traversal. */
#ifndef CGROUP_BASE_DEFAULT
#define CGROUP_BASE_DEFAULT "/sys/fs/cgroup/ninit"
#endif
#define CGROUP_BASE_PREFIX "/sys/fs/cgroup/"

static char cgroup_base_buf[256];
static const char *cgroup_base_ptr = NULL;

static const char *get_cgroup_base(void)
{
    if (cgroup_base_ptr) return cgroup_base_ptr;
    const char *env = getenv("NINIT_CGROUP_BASE");
    if (env && env[0] == '/' &&
        strncmp(env, CGROUP_BASE_PREFIX, strlen(CGROUP_BASE_PREFIX)) == 0 &&
        strstr(env, "..") == NULL &&
        strlen(env) < sizeof(cgroup_base_buf)) {
        strncpy(cgroup_base_buf, env, sizeof(cgroup_base_buf) - 1);
        cgroup_base_buf[sizeof(cgroup_base_buf) - 1] = 0;
        /* Strip trailing slashes */
        size_t len = strlen(cgroup_base_buf);
        while (len > 1 && cgroup_base_buf[len - 1] == '/')
            cgroup_base_buf[--len] = 0;
        cgroup_base_ptr = cgroup_base_buf;
        init_log("cgroup: base path overridden: %s", cgroup_base_ptr);
    } else {
        cgroup_base_ptr = CGROUP_BASE_DEFAULT;
    }
    return cgroup_base_ptr;
}

/* Access macro: all code previously using CGROUP_BASE transparently uses
   the resolved path. */
#define CGROUP_BASE (get_cgroup_base())

/* Second line of defense for cgroup paths (SANE-06-02): parse_config already
   rejects empty/"."/".."/names containing "..", but setup_cgroup(),
   cgroup_kill_service(), and cleanup_cgroup() construct paths as
   CGROUP_BASE/<name> — verify no problematic name escapes from internal
   state. Returns 1 if name is safe, 0 if rejected. */
static int cgroup_name_safe(const char *name)
{
    if (!name || name[0] == '\0' || strcmp(name, ".") == 0 ||
        strcmp(name, "..") == 0 || strstr(name, "..") != NULL) {
        init_log("cgroup: service name '%s' invalid, cgroup operation aborted",
                 name ? name : "(null)");
        return 0;
    }
    return 1;
}

/* Trigger service cgroup.kill (by NAME, not PID): kills all members of
   the cgroup, including processes whose process group changed.
   Called during respawn, leader exit, and shutdown. */
static void cgroup_kill_service(const char *name)
{
    char kill_path[320];
    snprintf(kill_path, sizeof(kill_path), "%s/%s/cgroup.kill", CGROUP_BASE, name);
    int fd = open(kill_path, O_WRONLY);
    int written = -1;
    if (fd >= 0) {
        written = write(fd, "1\n", 2);
        if (written < 0) {
            init_log("cgroup: write 1 to %s failed: %s", kill_path, strerror(errno));
        }
        close(fd);
        if (written >= 0) return;
    }

    /* Fallback for pre-Linux 5.14 or when cgroup.kill write fails:
       read cgroup.procs and send SIGKILL to every listed PID */
    char procs_path[320];
    snprintf(procs_path, sizeof(procs_path), "%s/%s/cgroup.procs", CGROUP_BASE, name);
    FILE *fp = fopen(procs_path, "r");
    if (fp) {
        int p;
        while (fscanf(fp, "%d", &p) == 1) {
            if (p > 1) {
                kill((pid_t)p, SIGKILL);
            }
        }
        fclose(fp);
    }
}

/* Deliver `sig` to EVERY process still attached to the service cgroup (T13).
   cgroup.kill is NOT usable for this: writing to it always delivers SIGKILL, so
   using it for the polite signal would silently skip the whole grace window and
   kill services that would have exited cleanly on SIGTERM (scripts/test-sigterm.sh
   scenario 1 asserts the "bye!" trap does run). The only correct whole-cgroup
   delivery of a non-fatal signal is walking cgroup.procs: that also reaches
   processes which called setsid()/setpgid() and therefore miss kill(-pgid).
   Processes that left the cgroup cannot be reached this way and are covered by
   kill_service_group()'s pgid path. */
static void cgroup_signal_service(const char *name, int sig)
{
    if (!cgroup_name_safe(name)) return;
    if (sig == SIGKILL) { cgroup_kill_service(name); return; }

    char procs_path[320];
    snprintf(procs_path, sizeof(procs_path), "%s/%s/cgroup.procs", CGROUP_BASE, name);
    FILE *fp = fopen(procs_path, "r");
    if (!fp) return;   /* no cgroup (fail-open) -> pgid path is the fallback */

    int p;
    while (fscanf(fp, "%d", &p) == 1) {
        if (p > 1) kill((pid_t)p, sig);
    }
    fclose(fp);
}

/* Explicit fail-open fallback when cgroup cannot be prepared */
static void cgroup_fail_open(const char *svc_name)
{
    init_log("cgroup: fail-open active for '%s' (cgroup unavailable)", svc_name);
    int idx = find_service(svc_name);
    if (idx >= 0) {
        const service_t *svc = &services[idx];
        if (svc->memory_max[0] || svc->cpu_max[0] || svc->pids_max[0]) {
            init_log("Warning: resource limits ignored on service '%s' because cgroup unavailable", svc_name);
        }
    }
}

/* Move service PID to /sys/fs/cgroup/ninit/<name>. Called from parent
   after successful fork(). Returns 0=ok, 1=fail-open. */
static int setup_cgroup(const char *svc_name, pid_t pid)
{
    char dir[256], procs[320];   /* procs = dir (max 255) + "/cgroup.procs" */
    int fd;

    if (!cgroup_name_safe(svc_name)) return 1;   /* fail-open: do not touch path */

    /* cgroup v2 does not automatically create parent directories */
    if (mkdir(CGROUP_BASE, 0755) < 0 && errno != EEXIST) {
        init_log("cgroup: mkdir %s failed: %s", CGROUP_BASE, strerror(errno));
        cgroup_fail_open(svc_name);
        return 1;
    }
    {
        char subtree_path[320];
        snprintf(subtree_path, sizeof(subtree_path), "%s/cgroup.subtree_control", CGROUP_BASE);
        enable_cgroup_subtree(subtree_path);
    }

    snprintf(dir, sizeof(dir), "%s/%s", CGROUP_BASE, svc_name);
    if (mkdir(dir, 0755) < 0 && errno != EEXIST) {
        init_log("cgroup: mkdir %s failed: %s", dir, strerror(errno));
        cgroup_fail_open(svc_name);
        return 1;
    }

    /* R3: Clean up any old child/orphan processes before moving the new PID */
    cgroup_kill_service(svc_name);

    /* R2: Apply resource limits if configured */
    int idx = find_service(svc_name);
    if (idx >= 0) {
        const service_t *svc = &services[idx];
        if (svc->memory_max[0]) {
            char path[320];
            snprintf(path, sizeof(path), "%s/memory.max", dir);
            int lim_fd = open(path, O_WRONLY);
            if (lim_fd >= 0) {
                if (dprintf(lim_fd, "%s\n", svc->memory_max) < 0) {
                    int err = errno;
                    init_log("cgroup: write %s to %s failed: %s", svc->memory_max, path, strerror(err));
                    init_log("Warning: memory.max resource limit ignored on service '%s'", svc_name);
                } else {
                    init_log("cgroup: '%s' memory.max = %s", svc_name, svc->memory_max);
                }
                close(lim_fd);
            } else {
                int err = errno;
                init_log("cgroup: open %s failed: %s", path, strerror(err));
                init_log("Warning: memory.max resource limit ignored on service '%s'", svc_name);
            }

            /* Limit memory.swap.max=0 if supported, so memory_max does not leak to swap */
            snprintf(path, sizeof(path), "%s/memory.swap.max", dir);
            int swap_fd = open(path, O_WRONLY);
            if (swap_fd >= 0) {
                if (write(swap_fd, "0\n", 2) < 0) {
                    /* ignore if swap controller is not active or rejects */
                }
                close(swap_fd);
            }
        }
        if (svc->cpu_max[0]) {
            char path[320];
            snprintf(path, sizeof(path), "%s/cpu.max", dir);
            int lim_fd = open(path, O_WRONLY);
            if (lim_fd >= 0) {
                if (dprintf(lim_fd, "%s\n", svc->cpu_max) < 0) {
                    int err = errno;
                    init_log("cgroup: write %s to %s failed: %s", svc->cpu_max, path, strerror(err));
                    init_log("Warning: cpu.max resource limit ignored on service '%s'", svc_name);
                } else {
                    init_log("cgroup: '%s' cpu.max = %s", svc_name, svc->cpu_max);
                }
                close(lim_fd);
            } else {
                int err = errno;
                init_log("cgroup: open %s failed: %s", path, strerror(err));
                init_log("Warning: cpu.max resource limit ignored on service '%s'", svc_name);
            }
        }
        if (svc->pids_max[0]) {
            char path[320];
            snprintf(path, sizeof(path), "%s/pids.max", dir);
            int lim_fd = open(path, O_WRONLY);
            if (lim_fd >= 0) {
                if (dprintf(lim_fd, "%s\n", svc->pids_max) < 0) {
                    int err = errno;
                    init_log("cgroup: write %s to %s failed: %s", svc->pids_max, path, strerror(err));
                    init_log("Warning: pids.max resource limit ignored on service '%s'", svc_name);
                } else {
                    init_log("cgroup: '%s' pids.max = %s", svc_name, svc->pids_max);
                }
                close(lim_fd);
            } else {
                int err = errno;
                init_log("cgroup: open %s failed: %s", path, strerror(err));
                init_log("Warning: pids.max resource limit ignored on service '%s'", svc_name);
            }
        }
    }

    snprintf(procs, sizeof(procs), "%s/cgroup.procs", dir);
    fd = open(procs, O_WRONLY);
    if (fd < 0) {
        init_log("cgroup: open %s failed: %s", procs, strerror(errno));
        /* Clean up partial leaf directory to avoid leaks on the host */
        rmdir(dir);
        cgroup_fail_open(svc_name);
        return 1;
    }

    if (dprintf(fd, "%d\n", (int)pid) < 0) {
        init_log("cgroup: write pid %d to %s failed: %s", (int)pid, procs, strerror(errno));
        close(fd);
        /* Clean up partial leaf directory */
        rmdir(dir);
        cgroup_fail_open(svc_name);
        return 1;
    }

    close(fd);
    init_log("cgroup: '%s' (pid %d) -> %s", svc_name, (int)pid, dir);
    return 0;
}

/* Remove the service leaf cgroup when the service stops (T14).
   Sequence: cgroup.kill (sweep every process in the leaf) -> bounded poll
   until cgroup.procs is empty -> rmdir. The empty-check is what makes the
   rmdir deterministic: rmdir on a cgroup with live processes fails with
   EBUSY. Failures are logged as warnings and never abort PID 1 (a leaking
   leaf is recoverable on the next boot; a crashed init is not). */
static void cleanup_cgroup(const char *svc_name)
{
    if (!cgroup_name_safe(svc_name)) return;

    char dir[256], procs[320];
    snprintf(dir, sizeof(dir), "%s/%s", CGROUP_BASE, svc_name);
    snprintf(procs, sizeof(procs), "%s/cgroup.procs", dir);

    cgroup_kill_service(svc_name);

    /* cgroup.kill is asynchronous: wait (bounded, no unbounded sleep loop)
       until the kernel has reaped every process from the leaf before
       attempting rmdir. */
    for (int i = 0; i < 50; i++) {
        FILE *fp = fopen(procs, "r");
        if (!fp) break;              /* leaf already gone */
        int p, n = 0;
        while (fscanf(fp, "%d", &p) == 1) n++;
        fclose(fp);
        if (n == 0) break;
        usleep(10000);
    }

    for (int i = 0; i < 20; i++) {
        if (rmdir(dir) == 0) {
            init_log("cgroup: cleaned up '%s'", svc_name);
            return;
        }
        if (errno != EBUSY) {
            if (errno != ENOENT) {
                init_log("Warning: cgroup rmdir %s failed: %s (leaf may leak)",
                         dir, strerror(errno));
            }
            return;
        }
        usleep(5000);
    }
    init_log("Warning: cgroup rmdir %s failed: %s (leaf may leak)",
             dir, strerror(errno));
}

/* ---------- config parser (FIXED: Robust) ---------- */
/* fgets() splits lines longer than the buffer into multiple chunks that look
   like distinct lines; without detection, trailing fragments could be parsed
   as phantom entries (audit SANE-03). The boundary is explicit:
   lines containing up to MAX_LINE-1 characters are ACCEPTED (with or without
   '\n', including the final line ending exactly at EOF); lines that still have
   continuation characters after the buffer fills are REJECTED — the remainder
   of the line is discarded until '\n'/EOF here so it is not parsed as a new
   line. A single probe character (fgetc) distinguishes between the two cases
   without relying on when libc sets the EOF indicator. */
static int line_overlong(FILE *f, const char *line)
{
    size_t len = strlen(line);
    if (len == MAX_LINE - 1 && line[len - 1] != '\n') {
        int c = fgetc(f);
        if (c == EOF) return 0;   /* last line exactly at boundary, intact */
        while (c != EOF && c != '\n') c = fgetc(f);
        return 1;
    }
    return 0;
}

/* Validate cpu_max format: <quota> <period> (positive numbers separated by single space) */
static int validate_cpu_max(const char *s)
{
    if (!s || !*s) return 0;
    const char *sp = strchr(s, ' ');
    if (!sp) return 0;
    if (strchr(sp + 1, ' ')) return 0; /* reject if more than one space */
    if (sp == s || *(sp + 1) == '\0') return 0; /* empty quota or period */

    for (const char *p = s; p < sp; p++) {
        if (!isdigit((unsigned char)*p)) return 0;
    }
    for (const char *p = sp + 1; *p; p++) {
        if (!isdigit((unsigned char)*p)) return 0;
    }

    errno = 0;
    unsigned long long quota = strtoull(s, NULL, 10);
    if (errno == ERANGE || quota == 0) return 0;

    errno = 0;
    unsigned long long period = strtoull(sp + 1, NULL, 10);
    if (errno == ERANGE || period == 0) return 0;

    return 1;
}

/* Validate memory_max format: 'max' or number with K, M, G units (or raw bytes) */
static int validate_memory_max(const char *s)
{
    if (!s || !*s) return 0;
    if (strcmp(s, "max") == 0) return 1;

    size_t len = strlen(s);
    size_t num_len = len;
    char last = s[len - 1];

    if (last == 'k' || last == 'K' ||
        last == 'm' || last == 'M' ||
        last == 'g' || last == 'G') {
        if (len < 2) return 0;
        num_len = len - 1;
    }

    for (size_t i = 0; i < num_len; i++) {
        if (!isdigit((unsigned char)s[i])) return 0;
    }

    errno = 0;
    unsigned long long val = strtoull(s, NULL, 10);
    if (errno == ERANGE || val == 0) return 0;

    return 1;
}

/* Validate pids_max format: 'max' or positive integer */
static int validate_pids_max(const char *s)
{
    if (!s || !*s) return 0;
    if (strcmp(s, "max") == 0) return 1;

    for (const char *p = s; *p; p++) {
        if (!isdigit((unsigned char)*p)) return 0;
    }

    errno = 0;
    unsigned long long val = strtoull(s, NULL, 10);
    if (errno == ERANGE || val == 0) return 0;

    return 1;
}

static int parse_config(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { init_log("open %s failed: %s", path, strerror(errno)); return -1; }

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        if (line_overlong(f, line)) {
            init_log("Parse err: line exceeds MAX_LINE (%d), line rejected", MAX_LINE);
            continue;
        }
        line[strcspn(line, "\n")] = 0;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == 0) continue;

        if (num_services >= MAX_SERVICES) {
            init_log("Warning: limit of %d services reached, '%s' ignored", MAX_SERVICES, p);
            continue;
        }

        char *name = p;
        char *c1 = strchr(p, ':'); if (!c1) { init_log("Parse err: no mode in %s", name); continue; }
        *c1 = 0;
        char *mode = c1 + 1;
        char *c2 = strchr(mode, ':'); if (!c2) { init_log("Parse err: no cmd in %s", name); continue; }
        *c2 = 0;
        char *cmd = c2 + 1;

        /* Service Name Validation: cannot contain '/' (used for cgroup directory) */
        if (strchr(name, '/')) {
            init_log("Parse err: service name '%s' cannot contain '/'", name);
            continue;
        }

        /* Reject empty names, ".", "..", or names containing "..": cgroup paths
           are constructed as CGROUP_BASE/<name>, and "."/".." components would
           allow path traversal escaping the base directory (SANE-06-02). */
        if (name[0] == '\0' || strcmp(name, ".") == 0 ||
            strcmp(name, "..") == 0 || strstr(name, "..") != NULL) {
            init_log("Parse err: service name '%s' invalid (empty, '.', '..' or contains '..'), entry rejected",
                     name);
            continue;
        }

        /* Reject duplicate names: find_service() always resolves to the first
           occurrence, so a second entry would silently share cgroup leaves,
           dependencies, and respawn schedules with the first (SANE-06-03). */
        if (find_service(name) >= 0) {
            init_log("Parse err: service name '%s' already registered, duplicate entry rejected", name);
            continue;
        }
        
        /* Scan for option tags (:requires=, :memory_max=, :cpu_max=, :pids_max=, :timeout=) */
        char *deps = "";
        char *mem_max = "";
        char *cpu_limit = "";
        char *pids_limit = "";
        int timeout_val = ONCE_START_TIMEOUT;
        int grace_val = SIGTERM_GRACE_SECS;   /* T13: SIGTERM -> SIGKILL grace window */

        char *t_req = strstr(cmd, ":requires=");
        char *t_mem = strstr(cmd, ":memory_max=");
        char *t_cpu = strstr(cmd, ":cpu_max=");
        char *t_pid = strstr(cmd, ":pids_max=");
        char *t_tout = strstr(cmd, ":timeout=");
        char *t_grace = strstr(cmd, ":grace=");

        /* Find the earliest occurring tag so commands containing ':' remain intact */
        char *first_tag = NULL;
        if (t_req && (!first_tag || t_req < first_tag)) first_tag = t_req;
        if (t_mem && (!first_tag || t_mem < first_tag)) first_tag = t_mem;
        if (t_cpu && (!first_tag || t_cpu < first_tag)) first_tag = t_cpu;
        if (t_pid && (!first_tag || t_pid < first_tag)) first_tag = t_pid;
        if (t_tout && (!first_tag || t_tout < first_tag)) first_tag = t_tout;
        if (t_grace && (!first_tag || t_grace < first_tag)) first_tag = t_grace;

        if (first_tag) {
            *first_tag = 0; /* Split cmd right before first option tag */
            char *scan = first_tag + 1;
            while (scan && *scan) {
                char *next_tag = strchr(scan, ':');
                if (next_tag) *next_tag = 0;

                if (strncmp(scan, "requires=", 9) == 0) {
                    deps = trim(scan + 9);
                } else if (strncmp(scan, "memory_max=", 11) == 0) {
                    mem_max = trim(scan + 11);
                } else if (strncmp(scan, "cpu_max=", 8) == 0) {
                    cpu_limit = trim(scan + 8);
                } else if (strncmp(scan, "pids_max=", 9) == 0) {
                    pids_limit = trim(scan + 9);
                } else if (strncmp(scan, "timeout=", 8) == 0) {
                    char *tout_str = trim(scan + 8);
                    if (strcmp(tout_str, "0") == 0 || strcmp(tout_str, "none") == 0 ||
                        strcmp(tout_str, "infinity") == 0) {
                        timeout_val = 0;
                    } else {
                        int valid = 1;
                        if (!*tout_str || strlen(tout_str) > 10) valid = 0;
                        for (const char *tp = tout_str; *tp; tp++) {
                            if (!isdigit((unsigned char)*tp)) { valid = 0; break; }
                        }
                        if (valid) {
                            long v = strtol(tout_str, NULL, 10);
                            if (v > 0 && v <= 86400) {
                                timeout_val = (int)v;
                            } else {
                                init_log("Parse err: timeout '%s' out of range (1-86400s) on service '%s', using default %ds",
                                         tout_str, name, ONCE_START_TIMEOUT);
                            }
                        } else {
                            init_log("Parse err: invalid timeout format '%s' on service '%s', using default %ds",
                                     tout_str, name, ONCE_START_TIMEOUT);
                        }
                    }
                } else if (strncmp(scan, "grace=", 6) == 0) {
                    /* T13: per-service SIGTERM grace window, same validation style
                       as :timeout= — digits only, bounded, default on rejection.
                       grace=0 is accepted and means "escalate immediately". */
                    char *gr_str = trim(scan + 6);
                    int valid = 1;
                    if (!*gr_str || strlen(gr_str) > 6) valid = 0;
                    for (const char *gp = gr_str; *gp; gp++) {
                        if (!isdigit((unsigned char)*gp)) { valid = 0; break; }
                    }
                    if (valid) {
                        long v = strtol(gr_str, NULL, 10);
                        if (v >= 0 && v <= 3600) {
                            grace_val = (int)v;
                        } else {
                            init_log("Parse err: grace '%s' out of range (0-3600s) on service '%s', using default %ds",
                                     gr_str, name, SIGTERM_GRACE_SECS);
                        }
                    } else {
                        init_log("Parse err: invalid grace format '%s' on service '%s', using default %ds",
                                 gr_str, name, SIGTERM_GRACE_SECS);
                    }
                } else {
                    init_log("Warning: unknown option '%s' on service '%s'", scan, name);
                }

                scan = next_tag ? next_tag + 1 : NULL;
            }
        }

        /* Semantic Validation for Cgroup v2 Resource Limits */
        if (mem_max[0] != '\0') {
            if (!validate_memory_max(mem_max)) {
                init_log("Parse err: invalid memory_max '%s' on service '%s', limit ignored",
                         mem_max, name);
                mem_max = "";
            }
        }
        if (cpu_limit[0] != '\0') {
            if (!validate_cpu_max(cpu_limit)) {
                init_log("Parse err: invalid cpu_max '%s' on service '%s', limit ignored",
                         cpu_limit, name);
                cpu_limit = "";
            }
        }
        if (pids_limit[0] != '\0') {
            if (!validate_pids_max(pids_limit)) {
                init_log("Parse err: invalid pids_max '%s' on service '%s', limit ignored",
                         pids_limit, name);
                pids_limit = "";
            }
        }

        /* Mode Validation */
        int is_respawn = 0;
        if (strcmp(mode, "respawn") == 0) is_respawn = 1;
        else if (strcmp(mode, "once") != 0) {
            init_log("Warning: unknown mode '%s' for '%s'. Default: once", mode, name);
        }

        /* Reject entries where fields exceed buffer limits (audit SANE-03):
           earlier versions only warned and registered TRUNCATED services — names
           could collide with other services, commands could alter semantics, and
           truncated dependencies could point to invalid service names. Rejecting
           the entry fail-closed is safer than running with modified configuration. */
        int too_long = 0;
        if (strlen(name) >= sizeof(services[num_services].name)) {
            init_log("Parse err: service name too long (length %zu > max %d), entry rejected",
                     strlen(name), (int)sizeof(services[num_services].name) - 1);
            too_long = 1;
        }
        if (strlen(cmd) >= sizeof(services[num_services].cmd)) {
            init_log("Parse err: service command '%s' too long (length %zu > max %d), entry rejected",
                     name, strlen(cmd), (int)sizeof(services[num_services].cmd) - 1);
            too_long = 1;
        }
        if (strlen(deps) >= sizeof(services[num_services].deps_str)) {
            init_log("Parse err: service dependency '%s' too long (length %zu > max %d), entry rejected",
                     name, strlen(deps), (int)sizeof(services[num_services].deps_str) - 1);
            too_long = 1;
        }
        if (strlen(mem_max) >= sizeof(services[num_services].memory_max)) {
            init_log("Parse err: service memory_max '%s' too long (length %zu > max %d), entry rejected",
                     name, strlen(mem_max), (int)sizeof(services[num_services].memory_max) - 1);
            too_long = 1;
        }
        if (strlen(cpu_limit) >= sizeof(services[num_services].cpu_max)) {
            init_log("Parse err: service cpu_max '%s' too long (length %zu > max %d), entry rejected",
                     name, strlen(cpu_limit), (int)sizeof(services[num_services].cpu_max) - 1);
            too_long = 1;
        }
        if (strlen(pids_limit) >= sizeof(services[num_services].pids_max)) {
            init_log("Parse err: service pids_max '%s' too long (length %zu > max %d), entry rejected",
                     name, strlen(pids_limit), (int)sizeof(services[num_services].pids_max) - 1);
            too_long = 1;
        }
        if (too_long) continue;

        /* Bound precision to destination size to eliminate -Wformat-truncation warnings (name max 127 chars) */
        snprintf(services[num_services].name, sizeof(services[num_services].name), "%.*s",
                 (int)sizeof(services[num_services].name) - 1, name);
        snprintf(services[num_services].cmd,  sizeof(services[num_services].cmd),  "%.*s",
                 (int)sizeof(services[num_services].cmd) - 1, cmd);
        snprintf(services[num_services].deps_str, sizeof(services[num_services].deps_str), "%.*s",
                 (int)sizeof(services[num_services].deps_str) - 1, deps);
        snprintf(services[num_services].memory_max, sizeof(services[num_services].memory_max), "%.*s",
                 (int)sizeof(services[num_services].memory_max) - 1, mem_max);
        snprintf(services[num_services].cpu_max, sizeof(services[num_services].cpu_max), "%.*s",
                 (int)sizeof(services[num_services].cpu_max) - 1, cpu_limit);
        snprintf(services[num_services].pids_max, sizeof(services[num_services].pids_max), "%.*s",
                 (int)sizeof(services[num_services].pids_max) - 1, pids_limit);
        services[num_services].respawn      = is_respawn;
        services[num_services].need_respawn = 0;
        services[num_services].spawn_tries  = 0;
        services[num_services].crash_count  = 0;
        services[num_services].respawn_delay = RESPAWN_DELAY;
        services[num_services].timeout      = timeout_val;
        services[num_services].cgroup_fail_open = 0;
        services[num_services].pid          = 0;
        services[num_services].pgid         = 0;
        services[num_services].last_start   = 0;
        services[num_services].grace        = grace_val;
        services[num_services].sigkill_sent = 0;
        /* T10: registration is not a transition (the entry is already STOPPED),
           so it goes through the same single assignment point as everything else. */
        svc_set_state(&services[num_services], SVC_STATE_STOPPED);
        num_services++;
    }
    fclose(f);
    return 0;
}

/* ---------- dependencies ---------- */
static int find_service(const char *name)
{
    for (int i = 0; i < num_services; i++)
        if (strcmp(services[i].name, name) == 0) return i;
    return -1;
}

/* Next comma-separated token from deps_str WITHOUT mutating the original string:
   read offset is tracked in *off so callers can resume from the last point.
   Empty tokens (e.g. "a,,b") and outer whitespace are stripped.
   Returns 1 if token retrieved, 0 when exhausted. */
static int next_dep(const char *deps_str, int *off, char *out, size_t outsz)
{
    const char *s = deps_str + *off;

    for (;;) {
        size_t n = 0;
        while (*s == ',' || *s == ' ' || *s == '\t') s++;
        if (*s == 0) { *off = (int)(s - deps_str); return 0; }

        while (*s && *s != ',' && n < outsz - 1) out[n++] = *s++;
        /* Token exceeds output buffer size: discard remainder of this token
           so its trailing chunk is not parsed as a second dependency on the
           next call (audit SANE-03). deps_str length is already validated in
           parse_config(); this is a second line of defense ensuring the
           tokenizer never splits a single dependency name into two. */
        while (*s && *s != ',') s++;
        while (n > 0 && (out[n - 1] == ' ' || out[n - 1] == '\t')) n--;
        if (n > 0) { out[n] = 0; *off = (int)(s - deps_str); return 1; }
        /* empty token -> continue to next token */
    }
}

/* Every name in `:requires=` must exist in the service registry.
   Dependencies pointing to unknown services cause silently incorrect boot order
   (services running without prerequisites); falling back to the rescue shell
   is strictly preferred over an invalid partial boot. */
static int validate_dependencies(void)
{
    for (int i = 0; i < num_services; i++) {
        int off = 0;
        char token[256];
        while (next_dep(services[i].deps_str, &off, token, sizeof(token))) {
            if (find_service(token) < 0) {
                init_log("FATAL: Dependency '%s' for '%s' not found",
                         token, services[i].name);
                return -1;
            }
        }
    }
    return 0;
}

/* ---------- Topological Sort (Iterative DFS; mark BEFORE push) ----------
   Legacy implementations marked nodes on expansion rather than on push.
   Consequently, services still "pending" on the stack could be pushed again
   whenever another service expanded its dependencies, exceeding MAX_SERVICES
   and causing an out-of-bounds write on stack[] (stack overflow). By marking
   upon push, each service enters the stack at most once; since dependencies
   are processed sequentially, "gray" nodes strictly represent ancestors (not
   siblings), preventing diamond-shaped dependencies from falsely triggering
   cycle detection. */
static int sort_services(void)
{
    int visited[MAX_SERVICES]      = {0};   /* black: entered final sorted order */
    int temp_visited[MAX_SERVICES] = {0};   /* gray: currently on stack */
    int dep_off[MAX_SERVICES]      = {0};   /* deps_str read progress per service */
    service_t sorted[MAX_SERVICES];
    int sorted_count = 0;

    for (int i = 0; i < num_services; i++) {
        if (visited[i]) continue;

        int stack[MAX_SERVICES], stack_top = 0;

        if (stack_top >= MAX_SERVICES) {        /* guard before each push */
            init_log("FATAL: Stack overflow in topological sort!");
            return -1;
        }
        temp_visited[i] = 1;                    /* mark BEFORE push */
        stack[stack_top++] = i;

        while (stack_top > 0) {
            int curr = stack[stack_top - 1];
            char token[256];

            if (next_dep(services[curr].deps_str, &dep_off[curr], token, sizeof(token))) {
                int dep_idx = find_service(token);

                /* Unknown service names are already rejected by validate_dependencies();
                   if encountered here, skip the dependency. */
                if (dep_idx < 0) continue;

                if (temp_visited[dep_idx]) {
                    init_log("FATAL: CYCLE DETECTED at %s -> %s", services[curr].name, token);
                    return -1; /* Abort! */
                }
                if (!visited[dep_idx]) {
                    if (stack_top >= MAX_SERVICES) {
                        init_log("FATAL: Stack overflow in topological sort!");
                        return -1;
                    }
                    temp_visited[dep_idx] = 1;  /* mark BEFORE push */
                    dep_off[dep_idx]      = 0;
                    stack[stack_top++]    = dep_idx;
                }
                continue;   /* next dependency after child finishes */
            }

            /* All dependencies satisfied -> add to final ordering */
            visited[curr]          = 1;
            temp_visited[curr]     = 0;
            sorted[sorted_count++] = services[curr];
            stack_top--;
        }
    }

    for (int i = 0; i < sorted_count; i++) services[i] = sorted[i];
    return 0; /* Success */
}

/* ---------- process management ---------- */
/* Return values:
     1 = concrete progress made (process spawned, OR terminal failure reached)
         -> caller may mark progress
     0 = no progress (delayed by RESPAWN_DELAY window, or fork() failed but
         retry attempts remain)
   Previously void, allowing spawn_eligible_services() to mark progress
   blindly without inspecting results. Fork failures had no terminal state,
   leaving once services indefinitely STOPPED and dependencies blocked without
   diagnostic logs. */
static int spawn_service(service_t *svc)
{
    if (shutting_down) return 0;   /* during shutdown: do not sleep, do not fork */

    time_t now = time(NULL);

    /* Never block event loop with sleep(): if within respawn_delay window,
       mark need_respawn and let ppoll timeout in main loop act as timer.
       respawn_delay increases exponentially on crash loops (T8D), rather than
       staying fixed at RESPAWN_DELAY. */
    if (svc->last_start && (now - svc->last_start) < svc->respawn_delay) {
        if (!svc->need_respawn)
            init_log("%s: respawn delayed (timer %d seconds, loop unblocked)",
                     svc->name, svc->respawn_delay);
        svc->need_respawn = 1;
        return 0;
    }

    /* T12: the respawn delay has elapsed (or a once-service fork is being
       retried). Flush every process still attached to the service cgroup
       BEFORE the new generation is forked, so orphans/grandchildren from the
       previous generation can never survive into the new one. cgroup.kill
       sweeps the whole leaf; the kill inside setup_cgroup() afterwards is
       defense in depth. Skipped on the very first spawn (last_start == 0):
       there is no previous generation to flush. */
    if (svc->last_start) {
        init_log("%s: flushing cgroup before respawn", svc->name);
        cgroup_kill_service(svc->name);
    }

    /* T10: from this point the service is being started; the state leaves the
       idle STOPPED state so the lifecycle is observable while the spawn
       sequence (pipe setup, fork, backoff) is running. */
    svc_set_state(svc, SVC_STATE_STARTING);

    int sync_pipe[2] = { -1, -1 };
    int has_sync = 1;
    if (pipe2(sync_pipe, O_CLOEXEC) < 0) {
        if (pipe(sync_pipe) < 0) {
            /* Pipe creation failed: do not fork without synchronization, retry later */
            init_log("pipe2 %s: %s (spawn aborted, retry)",
                     svc->name, strerror(errno));
            svc->spawn_tries++;
            if (!svc->respawn && svc->spawn_tries >= MAX_SPAWN_RETRY) {
                init_log("%s: failed to create pipe %d times, service marked failed",
                         svc->name, svc->spawn_tries);
                svc_set_state(svc, SVC_STATE_FAILED);
                svc->spawn_tries = 0;
                return 1;
            }
            svc->need_respawn = 1;
            svc_set_state(svc, SVC_STATE_STOPPED);   /* start aborted, retry later */
            return 0;
        } else {
            /* Fallback pipe() succeeded: explicitly set FD_CLOEXEC.
               Fail-closed: if fcntl fails, the pipe MUST NOT be used
               (child could inherit synchronization FD across exec), so close
               both ends and retry via ppoll. */
            int fl0 = fcntl(sync_pipe[0], F_GETFD);
            int fl1 = fcntl(sync_pipe[1], F_GETFD);
            if (fl0 < 0 || fl1 < 0 ||
                fcntl(sync_pipe[0], F_SETFD, fl0 | FD_CLOEXEC) < 0 ||
                fcntl(sync_pipe[1], F_SETFD, fl1 | FD_CLOEXEC) < 0) {
                int err = errno;
                init_log("fcntl CLOEXEC %s: %s (spawn aborted, retry)",
                         svc->name, strerror(err));
                close(sync_pipe[0]);
                close(sync_pipe[1]);
                sync_pipe[0] = sync_pipe[1] = -1;
                svc->spawn_tries++;
                if (!svc->respawn && svc->spawn_tries >= MAX_SPAWN_RETRY) {
                    init_log("%s: failed to set CLOEXEC %d times, service marked failed",
                             svc->name, svc->spawn_tries);
                    svc_set_state(svc, SVC_STATE_FAILED);
                    svc->spawn_tries = 0;
                    return 1;
                }
                svc->need_respawn = 1;
                svc_set_state(svc, SVC_STATE_STOPPED);   /* start aborted, retry later */
                return 0;
            }
        }
    }

    svc->need_respawn = 0;
    svc->last_start   = time(NULL);

    /* T11: fork() with bounded retry + exponential backoff.
       fork() returns EAGAIN when the kernel cannot allocate a task — RLIMIT_NPROC,
       a saturated cgroup pids.max (the case scripts/test-spawn-failure.sh scenario 3
       reproduces), or pid-space exhaustion. That is a transient resource condition:
       retry it, but never in a busy loop. Attempt 1 is the initial fork(), then up
       to MAX_SPAWN_RETRY retries sleeping SPAWN_RETRY_BASE_MS << n (100/200/400 ms)
       with nanosleep(); fork() calls stay bounded by MAX_SPAWN_RETRY + 1. Any other
       errno is NOT retried: ENOENT/ENOMEM-class errors do not resolve by waiting and
       retrying them would only delay the terminal failure. */
    pid_t pid = -1;
    int   err = 0;
    for (int attempt = 1; attempt <= MAX_SPAWN_RETRY + 1; attempt++) {
        pid = fork();
        if (pid >= 0) break;
        err = errno;   /* capture before init_log(): open/dprintf modifies errno */

        if (attempt == 1)
            init_log("fork %s: %s", svc->name, strerror(err));
        if (err != EAGAIN || attempt > MAX_SPAWN_RETRY)
            break;

        int delay_ms = SPAWN_RETRY_BASE_MS << (attempt - 1);
        init_log("spawn: fork() EAGAIN for '%s', retrying in %dms (retry %d/%d)",
                 svc->name, delay_ms, attempt, MAX_SPAWN_RETRY);
        sleep_ms(delay_ms);
    }

    if (pid < 0) {
        if (has_sync) {
            if (sync_pipe[0] >= 0) close(sync_pipe[0]);
            if (sync_pipe[1] >= 0) close(sync_pipe[1]);
        }
        svc->spawn_tries++;
        /* Retries exhausted (or the error is not retryable): release the sync
           pipe, log the critical failure and reach a terminal state. Once services
           are never respawned, so without a terminal state they stayed STOPPED
           forever and their dependents waited without any diagnostic; marking
           FAILED lets deps_satisfied() cancel them instead. */
        if (err == EAGAIN)
            init_log("fork EAGAIN after %d retries for %s: %s",
                     MAX_SPAWN_RETRY, svc->name, strerror(err));
        init_log("fork %s: %s (%d attempts, service marked failed)",
                 svc->name, strerror(err), MAX_SPAWN_RETRY + 1);
        svc_set_state(svc, SVC_STATE_FAILED);
        svc->spawn_tries = 0;
        svc->need_respawn = 0;
        return 1;
    }

    if (pid == 0) {
        if (has_sync && sync_pipe[1] >= 0) {
            close(sync_pipe[1]);
        }

        setsid();

        /* Child inherits PID 1 signal mask (SIGCHLD/SIGTERM/SIGINT/SIGUSR1/
           SIGUSR2 blocked in main() for ppoll). With this mask inherited,
           the service NEVER receives SIGTERM -> shutdown_all() would kill it
           via SIGKILL. Clear mask in child so service signal handlers and
           traps function properly. */
        sigset_t empty;
        sigemptyset(&empty);
        if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0) {
            if (has_sync && sync_pipe[0] >= 0) close(sync_pipe[0]);
            _exit(126);
        }

        signal(SIGCHLD, SIG_DFL); signal(SIGTERM, SIG_DFL);
        signal(SIGINT,  SIG_DFL); signal(SIGUSR1, SIG_DFL); signal(SIGUSR2, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);

        int fd = open("/dev/null", O_RDONLY);
        if (fd >= 0) { dup2(fd, 0); close(fd); }

        /* Open FIFO blocking (without O_NONBLOCK) so child stdout/stderr does not return EAGAIN */
        fd = open("/run/log.fifo", O_WRONLY);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        else {
            fd = open("/dev/console", O_WRONLY);
            if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        }

        /* Synchronization handshake: wait for parent confirmation after cgroup setup finishes */
        if (has_sync && sync_pipe[0] >= 0) {
            char sync_byte;
            ssize_t nr;
            while ((nr = read(sync_pipe[0], &sync_byte, 1)) < 0) {
                if (errno == EINTR) continue;
                break;
            }
            /* Strict validation: require exactly 1 byte containing '1' */
            if (nr != 1 || sync_byte != '1') {
                close(sync_pipe[0]);
                _exit(127);
            }
            close(sync_pipe[0]);
        }

        /* T8B: prevent PID 1 control fds from leaking to child services.
           O_CLOEXEC is set on parent fds, but explicit closure in the child
           covers fds opened before flags were set and guarantees privilege
           separation preventing control plane leaks (SANE-06-01). */
        if (initctl_fd >= 0)    close(initctl_fd);
        if (g_log_fifo_fd >= 0) close(g_log_fifo_fd);
        if (log_file_fd >= 0)   close(log_file_fd);

        execl("/bin/sh", "sh", "-c", svc->cmd, (char *)NULL);
        _exit(127);
    }

    if (has_sync && sync_pipe[0] >= 0) {
        close(sync_pipe[0]);
    }

    svc->pid  = pid;
    svc->pgid = pid;   /* child called setsid(): acts as process group leader */
    svc_set_state(svc, SVC_STATE_RUNNING);
    svc->spawn_tries = 0;
    svc->sigkill_sent = 0;   /* T13: fresh process period, escalation not yet used */
    init_log("started %s (pid %d)", svc->name, pid);
    svc->cgroup_fail_open = setup_cgroup(svc->name, pid);

    if (has_sync && sync_pipe[1] >= 0) {
        ssize_t nw;
        do {
            nw = write(sync_pipe[1], "1", 1);
        } while (nw < 0 && errno == EINTR);
        (void)nw;
        close(sync_pipe[1]);
    }

    return 1;
}

/* T12: Reset the respawn generation counters of a service that is stopped or
   disabled. A service must never inherit the crash-loop backoff of a previous
   run: the next start begins with a clean generation (crash_count=0,
   respawn_delay=RESPAWN_DELAY). The reset is logged so the lifecycle stays
   auditable. Called on shutdown (service stopped) and when a service is
   disabled (marked FAILED: crash-loop, dependency failure, once timeout). */
static void reset_respawn_counters(service_t *svc)
{
    if (!svc) return;
    svc->crash_count   = 0;
    svc->respawn_delay = RESPAWN_DELAY;
    init_log("%s: respawn counters reset (generation=0, crash_count=0, respawn_delay=%d)",
             svc->name, svc->respawn_delay);
}

static void reap_zombies(void)
{
    int status; pid_t pid;

    /* Only reap terminated child processes. NEVER spawn inside this while(waitpid) loop:
       if a respawned service immediately exits, waitpid() continues returning
       new PIDs -> loop never terminates, starving the main ppoll event loop
       and delaying shutdown signals. */
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        for (int i = 0; i < num_services; i++) {
            if (services[i].pid == pid) {
                init_log("%s (pid %d) exit status=0x%x", services[i].name, pid, status);
                services[i].pid = 0;
                /* pgid INTENTIONALLY preserved: other group members may
                   still be alive after leader exits (audit SANE-01).
                   shutdown_all() tracks the group via this pgid. */
                if (!services[i].respawn) {
                    if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
                        svc_set_state(&services[i], SVC_STATE_DONE);
                    else
                        svc_set_state(&services[i], SVC_STATE_FAILED);
                    if (!shutting_down) {
                        cgroup_kill_service(services[i].name);
                        /* Fallback kill when cgroup fails open: leader exited but runtime
                           orphans may remain alive in group */
                        if (services[i].cgroup_fail_open && services[i].pgid > 0)
                            kill(-services[i].pgid, SIGKILL);
                        cleanup_cgroup(services[i].name);
                    }
                } else {
                    svc_set_state(&services[i], SVC_STATE_STOPPED);
                    if (!shutting_down) {
                        cgroup_kill_service(services[i].name);
                        /* Fallback kill when cgroup fails open: leader exited but runtime
                           orphans may remain alive in group */
                        if (services[i].cgroup_fail_open && services[i].pgid > 0)
                            kill(-services[i].pgid, SIGKILL);
                    }

                    /* T8D: crash-loop detection & start-limiting. Respawning
                       services that terminate within < RESPAWN_DELAY seconds
                       are treated as crashes; delay increases exponentially
                       (min(BACKOFF_MAX, 2 << crash_count)) and after
                       CRASH_LIMIT consecutive failures the service is marked
                       failed. Running longer than STABLE_RUNTIME seconds indicates
                       stability: crash count and backoff delay are reset. */
                    if (!shutting_down) {
                        long lifetime = services[i].last_start
                                        ? (long)(time(NULL) - services[i].last_start) : 0;
                        if (lifetime >= 0 && lifetime < RESPAWN_DELAY) {
                            services[i].crash_count++;
                            int d = 2 << services[i].crash_count;
                            services[i].respawn_delay = d > BACKOFF_MAX ? BACKOFF_MAX : d;
                            if (services[i].crash_count >= CRASH_LIMIT) {
                                init_log("%s: crash-loop detected (%d consecutive failures), service marked failed",
                                         services[i].name, services[i].crash_count);
                                svc_set_state(&services[i], SVC_STATE_FAILED);
                                services[i].need_respawn = 0;
                                reset_respawn_counters(&services[i]);
                            } else {
                                init_log("%s: crash-loop #%d, respawn delay increased to %d seconds",
                                         services[i].name, services[i].crash_count,
                                         services[i].respawn_delay);
                            }
                        } else if (lifetime > STABLE_RUNTIME) {
                            services[i].crash_count = 0;
                            services[i].respawn_delay = RESPAWN_DELAY;
                        }
                    }
                }
                break;
            }
        }
    }
}

/* Check if all service dependencies are satisfied:
   - Once services must have completed successfully (SVC_STATE_DONE).
   - Respawn services must be currently running (pid > 0).
   Returns:
     1 = all dependencies satisfied
     0 = still waiting on dependencies
    -1 = dependency failed (once failed/timed out, or respawn marked FAILED)
*/
static int deps_satisfied(const service_t *svc, const char **failed_dep)
{
    int off = 0;
    char token[256];
    while (next_dep(svc->deps_str, &off, token, sizeof(token))) {
        int idx = find_service(token);
        if (idx < 0) continue;
        const service_t *dep = &services[idx];
        if (dep->respawn) {
            if (dep->state == SVC_STATE_FAILED) {
                if (failed_dep) *failed_dep = dep->name;
                return -1;
            }
            if (dep->pid <= 0) return 0;
        } else {
            if (dep->state == SVC_STATE_FAILED) {
                if (failed_dep) *failed_dep = dep->name;
                return -1;
            }
            if (dep->state != SVC_STATE_DONE) return 0;
        }
    }
    return 1;
}

/* Spawn all services whose dependencies are satisfied. */
static void spawn_eligible_services(void)
{
    if (shutting_down) return;

    int progress;
    do {
        progress = 0;
        for (int i = 0; i < num_services; i++) {
            service_t *svc = &services[i];
            if (svc->pid > 0 || svc->state == SVC_STATE_DONE || svc->state == SVC_STATE_FAILED)
                continue;
            if (svc->need_respawn)
                continue;

            const char *failed_dep = NULL;
            int ret = deps_satisfied(svc, &failed_dep);
            if (ret < 0) {
                init_log("service '%s' cancelled: dependency '%s' failed", svc->name, failed_dep);
                svc_set_state(svc, SVC_STATE_FAILED);
                reset_respawn_counters(svc);
                progress = 1;
            } else if (ret == 1) {
                /* Only mark progress if spawn_service made actual state changes.
                   Otherwise, fork() failures (which only set need_respawn) would
                   cause the do-while loop to spin repeatedly without state progress. */
                if (spawn_service(svc)) progress = 1;
            }
        }
    } while (progress);
}

/* Respawn execution occurs only from the main event loop, outside reap_zombies().
   Dependencies MUST be checked here. Earlier versions only evaluated
   `respawn && pid == 0` before spawning immediately, reviving services whose
   once dependencies failed (marked FAILED) indefinitely — violating
   `requires=` order and rendering cancellation a no-op log.
   This path also serves as a retry handler for once services whose initial
   fork() failed (need_respawn): once services never respawn, so without this
   they remained stalled in STOPPED state forever. */
static void respawn_services(void)
{
    if (shutting_down) return;

    for (int i = 0; i < num_services; i++) {
        service_t *svc = &services[i];
        if (svc->pid > 0 || svc->state == SVC_STATE_DONE || svc->state == SVC_STATE_FAILED)
            continue;
        if (!svc->respawn && !svc->need_respawn)
            continue;   /* not yet attempted: handled by spawn_eligible_services() */

        const char *failed_dep = NULL;
        int ret = deps_satisfied(svc, &failed_dep);
        if (ret < 0) {
            init_log("service '%s' cancelled: dependency '%s' failed", svc->name, failed_dep);
            svc_set_state(svc, SVC_STATE_FAILED);
            svc->need_respawn = 0;
            reset_respawn_counters(svc);
            continue;
        }
        if (ret == 0) {
            /* Dependencies not yet satisfied: nothing further to attempt,
               so clear need_respawn. Otherwise, respawn_pending() wakes ppoll
               10 times/second indefinitely without making progress — and this
               service will be re-evaluated by spawn_eligible_services() on the
               next iteration regardless. */
            svc->need_respawn = 0;
            continue;
        }
        spawn_service(svc);
    }
}

/* Are any services waiting on respawn_delay timer? If so, ppoll uses 100 ms
   timeout; otherwise NULL (blocks until signal or fd event). */
static int respawn_pending(void)
{
    for (int i = 0; i < num_services; i++)
        if (services[i].need_respawn)
            return 1;
    return 0;
}

/* ppoll timeout calculation for main loop housekeeping:
   - 100 ms if respawn pending (respawn_delay / backoff timer);
   - 1 second if once service running, ensuring enforce_once_timeout()
     executes even if ppoll would otherwise block indefinitely;
   - NULL (full block) when no housekeeping is pending. */
static struct timespec *compute_poll_timeout(struct timespec *ts)
{
    if (respawn_pending()) {
        ts->tv_sec = 0;
        ts->tv_nsec = 100 * 1000 * 1000;
        return ts;
    }
    for (int i = 0; i < num_services; i++) {
        if (services[i].respawn) continue;
        if (services[i].state == SVC_STATE_RUNNING && services[i].timeout > 0) {
            ts->tv_sec = 1;
            ts->tv_nsec = 0;
            return ts;
        }
    }
    return NULL;
}

/* T8D: transitively cancel all services dependent on a failed service.
   Transitive closure runs to a fixed point ensuring indirect dependents
   are cancelled as well. Currently running services (pid > 0) are left intact
   for shutdown handling. */
static void cancel_dependents(void)
{
    int changed = 1;
    while (changed) {
        changed = 0;
        for (int i = 0; i < num_services; i++) {
            service_t *svc = &services[i];
            if (svc->state == SVC_STATE_FAILED || svc->state == SVC_STATE_DONE)
                continue;
            if (svc->pid > 0) continue;
            int off = 0;
            char token[256];
            while (next_dep(svc->deps_str, &off, token, sizeof(token))) {
                int di = find_service(token);
                if (di >= 0 && services[di].state == SVC_STATE_FAILED) {
                    init_log("service '%s' cancelled: dependency '%s' failed",
                             svc->name, token);
                    svc_set_state(svc, SVC_STATE_FAILED);
                    reset_respawn_counters(svc);
                    changed = 1;
                    break;
                }
            }
        }
    }
}

/* T8D: once services exceeding their timeout threshold are marked failed
   (fail-closed). Default ONCE_START_TIMEOUT (30 seconds), or configured via
   :timeout= option. Setting :timeout=0 / none disables timeout enforcement.
   The process is killed and all waiting dependents are cancelled. */
static void enforce_once_timeout(void)
{
    if (shutting_down) return;

    time_t now = time(NULL);
    for (int i = 0; i < num_services; i++) {
        service_t *svc = &services[i];
        if (svc->respawn) continue;
        if (svc->state != SVC_STATE_RUNNING) continue;
        if (svc->timeout <= 0) continue;
        if (!svc->last_start || (now - svc->last_start) < svc->timeout) continue;

        init_log("%s: once service exceeded %d seconds timeout, marked failed",
                 svc->name, svc->timeout);
        /* T10: a timeout is a stop followed by a failure, so the state travels
           RUNNING -> STOPPING -> FAILED instead of jumping straight to FAILED. */
        svc_set_state(svc, SVC_STATE_STOPPING);
        svc_set_state(svc, SVC_STATE_FAILED);
        svc->need_respawn = 0;
        reset_respawn_counters(svc);
        if (svc->pid > 0)
            kill_service_group(svc, SIGKILL);
        cancel_dependents();
    }
}

/* Read ALL pending service output from /run/log.fifo and forward to
   stderr + init log. Used by the event loop AND shutdown_all(): otherwise,
   final log messages emitted by services shutting down on SIGTERM (e.g. "bye!")
   would never be captured since the main loop stops draining FIFO during shutdown.
   Capped at 64 iterations per invocation to prevent CPU monopolization and
   avoid delaying ppoll signal handling. */
static void drain_log_fifo(void)
{
    if (g_log_fifo_fd < 0) return;

    for (int i = 0; i < 64; i++) {
        char log_buf[1024];
        ssize_t n = read(g_log_fifo_fd, log_buf, sizeof(log_buf) - 1);
        if (n <= 0) return;   /* EAGAIN (empty) or EOF */
        log_buf[n] = 0;

        char time_buf[32]; time_t now = time(NULL);
        struct tm tm_info; localtime_r(&now, &tm_info);
        strftime(time_buf, sizeof(time_buf), "[%Y-%m-%d %H:%M:%S]", &tm_info);

        fprintf(stderr, "%s [service] %s", time_buf, log_buf);
        if (log_file_fd >= 0) dprintf(log_file_fd, "%s [service] %s", time_buf, log_buf);
    }
}


/* Send signal to entire service process group (via recorded pgid,
   NOT leader pid: leader may have exited while child processes remain active —
   audit SANE-01), and to the whole cgroup as well: SIGKILL through cgroup.kill,
   any other signal (T13 SIGTERM) through cgroup_signal_service(). The two paths
   are complementary — the pgid covers processes that left the cgroup, the cgroup
   covers processes that left the process group (setsid/setpgid). */
static void kill_service_group(const service_t *svc, int sig)
{
    if (svc->pgid > 0) {
        if (kill(-svc->pgid, sig) < 0 && errno == ESRCH && svc->pid > 0)
            kill(svc->pid, sig);
    } else if (svc->pid > 0) {
        kill(svc->pid, sig);
    }

    cgroup_signal_service(svc->name, sig);
}

/* Is any process in this service still alive? Leader (pid) OR any process
   in its process group. Empty groups are detected via kill(-pgid, 0) failing
   with ESRCH; pgid is then cleared to avoid misdirected signals if the PID
   is later recycled by the kernel. */
static int service_still_alive(service_t *svc)
{
    if (svc->pid > 0) return 1;
    if (svc->pgid > 0) {
        if (kill(-svc->pgid, 0) == 0 || errno == EPERM) return 1;
        svc->pgid = 0;
    }
    return 0;
}

/* T8E: prepare filesystems before reboot. Remount / read-only first to prevent
   further writes to the rootfs, then detach fstab entries recorded by
   mount_fstab() with MNT_DETACH (safe even if processes still reference them).
   Failures are logged and do not abort shutdown. */
static void prepare_filesystems(void)
{
    if (mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL) < 0)
        init_log("shutdown: remount / read-only failed: %s", strerror(errno));
    else
        init_log("shutdown: / remounted read-only");

    for (int i = 0; i < g_seen_cnt; i++) {
        if (umount2(g_seen_mnt[i], MNT_DETACH) < 0) {
            if (errno != EINVAL && errno != ENOENT)
                init_log("shutdown: umount2 %s failed: %s", g_seen_mnt[i], strerror(errno));
        } else {
            init_log("shutdown: umount2 %s ok", g_seen_mnt[i]);
        }
    }
}

/* ---------- shutdown ---------- */
static void shutdown_all(int reboot_cmd, int force)
{
    shutting_down = 1;   /* mark shutdown in progress: respawning disabled */

    if (force) {
        init_log("FORCE shutdown (cmd=%d)", reboot_cmd);
        for (int i = 0; i < num_services; i++) {
            /* Probe first (addressing PR #2 review note): service_still_alive()
               cleans up stale pgids from services that exited earlier, preventing
               SIGKILL from targeting recycled process groups.
               Processes escaping their group are still terminated by cgroup.kill. */
            if (service_still_alive(&services[i])) {
                svc_set_state(&services[i], SVC_STATE_STOPPING);
                kill_service_group(&services[i], SIGKILL);
            } else {
                cgroup_kill_service(services[i].name);
            }
            /* T12: the service is stopped: reset its generation counters so a
               future start never inherits this run's crash-loop backoff. */
            reset_respawn_counters(&services[i]);
            cleanup_cgroup(services[i].name);
        }
        rmdir(CGROUP_BASE);
        reap_zombies(); prepare_filesystems(); sync();
        if (reboot(reboot_cmd) < 0) init_log("reboot(%d) failed: %s", reboot_cmd, strerror(errno));
        while (1) pause();
    }

    init_log("graceful shutdown (cmd=%d)", reboot_cmd);

    /* T13 phase 1 — SIGTERM to every live service, across BOTH its process group
       and its cgroup: kill_service_group() reaches processes that left the
       cgroup, the cgroup.procs sweep reaches processes that called setsid()/
       setpgid() and would otherwise miss kill(-pgid) (SANE-01). cgroup.kill is
       deliberately NOT used for the polite signal: it only implements SIGKILL and
       would end the grace window before a well-behaved service could exit
       (scripts/test-sigterm.sh scenario 1 asserts the trap really runs). */
    long long grace_t0_ms = monotonic_ms();
    for (int i = 0; i < num_services; i++) {
        /* Probe before signaling (same as force shutdown path above):
           stale pgids are pruned first, ensuring only genuinely active
           groups receive SIGTERM. */
        if (service_still_alive(&services[i])) {
            svc_set_state(&services[i], SVC_STATE_STOPPING);
            kill_service_group(&services[i], SIGTERM);
        }
    }

    /* T13 phase 2 — per-service grace window (:grace=N, default
       SIGTERM_GRACE_SECS), polled every 100 ms with nanosleep(). A service still
       alive when its own window expires is escalated to SIGKILL immediately and
       exactly once ("grace expired, SIGKILL"). The loop ends when nothing is
       alive, or when every survivor has already been escalated, so the total
       wait is bounded by the LONGEST configured grace instead of growing with
       the number of services. */
    for (;;) {
        int alive = 0, waiting = 0;

        reap_zombies();
        drain_log_fifo();   /* capture last logs before death (e.g. "bye!") */
        long long elapsed_ms = monotonic_ms() - grace_t0_ms;

        /* Probe EVERY service, do not break on the first active one: only
           service_still_alive() clears stale pgids. Breaking early would leave
           services after an active one unprobed on the final pass, allowing
           stale pgids to persist into the SIGKILL sweep below and hit recycled
           process groups. */
        for (int j = 0; j < num_services; j++) {
            service_t *svc = &services[j];
            if (!service_still_alive(svc)) continue;
            alive = 1;
            if (elapsed_ms >= (long long)svc->grace * 1000) {
                if (!svc->sigkill_sent) {
                    svc->sigkill_sent = 1;
                    init_log("%s: grace expired, SIGKILL", svc->name);
                    kill_service_group(svc, SIGKILL);
                }
            } else {
                waiting = 1;   /* still inside its grace window: keep polling */
            }
        }
        if (!alive || !waiting) break;
        sleep_ms(100);
    }

    for (int i = 0; i < num_services; i++) {
        service_t *svc = &services[i];
        /* Probe once more before SIGKILL, matching force and SIGTERM paths:
           groups may have exited after the last pass. Services with empty groups
           only require cgroup.kill — signaling stale pgids with SIGKILL is dangerous.
           A service already escalated when its own grace window expired (T13) is
           not re-reported as a dead group: its SIGKILL was deliberate, and the
           "already dead" message would misreport the escalation as a no-op. */
        if (svc->sigkill_sent) {
            cgroup_kill_service(svc->name);
        } else if (service_still_alive(svc)) {
            kill_service_group(svc, SIGKILL);
        } else {
            init_log("%s: process group already dead, SIGKILL skipped", svc->name);
            cgroup_kill_service(svc->name);
        }
        /* T12: the service is stopped: reset its generation counters so a
           future start never inherits this run's crash-loop backoff. */
        reset_respawn_counters(&services[i]);
        cleanup_cgroup(services[i].name);
    }
    rmdir(CGROUP_BASE);
    prepare_filesystems();
    sync();
    if (reboot(reboot_cmd) < 0) init_log("reboot(%d) failed: %s", reboot_cmd, strerror(errno));
    while (1) pause();
}

/* ---------- setup IPC (FIXED: O_RDWR) ---------- */
/* T8B: O_CLOEXEC mandatory on PID 1 control fds to prevent leaks to child
   services (SANE-06-01). O_RDWR ensures the FIFO always has an active reader. */
static int setup_initctl(void) { mkfifo("/run/initctl", 0600); return open("/run/initctl", O_RDWR | O_NONBLOCK | O_CLOEXEC); }
static int setup_log_fifo(void) { mkfifo("/run/log.fifo", 0600); return open("/run/log.fifo", O_RDWR | O_NONBLOCK | O_CLOEXEC); }

/* ---------- /etc/fstab ---------- */
#ifndef FSTAB_PATH
#define FSTAB_PATH "/etc/fstab"
#endif

#ifndef MS_LAZYTIME
#define MS_LAZYTIME (1U << 25)   /* kernel >= 4.0; missing in older glibc headers */
#endif

/* Classify fstab options in a single pass (audit SANE-02, expanded
   following PR #2 review):
     1. VFS flags (ro, noatime, lazytime, ...) -> returned as MS_* flags
        for 4th argument of mount(). Inverse counterparts (rw, exec,
        suid, dev, async, atime, diratime) CLEAR opposing bits, and
        "user"/"users"/"owner"/"group" apply mount(8) implied flags —
        all processed left-to-right so later tokens take precedence.
     2. Pure userspace fstab options (_netdev, nofail, x-*, comment=*, ...) ->
        handled by mount(8)/systemd, NOT kernel: logged then ignored,
        never passed along as filesystem data.
     3. "noauto" -> entry is skipped entirely (*skip_reason = SKIP_NOAUTO),
        matching standard `mount -a` boot behavior.
     4. "bind"/"rbind" -> NOT supported: entry skipped with explicit reason
        (*skip_reason = SKIP_BIND) logged by caller.
        Bind mounts change first-column fstab semantics into a source path,
        whereas ninit treats it as a device node/filesystem label; partial
        support leads to silent mount failures.
     5. Other tokens -> filesystem-specific data options (size=, mode=, uid=, ...),
        copied to `data` for 5th argument of mount().
   Flag tokens MUST NOT leak into data buffer: strict filesystem option
   parsers (ext4, tmpfs) reject unknown data options with EINVAL. */
#define SKIP_NONE   0
#define SKIP_NOAUTO 1
#define SKIP_BIND   2
static unsigned long parse_mount_flags(char *opts, char *data, size_t datasz, int *skip_reason)
{
    unsigned long flags = 0;
    char *tok;

    if (data && datasz) data[0] = 0;
    if (skip_reason) *skip_reason = SKIP_NONE;
    if (!opts) return 0;

    /* Tokens processed LEFT TO RIGHT matching mount(8): negating tokens
       clear opposing bits (ro then rw ends up rw), and "user"
       applies implications that can be overridden by subsequent tokens
       (user,exec ends up exec) — PR #2 review items 1 & 2. */
    for (tok = strtok(opts, ","); tok; tok = strtok(NULL, ",")) {
        if (!strcmp(tok, "defaults")) continue;
        else if (!strcmp(tok, "rw"))          flags &= ~MS_RDONLY;
        else if (!strcmp(tok, "async"))       flags &= ~MS_SYNCHRONOUS;
        else if (!strcmp(tok, "atime"))       flags &= ~(MS_NOATIME | MS_RELATIME | MS_STRICTATIME);
        else if (!strcmp(tok, "diratime"))    flags &= ~MS_NODIRATIME;
        else if (!strcmp(tok, "exec"))        flags &= ~MS_NOEXEC;
        else if (!strcmp(tok, "suid"))        flags &= ~MS_NOSUID;
        else if (!strcmp(tok, "dev"))         flags &= ~MS_NODEV;
        else if (!strcmp(tok, "ro"))          flags |= MS_RDONLY;
        else if (!strcmp(tok, "noexec"))      flags |= MS_NOEXEC;
        else if (!strcmp(tok, "nosuid"))      flags |= MS_NOSUID;
        else if (!strcmp(tok, "nodev"))       flags |= MS_NODEV;
        else if (!strcmp(tok, "sync"))        flags |= MS_SYNCHRONOUS;
        else if (!strcmp(tok, "dirsync"))     flags |= MS_DIRSYNC;
        else if (!strcmp(tok, "remount"))     flags |= MS_REMOUNT;
        else if (!strcmp(tok, "bind"))        flags |= MS_BIND;
        else if (!strcmp(tok, "rbind"))       flags |= MS_BIND | MS_REC;
        else if (!strcmp(tok, "noatime"))     { flags |= MS_NOATIME;     flags &= ~(MS_RELATIME | MS_STRICTATIME); }
        else if (!strcmp(tok, "relatime"))    { flags |= MS_RELATIME;    flags &= ~(MS_NOATIME | MS_STRICTATIME); }
        else if (!strcmp(tok, "strictatime")) { flags |= MS_STRICTATIME; flags &= ~(MS_NOATIME | MS_RELATIME); }
        else if (!strcmp(tok, "nodiratime"))  flags |= MS_NODIRATIME;
        else if (!strcmp(tok, "lazytime"))    flags |= MS_LAZYTIME;
        else if (!strcmp(tok, "user") || !strcmp(tok, "users")) {
            /* mount(8): user/users implies noexec+nosuid+nodev
               (can be overridden by subsequent exec/suid/dev tokens). */
            flags |= MS_NOEXEC | MS_NOSUID | MS_NODEV;
            init_log("fstab: option '%s' applies noexec,nosuid,nodev", tok);
        }
        else if (!strcmp(tok, "owner") || !strcmp(tok, "group")) {
            /* mount(8): owner/group implies nosuid+nodev. */
            flags |= MS_NOSUID | MS_NODEV;
            init_log("fstab: option '%s' applies nosuid,nodev", tok);
        }
        else if (!strcmp(tok, "noauto")) {
            if (skip_reason && *skip_reason == SKIP_NONE) *skip_reason = SKIP_NOAUTO;
        }
        else if (!strcmp(tok, "auto") || !strcmp(tok, "nouser") ||
                 !strcmp(tok, "_netdev") || !strcmp(tok, "nofail") ||
                 !strncmp(tok, "x-", 2) || !strncmp(tok, "comment=", 8)) {
            init_log("fstab: option '%s' is userspace-only, ignored", tok);
        }
        else {
            init_log("fstab: option '%s' is not a flag, passed as data", tok);
            if (data && datasz) {
                if (data[0]) strncat(data, ",", datasz - strlen(data) - 1);
                strncat(data, tok, datasz - strlen(data) - 1);
            }
        }
    }
    /* MS_BIND has no negating token: once bind/rbind (including combinations
       like remount,bind) appears, the entry is unsupported and skipped —
       decided here in the parser so callers skip BEFORE creating mountpoints
       (preventing phantom directories for unmounted entries). */
    if ((flags & MS_BIND) && skip_reason && *skip_reason == SKIP_NONE)
        *skip_reason = SKIP_BIND;
    return flags;
}

/* Create directory and parent hierarchy (mkdir -p), mode 0755 for each
   NEWLY created directory (explicit chmod applied so permissions do not
   depend on inherited PID 1 umask; chmod failure aborts entry).
   Entire path is PRE-SCANNED: "." and ".." components are rejected before
   creating any directories, preventing phantom directories on failure
   (fstab entries must not silently normalize to unexpected paths).
   Existing components must be directories: verified using stat() which
   FOLLOWS symlinks — symlinks to directories are accepted, symlinks to files
   or regular file components are rejected with clear diagnostic logs (without
   this, mkdir EEXIST would pass and mount() would fail with ENOTDIR far from
   the root cause). Path must be absolute and fit in buffer (no silent truncation).
   Returns 0 when mountpoint is ready, -1 if entry should be skipped. */
static int mkdir_p(const char *path)
{
    char buf[MAX_LINE];
    size_t len;

    if (!path) return -1;
    len = strlen(path);
    if (path[0] != '/' || len >= sizeof(buf)) {
        init_log("fstab: mountpoint '%s' invalid (must be absolute, max %zu chars)",
                 path, sizeof(buf) - 1);
        return -1;
    }

    /* Pre-scan components: reject "." / ".." before first mkdir call. */
    for (const char *s = path; *s; ) {
        while (*s == '/') s++;
        const char *e = s;
        while (*e && *e != '/') e++;
        size_t clen = (size_t)(e - s);
        if ((clen == 1 && s[0] == '.') ||
            (clen == 2 && s[0] == '.' && s[1] == '.')) {
            init_log("fstab: mountpoint '%s' contains component '%.*s', rejected",
                     path, (int)clen, s);
            return -1;
        }
        s = e;
    }

    memcpy(buf, path, len + 1);

    /* Iterate component-by-component; empty segments (double slashes,
       trailing slash, and "/" itself) resolve to existing directories
       and pass via EEXIST + stat check below. */
    for (char *p = buf + 1; ; p++) {
        if (*p != '/' && *p != '\0') continue;
        char save = *p;
        *p = '\0';
        if (mkdir(buf, 0755) == 0) {
            if (chmod(buf, 0755) < 0) {
                init_log("fstab: chmod '%s' failed: %s", buf, strerror(errno));
                return -1;
            }
        } else if (errno == EEXIST) {
            struct stat st;
            if (stat(buf, &st) < 0) {
                init_log("fstab: stat '%s' failed: %s", buf, strerror(errno));
                return -1;
            }
            if (!S_ISDIR(st.st_mode)) {
                init_log("fstab: component '%s' of mountpoint '%s' is not a directory", buf, path);
                return -1;
            }
        } else {
            init_log("fstab: mkdir '%s' failed: %s", buf, strerror(errno));
            return -1;
        }
        *p = save;
        if (save == '\0') break;
    }
    return 0;
}

/* Decode octal escape sequences in fstab in-place, following getmntent(3)/mount(8):
   backslash followed by EXACTLY three octal digits (\040 space, \011 tab, \012
   newline, \134 backslash, and other \ooo) decodes to a single byte; other
   sequences are left intact. Decoded output is never longer than input,
   making in-place transformation safe. Applied to device and mountpoint fields
   BEFORE other validations (mkdir_p pre-scan, duplicate check), ensuring all
   checks operate on true paths — e.g. \056\056 decoding to ".." is still caught
   by mkdir_p pre-scan. Without decoding (finding PR3-C1), paths with spaces
   created literal directories like "spa\040ce", deviating silently from mount -a.
   Options field is NOT decoded: tokens are comma-separated by parse_mount_flags(),
   and decoded commas (\054) would alter token boundary semantics; spaces in paths
   live in device/mountpoint. */
static void unescape_fstab_field(char *s)
{
    char *r = s, *w = s;
    while (*r) {
        if (r[0] == '\\' && r[1] >= '0' && r[1] <= '7' &&
            r[2] >= '0' && r[2] <= '7' && r[3] >= '0' && r[3] <= '7') {
            *w++ = (char)((r[1] - '0') * 64 + (r[2] - '0') * 8 + (r[3] - '0'));
            r += 4;
        } else {
            *w++ = *r++;
        }
    }
    *w = '\0';
}

/* Two mountpoints are identical if equivalent after ignoring trailing slashes
   ("/mnt/x/" and "/mnt/x" are the same directory; "/" remains "/").
   Used for mount_fstab duplicate checking. */
static int same_mountpoint(const char *a, const char *b)
{
    size_t la = strlen(a), lb = strlen(b);
    while (la > 1 && a[la - 1] == '/') la--;
    while (lb > 1 && b[lb - 1] == '/') lb--;
    return la == lb && strncmp(a, b, la) == 0;
}

/* Format: <device> <mountpoint> <fstype> <options> [dump] [pass]; '#' lines ignored */
static void mount_fstab(void)
{
    FILE *f = fopen(FSTAB_PATH, "r");
    if (!f) {
        init_log("fstab: %s does not exist, skipped", FSTAB_PATH);
        return;
    }

    /* Mountpoints ALREADY successfully mounted by an earlier entry during
       this pass (finding PR3-C2): mount(2) silently stacks duplicate mounts,
       where top mount options shadow underlying protections (nosuid lost
       without warning). Duplicate entries are now skipped and logged. Only
       SUCCESSFUL mounts are tracked, ensuring first-entry failures do not
       prevent subsequent valid entries from mounting to the same mountpoint.
       This tracking is also used by prepare_filesystems() at shutdown (T8E). */
    /* g_seen_mnt/g_seen_cnt defined at file scope (T8E). */

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        if (line_overlong(f, line)) {
            init_log("fstab: line exceeds MAX_LINE (%d), skipped", MAX_LINE);
            continue;
        }
        line[strcspn(line, "\n")] = 0;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == 0) continue;

        char *dev  = strtok(p, " \t");
        char *mnt  = strtok(NULL, " \t");
        char *type = strtok(NULL, " \t");
        char *opts = strtok(NULL, " \t");

        if (!dev || !mnt || !type) {
            init_log("fstab: incomplete line: '%s'", p);
            continue;
        }

        /* Octal escapes decoded prior to any subsequent processing (see
           unescape_fstab_field): logs, mkdir, duplicate checks, and mount()
           all observe true filesystem paths. */
        unescape_fstab_field(dev);
        unescape_fstab_field(mnt);

        /* Options parsed ONCE by parse_mount_flags() from a string copy
           (strtok modifies original string in-place): flag tokens become MS_*
           flags (arg 4) and non-flag tokens become filesystem-specific data
           (arg 5). Flag tokens MUST NOT leak into data — strict option parsers
           (ext4/tmpfs) reject unknown data options with EINVAL (audit SANE-02). */
        char flagbuf[MAX_LINE];
        char databuf[MAX_LINE] = "";
        snprintf(flagbuf, sizeof(flagbuf), "%s", opts ? opts : "");
        int skip_reason = SKIP_NONE;
        unsigned long flags = parse_mount_flags(flagbuf, databuf, sizeof(databuf), &skip_reason);
        /* Skip decisions determined by parser and evaluated here,
           BEFORE mountpoints are created: skipped entries do not leave
           phantom directories on rootfs. */
        if (skip_reason == SKIP_NOAUTO) {
            init_log("fstab: %s -> %s skipped (noauto option)", dev, mnt);
            continue;
        }
        if (skip_reason == SKIP_BIND) {
            init_log("fstab: %s -> %s skipped (bind/rbind not supported)", dev, mnt);
            continue;
        }

        /* Duplicate check runs after parser skip decision, before mkdir:
           skipped entries do not leave phantom directories, identical to
           noauto/bind handling. */
        int is_dup = 0;
        for (int i = 0; i < g_seen_cnt; i++)
            if (same_mountpoint(g_seen_mnt[i], mnt)) { is_dup = 1; break; }
        if (is_dup) {
            init_log("fstab: %s -> %s skipped (duplicate mountpoint, already mounted by previous entry)", dev, mnt);
            continue;
        }

        if (mkdir_p(mnt) < 0) {
            init_log("fstab: %s -> %s skipped (mountpoint could not be prepared)", dev, mnt);
            continue;
        }
        if (mount(dev, mnt, type, flags, databuf[0] ? databuf : NULL) < 0)
            init_log("fstab: mount %s -> %s (%s) [data: %s] failed: %s", dev, mnt, type,
                     databuf[0] ? databuf : "-", strerror(errno));
        else {
            init_log("fstab: mount %s -> %s (%s) [data: %s] ok", dev, mnt, type,
                     databuf[0] ? databuf : "-");
            if (g_seen_cnt < MAX_SEEN_MNT)
                snprintf(g_seen_mnt[g_seen_cnt++], MAX_LINE, "%s", mnt);
        }
    }
    fclose(f);
}

/* ---------- rescue mode ----------
   The sole fallback path when init cannot proceed with normal boot.
   Three mandatory requirements:

     1. PID 1 signal mask is cleared. main() blocks SIGINT/SIGTERM/SIGCHLD/
        SIGUSR1/SIGUSR2 for ppoll; without a reset, the rescue shell inherits
        this mask and Ctrl+C in emergency shell is ignored (SIGINT blocked).
        spawn_service() performs identical mask clearing for child services.
     2. SIGPIPE disposition reset to SIG_DFL. main() configures signal(SIGPIPE, SIG_IGN)
        for PID 1; without a reset, emergency shell inherits SIG_IGN breaking
        standard pipeline tools (yes | head -n 1).
     3. execl() replaces PID 1 with /bin/sh. If execl fails (e.g. /bin/sh missing
        from rootfs), process exits with status 1 -- NEVER return to boot flow
        with an invalid internal state.

   This function never returns. */
static void enter_rescue_mode(const char *reason)
{
    sigset_t empty;

    if (reason) init_log("%s", reason);

    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0)
        init_log("Warning: failed to clear signal mask: %s", strerror(errno));

    init_log("Entering rescue mode (shell).");
    signal(SIGPIPE, SIG_DFL);

    /* T8B: release PID 1 control fds before exec (SANE-06-01).
       O_CLOEXEC flag is set on parent fds; this explicit close covers fds
       opened before flags were present and covers rescue invocations prior
       to setup_initctl()/setup_log_fifo(). */
    if (initctl_fd >= 0)    close(initctl_fd);
    if (g_log_fifo_fd >= 0) close(g_log_fifo_fd);
    if (log_file_fd >= 0)   close(log_file_fd);

    execl("/bin/sh", "sh", (char *)NULL);
    init_log("FATAL: execl /bin/sh failed: %s", strerror(errno));
    _exit(1);
}

/* ---------- main ---------- */
int main(int argc, char **argv)
{
    if (getpid() != 1) {
        fprintf(stderr, "ninit must be run as PID 1\n");
        return 1;
    }
    umask(022);

    sigset_t block, orig;
    sigemptyset(&block);
    sigaddset(&block, SIGCHLD); sigaddset(&block, SIGTERM); sigaddset(&block, SIGINT);
    sigaddset(&block, SIGUSR1); sigaddset(&block, SIGUSR2);
    sigprocmask(SIG_BLOCK, &block, &orig);
    sigemptyset(&orig);   /* force ppoll to unblock ALL signals (including inherited mask) */

    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigchld; sigaction(SIGCHLD, &sa, NULL);
    sa.sa_handler = on_sigterm; sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_sigint;  sigaction(SIGINT,  &sa, NULL);
    sa.sa_handler = on_sigusr1; sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = on_sigusr2; sigaction(SIGUSR2, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    setup_pseudo_fs();
    mount_fstab();
    
    log_file_fd = open("/var/log/ninit.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    init_log("=== ninit start (PID 1) v1.0.0 ===");

    set_hostname();

    /* Without a valid readable config, boot has no blueprint; never
       proceed with zero services and claim "ready". */
    const char *conf = (argc > 1) ? argv[1] : "/etc/init.conf";
    if (parse_config(conf) < 0)
        enter_rescue_mode("Config failed to read/parse!");

    /* Invoked immediately after parse_config(): dependencies must point to valid
       services. If any are missing, system hands control to rescue shell. */
    if (validate_dependencies() < 0)
        enter_rescue_mode("Invalid dependencies!");

    /* Invoke topological sort; if -1 (cycle detected), abort and enter rescue */
    if (num_services > 0 && sort_services() < 0)
        enter_rescue_mode("Cycle detected!");

    initctl_fd = setup_initctl();
    int log_fifo_fd = setup_log_fifo();
    g_log_fifo_fd = log_fifo_fd;

    spawn_eligible_services();

    init_log("main loop ready");

    /* Dynamically configure fds array */
    struct pollfd fds[2];
    int nfds = 0;
    
    if (initctl_fd >= 0) {
        fds[nfds].fd = initctl_fd; 
        fds[nfds].events = POLLIN; 
        nfds++;
    } else init_log("Warning: initctl_fd invalid");

    if (log_fifo_fd >= 0) {
        fds[nfds].fd = log_fifo_fd; 
        fds[nfds].events = POLLIN; 
        nfds++;
    } else init_log("Warning: log_fifo_fd invalid");

    for (;;) {
        /* Dynamically configure nfds, ppoll using orig mask.
           Housekeeping timeout: 100 ms if respawn pending, or
           1 second if once service running (so enforce_once_timeout()
           executes without waiting for signals). */
        struct timespec ts;
        struct timespec *pto = compute_poll_timeout(&ts);

        int ret = ppoll(fds, nfds, pto, &orig);
        int perr = errno;   /* capture immediately: errno easily modified by subsequent calls */
        if (ret < 0 && perr != EINTR) {
            init_log("ppoll error: %s", strerror(perr));
            usleep(100000); /* 100ms throttle to prevent log flooding on repeated errors */
            continue;
        }

        /* 1. Check Signals: shutdown is PRIORITIZED before reap_zombies()/respawn,
           ensuring SIGTERM arriving alongside SIGCHLD is handled immediately. */
        if (sigterm_flag) { sigterm_flag = 0; shutdown_all(RB_POWER_OFF, 0); }
        if (sigint_flag ) { sigint_flag  = 0; shutdown_all(RB_AUTOBOOT,   0); }
        if (sigusr1_flag) { sigusr1_flag = 0; shutdown_all(RB_POWER_OFF, 1); }
        if (sigusr2_flag) { sigusr2_flag = 0; shutdown_all(RB_AUTOBOOT,   1); }
        if (sigchld_flag) {
            sigchld_flag = 0;
            reap_zombies();
            spawn_eligible_services();
        }

        /* 2. Check active file descriptors */
        for (int i = 0; i < nfds; i++) {
            if (!(fds[i].revents & POLLIN)) continue;

            if (fds[i].fd == initctl_fd) {
                char cmd[256];
                ssize_t n = read(initctl_fd, cmd, sizeof(cmd) - 1);
                if (n > 0) {
                    cmd[n] = 0;

                    /* Process LINE-BY-LINE: a single write may contain multiple commands
                       (e.g. printf 'poweroff\nreboot\n' > /run/initctl). Older versions
                       truncated the buffer at the first newline, silently discarding
                       subsequent commands without logging them.
                       Since terminal commands never return from shutdown_all(),
                       only the first valid line takes effect. */
                    for (char *line = strtok(cmd, "\n"); line; line = strtok(NULL, "\n")) {
                        char *cmdline = trim(line);
                        if (*cmdline == 0) continue;   /* ignore empty lines */
                        init_log("initctl cmd: '%s'", cmdline);
                        if (!strcmp(cmdline, "poweroff")) shutdown_all(RB_POWER_OFF, 0);
                        else if (!strcmp(cmdline, "reboot")) shutdown_all(RB_AUTOBOOT, 0);
                        else if (!strcmp(cmdline, "force-poweroff")) shutdown_all(RB_POWER_OFF, 1);
                        else if (!strcmp(cmdline, "force-reboot")) shutdown_all(RB_AUTOBOOT, 1);
                    }
                }
            }
            else if (fds[i].fd == log_fifo_fd) {
                drain_log_fifo();
            }
        }

        /* End of loop: once service timeout housekeeping, followed by processing
           services with pending respawns. Also triggered on ppoll timeout
           (ret == 0) -> timer-driven respawn without blocking sleep(). */
        enforce_once_timeout();
        respawn_services();
        spawn_eligible_services();
    }
    return 0;
}
