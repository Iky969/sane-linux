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
  `/etc/shadow`; `/etc/passwd` only contains the `x` placeholder.
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
- UID is numeric, in `1000..65534`, and unique.
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
(`scripts/test-accounts.sh`, 92 assertions; 94 when run as root).

## Privilege escalation (`doas`)

- Policy: `permit persist :wheel` — after authentication, `wheel` members may
  run any command as root; the credential is cached per session.
- The binary is setuid root (`4755`) and the config is `0600` root:root.
  `validate` rejects wrong modes, non-root ownership, missing or ineffective
  permit rules, and any `permit nopass` grant.
- Do not add wildcard `nopass` rules: they defeat the password prompt.

## Security boundaries

- `ninit` still runs as PID 1 without dropping root; service commands in
  `/etc/init.conf` are trusted root-authored input.
- The account tooling is separate from PID 1 and `spm`; it does not add
  authentication to init itself.
- Cgroup v2 limits are resource containment, not a process isolation sandbox.
- See [../SECURITY.md](../SECURITY.md) for vulnerability reporting and the
  full threat model.
