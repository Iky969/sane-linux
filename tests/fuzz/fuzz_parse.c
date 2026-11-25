/*
 * fuzz_parse.c -- ASan + UBSan driver for ninit's input parsers.
 *
 * Built and fed by scripts/fuzz-parsers.sh. This file intentionally performs
 * NO syscalls with side effects: mount_fstab() is never called (it would
 * really mount(2)/mkdir(2) on the host); only its pure option classifier
 * parse_mount_flags() and mountpoint comparator same_mountpoint() are exercised.
 * State file writes are disabled via NINIT_FUZZ so parse_config() never touches
 * /run on the host.
 *
 * Modes:
 *   config  <file>            -> parse_config(file) + validate_dependencies() + sort_services()
 *   fstab   <file>            -> unescape_fstab_field + parse_mount_flags + same_mountpoint
 *   initctl <file>            -> initctl_parse_stream (37/64) + initctl_parse_next (1024/16)
 *   mutate  <seed> <iters>    -> deterministic LCG mutations through all parsers
 *   verify  <unused>          -> deterministic assertions for P1-1/P1-2/P2 parser contracts
 *
 * Exit code is always 0 unless verify fails or the driver itself is misused;
 * sanitizer findings are reported by the runtime and detected by the runner.
 */
#define NINIT_FUZZ 1
#define main ninit_main_unused      /* ninit.c: main() refuses to run as non-PID-1 */
#include "../../ninit.c"
#undef main

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void run_initctl_1024(const char *buf, size_t n)
{
    char sbuf[MAX_LINE];
    sbuf[0] = '\0';
    size_t slen = 0;
    char cmds[16][MAX_LINE];
    int disc = 0;
    size_t chunk_sz = MAX_LINE;

    for (size_t off = 0; off < n; off += chunk_sz) {
        size_t c_len = (n - off < chunk_sz) ? (n - off) : chunk_sz;
        size_t pos = 0;
        while (pos < c_len) {
            size_t used = 0;
            initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                               buf + off + pos, c_len - pos, &used,
                               cmds, 16, &disc);
            if (used == 0) break;
            pos += used;
        }
    }
    if (slen > 0 && slen < sizeof(sbuf)) {
        for (int k = 0; k < 16; k++) {
            size_t used = 0;
            int got = initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                                         NULL, 0, &used, cmds, 16, &disc);
            if (got <= 0) break;
        }
    }
}

static int run_verify_checks(void)
{
    /* 1. P1-2: prefix + 1024B read must not wipe prefix or drop byte 1023 */
    {
        char sbuf[MAX_LINE];
        sbuf[0] = '\0';
        size_t slen = 0;
        char cmds[16][MAX_LINE];
        int disc = 0;
        size_t used = 0;

        int n = initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                                   "start ", 6, &used, cmds, 16, &disc);
        if (n != 0 || slen != 6 || disc != 0) {
            fprintf(stderr, "verify: prefix buffering failed\n");
            return 1;
        }

        char chunk[MAX_LINE];
        memset(chunk, 'x', sizeof(chunk));
        memcpy(chunk, "poweroff\n", 9);
        size_t off = 0;
        int total = 0;
        char first_cmd[MAX_LINE] = "";
        while (off < sizeof(chunk)) {
            n = initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                                   chunk + off, sizeof(chunk) - off, &used,
                                   cmds, 16, &disc);
            if (n > 0 && total == 0)
                snprintf(first_cmd, sizeof(first_cmd), "%s", cmds[0]);
            total += n;
            if (used == 0) break;
            off += used;
        }
        if (strcmp(first_cmd, "start poweroff") != 0 || total != 1 || disc != 0) {
            fprintf(stderr, "verify: 1024B prefix test failed (cmd='%s' total=%d disc=%d)\n",
                    first_cmd, total, disc);
            return 1;
        }

        /* Now send 1024 more 'x's (overflowing partial line) + "\nreboot\n" */
        memset(chunk, 'x', sizeof(chunk));
        n = initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                               chunk, sizeof(chunk), &used, cmds, 16, &disc);
        if (n != 0 || disc != 1 || slen != sizeof(sbuf)) {
            fprintf(stderr, "verify: multi-chunk overflow state failed (n=%d disc=%d slen=%zu)\n",
                    n, disc, slen);
            return 1;
        }
        n = initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                               "poweroff\nreboot\n", 16, &used, cmds, 16, &disc);
        if (n != 1 || strcmp(cmds[0], "reboot") != 0) {
            fprintf(stderr, "verify: overflow tail smuggled command (n=%d cmd='%s')\n",
                    n, n > 0 ? cmds[0] : "");
            return 1;
        }
    }

    /* 2. P1-2: exact 1023-char + '\n' (1024B) accepted & >16 cmds drained */
    {
        char sbuf[MAX_LINE];
        sbuf[0] = '\0';
        size_t slen = 0;
        char cmds[16][MAX_LINE];
        int disc = 0;
        size_t used = 0;
        char exact[MAX_LINE];
        memset(exact, 'a', MAX_LINE - 1);
        exact[MAX_LINE - 1] = '\n';

        int n = initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                                   exact, sizeof(exact), &used, cmds, 16, &disc);
        if (n != 1 || disc != 0 || strlen(cmds[0]) != MAX_LINE - 1) {
            fprintf(stderr, "verify: exact 1024B line failed (n=%d disc=%d len=%zu)\n",
                    n, disc, n > 0 ? strlen(cmds[0]) : 0);
            return 1;
        }

        char many[1024];
        size_t mlen = 0;
        for (int i = 0; i < 25; i++) {
            int w = snprintf(many + mlen, sizeof(many) - mlen, "status s%d\n", i);
            mlen += (size_t)w;
        }
        size_t off = 0;
        int total = 0;
        slen = 0;
        sbuf[0] = '\0';
        while (off < mlen) {
            n = initctl_parse_next(sbuf, sizeof(sbuf), &slen,
                                   many + off, mlen - off, &used, cmds, 16, &disc);
            total += n;
            if (used == 0) break;
            off += used;
        }
        if (total != 25) {
            fprintf(stderr, "verify: >16 cmds drain failed (got %d != 25)\n", total);
            return 1;
        }
    }

    /* 3. P1-1: backslash escapes, unbalanced quotes, unknown :key= */
    {
        char c1[] = "echo \"\\\"\"; id && echo :user=nobody";
        char *tag = NULL;
        if (find_option_tag_start(c1, &tag) != 0 || !tag || strcmp(tag, ":user=nobody") != 0) {
            fprintf(stderr, "verify: escaped double quote scan failed\n");
            return 1;
        }
        char c2[] = "echo \\'; id && echo :user=nobody";
        if (find_option_tag_start(c2, &tag) != 0 || !tag || strcmp(tag, ":user=nobody") != 0) {
            fprintf(stderr, "verify: escaped single quote scan failed\n");
            return 1;
        }
        char c3[] = "echo '\\\\'; id && echo :user=nobody";
        if (find_option_tag_start(c3, &tag) != 0 || !tag || strcmp(tag, ":user=nobody") != 0) {
            fprintf(stderr, "verify: single-quote backslash scan failed\n");
            return 1;
        }
        char c4[] = "echo ok # don't:user=nobody";
        if (find_option_tag_start(c4, &tag) != -1) {
            fprintf(stderr, "verify: unbalanced quote not detected\n");
            return 1;
        }
        char c5[] = "echo hi:usr=nobody";
        if (find_option_tag_start(c5, &tag) != 0 || !tag || strcmp(tag, ":usr=nobody") != 0) {
            fprintf(stderr, "verify: unknown :key= tag not detected\n");
            return 1;
        }
    }

    /* 4. P2 #6 & #8: (uid_t)-1 rejection and same_mountpoint '//' */
    {
        unsigned long v = 0;
        if (parse_numeric_id("4294967295", &v) != -1) {
            fprintf(stderr, "verify: 4294967295 not rejected\n");
            return 1;
        }
        if (parse_numeric_id("0", &v) != 0 || v != 0) {
            fprintf(stderr, "verify: 0 rejected unexpectedly\n");
            return 1;
        }
        if (!same_mountpoint("//", "/") || !same_mountpoint("/mnt//a/", "/mnt/a") ||
            same_mountpoint("/mnt/a", "/mnt/ab")) {
            fprintf(stderr, "verify: same_mountpoint normalization failed\n");
            return 1;
        }
    }

    /* 5. P1-4: enforce_stop_timeout clears STOPPING -> STOPPED when pid==0 and dead */
    {
        memset(services, 0, sizeof(services));
        num_services = 1;
        snprintf(services[0].name, sizeof(services[0].name), "%s", "fuzz_nonexistent_svc");
        services[0].state = SVC_STATE_STOPPING;
        services[0].pid = 0;
        services[0].pgid = 0;
        services[0].grace = 5;
        services[0].stop_t0 = monotonic_ms();
        enforce_stop_timeout();
        if (services[0].state != SVC_STATE_STOPPED) {
            fprintf(stderr, "verify: enforce_stop_timeout left STOPPING when dead (state=%s)\n",
                    svc_state_name(services[0].state));
            return 1;
        }
        memset(services, 0, sizeof(services));
        num_services = 0;
    }

    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    const char *mode = argv[1];
    const char *path = argv[2];

    if (strcmp(mode, "verify") == 0) {
        return run_verify_checks();
    }

    if (strcmp(mode, "config") == 0) {
        memset(services, 0, sizeof(services));
        num_services = 0;
        if (parse_config(path) == 0 && num_services > 0) {
            validate_dependencies();
            sort_services();
        }
        return 0;
    }

    if (strcmp(mode, "mutate") == 0) {
        unsigned int seed = (unsigned int)strtoul(argv[2], NULL, 10);
        int iters = argc > 3 ? atoi(argv[3]) : 1000;
        static const char *tokens[] = {
            ":", "\n", " ", "\t", "/", "//", "..", ":requires=", ":memory_max=",
            ":cpu_max=", ":pids_max=", ":timeout=", ":grace=", ":user=", ":group=",
            ":on_fail=", ":usr=", ":deps=", "rescue", "fail", "none", "nobody",
            "root", "4294967295", "\"", "'", "\\\"", "\\'", "\\\\",
            "1K", "2M", "3G", "max", "50000 100000", "100 0",
            "\\040", "\\000", "\\777", "respawn", "once", "a:once:",
            "rw", "ro", "noauto", "bind", "user", "x-foo", "0", "-1",
            "999999999999999999999", "\x01", "\xff", "a", "srv"
        };
        const size_t ntokens = sizeof(tokens) / sizeof(tokens[0]);
        static char buf[4096];
        char tmp[256];
        snprintf(tmp, sizeof(tmp), "/tmp/ninit-fuzz-mutate.%ld", (long)getpid());

        for (int it = 0; it < iters; it++) {
            unsigned int r = seed + (unsigned int)it * 2654435761u;
            int len = 0;
            int nbits = 1 + (int)(r % 64);
            for (int k = 0; k < nbits && len < (int)sizeof(buf) - 64; k++) {
                r = r * 1103515245u + 12345u;
                const char *t = tokens[(r >> 16) % ntokens];
                size_t tl = strlen(t);
                if (len + (int)tl < (int)sizeof(buf) - 1) {
                    memcpy(buf + len, t, tl);
                    len += (int)tl;
                }
            }
            buf[len] = '\0';
            if ((it % 7 == 0) && len > 4) {
                buf[(r >> 8) % (unsigned int)len] = '\0';
            }

            /* fstab octal unescape + same_mountpoint + option classifier (pure) */
            char esc[4096];
            memcpy(esc, buf, (size_t)len + 1);
            unescape_fstab_field(esc);
            same_mountpoint(buf, esc);
            same_mountpoint(buf, "/");

            char data[1024];
            int skip = SKIP_NONE;
            char fbuf[4096];
            memcpy(fbuf, buf, (size_t)len + 1);
            parse_mount_flags(fbuf, data, sizeof(data), &skip);

            /* initctl streaming parser: multi-chunk 1024/16 + single-call 16 */
            run_initctl_1024(buf, (size_t)len);
            char sbuf[MAX_LINE];
            sbuf[0] = '\0';
            size_t slen = 0;
            char cmds[16][MAX_LINE];
            int disc = 0;
            initctl_parse_stream(sbuf, sizeof(sbuf), &slen,
                                 buf, (size_t)len, cmds, 16, &disc);

            /* init.conf parser + dep validator + topo sort (file-backed) */
            FILE *mf = fopen(tmp, "wb");
            if (mf) {
                fwrite(buf, 1, (size_t)len, mf);
                fclose(mf);
                memset(services, 0, sizeof(services));
                num_services = 0;
                if (parse_config(tmp) == 0 && num_services > 0) {
                    validate_dependencies();
                    sort_services();
                }
            }
        }
        remove(tmp);
        return 0;
    }

    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    static char buf[1 << 20];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';

    if (strcmp(mode, "fstab") == 0) {
        char esc[1 << 20];
        memcpy(esc, buf, n + 1);
        unescape_fstab_field(esc);
        same_mountpoint(esc, "/");
        same_mountpoint(buf, esc);
        char data[1024];
        int skip = SKIP_NONE;
        parse_mount_flags(buf, data, sizeof(data), &skip);
        return 0;
    }
    if (strcmp(mode, "initctl") == 0) {
        /* Fuzz both small-prime chunks and real process_initctl 1024/16 chunks */
        char sbuf[MAX_LINE];
        sbuf[0] = '\0';
        size_t slen = 0;
        char cmds[64][MAX_LINE];
        int disc = 0;
        size_t chunk_sz = 37;
        for (size_t off = 0; off < n; off += chunk_sz) {
            size_t c_len = (n - off < chunk_sz) ? (n - off) : chunk_sz;
            initctl_parse_stream(sbuf, sizeof(sbuf), &slen,
                                 buf + off, c_len, cmds, 64, &disc);
        }
        run_initctl_1024(buf, n);
        return 0;
    }
    return 0;
}
