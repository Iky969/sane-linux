/* safe_path -- reusable path guard extracted from MUSLBOX's mbpm.c.
 *
 * Rules (deliberately strict, suitable for tarball/package installers):
 *   - reject empty and absolute paths
 *   - reject any ".." substring (conservative: even "a..b" is refused)
 *   - allow only ASCII [A-Za-z0-9._/-+] (no locale-dependent isalnum)
 *
 * This is a C reference implementation; S.A.N.E's spm is POSIX shell and
 * already has its own equivalent guards. Keep both in sync conceptually.
 */
#include "safe_path.h"

#include <string.h>

static int ascii_alnum(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9');
}

int safe_path(const char *s) {
    if (!s || !*s || *s == '/')
        return 0;
    if (strstr(s, ".."))
        return 0;
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (!ascii_alnum(c) && !strchr("._/-+", c))
            return 0;
    }
    return 1;
}
