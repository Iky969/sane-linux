/* Tests for the reusable safe_path() guard. Build:
 *   cc -Wall -Wextra -Werror safe_path.c test-safe-path.c -o /tmp/t && /tmp/t
 */
#include <stdio.h>
#include <string.h>

#include "safe_path.h"

static int failures = 0;
static int total = 0;

static void check(const char *s, int want) {
    int got;
    total++;
    got = safe_path(s);
    if (got != want) {
        fprintf(stderr, "FAIL safe_path(%s) = %d, want %d\n", s, got, want);
        failures++;
    }
}

int main(void) {
    check("etc/hostname", 1);
    check("usr/bin/hello", 1);
    check("lib/modules/virtio_net.ko", 1);
    check("a+b", 1);
    check(".hidden", 1);
    check("dir/file-1", 1);
    check(NULL, 0);
    check("", 0);
    check("/etc/passwd", 0);
    check("../etc/passwd", 0);
    check("a/../b", 0);
    check("..", 0);
    check("has space", 0);
    check("cmd;id", 0);
    check("back\\slash", 0);
    check("$(id)", 0);
    check("-leading", 1);
    check("foo..bar", 0);       /* conservative: ".." substring refused */
    check("\xc3\xa9", 0);         /* non-ASCII refuses regardless of locale */
    check("tab\there", 0);

    if (failures) {
        fprintf(stderr, "%d safe_path test(s) failed\n", failures);
        return 1;
    }
    printf("safe_path: all %d cases passed\n", total);
    return 0;
}
