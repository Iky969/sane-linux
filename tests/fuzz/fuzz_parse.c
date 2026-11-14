/*
 * fuzz_parse.c -- ASan + UBSan driver for ninit's input parsers.
 *
 * Built and fed by scripts/fuzz-parsers.sh. This file intentionally performs
 * NO syscalls with side effects: mount_fstab() is never called (it would
 * really mount(2)/mkdir(2) on the host); only its pure option classifier
 * parse_mount_flags() is exercised. The syscall glue is covered by the
 * chroot/unshare suites instead.
 *
 * Modes:
 *   config  <file>            -> parse_config(file)
 *   fstab   <file>            -> parse_mount_flags(file contents)
 *   initctl <file>            -> initctl_parse_stream(file contents)
 *   mutate  <seed> <iters>    -> deterministic LCG mutations through all three
 *
 * Exit code is always 0 unless the driver itself is misused; sanitizer
 * findings are reported by the runtime and detected by the runner.
 */
#define main ninit_main_unused      /* ninit.c: main() refuses to run as non-PID-1 */
#include "../../ninit.c"
#undef main

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    const char *mode = argv[1];
    const char *path = argv[2];

    if (strcmp(mode, "config") == 0) {
        parse_config(path);
        return 0;
    }

    if (strcmp(mode, "mutate") == 0) {
        unsigned int seed = (unsigned int)strtoul(argv[2], NULL, 10);
        int iters = argc > 3 ? atoi(argv[3]) : 1000;
        static const char *tokens[] = {
            ":", "\n", " ", "\t", "/", "..", ":requires=", ":memory_max=",
            ":cpu_max=", ":pids_max=", ":timeout=", ":grace=", "\\040", "\\000", "\\777", "respawn", "once",
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

            /* fstab octal unescape (pure, in-place on scratch copy) */
            char esc[4096];
            memcpy(esc, buf, (size_t)len + 1);
            unescape_fstab_field(esc);

            /* fstab option classifier (pure) */
            char data[1024];
            int skip = SKIP_NONE;
            parse_mount_flags(buf, data, sizeof(data), &skip);

            /* initctl streaming parser (pure real code) */
            char sbuf[MAX_LINE];
            sbuf[0] = '\0';
            size_t slen = 0;
            char cmds[16][MAX_LINE];
            int disc = 0;
            initctl_parse_stream(sbuf, sizeof(sbuf), &slen,
                                 buf, (size_t)len, cmds, 16, &disc);

            /* init.conf parser (file-backed) */
            FILE *mf = fopen(tmp, "wb");
            if (mf) {
                fwrite(buf, 1, (size_t)len, mf);
                fclose(mf);
                num_services = 0;   /* re-arm the registry for the next iteration */
                parse_config(tmp);
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
        char data[1024];
        int skip = SKIP_NONE;
        parse_mount_flags(buf, data, sizeof(data), &skip);
        return 0;
    }
    if (strcmp(mode, "initctl") == 0) {
        /* Fuzz streaming parser directly in chunks to exercise buffer boundary */
        char sbuf[MAX_LINE];
        sbuf[0] = '\0';
        size_t slen = 0;
        char cmds[64][MAX_LINE];
        int disc = 0;
        size_t chunk_sz = 37; /* prime chunk size to test split lines */
        for (size_t off = 0; off < n; off += chunk_sz) {
            size_t c_len = (n - off < chunk_sz) ? (n - off) : chunk_sz;
            initctl_parse_stream(sbuf, sizeof(sbuf), &slen,
                                 buf + off, c_len, cmds, 64, &disc);
        }
        return 0;
    }
    return 0;
}
