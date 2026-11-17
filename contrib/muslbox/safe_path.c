#include "safe_path.h"

#include <ctype.h>
#include <string.h>

int safe_path(const char *s) {
    if (!s || !*s || *s == '/')
        return 0;
    if (strstr(s, ".."))
        return 0;
    for (; *s; s++)
        if (!(isalnum((unsigned char)*s) || strchr("._/-+", *s)))
            return 0;
    return 1;
}
