# Account & Security (Phase A)

This document describes the S.A.N.E Linux account model: identity files,
password management, user lifecycle tooling, and privilege escalation via
`doas`. The core `ninit` PID 1 and `spm` engines remain feature-frozen; this
phase only completes the workstation userspace account layer.

## Default accounts

Provisioned identically by `scripts/build-rootfs.sh`, `scripts/make-image.sh`,
and `scripts/sane-install.sh`:

| Account | UID | GID | Home | Shell | Groups |
|---|---|---|---|---|---|
| `root` | 0 | 0 | `/root` | `/bin/sh` | `root`, `wheel` |
| `sane` | 1000 | 1000 | `/home/sane` | `/bin/sh` | `sane`, `wheel` |

Files and permissions:

| File | Mode | Purpose |
|---|---|---|
| `/etc/passwd` | `0644` | account names, UID/GID, home, shell |
| `/etc/group` | `0644` | groups and supplementary members |
| `/etc/shadow` | `0600` | SHA-512 crypt password hashes |
| `/etc/doas.conf` | `0600`, root:root | privilege escalation policy |
| `/usr/bin/doas` | `4755` root:setuid | escalation utility |

> **Warning:** the shipped passwords are `root` for the `root` account and
> `sane` for the `sane` account (the stored hashes use salts `root` and `sane`
> respectively). With `getty` login enabled and `permit persist :wheel`,
> anyone who reaches a console can log in as `sane` and escalate to root with
> that password. Change **both** passwords on first boot (`passwd`) before
> exposing the machine to any network.

## Password management

- Active passwords are stored as SHA-512 crypt (`$6$<salt>$<hash>`) in
  `/etc/shadow`; `/etc/passwd` only contains the `x` placeholder.
- New accounts are created **locked** (`!` prefix in the shadow hash) and must
  be assigned a password explicitly. A lock marker with no hash cannot be
  removed: `unlock` refuses it and directs the operator to `set-password`
  first, so an empty (passwordless) shadow field can never be produced.
- In-guest: `/bin/passwd` (BusyBox applet, linked in the rootfs) changes the
  current user's password and rewrites `/etc/shadow` with mode `0600`.
- At build time: `scripts/sane-accounts set-password <root> <user> <password>`
  hashes with `openssl passwd -6` using a random 8-byte salt.

## User lifecycle (`scripts/sane-accounts`)

POSIX `sh`, root-agnostic: pass `--root DIR` to operate on a target rootfs. It
never touches the host `/etc` unless `--root /` is given explicitly. Invalid
input is rejected before any file is modified (fail-closed).

```
sane-accounts [--root DIR] init
sane-accounts [--root DIR] add-user NAME [UID] [GROUP]
sane-accounts [--root DIR] del-user NAME [--remove-home]
sane-accounts [--root DIR] set-password NAME PASSWORD
sane-accounts [--root DIR] lock NAME
sane-accounts [--root DIR] unlock NAME
sane-accounts [--root DIR] list
sane-accounts [--root DIR] validate
```

Rules enforced by `add-user`:

- Names must match `^[a-z_][a-z0-9_-]*$`; `root` is reserved.
- UID must be numeric and in `1000..65534`, and must be unique.
- Without an explicit group, a private group with `GID == UID` is created.
  With an existing group, the account is appended to that group's member list.
- The home directory is created as `/home/NAME` with mode `0750`.

`del-user` removes the passwd/shadow entries and all group memberships. The
home directory is removed only with `--remove-home`. Account creation is
transactional: the home directory is created first and any later write failure
rolls back all identity entries.

`validate` audits file existence and modes, numeric and duplicate UIDs/GIDs,
absence of a second UID 0, empty password fields, SHA-512 (or locked) shadow
hashes, the `wheel` group membership, a non-`nopass` `doas.conf` with at least
one `permit` rule, and the setuid bit on `/usr/bin/doas`. It exits non-zero on
any violation and is wired into `make test` and CI
(`scripts/test-accounts.sh`, 63 assertions).

## Privilege escalation (`doas`)

- Policy: `permit persist :wheel` — members of `wheel` may run any command as
  root after entering their password; the credential is cached per session.
- The binary is installed setuid root (`4755`) and the config is `0600`
  root:root. `sane-accounts validate` rejects permissive modes, a missing
  `permit` rule, or any `permit nopass` grant.
- Do not add wildcard `nopass` rules: they defeat the password prompt that
  `login` and `doas` rely on.

## Security boundaries

- `ninit` still runs as PID 1 without dropping root; service commands in
  `/etc/init.conf` are trusted root-authored input.
- Password hashing and account lifecycle tooling are build-time/host-side
  conveniences. They do not add authentication to PID 1 itself.
- Cgroup v2 limits are resource containment, not a process isolation sandbox.
- See [../SECURITY.md](../SECURITY.md) for vulnerability reporting and the
  full threat model.
