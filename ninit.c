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
#define MAX_SPAWN_RETRY 3   /* percobaan fork() ulang untuk layanan once */

typedef enum {
    SVC_STATE_STOPPED = 0,
    SVC_STATE_RUNNING,
    SVC_STATE_DONE,
    SVC_STATE_FAILED
} svc_state_t;

typedef struct {
    char        name[128];
    char        cmd[512];
    pid_t       pid;
    pid_t       pgid;           /* grup proses layanan: anak memanggil setsid() sehingga
                                   pgid == pid saat spawn. SENGAJA tidak di-nol-kan saat
                                   leader mati — grup bisa hidup lebih lama dari
                                   leadernya (audit SANE-01). */
    int         respawn;
    int         need_respawn;   /* 1 = menunggu jendela RESPAWN_DELAY (tanpa blokir loop) */
    int         spawn_tries;    /* jumlah berturut-turut fork() gagal; dinolkan saat spawn sukses */
    time_t      last_start;
    char        deps_str[256]; 
    svc_state_t state;
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

/* Hapus direktori cgroup layanan saat layanan berhenti */
static void cleanup_cgroup(const char *svc_name)
{
    char dir[256];
    snprintf(dir, sizeof(dir), "%s/%s", CGROUP_BASE, svc_name);
    if (rmdir(dir) == 0) {
        init_log("cgroup: dibersihkan '%s'", svc_name);
    }
}

/* ---------- config parser (FIXED: Robust) ---------- */
/* fgets() membelah baris yang lebih panjang dari buffer menjadi beberapa
   potongan yang tampak seperti baris terpisah; tanpa deteksi, potongan ekor
   bisa terparsing sebagai entri hantu (audit SANE-03). Batasnya eksplisit:
   baris berisi sampai MAX_LINE-1 karakter DITERIMA (dengan atau tanpa '\n',
   termasuk baris terakhir yang berakhir tepat di EOF); baris yang masih
   punya karakter kelanjutan setelah buffer penuh DITOLAK — sisa barisnya
   dibuang sampai '\n'/EOF di sini supaya tidak terparsing sebagai baris
   baru. Satu karakter sondir (fgetc) membedakan kedua kasus itu tanpa
   bergantung pada kapan libc memasang indikator EOF. */
static int line_overlong(FILE *f, const char *line)
{
    size_t len = strlen(line);
    if (len == MAX_LINE - 1 && line[len - 1] != '\n') {
        int c = fgetc(f);
        if (c == EOF) return 0;   /* baris terakhir tepat di batas, utuh */
        while (c != EOF && c != '\n') c = fgetc(f);
        return 1;
    }
    return 0;
}

static int parse_config(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { init_log("buka %s gagal: %s", path, strerror(errno)); return -1; }

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        if (line_overlong(f, line)) {
            init_log("Parse err: baris melebihi MAX_LINE (%d), baris ditolak", MAX_LINE);
            continue;
        }
        line[strcspn(line, "\n")] = 0;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == 0) continue;

        if (num_services >= MAX_SERVICES) {
            init_log("Peringatan: batas %d layanan tercapai, '%s' diabaikan", MAX_SERVICES, p);
            continue;
        }

        char *name = p;
        char *c1 = strchr(p, ':'); if (!c1) { init_log("Parse err: no mode in %s", name); continue; }
        *c1 = 0;
        char *mode = c1 + 1;
        char *c2 = strchr(mode, ':'); if (!c2) { init_log("Parse err: no cmd in %s", name); continue; }
        *c2 = 0;
        char *cmd = c2 + 1;

        /* Validasi Nama Layanan: tidak boleh memuat '/' (dipakai untuk direktori cgroup) */
        if (strchr(name, '/')) {
            init_log("Parse err: nama layanan '%s' tidak boleh memuat '/'", name);
            continue;
        }
        
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

        /* Tolak entri yang bidangnya melebihi buffer (audit SANE-03): versi
           lama hanya memperingatkan lalu mendaftarkan layanan dalam keadaan
           TERPOTONG — nama bisa menabrak layanan lain, cmd berubah arti, dan
           dependensi terpotong bisa menunjuk nama yang salah. Lebih aman
           entri ditolak keras daripada sistem jalan dengan config yang
           berbeda dari yang ditulis pengguna. */
        int too_long = 0;
        if (strlen(name) >= sizeof(services[num_services].name)) {
            init_log("Parse err: nama layanan terlalu panjang (panjang %zu > maks %d), entri ditolak",
                     strlen(name), (int)sizeof(services[num_services].name) - 1);
            too_long = 1;
        }
        if (strlen(cmd) >= sizeof(services[num_services].cmd)) {
            init_log("Parse err: perintah layanan '%s' terlalu panjang (panjang %zu > maks %d), entri ditolak",
                     name, strlen(cmd), (int)sizeof(services[num_services].cmd) - 1);
            too_long = 1;
        }
        if (strlen(deps) >= sizeof(services[num_services].deps_str)) {
            init_log("Parse err: dependensi layanan '%s' terlalu panjang (panjang %zu > maks %d), entri ditolak",
                     name, strlen(deps), (int)sizeof(services[num_services].deps_str) - 1);
            too_long = 1;
        }
        if (too_long) continue;

        /* Batasi presisi ke ukuran tujuan: menghilangkan -Wformat-truncation (nama max 127 char) */
        snprintf(services[num_services].name, sizeof(services[num_services].name), "%.*s",
                 (int)sizeof(services[num_services].name) - 1, name);
        snprintf(services[num_services].cmd,  sizeof(services[num_services].cmd),  "%.*s",
                 (int)sizeof(services[num_services].cmd) - 1, cmd);
        snprintf(services[num_services].deps_str, sizeof(services[num_services].deps_str), "%.*s",
                 (int)sizeof(services[num_services].deps_str) - 1, deps);
        services[num_services].respawn      = is_respawn;
        services[num_services].need_respawn = 0;
        services[num_services].spawn_tries  = 0;
        services[num_services].pid          = 0;
        services[num_services].pgid         = 0;
        services[num_services].last_start   = 0;
        services[num_services].state        = SVC_STATE_STOPPED;
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
        /* Token lebih panjang dari buffer keluaran: buang sisa token ini
           supaya ekornya tidak terbaca sebagai token dependensi kedua pada
           panggilan berikutnya (audit SANE-03). deps_str sendiri sudah
           divalidasi panjangnya di parse_config(); ini lapis pertahanan
           kedua agar tokenizer tidak pernah membelah satu nama menjadi dua. */
        while (*s && *s != ',') s++;
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
/* Kembalikan:
     1 = ada kemajuan nyata (proses berjalan, ATAU kegagalan final yang
         menjadikan state terminal) -> pemanggil boleh menandai progress
     0 = tidak ada kemajuan (ditunda jendela RESPAWN_DELAY, atau fork() gagal
         tapi masih punya jatah percobaan)
   Dulu fungsi ini void dan spawn_eligible_services() menandai progress tanpa
   melihat hasilnya, sehingga kegagalan fork() tidak punya keadaan akhir:
   layanan once tertinggal di STOPPED selamanya dan dependensinya menunggu
   tanpa pesan apa pun. */
static int spawn_service(service_t *svc)
{
    if (shutting_down) return 0;   /* saat shutdown: jangan sleep, jangan fork */

    time_t now = time(NULL);

    /* Jangan blokir event loop dengan sleep(): kalau masih di dalam jendela
       RESPAWN_DELAY, tandai need_respawn dan biarkan timeout ppoll di loop utama
       yang berperan sebagai timer. */
    if (svc->last_start && (now - svc->last_start) < RESPAWN_DELAY) {
        if (!svc->need_respawn)
            init_log("%s: respawn ditunda (timer %d detik, loop tidak diblokir)",
                     svc->name, RESPAWN_DELAY);
        svc->need_respawn = 1;
        return 0;
    }

    svc->need_respawn = 0;
    svc->last_start   = time(NULL);
    pid_t pid = fork();
    
    if (pid < 0) {
        int err = errno;   /* dibaca sebelum init_log(): open/dprintf mengubah errno */
        svc->spawn_tries++;
        /* Layanan once tidak di respawn, jadi tanpa batas percobaan kegagalan
           fork() tidak akan pernah berakhir di keadaan terminal. Setelah
           MAX_SPAWN_RETRY: nyatakan gagal supaya deps_satisfied() melaporkan
           dependensi sebagai batal, bukan menggantung selamanya. */
        if (!svc->respawn && svc->spawn_tries >= MAX_SPAWN_RETRY) {
            init_log("fork %s: %s (%d percobaan, layanan dinyatakan gagal)",
                     svc->name, strerror(err), svc->spawn_tries);
            svc->state = SVC_STATE_FAILED;
            svc->spawn_tries = 0;
            return 1;
        }
        init_log("fork %s: %s", svc->name, strerror(err));
        svc->need_respawn = 1;   /* retry lewat timer ppoll, bukan busy-loop */
        return 0;
    }

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

        /* Buka FIFO tanpa O_NONBLOCK agar stdout/stderr layanan tidak mengembalikan EAGAIN */
        fd = open("/run/log.fifo", O_WRONLY);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        else {
            fd = open("/dev/console", O_WRONLY);
            if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        }

        execl("/bin/sh", "sh", "-c", svc->cmd, (char *)NULL);
        _exit(127);
    }

    svc->pid  = pid;
    svc->pgid = pid;   /* anak memanggil setsid(): dia pemimpin grup prosesnya */
    svc->state = SVC_STATE_RUNNING;
    svc->spawn_tries = 0;
    init_log("started %s (pid %d)", svc->name, pid);
    setup_cgroup(svc->name, pid);
    return 1;
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
                /* pgid SENGAJA tidak ikut di-nol-kan: anggota grup lain bisa
                   masih hidup setelah leader mati (audit SANE-01).
                   shutdown_all() memeriksa grup lewat pgid ini. */
                if (!services[i].respawn) {
                    if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
                        services[i].state = SVC_STATE_DONE;
                    else
                        services[i].state = SVC_STATE_FAILED;
                    cleanup_cgroup(services[i].name);
                } else {
                    services[i].state = SVC_STATE_STOPPED;
                }
                break;
            }
        }
    }
}

/* Cek apakah semua dependensi layanan sudah terpenuhi:
   - Layanan once harus sudah selesai dengan sukses (SVC_STATE_DONE).
   - Layanan respawn harus sedang berjalan (pid > 0).
   Mengembalikan:
     1 = semua dependensi terpenuhi
     0 = masih menunggu dependensi
    -1 = ada dependensi once yang gagal
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

/* Menjalankan semua layanan yang dependensinya sudah terpenuhi. */
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
                init_log("layanan '%s' dibatalkan: dependensi '%s' gagal", svc->name, failed_dep);
                svc->state = SVC_STATE_FAILED;
                progress = 1;
            } else if (ret == 1) {
                /* Hanya tandai kemajuan bila spawn_service benar-benar mengubah
                   keadaan layanan. Tanpa ini, kegagalan fork() (yang hanya
                   menandai need_respawn) akan membuat do-while berputar lagi
                   dan lagi tanpa ada yang berubah. */
                if (spawn_service(svc)) progress = 1;
            }
        }
    } while (progress);
}

/* Respawn hanya dijalankan dari loop utama, di luar reap_zombies().
   Dependensi WAJIB diperiksa di sini. Versi lama hanya melihat
   `respawn && pid == 0` lalu langsung spawn, sehingga layanan yang sudah
   "dibatalkan" karena dependensi once-nya gagal (state FAILED) tetap
   dihidupkan ulang selamanya — janji urutan `requires=` dilanggar lewat
   jalur respawn ini, dan pembatalannya menjadi pesan tanpa efek.
   Sekaligus menjadi jalur retry bagi layanan once yang fork()-nya gagal
   (need_respawn): layanan jenis ini tidak pernah di-respawn, jadi tanpa
   jalur itu ia berhenti sebagai STOPPED selamanya. */
static void respawn_services(void)
{
    if (shutting_down) return;

    for (int i = 0; i < num_services; i++) {
        service_t *svc = &services[i];
        if (svc->pid > 0 || svc->state == SVC_STATE_DONE || svc->state == SVC_STATE_FAILED)
            continue;
        if (!svc->respawn && !svc->need_respawn)
            continue;   /* belum pernah dicoba: itu tugas spawn_eligible_services() */

        const char *failed_dep = NULL;
        int ret = deps_satisfied(svc, &failed_dep);
        if (ret < 0) {
            init_log("layanan '%s' dibatalkan: dependensi '%s' gagal", svc->name, failed_dep);
            svc->state = SVC_STATE_FAILED;
            svc->need_respawn = 0;
            continue;
        }
        if (ret == 0) {
            /* Dependensi belum terpenuhi: tidak ada yang perlu dicoba lagi,
               jadi need_respawn di-clear. Kalau dibiarkan, respawn_pending()
               membuat ppoll bangun 10x/detik selamanya tanpa pernah ada
               kemajuan — dan layanan ini toh akan dinilai ulang oleh
               spawn_eligible_services() pada iterasi berikutnya. */
            svc->need_respawn = 0;
            continue;
        }
        spawn_service(svc);
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

/* Picu cgroup.kill layanan (berdasarkan NAMA, bukan pid): membunuh seluruh
   anggota cgroup, termasuk proses yang grup prosesnya sudah berubah.
   Dipanggil terpisah dari kill_service_group() supaya tetap terjangkau saat
   leader sudah lama mati dan pid/pgid tidak lagi bisa diandalkan. */
static void cgroup_kill_service(const char *name)
{
    char kill_path[320];
    snprintf(kill_path, sizeof(kill_path), "%s/%s/cgroup.kill", CGROUP_BASE, name);
    int fd = open(kill_path, O_WRONLY);
    if (fd >= 0) {
        if (write(fd, "1\n", 2) < 0) {
            /* abaikan bila cgroup.kill belum didukung kernel */
        }
        close(fd);
    }
}

/* Kirim sinyal ke seluruh grup proses layanan (lewat pgid yang disimpan,
   BUKAN pid leader: leader bisa sudah mati sementara grupnya masih hidup —
   audit SANE-01), dan coba cgroup.kill bila SIGKILL. */
static void kill_service_group(const service_t *svc, int sig)
{
    if (svc->pgid > 0) {
        if (kill(-svc->pgid, sig) < 0 && errno == ESRCH && svc->pid > 0)
            kill(svc->pid, sig);
    } else if (svc->pid > 0) {
        kill(svc->pid, sig);
    }

    if (sig == SIGKILL) cgroup_kill_service(svc->name);
}

/* Masih adakah yang hidup dari layanan ini? Leader (pid) ATAU siapa pun di
   grup prosesnya. Grup yang sudah kosong terdeteksi lewat kill(-pgid, 0)
   yang gagal ESRCH; pgid lalu dibersihkan supaya tidak ada sinyal nyasar ke
   grup lain bila nomor itu kelak didaur ulang kernel. */
static int service_still_alive(service_t *svc)
{
    if (svc->pid > 0) return 1;
    if (svc->pgid > 0) {
        if (kill(-svc->pgid, 0) == 0 || errno == EPERM) return 1;
        svc->pgid = 0;
    }
    return 0;
}

/* ---------- shutdown ---------- */
static void shutdown_all(int reboot_cmd, int force)
{
    shutting_down = 1;   /* tandai shutdown: respawn dinonaktifkan (fix bug shutdown) */

    if (force) {
        init_log("FORCE shutdown (cmd=%d)", reboot_cmd);
        for (int i = 0; i < num_services; i++) {
            /* Probe dulu (menutup catatan review PR #2): service_still_alive()
               membersihkan pgid basi layanan yang sudah lama selesai, supaya
               SIGKILL tidak nyasar ke grup lain yang nomornya didaur ulang.
               Layanan yang lolos dari grupnya tetap dijangkau cgroup.kill. */
            if (service_still_alive(&services[i]))
                kill_service_group(&services[i], SIGKILL);
            else
                cgroup_kill_service(services[i].name);
            cleanup_cgroup(services[i].name);
        }
        rmdir(CGROUP_BASE);
        reap_zombies(); sync();
        if (reboot(reboot_cmd) < 0) init_log("reboot(%d) gagal: %s", reboot_cmd, strerror(errno));
        while (1) pause();
    }

    init_log("graceful shutdown (cmd=%d)", reboot_cmd);
    for (int i = 0; i < num_services; i++) {
        /* Probe sebelum memberi sinyal (sama seperti jalur force di atas):
           pgid basi dibersihkan lebih dulu, baru grup yang benar-benar
           masih hidup menerima SIGTERM. */
        if (service_still_alive(&services[i]))
            kill_service_group(&services[i], SIGTERM);
    }

    for (int i = 0; i < 50; i++) {
        int alive = 0;
        /* Probe SETIAP layanan, jangan berhenti di yang pertama hidup: hanya
           service_still_alive() yang membersihkan pgid basi (:681). Dengan
           break dini, layanan yang indeksnya setelah layanan hidup tidak
           pernah ter-probe pada pass terakhir, jadi pgid kadaluarsanya
           bertahan sampai SIGKILL di bawah dan bisa mengenai grup proses lain
           yang nomornya sudah didaur ulang kernel. */
        for (int j = 0; j < num_services; j++)
            if (service_still_alive(&services[j])) alive = 1;
        if (!alive) break;
        reap_zombies();
        drain_log_fifo();   /* pesan terakhir layanan sebelum mati (mis. "bye!") */
        usleep(100000);
    }

    for (int i = 0; i < num_services; i++) {
        /* Probe sekali lagi sebelum SIGKILL, sama seperti jalur force dan
           jalur SIGTERM di atas: grup bisa saja baru mati setelah pass
           terakhir. Layanan yang grupnya sudah kosong hanya perlu
           cgroup.kill — SIGKILL lewat pgid basi justru berbahaya. */
        if (service_still_alive(&services[i])) {
            kill_service_group(&services[i], SIGKILL);
        } else {
            init_log("%s: grup sudah mati, SIGKILL dilewati", services[i].name);
            cgroup_kill_service(services[i].name);
        }
        cleanup_cgroup(services[i].name);
    }
    rmdir(CGROUP_BASE);
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

#ifndef MS_LAZYTIME
#define MS_LAZYTIME (1U << 25)   /* kernel >= 4.0; glibc lama belum tentu punya */
#endif

/* Klasifikasikan opsi fstab dalam satu lintasan (audit SANE-02, diperluas
   mengikuti review PR #2):
     1. Flag VFS (ro, noatime, lazytime, ...) -> nilai balik sebagai MS_*
        flags untuk argumen ke-4 mount(). Pasangan peniadanya (rw, exec,
        suid, dev, async, atime, diratime) MEMBERSIHKAN bit lawannya, dan
        "user"/"users"/"owner"/"group" memasang flag implikasi mount(8) —
        semua diproses kiri-ke-kanan sehingga token belakangan menang.
     2. Opsi userspace fstab murni (_netdev, nofail, x-*, comment=*, ...) ->
        wewenang mount(8)/systemd, BUKAN kernel: dicatat lalu diabaikan,
        tidak pernah diteruskan sebagai data.
     3. "noauto" -> entri dilewati seluruhnya (*skip_reason = SKIP_NOAUTO),
        seperti perilaku `mount -a` saat boot.
     4. "bind"/"rbind" -> TIDAK didukung: entri dilewati dengan alasan
        (*skip_reason = SKIP_BIND) yang dicatat eksplisit oleh pemanggil.
        Bind mengubah semantik kolom pertama fstab menjadi path sumber,
        sedangkan ninit memperlakukannya sebagai label/device filesystem;
        mendukungnya setengah-setengah hanya menghasilkan kegagalan senyap.
     5. Selainnya -> opsi khas filesystem (size=, mode=, uid=, ...), disalin
        ke `data` untuk argumen ke-5 mount().
   Token flag TIDAK boleh ikut terbawa ke data: parser opsi filesystem yang
   ketat (ext4, tmpfs) menolak opsi data tak dikenal dengan EINVAL. */
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

    /* Token diproses KIRI KE KANAN seperti mount(8): token peniada
       membersihkan bit lawannya (ro lalu rw berakhir rw), dan "user"
       memasang implikasinya yang bisa dibatalkan token sesudahnya
       (user,exec berakhir exec) — review PR #2 butir 1 & 2. */
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
            /* mount(8): user/users mengimplikasikan noexec+nosuid+nodev
               (bisa dibatalkan token exec/suid/dev sesudahnya). */
            flags |= MS_NOEXEC | MS_NOSUID | MS_NODEV;
            init_log("fstab: opsi '%s' menerapkan noexec,nosuid,nodev", tok);
        }
        else if (!strcmp(tok, "owner") || !strcmp(tok, "group")) {
            /* mount(8): owner/group mengimplikasikan nosuid+nodev. */
            flags |= MS_NOSUID | MS_NODEV;
            init_log("fstab: opsi '%s' menerapkan nosuid,nodev", tok);
        }
        else if (!strcmp(tok, "noauto")) {
            if (skip_reason && *skip_reason == SKIP_NONE) *skip_reason = SKIP_NOAUTO;
        }
        else if (!strcmp(tok, "auto") || !strcmp(tok, "nouser") ||
                 !strcmp(tok, "_netdev") || !strcmp(tok, "nofail") ||
                 !strncmp(tok, "x-", 2) || !strncmp(tok, "comment=", 8)) {
            init_log("fstab: opsi '%s' khusus userspace, diabaikan", tok);
        }
        else {
            init_log("fstab: opsi '%s' bukan flag, diteruskan sebagai data", tok);
            if (data && datasz) {
                if (data[0]) strncat(data, ",", datasz - strlen(data) - 1);
                strncat(data, tok, datasz - strlen(data) - 1);
            }
        }
    }
    /* MS_BIND tidak punya token peniada: sekali bind/rbind (termasuk dalam
       kombinasi seperti remount,bind) muncul, entri ini tidak didukung dan
       dilewati — keputusannya di sini, di parser, supaya pemanggil bisa
       melewatinya SEBELUM mountpoint dibuat (tidak ada direktori hantu
       untuk entri yang tidak pernah di-mount). */
    if ((flags & MS_BIND) && skip_reason && *skip_reason == SKIP_NONE)
        *skip_reason = SKIP_BIND;
    return flags;
}

/* Buat direktori beserta seluruh induknya (mkdir -p), mode 0755 untuk tiap
   direktori yang BARU dibuat (di-chmod eksplisit supaya hasilnya tidak
   bergantung umask warisan PID 1; kegagalan chmod menggagalkan entri).
   Seluruh path DIPINDAI DI MUKA: komponen "." dan ".." ditolak sebelum
   direktori apa pun dibuat, supaya penolakan tidak meninggalkan direktori
   hantu (fstab juga tidak boleh diam-diam menormalisasi path ke tempat
   lain). Komponen yang sudah ada harus direktori: diperiksa dengan stat()
   yang MENGIKUTI symlink — symlink ke direktori diterima, symlink ke file
   / komponen berupa file biasa ditolak dengan log jelas (tanpa cek ini,
   mkdir EEXIST akan lolos dan mount() gagal ENOTDIR jauh dari
   penyebabnya). Path harus absolut dan muat di buffer (tidak ada
   pemotongan diam-diam). Mengembalikan 0 bila mountpoint siap, -1 bila
   entri harus dilewati. */
static int mkdir_p(const char *path)
{
    char buf[MAX_LINE];
    size_t len;

    if (!path) return -1;
    len = strlen(path);
    if (path[0] != '/' || len >= sizeof(buf)) {
        init_log("fstab: mountpoint '%s' tidak valid (harus absolut, maks %zu karakter)",
                 path, sizeof(buf) - 1);
        return -1;
    }

    /* Pra-pindai komponen: tolak "." / ".." sebelum mkdir pertama. */
    for (const char *s = path; *s; ) {
        while (*s == '/') s++;
        const char *e = s;
        while (*e && *e != '/') e++;
        size_t clen = (size_t)(e - s);
        if ((clen == 1 && s[0] == '.') ||
            (clen == 2 && s[0] == '.' && s[1] == '.')) {
            init_log("fstab: mountpoint '%s' memuat komponen '%.*s', ditolak",
                     path, (int)clen, s);
            return -1;
        }
        s = e;
    }

    memcpy(buf, path, len + 1);

    /* Berjalan komponen demi komponen; potongan kosong (slash ganda,
       trailing slash, dan "/" itu sendiri) berakhir sebagai direktori
       yang sudah ada dan lolos lewat jalur EEXIST + stat di bawah. */
    for (char *p = buf + 1; ; p++) {
        if (*p != '/' && *p != '\0') continue;
        char save = *p;
        *p = '\0';
        if (mkdir(buf, 0755) == 0) {
            if (chmod(buf, 0755) < 0) {
                init_log("fstab: chmod '%s' gagal: %s", buf, strerror(errno));
                return -1;
            }
        } else if (errno == EEXIST) {
            struct stat st;
            if (stat(buf, &st) < 0) {
                init_log("fstab: stat '%s' gagal: %s", buf, strerror(errno));
                return -1;
            }
            if (!S_ISDIR(st.st_mode)) {
                init_log("fstab: komponen '%s' dari mountpoint '%s' bukan direktori", buf, path);
                return -1;
            }
        } else {
            init_log("fstab: mkdir '%s' gagal: %s", buf, strerror(errno));
            return -1;
        }
        *p = save;
        if (save == '\0') break;
    }
    return 0;
}

/* Dekode escape oktal fstab di tempat, mengikuti getmntent(3)/mount(8):
   backslash diikuti TEPAT tiga digit oktal (\040 spasi, \011 tab, \012
   newline, \134 backslash, dan \ooo lain) menjadi satu byte; urutan selain
   itu dibiarkan apa adanya. Hasil dekode tidak pernah lebih panjang dari
   sumbernya, jadi aman dilakukan in-place. Diterapkan pada field device
   dan mountpoint SEBELUM validasi lain (pra-pindai mkdir_p, cek duplikat),
   supaya semua pemeriksaan bekerja pada path yang sebenarnya — mis.
   \056\056 yang terdekode menjadi ".." tetap ditolak pra-pindai mkdir_p.
   Tanpa dekode ini (temuan PR3-C1), path berisi spasi dibuat sebagai
   direktori bernama harfiah "spa\040ce" dan di-mount di sana: berhasil,
   tapi diam-diam menyimpang dari mount -a. Field opsi TIDAK didekode:
   tokennya dipisah koma oleh parse_mount_flags(), dan koma hasil dekode
   (\054) akan mengubah makna pemisahan itu; path berisi spasi — kasus
   nyata temuan ini — hidup di device/mountpoint. */
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

/* Dua mountpoint dianggap sama bila identik setelah slash di ujung
   diabaikan ("/mnt/x/" dan "/mnt/x" adalah direktori yang sama; "/"
   tetap "/"). Dipakai cek duplikat mount_fstab. */
static int same_mountpoint(const char *a, const char *b)
{
    size_t la = strlen(a), lb = strlen(b);
    while (la > 1 && a[la - 1] == '/') la--;
    while (lb > 1 && b[lb - 1] == '/') lb--;
    return la == lb && strncmp(a, b, la) == 0;
}

/* Format: <device> <mountpoint> <fstype> <options> [dump] [pass]; baris '#' diabaikan */
static void mount_fstab(void)
{
    FILE *f = fopen(FSTAB_PATH, "r");
    if (!f) {
        init_log("fstab: %s tidak ada, dilewati", FSTAB_PATH);
        return;
    }

    /* Mountpoint yang SUDAH berhasil di-mount entri sebelumnya pada
       lintasan ini (temuan PR3-C2): mount(2) menumpuk mount duplikat
       diam-diam, dan opsi mount teratas menutupi proteksi mount di
       bawahnya (nosuid bisa hilang tanpa jejak). Entri duplikat kini
       dilewati dan dicatat. Hanya mount yang BERHASIL yang dicatat, jadi
       kegagalan entri pertama tidak menghalangi mountpoint yang sama
       dicoba lagi oleh entri berikutnya. */
    enum { MAX_SEEN_MNT = 64 };
    static char seen_mnt[MAX_SEEN_MNT][MAX_LINE];
    int seen_cnt = 0;

    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        if (line_overlong(f, line)) {
            init_log("fstab: baris melebihi MAX_LINE (%d), dilewati", MAX_LINE);
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
            init_log("fstab: baris tidak lengkap: '%s'", p);
            continue;
        }

        /* Escape oktal didekode sebelum pemrosesan lain apa pun (lihat
           unescape_fstab_field): log, mkdir, cek duplikat, dan mount()
           semuanya melihat path yang sebenarnya. */
        unescape_fstab_field(dev);
        unescape_fstab_field(mnt);

        /* Opsi dipisahkan SATU kali oleh parse_mount_flags() dari salinan
           string (strtok merusak string aslinya): token flag menjadi MS_*
           flags (arg ke-4) dan token non-flag menjadi data khas filesystem
           (arg ke-5). Token flag TIDAK boleh ikut terbawa ke data — parser
           opsi ext4/tmpfs menolaknya dengan EINVAL (audit SANE-02). */
        char flagbuf[MAX_LINE];
        char databuf[MAX_LINE] = "";
        snprintf(flagbuf, sizeof(flagbuf), "%s", opts ? opts : "");
        int skip_reason = SKIP_NONE;
        unsigned long flags = parse_mount_flags(flagbuf, databuf, sizeof(databuf), &skip_reason);
        /* Keputusan lewati diputuskan parser dan dievaluasi di sini,
           SEBELUM mountpoint dibuat: entri yang dilewati tidak meninggalkan
           direktori hantu di rootfs. */
        if (skip_reason == SKIP_NOAUTO) {
            init_log("fstab: %s -> %s dilewati (opsi noauto)", dev, mnt);
            continue;
        }
        if (skip_reason == SKIP_BIND) {
            init_log("fstab: %s -> %s dilewati (bind/rbind tidak didukung)", dev, mnt);
            continue;
        }

        /* Duplikat diperiksa setelah keputusan parser, sebelum mkdir:
           entri yang dilewati tidak meninggalkan direktori hantu, sama
           seperti noauto/bind. */
        int is_dup = 0;
        for (int i = 0; i < seen_cnt; i++)
            if (same_mountpoint(seen_mnt[i], mnt)) { is_dup = 1; break; }
        if (is_dup) {
            init_log("fstab: %s -> %s dilewati (mountpoint duplikat, sudah di-mount entri sebelumnya)", dev, mnt);
            continue;
        }

        if (mkdir_p(mnt) < 0) {
            init_log("fstab: %s -> %s dilewati (mountpoint tidak bisa disiapkan)", dev, mnt);
            continue;
        }
        if (mount(dev, mnt, type, flags, databuf[0] ? databuf : NULL) < 0)
            init_log("fstab: mount %s -> %s (%s) [data: %s] gagal: %s", dev, mnt, type,
                     databuf[0] ? databuf : "-", strerror(errno));
        else {
            init_log("fstab: mount %s -> %s (%s) [data: %s] ok", dev, mnt, type,
                     databuf[0] ? databuf : "-");
            if (seen_cnt < MAX_SEEN_MNT)
                snprintf(seen_mnt[seen_cnt++], MAX_LINE, "%s", mnt);
        }
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

    spawn_eligible_services();

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
        if (ret < 0 && perr != EINTR) {
            init_log("ppoll error: %s", strerror(perr));
            usleep(100000); /* jeda 100ms cegah log spam bila terjadi error berulang */
            continue;
        }

        /* 1. Cek Sinyal: shutdown DIPRIORITASKAN sebelum reap_zombies()/respawn,
           supaya SIGTERM yang datang bersamaan SIGCHLD tidak tertunda. */
        if (sigterm_flag) { sigterm_flag = 0; shutdown_all(RB_POWER_OFF, 0); }
        if (sigint_flag ) { sigint_flag  = 0; shutdown_all(RB_AUTOBOOT,   0); }
        if (sigusr1_flag) { sigusr1_flag = 0; shutdown_all(RB_POWER_OFF, 1); }
        if (sigusr2_flag) { sigusr2_flag = 0; shutdown_all(RB_AUTOBOOT,   1); }
        if (sigchld_flag) {
            sigchld_flag = 0;
            reap_zombies();
            spawn_eligible_services();
        }

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
        spawn_eligible_services();
    }
    return 0;
}
