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
    char   name[128];
    char   cmd[512];
    pid_t  pid;
    int    respawn;
    int    need_respawn;   /* 1 = menunggu jendela RESPAWN_DELAY (tanpa blokir loop) */
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
static int shutting_down = 0;   /* 1 = shutdown sedang berjalan: jangan respawn layanan */

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

    /* cgroup v2 (unified): mount hanya jika belum ter-mount */
    {
        struct stat st;
        if (stat("/sys/fs/cgroup/cgroup.controllers", &st) == 0) {
            init_log("cgroup2: /sys/fs/cgroup sudah ter-mount");
        } else {
            mkdir("/sys/fs/cgroup", 0755);
            if (mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, NULL) < 0)
                init_log("cgroup2: mount /sys/fs/cgroup gagal: %s", strerror(errno));
            else
                init_log("cgroup2: /sys/fs/cgroup ter-mount");
        }
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
#define CGROUP_BASE "/sys/fs/cgroup/ninit"

/* Pindahkan pid layanan ke /sys/fs/cgroup/ninit/<nama>. Dipanggil dari parent
   setelah fork() berhasil; kegagalan hanya di-log dan init tetap jalan. */
static void setup_cgroup(const char *svc_name, pid_t pid)
{
    char dir[256], procs[320];   /* procs = dir (maks 255) + "/cgroup.procs" */
    int fd;

    /* cgroup v2 tidak membuat parent otomatis */
    if (mkdir(CGROUP_BASE, 0755) < 0 && errno != EEXIST) {
        init_log("cgroup: mkdir %s gagal: %s", CGROUP_BASE, strerror(errno));
        return;
    }

    snprintf(dir, sizeof(dir), "%s/%s", CGROUP_BASE, svc_name);
    if (mkdir(dir, 0755) < 0 && errno != EEXIST) {
        init_log("cgroup: mkdir %s gagal: %s", dir, strerror(errno));
        return;
    }

    snprintf(procs, sizeof(procs), "%s/cgroup.procs", dir);
    fd = open(procs, O_WRONLY);
    if (fd < 0) {
        init_log("cgroup: buka %s gagal: %s", procs, strerror(errno));
        return;
    }

    if (dprintf(fd, "%d\n", (int)pid) < 0)
        init_log("cgroup: tulis pid %d ke %s gagal: %s", (int)pid, procs, strerror(errno));
    else
        init_log("cgroup: '%s' (pid %d) -> %s", svc_name, (int)pid, dir);

    close(fd);
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

        /* Batasi presisi ke ukuran tujuan: menghilangkan -Wformat-truncation (nama max 127 char) */
        snprintf(services[num_services].name, sizeof(services[num_services].name), "%.*s",
                 (int)sizeof(services[num_services].name) - 1, name);
        snprintf(services[num_services].cmd,  sizeof(services[num_services].cmd),  "%s", cmd);
        snprintf(services[num_services].deps_str, sizeof(services[num_services].deps_str), "%s", deps);
        services[num_services].respawn      = is_respawn;
        services[num_services].need_respawn = 0;
        services[num_services].pid          = 0;
        services[num_services].last_start   = 0;
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
    if (shutting_down) return;   /* saat shutdown: jangan sleep, jangan fork */

    time_t now = time(NULL);

    /* Jangan blokir event loop dengan sleep(): kalau masih di dalam jendela
       RESPAWN_DELAY, tandai need_respawn dan biarkan timeout ppoll di loop utama
       yang berperan sebagai timer. */
    if (svc->last_start && (now - svc->last_start) < RESPAWN_DELAY) {
        if (!svc->need_respawn)
            init_log("%s: respawn ditunda (timer %d detik, loop tidak diblokir)",
                     svc->name, RESPAWN_DELAY);
        svc->need_respawn = 1;
        return;
    }

    svc->need_respawn = 0;
    svc->last_start   = time(NULL);
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
    setup_cgroup(svc->name, pid);
}

static void reap_zombies(void)
{
    int status; pid_t pid;

    /* Hanya mengubur anak yang mati. JANGAN spawn di dalam while(waitpid) ini:
       kalau layanan yang di-respawn langsung mati lagi, waitpid() terus
       mengembalikan pid baru -> loop ini tidak pernah selesai dan loop utama
       (ppoll) tidak pernah dieksekusi lagi, sehingga sinyal shutdown tertahan. */
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        for (int i = 0; i < num_services; i++) {
            if (services[i].pid == pid) {
                init_log("%s (pid %d) exit status=0x%x", services[i].name, pid, status);
                services[i].pid = 0;
                break;
            }
        }
    }
}

/* Respawn hanya dijalankan dari loop utama, di luar reap_zombies(). */
static void respawn_services(void)
{
    if (shutting_down) return;

    for (int i = 0; i < num_services; i++) {
        if (services[i].respawn && services[i].pid == 0)
            spawn_service(&services[i]);
    }
}

/* Ada layanan yang menunggu timer RESPAWN_DELAY? Kalau ada, ppoll dipanggil
   dengan timeout 100 ms; kalau tidak, NULL (blokir sampai sinyal/fd). */
static int respawn_pending(void)
{
    for (int i = 0; i < num_services; i++)
        if (services[i].need_respawn)
            return 1;
    return 0;
}

/* ---------- shutdown ---------- */
static void shutdown_all(int reboot_cmd, int force)
{
    shutting_down = 1;   /* tandai shutdown: respawn dinonaktifkan (fix bug shutdown) */

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

/* ---------- /etc/fstab (FITUR BARU) ---------- */
#ifndef FSTAB_PATH
#define FSTAB_PATH "/etc/fstab"
#endif

static unsigned long parse_mount_flags(char *opts)
{
    unsigned long flags = 0;
    char *tok;

    if (!opts) return 0;

    for (tok = strtok(opts, ","); tok; tok = strtok(NULL, ",")) {
        if (!strcmp(tok, "defaults") || !strcmp(tok, "rw") || !strcmp(tok, "relatime")) continue;
        else if (!strcmp(tok, "ro"))      flags |= MS_RDONLY;
        else if (!strcmp(tok, "noexec"))  flags |= MS_NOEXEC;
        else if (!strcmp(tok, "nosuid"))  flags |= MS_NOSUID;
        else if (!strcmp(tok, "nodev"))   flags |= MS_NODEV;
        else if (!strcmp(tok, "sync"))    flags |= MS_SYNCHRONOUS;
        else if (!strcmp(tok, "dirsync")) flags |= MS_DIRSYNC;
        else if (!strcmp(tok, "remount")) flags |= MS_REMOUNT;
        else if (!strcmp(tok, "bind"))    flags |= MS_BIND;
        else init_log("fstab: opsi '%s' bukan flag, diteruskan sebagai data", tok);
    }
    return flags;
}

/* Format: <device> <mountpoint> <fstype> <options> [dump] [pass]; baris '#' diabaikan */
static void mount_fstab(void)
{
    FILE *f = fopen(FSTAB_PATH, "r");
    if (!f) {
        init_log("fstab: %s tidak ada, dilewati", FSTAB_PATH);
        return;
    }

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\n")] = 0;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == 0) continue;

        char *dev  = strtok(p, " \t");
        char *mnt  = strtok(NULL, " \t");
        char *type = strtok(NULL, " \t");
        char *opts = strtok(NULL, " \t");

        if (!dev || !mnt || !type) {
            init_log("fstab: baris tidak lengkap: '%s'", p);
            continue;
        }

        /* Opsi dipakai dua kali: sebagai flag untuk arg ke-4 (dihitung dari salinan,
           karena parse_mount_flags() memakai strtok yang merusak string) dan sebagai
           data untuk arg ke-5. Kata kunci "defaults" dibuang dari data: ia hanya
           dikenal mount(8) dan ditolak kernel dengan EINVAL. */
        char flagbuf[MAX_LINE];
        char databuf[MAX_LINE] = "";
        if (opts) {
            char tmp[MAX_LINE];
            char *t;
            snprintf(tmp, sizeof(tmp), "%s", opts);
            for (t = strtok(tmp, ","); t; t = strtok(NULL, ",")) {
                if (!strcmp(t, "defaults")) {
                    init_log("fstab: kata kunci 'defaults' dibuang dari data");
                    continue;
                }
                if (databuf[0]) strncat(databuf, ",", sizeof(databuf) - strlen(databuf) - 1);
                strncat(databuf, t, sizeof(databuf) - strlen(databuf) - 1);
            }
        }
        snprintf(flagbuf, sizeof(flagbuf), "%s", opts ? opts : "");
        unsigned long flags = parse_mount_flags(flagbuf);

        mkdir(mnt, 0755);
        if (mount(dev, mnt, type, flags, databuf[0] ? databuf : NULL) < 0)
            init_log("fstab: mount %s -> %s (%s) [data: %s] gagal: %s", dev, mnt, type,
                     databuf[0] ? databuf : "-", strerror(errno));
        else
            init_log("fstab: mount %s -> %s (%s) [data: %s] ok", dev, mnt, type,
                     databuf[0] ? databuf : "-");
    }
    fclose(f);
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
    sigaddset(&block, SIGCHLD); sigaddset(&block, SIGTERM); sigaddset(&block, SIGINT);
    sigaddset(&block, SIGUSR1); sigaddset(&block, SIGUSR2);
    sigprocmask(SIG_BLOCK, &block, &orig);
    sigemptyset(&orig);   /* paksa ppoll meng-unblock SEMUA sinyal (termasuk mask warisan induk) */

    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigchld; sigaction(SIGCHLD, &sa, NULL);
    sa.sa_handler = on_sigterm; sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_sigint;  sigaction(SIGINT,  &sa, NULL);
    sa.sa_handler = on_sigusr1; sigaction(SIGUSR1, &sa, NULL);
    sa.sa_handler = on_sigusr2; sigaction(SIGUSR2, &sa, NULL);

    setup_pseudo_fs();
    mount_fstab();
    
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
        struct timespec respawn_ts = { 0, 100 * 1000 * 1000 };   /* timer 100 ms */
        struct timespec *pto = respawn_pending() ? &respawn_ts : NULL;

        int ret = ppoll(fds, nfds, pto, &orig);
        int perr = errno;   /* simpan segera: errno mudah berubah oleh panggilan lain */
        if (ret < 0 && perr != EINTR) { init_log("ppoll error: %s", strerror(perr)); continue; }

        /* 1. Cek Sinyal: shutdown DIPRIORITASKAN sebelum reap_zombies()/respawn,
           supaya SIGTERM yang datang bersamaan SIGCHLD tidak tertunda. */
        if (sigterm_flag) { sigterm_flag = 0; shutdown_all(RB_POWER_OFF, 0); }
        if (sigint_flag ) { sigint_flag  = 0; shutdown_all(RB_AUTOBOOT,   0); }
        if (sigusr1_flag) { sigusr1_flag = 0; shutdown_all(RB_POWER_OFF, 1); }
        if (sigusr2_flag) { sigusr2_flag = 0; shutdown_all(RB_AUTOBOOT,   1); }
        if (sigchld_flag) { sigchld_flag = 0; reap_zombies();                 }

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

        /* Akhir loop: proses layanan yang respawn-nya tertunda. Juga terpanggil
           saat ppoll timeout (ret == 0) -> timer merespawn tanpa sleep(). */
        respawn_services();
    }
    return 0;
}
