/*
 * ninit - minimal init system (PID 1)
 * Compile : gcc -static -O2 -Wall -o ninit ninit.c
 * v5 Fixes: ppoll nfds, O_RDWR FIFO, strict cycle detection, robust parser.
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

static int log_file_fd = -1;

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
        init_log("mount %s -> %s gagal: %s", src, tgt, strerror(errno));
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

/* ---------- config parser (FIXED: Robust) ---------- */
static int parse_config(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { init_log("buka %s gagal: %s", path, strerror(errno)); return -1; }

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f) && num_services < MAX_SERVICES) {
        line[strcspn(line, "\n")] = 0;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == 0) continue;

        char *name = p;
        char *c1 = strchr(p, ':'); if (!c1) { init_log("Parse err: no mode in %s", name); continue; }
        *c1 = 0;
        char *mode = c1 + 1;
        char *c2 = strchr(mode, ':'); if (!c2) { init_log("Parse err: no cmd in %s", name); continue; }
        *c2 = 0;
        char *cmd = c2 + 1;
        
        /* Cari :requires= dari kanan (menggunakan strstr) agar cmd dengan ':' aman */
        char *deps = "";
        char *req_tag = strstr(cmd, ":requires=");
        if (req_tag) {
            *req_tag = 0; /* Potong string di sini */
            deps = req_tag + 10; /* Panjang ":requires=" adalah 10 */
        }

        /* Validasi Mode */
        int is_respawn = 0;
        if (strcmp(mode, "respawn") == 0) is_respawn = 1;
        else if (strcmp(mode, "once") != 0) {
            init_log("Warning: mode '%s' tidak dikenal untuk '%s'. Default: once", mode, name);
        }

        snprintf(services[num_services].name, sizeof(services[num_services].name), "%s", name);
        snprintf(services[num_services].cmd,  sizeof(services[num_services].cmd),  "%s", cmd);
        snprintf(services[num_services].deps_str, sizeof(services[num_services].deps_str), "%s", deps);
        services[num_services].respawn    = is_respawn;
        services[num_services].pid        = 0;
        services[num_services].last_start = 0;
        num_services++;
    }
    fclose(f);
    return 0;
}

/* ---------- Topological Sort (FIXED: Return -1 on cycle) ---------- */
static int sort_services(void) {
    int visited[MAX_SERVICES] = {0}, temp_visited[MAX_SERVICES] = {0};
    service_t sorted[MAX_SERVICES]; int sorted_count = 0;
    
    for (int i = 0; i < num_services; i++) {
        if (visited[i]) continue;
        int stack[MAX_SERVICES], stack_top = 0; 
        stack[stack_top++] = i;
        
        while (stack_top > 0) {
            int curr = stack[stack_top - 1];
            if (!visited[curr]) {
                if (!temp_visited[curr]) {
                    temp_visited[curr] = 1;
                    char deps_copy[256]; 
                    snprintf(deps_copy, sizeof(deps_copy), "%s", services[curr].deps_str);
                    
                    char *token = strtok(deps_copy, ",");
                    while (token) {
                        int dep_idx = -1;
                        for (int j = 0; j < num_services; j++)
                            if (strcmp(services[j].name, token) == 0) { dep_idx = j; break; }
                        
                        if (dep_idx != -1 && !visited[dep_idx]) {
                            if (temp_visited[dep_idx]) {
                                init_log("FATAL: CYCLE DETECTED di %s -> %s", services[curr].name, token);
                                return -1; /* Abort! */
                            }
                            stack[stack_top++] = dep_idx;
                        }
                        token = strtok(NULL, ",");
                    }
                }
                int all_deps_done = 1; char deps_copy2[256]; 
                snprintf(deps_copy2, sizeof(deps_copy2), "%s", services[curr].deps_str);
                
                char *tok2 = strtok(deps_copy2, ",");
                while (tok2) {
                    for (int j = 0; j < num_services; j++)
                        if (strcmp(services[j].name, tok2) == 0 && !visited[j]) all_deps_done = 0;
                    tok2 = strtok(NULL, ",");
                }
                if (all_deps_done) {
                    visited[curr] = 1; temp_visited[curr] = 0;
                    sorted[sorted_count++] = services[curr]; 
                    stack_top--;
                }
            } else {
                stack_top--;
            }
        }
    }
    for (int i = 0; i < sorted_count; i++) services[i] = sorted[i];
    return 0; /* Sukses */
}

/* ---------- process management ---------- */
static void spawn_service(service_t *svc)
{
    time_t now = time(NULL);
    if (svc->last_start && (now - svc->last_start) < RESPAWN_DELAY)
        sleep(RESPAWN_DELAY - (now - svc->last_start));

    svc->last_start = time(NULL);
    pid_t pid = fork();
    
    if (pid < 0) { init_log("fork %s: %s", svc->name, strerror(errno)); return; }

    if (pid == 0) {
        setsid();
        signal(SIGCHLD, SIG_DFL); signal(SIGTERM, SIG_DFL);
        signal(SIGINT,  SIG_DFL); signal(SIGUSR1, SIG_DFL); signal(SIGUSR2, SIG_DFL);

        int fd = open("/dev/null", O_RDONLY);
        if (fd >= 0) { dup2(fd, 0); close(fd); }

        fd = open("/run/log.fifo", O_WRONLY | O_NONBLOCK); /* Non-block writer */
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        else {
            fd = open("/dev/console", O_WRONLY);
            if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        }

        execl("/bin/sh", "sh", "-c", svc->cmd, (char *)NULL);
        _exit(127);
    }

    svc->pid = pid;
    init_log("started %s (pid %d)", svc->name, pid);
}

static void reap_zombies(void)
{
    int status; pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        for (int i = 0; i < num_services; i++) {
            if (services[i].pid == pid) {
                init_log("%s (pid %d) exit status=0x%x", services[i].name, pid, status);
                services[i].pid = 0;
                if (services[i].respawn) spawn_service(&services[i]);
                break;
            }
        }
    }
}

/* ---------- shutdown ---------- */
static void shutdown_all(int reboot_cmd, int force)
{
    if (force) {
        init_log("FORCE shutdown (cmd=%d)", reboot_cmd);
        for (int i = 0; i < num_services; i++) if (services[i].pid > 0) kill(services[i].pid, SIGKILL);
        reap_zombies(); sync();
        if (reboot(reboot_cmd) < 0) init_log("reboot(%d) gagal: %s", reboot_cmd, strerror(errno));
        while (1) pause();
    }

    init_log("graceful shutdown (cmd=%d)", reboot_cmd);
    for (int i = 0; i < num_services; i++) if (services[i].pid > 0) kill(services[i].pid, SIGTERM);

    for (int i = 0; i < 50; i++) {
        int alive = 0;
        for (int j = 0; j < num_services; j++) if (services[j].pid > 0) { alive = 1; break; }
        if (!alive) break;
        reap_zombies(); usleep(100000);
    }

    for (int i = 0; i < num_services; i++) if (services[i].pid > 0) kill(services[i].pid, SIGKILL);
    sync();
    if (reboot(reboot_cmd) < 0) init_log("reboot(%d) gagal: %s", reboot_cmd, strerror(errno));
    while (1) pause();
}

/* ---------- setup IPC (FIXED: O_RDWR) ---------- */
static int setup_initctl(void) { mkfifo("/run/initctl", 0600); return open("/run/initctl", O_RDWR | O_NONBLOCK); }
static int setup_log_fifo(void) { mkfifo("/run/log.fifo", 0600); return open("/run/log.fifo", O_RDWR | O_NONBLOCK); }

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
    sigaddset(&block, SIGCHLD); sigaddset(&block, SIGTERM); sigaddset(&block, SIGINT);
    sigaddset(&block, SIGUSR1); sigaddset(&block, SIGUSR2);
    sigprocmask(SIG_BLOCK, &block, &orig);

    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigchld; sigaction(SIGCHLD, &sa, NULL);
    sa.sa_handler = on_sigterm; sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_sigint;  sigaction(SIGINT,  &sa, NULL);
    sa.sa_handler = on_sigusr1; sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = on_sigusr2; sigaction(SIGUSR2, &sa, NULL);

    setup_pseudo_fs(); 
    
    log_file_fd = open("/var/log/ninit.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    init_log("=== ninit start (PID 1) v5 ===");

    set_hostname();

    const char *conf = (argc > 1) ? argv[1] : "/etc/init.conf";
    if (parse_config(conf) < 0) init_log("config gagal, masuk rescue mode");
    
    /* Panggil sort, jika return -1 (cycle), jangan spawn apa-apa */
    if (num_services > 0) {
        if (sort_services() < 0) {
            init_log("Cycle terdeteksi! Masuk rescue mode (shell).");
            execl("/bin/sh", "sh", (char *)NULL);
            _exit(1);
        }
    }

    int initctl_fd = setup_initctl();
    int log_fifo_fd = setup_log_fifo();

    for (int i = 0; i < num_services; i++) spawn_service(&services[i]);

    init_log("main loop siap");

    /* FIXED: Susun array fds secara dinamis */
    struct pollfd fds[2];
    int nfds = 0;
    
    if (initctl_fd >= 0) {
        fds[nfds].fd = initctl_fd; 
        fds[nfds].events = POLLIN; 
        nfds++;
    } else init_log("Peringatan: initctl_fd tidak valid");

    if (log_fifo_fd >= 0) {
        fds[nfds].fd = log_fifo_fd; 
        fds[nfds].events = POLLIN; 
        nfds++;
    } else init_log("Peringatan: log_fifo_fd tidak valid");

    for (;;) {
        /* FIXED: Gunakan nfds yang dinamis, ppoll dengan mask orig */
        int ret = ppoll(fds, nfds, NULL, &orig);
        if (ret < 0 && errno != EINTR) { init_log("ppoll error: %s", strerror(errno)); continue; }

        /* 1. Cek Sinyal */
        if (sigchld_flag) { sigchld_flag = 0; reap_zombies();                 }
        if (sigterm_flag) { sigterm_flag = 0; shutdown_all(RB_POWER_OFF, 0); }
        if (sigint_flag ) { sigint_flag  = 0; shutdown_all(RB_AUTOBOOT,   0); }
        if (sigusr1_flag) { sigusr1_flag = 0; shutdown_all(RB_POWER_OFF, 1); }
        if (sigusr2_flag) { sigusr2_flag = 0; shutdown_all(RB_AUTOBOOT,   1); }

        /* 2. Cek fd yang aktif */
        for (int i = 0; i < nfds; i++) {
            if (!(fds[i].revents & POLLIN)) continue;

            if (fds[i].fd == initctl_fd) {
                char cmd[256]; ssize_t n = read(initctl_fd, cmd, sizeof(cmd) - 1);
                if (n > 0) {
                    cmd[n] = 0; cmd[strcspn(cmd, "\n")] = 0;
                    init_log("initctl cmd: '%s'", cmd);
                    if (!strcmp(cmd, "poweroff")) shutdown_all(RB_POWER_OFF, 0);
                    else if (!strcmp(cmd, "reboot")) shutdown_all(RB_AUTOBOOT, 0);
                    else if (!strcmp(cmd, "force-poweroff")) shutdown_all(RB_POWER_OFF, 1);
                    else if (!strcmp(cmd, "force-reboot")) shutdown_all(RB_AUTOBOOT, 1);
                }
            } 
            else if (fds[i].fd == log_fifo_fd) {
                char log_buf[1024]; ssize_t n = read(log_fifo_fd, log_buf, sizeof(log_buf) - 1);
                if (n > 0) {
                    log_buf[n] = 0;
                    char time_buf[32]; time_t now = time(NULL);
                    struct tm tm_info; localtime_r(&now, &tm_info);
                    strftime(time_buf, sizeof(time_buf), "[%Y-%m-%d %H:%M:%S]", &tm_info);
                    
                    fprintf(stderr, "%s [service] %s", time_buf, log_buf);
                    if (log_file_fd >= 0) dprintf(log_file_fd, "%s [service] %s", time_buf, log_buf);
                }
            }
        }
    }
    return 0;
}
