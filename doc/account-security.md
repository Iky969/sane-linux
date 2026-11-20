# Account & Security (Phase A)

This document describes the S.A.N.E Linux account model: identity files,
password management, user lifecycle tooling, first-boot credential setup, and
privilege escalation via `doas`. The core `ninit` PID 1 and `spm` engines
remain feature-frozen; this phase only completes the workstation userspace
account layer.

## Default accounts

`scripts/provision-accounts.sh` is the **single source of truth** used by
`build-rootfs.sh`, `make-image.sh`, and `sane-install.sh`:

| Account | UID | GID | Home | Shell | Groups |
|---|---|---|---|---|---|
| `root` | 0 | 0 | `/root` | `/bin/sh` | `root`, `wheel` |
| `sane` | 1000 | 1000 | `/home/sane` | `/bin/sh` | `sane`, `wheel` |

Files and permissions:

| File | Mode | Purpose |
|---|---|---|
| `/etc/passwd` | `0644` | account names, UID/GID, home, shell |
| `/etc/group` | `0644` | groups and supplementary members |
| `/etc/shadow` | `0600` | SHA-512 crypt password hashes (or `!` when locked) |
| `/etc/doas.conf` | `0600`, root:root | privilege escalation policy |
| `/usr/bin/doas` | `4755`, root:root | escalation utility |
| `/usr/bin/sane-accounts` | `0755` | account lifecycle CLI installed on the system |
| `/usr/bin/sane-firstboot` | `0755` | first-boot credential helper |

> **No public password ships in a distributed image.** Both accounts are
> created locked (`!` with no hash) and `/etc/.sane-firstboot-done` is absent.

## First-boot credential setup

`/etc/init.conf` starts `sane-firstboot` as a `once` service on the console;
the `tty1` and serial `console` getty services depend on it via
`:requires=firstboot`. The service line carries `:timeout=0`, which disables
ninit's 30-second `once` timeout so interactive password entry cannot be
killed. The helper:

1. prompts twice (no echo) for the `root` password,
2. prompts twice for the `sane` password,
3. sets both via BusyBox `passwd -a sha512` (which also unlocks the accounts),
4. writes `/etc/.sane-firstboot-done` so later boots skip the prompt.

Nobody can log in before this completes. If reading the console fails, the
service command falls back to a root shell on the console for recovery;
physical/serial console access is already a trusted boundary in this project.

### CI / test exception

`SANE_WEAK_DEFAULT_CREDS=1` makes provisioning write the deterministic
`root`/`root` and `sane`/`sane` hashes and pre-create the first-boot marker.
All GitHub Actions workflows set this flag because the serial-console and
installer tests log in with those credentials. **Never use this flag for an
image intended for distribution.**

## Password management

- Active passwords are stored as SHA-512 crypt (`$6$<salt>$<hash>`) in
  `/etc/shadow`; `/etc/passwd` only contains the `x` placeholder. The
  `validate` command accepts only a *complete* `$6$` hash for an active
  account; a bare `$6$` prefix from an interrupted `passwd`, or another
  algorithm such as `$5$` or `$y$`, is rejected. `sane-account-recovery`
  therefore rebuilds such an active hash with a fresh `$6$` value. This is
  deliberate: the BusyBox-only rootfs ships SHA-512 crypt only. Do not run
  `validate`/`recover` against a rootfs that depends on a different active
  hash algorithm without updating the validator and recovery script first.
- New accounts are created **locked** (`!` prefix) and must be assigned a
  password explicitly. `unlock` refuses a lock marker without a real hash,
  so an empty (passwordless) shadow field can never be produced.
- In-guest: `/bin/passwd` (BusyBox applet, linked in the rootfs) changes the
  current user's password.
- Build-time: the password is read from **stdin**, not from argv, so it never
  appears in a process listing or shell history:
  `printf '%s' 'secret' | sane-accounts --root DIR set-password USER`.

## User lifecycle (`scripts/sane-accounts`)

POSIX `sh`, root-agnostic via `--root DIR`; it never touches the host `/etc`
unless `--root /` is passed explicitly. Fail-closed on invalid input.

```
sane-accounts [--root DIR] [options] <command> [args]

  init [--force] [--firstboot]   write baseline files (refuse to overwrite)
  add-user NAME [UID] [GROUP]    create a locked account + home
  del-user NAME [--remove-home]  remove an account
  set-password NAME              read password from stdin (one line)
  lock NAME | unlock NAME        lock/unlock an account
  list | validate
```

Options: `--force` allows `init` to overwrite an existing account table;
`--firstboot` writes locked accounts with no known hash; `--skip-chown`
suppresses home ownership setting (only for non-privileged test builds);
`--skip-owner-check` relaxes ownership checks in `validate` for unprivileged
test roots.

Rules enforced by `add-user`:

- Names match `^[a-z_][a-z0-9_-]*$`; `root` is reserved.
- UID is numeric, in `1000..65534`, and unique. Without an explicit UID, the
  smallest free id in `1000..65534` is allocated (first-free scan: gaps below
  the maximum are reused, and a high-uid import such as `nobody` at 65534
  cannot exhaust the range). A completely full range is a clean error. The
  same allocation applies to automatically created group ids.
- Without an explicit group, a private group with `GID == UID` is created;
  with an existing group the account is appended to its member list.
- The home is created as `/home/NAME`, mode `0750`, and chowned to `UID:GID`.
  A chown failure is an error, not a silent success.
- Creation is transactional: the home is created first and a later write
  failure rolls back passwd/group/shadow entries (including a differently
  named group) and restores `0644/0644/0600` modes.

`del-user` removes passwd/shadow entries and group memberships. A private
group is retained when another account still uses it as a primary or
supplementary group. `validate` checks modes, ownership of doas files,
numeric/duplicate UIDs and GIDs, absence of a second UID 0, empty password
fields, SHA-512 (or locked) hashes, `wheel` membership, and an effective
`permit ... :wheel` rule with no `nopass`. Wired into `make test` and CI
(`scripts/test-accounts.sh`, 236 assertions; 238 when run as root).

### Recovery semantics (`recover`)

`recover` (and the boot-time `sane-account-recovery` wrapper that calls it)
repairs the identity files **per file, merging instead of rewriting**:

- `doas.conf`: content that passes the policy scan (no `nopass` grant and an
  effective `permit ... :wheel` rule, both bounded by the first `cmd`/`as`
  token) is **preserved**; only the mode (`0600`) and owner (`root:root` when
  run as root) are repaired. Missing or policy-violating content is replaced
  with the baseline `permit persist :wheel`.
- `passwd` / `group`: structurally sound files are **merged** — every
  non-baseline line and membership is preserved, and the baseline entries
  (`root`, `sane`; groups `root`, `wheel`, `sane`) are ensured: fixed in
  place when present, appended when missing, and `wheel` always contains
  `root` and `sane`. Structural corruption (non-numeric uid/gid, duplicate
  ids, a second uid 0, or a non-baseline line occupying a baseline id)
  rebuilds that file from the baseline template and re-appends the
  non-baseline lines that are themselves valid and conflict-free (numeric
  ids `>= 1000`, unique id and name). Conflicting or malformed lines are
  dropped.
- `shadow`: always rebuilt from the locked baseline; still-usable `root` and
  `sane` SHA-512 hashes are restored. Extra accounts' shadow entries are not
  preserved (by design). If either hash is unusable, the first-boot marker
  `/etc/.sane-firstboot-done` is removed so the console setup runs again on
  this boot; otherwise it is (re)written.

`recover` prints one line per file stating whether it was preserved/merged
or rebuilt, followed by the hash/marker summary. Accounts whose passwd lines
were destroyed by the corruption itself cannot be brought back — recreate
them after recovery; their home directories remain on disk. The wrapper also
ensures `awk`/`mktemp` applet links exist for the rebuild: it never clobbers
an existing regular file, creates a link only when the path is absent,
repairs dangling or wrong symlinks, and leaves correct symlinks untouched
(the PR #31 policy).

## Privilege escalation (`doas`)

- Policy: `permit persist :wheel` — after authentication, `wheel` members may
  run any command as root; the credential is cached per session.
- The binary is setuid root (`4755`) and the config is `0600` root:root.
  `validate` rejects wrong modes, non-root ownership, missing or ineffective
  permit rules, and any `permit` rule carrying a `nopass` option token
  before the first `cmd`/`as` terminator OUTSIDE a `setenv { ... }` block
  (e.g. `permit persist nopass :wheel`). A `setenv` block is skipped as a
  whole: names such as `as` or `cmd` inside the braces are environment
  variables, NOT terminators. Therefore `permit setenv { as } nopass :wheel`
  is a real passwordless grant and is rejected, while
  `permit setenv { as } :wheel` is a valid identity rule and is accepted.
  Tokens after a `cmd`/`as` terminator are command arguments, not options:
  `permit :wheel cmd /usr/bin/echo nopass` and
  `permit setenv { as } :wheel cmd /usr/bin/echo nopass` are both valid.
  Comment text and `setenv` values such as `X=nopass` are not grants and
  are accepted. The same scan rules apply to the effective `:wheel` check
  and to `recover`'s decision to preserve `doas.conf`; a valid rule on one
  line cannot mask a nopass grant hidden in a `setenv` block on another.
- Do not add wildcard `nopass` rules: they defeat the password prompt.

## Security boundaries

- `ninit` still runs as PID 1 without dropping root; service commands in
  `/etc/init.conf` are trusted root-authored input.
- The account tooling is separate from PID 1 and `spm`; it does not add
  authentication to init itself.
- Cgroup v2 limits are resource containment, not a process isolation sandbox.
- See [../SECURITY.md](../SECURITY.md) for vulnerability reporting and the
  full threat model.
