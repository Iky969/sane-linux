/*
 * ninit - minimal init system (PID 1) v4 - initctl + deps + logging daemon
 * Compile : gcc -static -O2 -Wall -o ninit ninit.c
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

#define MAX_SERVICES    64
#define MAX_LINE        1024
#define RESPAWN_DELAY   2

typedef struct {
    char   name[64];
    char   cmd[512];
    pid_t  pid;
    int    respawn;
    time_t last_start;
    char   deps_str[256];
} service_t;

static service_t services[MAX_SERVICES];
static int num_services = 0;

static volatile sig_atomic_t sigchld_flag  = 0;
static volatile sig_atomic_t sigterm_flag  = 0;
static volatile sig_atomic_t sigint_flag   = 0;
static volatile sig_atomic_t sigusr1_flag  = 0;
static volatile sig_atomic_t sigusr2_flag  = 0;

/* ---------- logging v4 ---------- */
static int log_file_fd = -1;

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

    int kfd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (kfd >= 0) {
        dprintf(kfd, "ninit: %s\n", buf);
        close(kfd);
    }
    fprintf(stderr, "%s ninit: %s\n", time_buf, buf);

    if (log_file_fd >= 0) {
        dprintf(log_file_fd, "%s ninit: %s\n", time_buf, buf);
    }
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
    if (mount(src, tgt, fstype, flags, NULL) < 0) {
        init_log("mount %s -> %s gagal: %s", src, tgt, strerror(errno));
    }
}

static void setup_pseudo_fs(void)
{
    try_mount("proc",     "/proc", "proc",     0);
    try_mount("sysfs",    "/sys",  "sysfs",    0);
    try_mount("devtmpfs", "/dev",  "devtmpfs", 0);
    try_mount("tmpfs",    "/run",  "tmpfs",    0);
    try_mount("tmpfs",    "/tmp",  "tmpfs",    0);
    mkdir("/tmp", 01777);
    chmod("/tmp", 01777);
    mkdir("/var", 0755);
    mkdir("/var/log", 0755);
}

static void set_hostname(void)
{
    FILE *f = fopen("/etc/hostname", "r");
    if (!f) return;
    char buf[256];
    if (fgets(buf, sizeof(buf), f)) {
        buf[strcspn(buf, "\n")] = '\0';
        if (sethostname(buf, strlen(buf)) < 0) {
            init_log("sethostname: %s", strerror(errno));
        } else {
            init_log("hostname = %s", buf);
        }
    }
    fclose(f);
}

/* ---------- config parser ---------- */
static int parse_config(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        init_log("buka %s gagal: %s", path, strerror(errno));
        return -1;
    }

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f) && num_services < MAX_SERVICES) {
        line[strcspn(line, "\n")] = '\0';
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\0') continue;

        char *name = p;
        char *c1 = strchr(p, ':');
        if (!c1) continue;
        *c1 = '\0';
        char *mode = c1 + 1;
        char *c2 = strchr(mode, ':');
        if (!c2) continue;
        *c2 = '\0';
        char *cmd = c2 + 1;

        char *c3 = strchr(cmd, ':');
        char *deps = "";
        if (c3) {
            *c3 = '\0';
            if (strncmp(c3 + 1, "requires=", 9) == 0) {
                deps = c3 + 10;
            }
        }

        snprintf(services[num_services].name, sizeof(services[num_services].name), "%s", name);
        snprintf(services[num_services].cmd,  sizeof(services[num_services].cmd),  "%s", cmd);
        snprintf(services[num_services].deps_str, sizeof(services[num_services].deps_str), "%s", deps);
        services[num_services].respawn = (strcmp(mode, "respawn") == 0);
        services[num_services].pid = 0;
        services[num_services].last_start = 0;
        num_services++;

        init_log("parsed: %s (deps: '%s')", name, deps);
    }
    fclose(f);
    return 0;
}

/* ---------- Topological Sort (DFS) ---------- */
static int find_svc_idx(const char *name)
{
    for (int i = 0; i < num_services; i++) {
        if (strcmp(services[i].name, name) == 0) return i;
    }
    return -1;
}

static int dfs_visit(int u, int *state, service_t *sorted, int *sorted_count)
{
    if (state[u] == 1) {
        init_log("CYCLE DETECTED di %s!", services[u].name);
        return 0;
    }
    if (state[u] == 2) return 0;
    state[u] = 1;

    char copy[256];
    strncpy(copy, services[u].deps_str, sizeof(copy)-1);
    copy[sizeof(copy)-1] = '\0';

    char *saveptr;
    char *token = strtok_r(copy, ",", &saveptr);
    while (token) {
        while (*token == ' ' || *token == '\t') token++;
        char *end = token + strlen(token) - 1;
        while (end > token && (*end == ' ' || *end == '\t')) {
            *end = '\0';
            end--;
        }
        if (*token) {
            int v = find_svc_idx(token);
            if (v == -1) {
                init_log("Warning: dependensi '%s' untuk %s tidak ditemukan", token, services[u].name);
            } else {
                dfs_visit(v, state, sorted, sorted_count);
            }
        }
        token = strtok_r(NULL, ",", &saveptr);
    }
    state[u] = 2;
    sorted[(*sorted_count)++] = services[u];
    return 0;
}

static void sort_services(void)
{
    int state[MAX_SERVICES] = {0};
    service_t sorted[MAX_SERVICES];
    int sorted_count = 0;

    for (int i = 0; i < num_services; i++) {
        if (state[i] == 0) dfs_visit(i, state, sorted, &sorted_count);
    }
    for (int i = 0; i < sorted_count; i++) {
        services[i] = sorted[i];
    }
    init_log("Urutan service setelah Topological Sort:");
    for (int i = 0; i < num_services; i++) {
        init_log("  %d. %s (requires=%s)", i+1, services[i].name, services[i].deps_str);
    }
}

/* ---------- process management ---------- */
static void spawn_service(service_t *svc)
{
    time_t now = time(NULL);
    if (svc->last_start && (now - svc->last_start) < RESPAWN_DELAY) {
        sleep(RESPAWN_DELAY - (now - svc->last_start));
    }

    svc->last_start = time(NULL);
    pid_t pid = fork();

    if (pid < 0) {
        init_log("fork %s: %s", svc->name, strerror(errno));
        return;
    }

    if (pid == 0) {
        setsid();
        signal(SIGCHLD, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT,  SIG_DFL);
        signal(SIGUSR1, SIG_DFL);
        signal(SIGUSR2, SIG_DFL);

        int fd = open("/dev/null", O_RDONLY);
        if (fd >= 0) {
            dup2(fd, 0);
            close(fd);
        }

        /* output ke log FIFO */
        fd = open("/run/log.fifo", O_WRONLY);
        if (fd >= 0) {
            dup2(fd, 1);
            dup2(fd, 2);
            close(fd);
        } else {
            fd = open("/dev/console", O_WRONLY);
            if (fd < 0) fd = open("/dev/tty1", O_WRONLY);
            if (fd >= 0) {
                dup2(fd, 1);
                dup2(fd, 2);
                close(fd);
            }
        }

        execl("/bin/sh", "sh", "-c", svc->cmd, (char *)NULL);
        _exit(127);
    }

    svc->pid = pid;
    init_log("started %s (pid %d)", svc->name, pid);
}

static void reap_zombies(void)
{
    int status;
    pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        for (int i = 0; i < num_services; i++) {
            if (services[i].pid == pid) {
                init_log("%s (pid %d) exit status=0x%x", services[i].name, pid, status);
                services[i].pid = 0;
                if (services[i].respawn) {
                    spawn_service(&services[i]);
                }
                break;
            }
        }
    }
}

static void shutdown_all(int reboot_cmd, int force)
{
    if (force) {
        init_log("FORCE shutdown (cmd=%d): SIGKILL semua service", reboot_cmd);
        for (int i = 0; i < num_services; i++) {
            if (services[i].pid > 0) kill(services[i].pid, SIGKILL);
        }
        reap_zombies();
        sync();
        if (reboot(reboot_cmd) < 0) {
            init_log("reboot(%d) gagal: %s", reboot_cmd, strerror(errno));
        }
        while (1) pause();
    }

    init_log("graceful shutdown (cmd=%d), SIGTERM ke semua service", reboot_cmd);
    for (int i = 0; i < num_services; i++) {
        if (services[i].pid > 0) kill(services[i].pid, SIGTERM);
    }

    for (int i = 0; i < 50; i++) {
        int alive = 0;
        for (int j = 0; j < num_services; j++) {
            if (services[j].pid > 0) {
                alive = 1;
                break;
            }
        }
        if (!alive) break;
        reap_zombies();
        usleep(100000);
    }

    for (int i = 0; i < num_services; i++) {
        if (services[i].pid > 0) kill(services[i].pid, SIGKILL);
    }

    sync();
    if (reboot(reboot_cmd) < 0) {
        init_log("reboot(%d) gagal: %s", reboot_cmd, strerror(errno));
    }
    while (1) pause();
}

/* ---------- setup IPC ---------- */
static int setup_initctl(void)
{
    mkdir("/run", 0755);
    unlink("/run/initctl");
    if (mkfifo("/run/initctl", 0600) < 0 && errno != EEXIST) {
        init_log("mkfifo /run/initctl gagal: %s", strerror(errno));
        return -1;
    }
    int fd = open("/run/initctl", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) init_log("/run/initctl siap (fd=%d)", fd);
    return fd;
}

static int setup_log_fifo(void)
{
    mkdir("/run", 0755);
    unlink("/run/log.fifo");
    if (mkfifo("/run/log.fifo", 0600) < 0 && errno != EEXIST) {
        init_log("mkfifo /run/log.fifo gagal: %s", strerror(errno));
        return -1;
    }
    int fd = open("/run/log.fifo", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0) init_log("/run/log.fifo siap (fd=%d)", fd);
    return fd;
}

/* ---------- main ---------- */
int main(int argc, char **argv)
{
    if (getpid() != 1) {
        fprintf(stderr, "ninit harus dijalankan sebagai PID 1\n");
        return 1;
    }
    umask(022);

    sigset_t block, orig;
    sigemptyset(&block);
    sigaddset(&block, SIGCHLD);
    sigaddset(&block, SIGTERM);
    sigaddset(&block, SIGINT);
    sigaddset(&block, SIGUSR1);
    sigaddset(&block, SIGUSR2);
    sigprocmask(SIG_BLOCK, &block, &orig);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigchld; sigaction(SIGCHLD, &sa, NULL);
    sa.sa_handler = on_sigterm; sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_sigint;  sigaction(SIGINT,  &sa, NULL);
    sa.sa_handler = on_sigusr1; sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = on_sigusr2; sigaction(SIGUSR2, &sa, NULL);

    setup_pseudo_fs();

    log_file_fd = open("/var/log/ninit.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    init_log("=== ninit start (PID 1) v4 logging ===");

    set_hostname();

    const char *conf = (argc > 1) ? argv[1] : "/etc/init.conf";
    if (parse_config(conf) < 0) {
        init_log("config gagal, masuk rescue mode");
    }

    if (num_services > 0) sort_services();

    int initctl_fd = setup_initctl();
    int log_fifo_fd = setup_log_fifo();

    for (int i = 0; i < num_services; i++) {
        spawn_service(&services[i]);
    }

    init_log("main loop siap (initctl + log.fifo)");

    struct pollfd fds[2];
    fds[0].fd = initctl_fd;
    fds[0].events = POLLIN;
    fds[1].fd = log_fifo_fd;
    fds[1].events = POLLIN;

    for (;;) {
        int nfds = 0;
        if (initctl_fd >= 0) nfds++;
        if (log_fifo_fd >= 0) nfds++;
        // ppoll pakai orig mask biar sinyal bisa bangun
        int ret = ppoll(fds, 2, NULL, &orig);
        if (ret < 0 && errno != EINTR) {
            init_log("poll error: %s", strerror(errno));
            continue;
        }

        if (sigchld_flag) { sigchld_flag = 0; reap_zombies(); }
        if (sigterm_flag) { sigterm_flag = 0; shutdown_all(RB_POWER_OFF, 0); }
        if (sigint_flag)  { sigint_flag = 0;  shutdown_all(RB_AUTOBOOT, 0); }
        if (sigusr1_flag) { sigusr1_flag = 0; shutdown_all(RB_POWER_OFF, 1); }
        if (sigusr2_flag) { sigusr2_flag = 0; shutdown_all(RB_AUTOBOOT, 1); }

        /* initctl */
        if (initctl_fd >= 0 && (fds[0].revents & POLLIN)) {
            char cmd[256];
            ssize_t n = read(initctl_fd, cmd, sizeof(cmd)-1);
            if (n > 0) {
                cmd[n] = '\0';
                char *saveptr;
                char *line = strtok_r(cmd, "\n", &saveptr);
                while (line) {
                    while (*line == ' ' || *line == '\t') line++;
                    if (*line) {
                        init_log("initctl cmd: '%s'", line);
                        if (!strcmp(line, "poweroff")) shutdown_all(RB_POWER_OFF, 0);
                        else if (!strcmp(line, "reboot")) shutdown_all(RB_AUTOBOOT, 0);
                        else if (!strcmp(line, "force-poweroff")) shutdown_all(RB_POWER_OFF, 1);
                        else if (!strcmp(line, "force-reboot")) shutdown_all(RB_AUTOBOOT, 1);
                        else init_log("perintah tidak dikenal: %s", line);
                    }
                    line = strtok_r(NULL, "\n", &saveptr);
                }
            } else if (n == 0) {
                close(initctl_fd);
                initctl_fd = open("/run/initctl", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
                fds[0].fd = initctl_fd;
            }
        }
        if (initctl_fd >= 0 && (fds[0].revents & (POLLHUP | POLLERR))) {
            close(initctl_fd);
            initctl_fd = open("/run/initctl", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
            fds[0].fd = initctl_fd;
        }

        /* log fifo */
        if (log_fifo_fd >= 0 && (fds[1].revents & POLLIN)) {
            char log_buf[1024];
            ssize_t n = read(log_fifo_fd, log_buf, sizeof(log_buf)-1);
            if (n > 0) {
                log_buf[n] = '\0';
                char time_buf[32];
                time_t now = time(NULL);
                struct tm tm_info;
                localtime_r(&now, &tm_info);
                strftime(time_buf, sizeof(time_buf), "[%Y-%m-%d %H:%M:%S]", &tm_info);

                // ke console
                fprintf(stderr, "%s [service] %s", time_buf, log_buf);
                if (log_buf[n-1] != '\n') fprintf(stderr, "\n");

                // ke file
                if (log_file_fd >= 0) {
                    dprintf(log_file_fd, "%s [service] %s", time_buf, log_buf);
                    if (log_buf[n-1] != '\n') dprintf(log_file_fd, "\n");
                }
            } else if (n == 0) {
                close(log_fifo_fd);
                log_fifo_fd = open("/run/log.fifo", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
                fds[1].fd = log_fifo_fd;
            }
        }
        if (log_fifo_fd >= 0 && (fds[1].revents & (POLLHUP | POLLERR))) {
            close(log_fifo_fd);
            log_fifo_fd = open("/run/log.fifo", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
            fds[1].fd = log_fifo_fd;
        }
    }
    return 0;
}
