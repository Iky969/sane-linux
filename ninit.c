/*
 * ninit - minimal init system (PID 1)
 * Compile : gcc -static -O2 -Wall -o ninit ninit.c
 * v5 Fixes: ppoll nfds, O_RDWR FIFO, strict cycle detection, robust parser.
 * v10+    : opsi data fstab, cgroup v2, timer respawn non-blocking, mask sinyal
 *           anak, validasi dependensi, initctl per baris, topo-sort tanpa
 *           stack overflow.
 * v1.0.0  : rescue mode sungguhan lewat enter_rescue_mode() (config rusak,
 *           dependensi hilang, siklus) + signal mask dikosongkan sebelum
 *           execl supaya Ctrl+C berfungsi di shell darurat.
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
static int g_log_fifo_fd = -1;  /* ujung baca /run/log.fifo; dipakai juga saat shutdown */
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

/* Buang spasi/tab/CR di ujung string (di tempat) dan kembalikan pointer ke awal
   teks yang sudah dipangkas. Dipakai pembaca perintah /run/initctl. */
static char *trim(char *s)
{
    while (*s == ' ' || *s == '\t' || *s == '\r') s++;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r')) s[--n] = 0;
    return s;
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

/* ---------- dependensi ---------- */
static int find_service(const char *name)
{
    for (int i = 0; i < num_services; i++)
        if (strcmp(services[i].name, name) == 0) return i;
    return -1;
}

/* Token berikutnya dari deps_str (dipisah koma) TANPA mengubah string aslinya:
   posisi baca disimpan di *off supaya pemanggil bisa melanjutkan dari titik
   terakhir. Token kosong (mis. "a,,b") dan spasi di ujung dibuang.
   Mengembalikan 1 bila ada token, 0 bila sudah habis. */
static int next_dep(const char *deps_str, int *off, char *out, size_t outsz)
{
    const char *s = deps_str + *off;

    for (;;) {
        size_t n = 0;
        while (*s == ',' || *s == ' ' || *s == '\t') s++;
        if (*s == 0) { *off = (int)(s - deps_str); return 0; }

        while (*s && *s != ',' && n < outsz - 1) out[n++] = *s++;
        while (n > 0 && (out[n - 1] == ' ' || out[n - 1] == '\t')) n--;
        if (n > 0) { out[n] = 0; *off = (int)(s - deps_str); return 1; }
        /* token kosong -> lanjut ke token berikutnya */
    }
}

/* Setiap nama di `:requires=` harus benar-benar ada di daftar layanan.
   Dependensi yang menunjuk layanan tak dikenal bikin urutan boot diam-diam salah
   (layanan jalan tanpa prasyaratnya), jadi lebih baik menyerahkan sistem ke
   rescue shell daripada boot setengah jalan. */
static int validate_dependencies(void)
{
    for (int i = 0; i < num_services; i++) {
        int off = 0;
        char token[256];
        while (next_dep(services[i].deps_str, &off, token, sizeof(token))) {
            if (find_service(token) < 0) {
                init_log("FATAL: Dependensi '%s' untuk '%s' tidak ditemukan",
                         token, services[i].name);
                return -1;
            }
        }
    }
    return 0;
}

/* ---------- Topological Sort (DFS iteratif; tandai SEBELUM push) ----------
   Versi lama menandai node saat di-expand, bukan saat di-push. Akibatnya layanan
   yang masih "pending" di stack bisa di-push ulang setiap kali layanan lain
   meng-expand dependensinya, dan stack_top bisa melewati MAX_SERVICES -> tulis di
   luar batas array stack[] (stack overflow). Dengan penandaan saat push, satu
   layanan hanya masuk stack sekali; dan karena dependensi diproses satu per satu,
   node "abu-abu" selalu berarti leluhur (bukan saudara), sehingga dependensi
   berbentuk berlian tidak salah dilaporkan sebagai cycle. */
static int sort_services(void)
{
    int visited[MAX_SERVICES]      = {0};   /* hitam: sudah masuk urutan akhir */
    int temp_visited[MAX_SERVICES] = {0};   /* abu-abu: ada di dalam stack */
    int dep_off[MAX_SERVICES]      = {0};   /* progres baca deps_str per layanan */
    service_t sorted[MAX_SERVICES];
    int sorted_count = 0;

    for (int i = 0; i < num_services; i++) {
        if (visited[i]) continue;

        int stack[MAX_SERVICES], stack_top = 0;

        if (stack_top >= MAX_SERVICES) {        /* guard sebelum setiap push */
            init_log("FATAL: Stack overflow pada topological sort!");
            return -1;
        }
        temp_visited[i] = 1;                    /* tandai SEBELUM push */
        stack[stack_top++] = i;

        while (stack_top > 0) {
            int curr = stack[stack_top - 1];
            char token[256];

            if (next_dep(services[curr].deps_str, &dep_off[curr], token, sizeof(token))) {
                int dep_idx = find_service(token);

                /* Nama tak dikenal sudah ditolak validate_dependencies();
                   kalau tetap sampai di sini, dependensi itu dilewati saja. */
                if (dep_idx < 0) continue;

                if (temp_visited[dep_idx]) {
                    init_log("FATAL: CYCLE DETECTED di %s -> %s", services[curr].name, token);
                    return -1; /* Abort! */
                }
                if (!visited[dep_idx]) {
                    if (stack_top >= MAX_SERVICES) {
                        init_log("FATAL: Stack overflow pada topological sort!");
                        return -1;
                    }
                    temp_visited[dep_idx] = 1;  /* tandai SEBELUM push */
                    dep_off[dep_idx]      = 0;
                    stack[stack_top++]    = dep_idx;
                }
                continue;   /* dependensi berikutnya setelah anak selesai */
            }

            /* Semua dependensi selesai -> masukkan ke urutan akhir */
            visited[curr]          = 1;
            temp_visited[curr]     = 0;
            sorted[sorted_count++] = services[curr];
            stack_top--;
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

        /* Anak mewarisi signal mask PID 1 (SIGCHLD/SIGTERM/SIGINT/SIGUSR1/
           SIGUSR2 diblokir di main() untuk ppoll). Selama mask itu masih
           terpasang, layanan TIDAK PERNAH menerima SIGTERM -> shutdown_all()
           akhirnya membunuhnya dengan SIGKILL. Kosongkan mask di child supaya
           handler/trap milik layanan benar-benar jalan. */
        sigset_t empty;
        sigemptyset(&empty);
        if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0) {
            _exit(126);
        }

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

/* Baca SEMUA output layanan yang tertunda di /run/log.fifo dan teruskan ke
   stderr + log init. Dipakai event loop DAN shutdown_all(): tanpa itu, pesan
   terakhir dari layanan yang menuruti SIGTERM (mis. "bye!") tidak akan pernah
   terbaca, karena loop utama sudah tidak men-drain FIFO selama shutdown. */
static void drain_log_fifo(void)
{
    if (g_log_fifo_fd < 0) return;

    for (;;) {
        char log_buf[1024];
        ssize_t n = read(g_log_fifo_fd, log_buf, sizeof(log_buf) - 1);
        if (n <= 0) return;   /* EAGAIN (kosong) atau EOF */
        log_buf[n] = 0;

        char time_buf[32]; time_t now = time(NULL);
        struct tm tm_info; localtime_r(&now, &tm_info);
        strftime(time_buf, sizeof(time_buf), "[%Y-%m-%d %H:%M:%S]", &tm_info);

        fprintf(stderr, "%s [service] %s", time_buf, log_buf);
        if (log_file_fd >= 0) dprintf(log_file_fd, "%s [service] %s", time_buf, log_buf);
    }
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
        reap_zombies();
        drain_log_fifo();   /* pesan terakhir layanan sebelum mati (mis. "bye!") */
        usleep(100000);
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

/* ---------- rescue mode ----------
   Satu-satunya jalan keluar bila init tidak bisa memulai boot dengan benar.
   Dua hal yang wajib terjadi di sini:

     1. Signal mask PID 1 dikosongkan. main() memblokir SIGINT/SIGTERM/SIGCHLD/
        SIGUSR1/SIGUSR2 untuk ppoll; tanpa reset, rescue shell mewarisi mask itu
        dan Ctrl+C di shell darurat tidak akan pernah sampai (SIGINT tertahan).
        spawn_service() melakukan hal yang sama untuk anak layanan.
     2. execl() menggantikan proses PID 1 ini dengan /bin/sh. Kalau gagal (mis.
        /bin/sh tidak ada di rootfs), proses keluar dengan status 1 -- JANGAN
        kembali ke alur boot dengan state yang sudah tidak valid.

   Fungsi ini tidak pernah kembali. */
static void enter_rescue_mode(const char *reason)
{
    sigset_t empty;

    if (reason) init_log("%s", reason);

    sigemptyset(&empty);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) < 0)
        init_log("Peringatan: gagal mengosongkan signal mask: %s", strerror(errno));

    init_log("Masuk rescue mode (shell).");
    execl("/bin/sh", "sh", (char *)NULL);
    init_log("FATAL: execl /bin/sh gagal: %s", strerror(errno));
    _exit(1);
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
    init_log("=== ninit start (PID 1) v1.0.0 ===");

    set_hostname();

    /* Tanpa config yang terbaca, boot tidak punya rencana sama sekali; jangan
       lanjut dengan nol layanan dan mengaku "siap". */
    const char *conf = (argc > 1) ? argv[1] : "/etc/init.conf";
    if (parse_config(conf) < 0)
        enter_rescue_mode("Config gagal dibaca/di-parse!");

    /* Dipanggil tepat setelah parse_config(): dependensi harus menunjuk layanan
       yang ada. Bila ada yang hilang, sistem diserahkan ke rescue shell. */
    if (validate_dependencies() < 0)
        enter_rescue_mode("Dependensi tidak valid!");

    /* Panggil sort, jika return -1 (cycle), jangan spawn apa-apa */
    if (num_services > 0 && sort_services() < 0)
        enter_rescue_mode("Cycle terdeteksi!");

    int initctl_fd = setup_initctl();
    int log_fifo_fd = setup_log_fifo();
    g_log_fifo_fd = log_fifo_fd;

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
                char cmd[256];
                ssize_t n = read(initctl_fd, cmd, sizeof(cmd) - 1);
                if (n > 0) {
                    cmd[n] = 0;

                    /* Baca PER BARIS: satu penulisan bisa memuat beberapa perintah
                       (printf 'poweroff\nreboot\n' > /run/initctl). Versi lama
                       memotong buffer di newline pertama, jadi perintah kedua dan
                       seterusnya hilang tanpa jejak -- bahkan tidak tercatat log.
                       Perintah penutup tidak pernah kembali dari shutdown_all(),
                       jadi praktis hanya baris pertama yang benar-benar jalan. */
                    for (char *line = strtok(cmd, "\n"); line; line = strtok(NULL, "\n")) {
                        char *cmdline = trim(line);
                        if (*cmdline == 0) continue;   /* abaikan baris kosong */
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

        /* Akhir loop: proses layanan yang respawn-nya tertunda. Juga terpanggil
           saat ppoll timeout (ret == 0) -> timer merespawn tanpa sleep(). */
        respawn_services();
    }
    return 0;
}
