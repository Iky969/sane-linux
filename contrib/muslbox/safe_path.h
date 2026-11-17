/* safe_path -- reusable path guard extracted from MUSLBOX's mbpm.c.
 *
 * Rules (deliberately strict, suitable for tarball/package installers):
 *   - reject empty and absolute paths
 *   - reject any ".." component (tar-slip / traversal)
 *   - allow only [A-Za-z0-9._/-+] so shell quoting and globbing stay safe
 *
 * This is a C reference implementation; S.A.N.E's spm is POSIX shell and
 * already has its own equivalent guards.  Keep both in sync conceptually.
 */
#ifndef MUSLBOX_SAFE_PATH_H
#define MUSLBOX_SAFE_PATH_H

int safe_path(const char *s);

#endif /* MUSLBOX_SAFE_PATH_H */
