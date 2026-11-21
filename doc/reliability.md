# Reliability (Phase C)

Phase C adds a fail-closed reliability toolkit for S.A.N.E target roots
selected by an absolute `--root DIR`. It is usable host-side/build-time
(like `spm` payload construction) **and** at runtime: the target image
installs a `reliability:once` boot service that runs journal-driven
`recover` before user services (see *Runtime recovery boot service*). The
tool is POSIX `sh`. `--root` is canonicalized at entry to a physical
directory with `cd -P` + `pwd` (no `realpath` dependency): symlinked roots
resolve to their canonical target, and a root that does not exist yet —
including a dangling symlink root — is resolved through its nearest
existing ancestor (symlink components of the remaining tail are expanded
with bounded readlink hops) so `init` can create it. Nothing is created
during canonicalization itself, so malformed commands still fail before
any write. Snapshot and upgrade commands have no dependencies beyond
coreutils and `sha256sum`; `net-recover` additionally resolves `sane-net`
through `PATH` and passes `SANE_ROOT="$ROOT"` explicitly to both network
subcommands. An unset `SANE_ROOT` makes `sane-net` default to `/`;
consequently, host paths under `/etc` are selected only when the effective
target root is `/`.

State lives under the target root:

| Path | Purpose |
|---|---|
| `/var/lib/sane/reliability/snapshots/<tag>/` | Verified state snapshots |
| `/var/lib/sane/reliability/staging/` | Reserved for staged payloads |
| `/var/lib/sane/reliability/journal` | Upgrade/recovery state (`0600`) |
| `/var/lib/sane/reliability/lock/` | Command exclusion lock (holder `pid` file) |
| `/var/log/sane/reliability.log` | Structured event log (rotated at 64 KiB) |

## Commands

```
sane-reliability [--root DIR] init
sane-reliability [--root DIR] snapshot TAG [--force]
sane-reliability [--root DIR] list
sane-reliability [--root DIR] verify TAG
sane-reliability [--root DIR] rollback TAG
sane-reliability [--root DIR] upgrade PAYLOAD_DIR
sane-reliability [--root DIR] recover
sane-reliability [--root DIR] net-recover [--iface IFACE]
sane-reliability [--root DIR] log LEVEL MESSAGE
sane-reliability [--root DIR] backup ARCHIVE [--force]
sane-reliability [--root DIR] restore ARCHIVE
```

### Snapshots

`snapshot` captures the identity/config files (`/etc/passwd`, `/etc/group`,
`/etc/shadow`, `/etc/doas.conf`, `/etc/init.conf`, `/etc/fstab`,
`/etc/hostname`) plus the whole `/var/lib/spm` package database. Every captured
file is listed in `manifest.sha256` with a SHA-256 digest; `meta` records the
UTC creation time. Tags accept `[A-Za-z0-9._-]`, max 64 chars, may not
start with `-`, and may not be `.` or `..` (whole-dot tags can never be
installed by the snapshot swap renames). The `.tmp.*` and `.old.*` prefixes
are the internal staging/aside namespaces and are also rejected as user tags
(up front, including with `--force`), so no user tag can collide with
crash-window residue. Dot-prefixed tags such as `.hidden` are legal, are
written into the snapshot directory, verify and roll back like any other tag,
and are shown by `list`. Overwriting an existing tag requires `--force`.

Symlinks are preserved, not dereferenced: a symlink among the identity/config
files, inside the `spm` database, or at a pre-upgrade payload target path is
recorded in a `symlinks` metadata file at the snapshot root (two lines per
entry: the relative path, then the verbatim `readlink` target). The metadata
is a regular file, so it is hashed into `manifest.sha256` and protected by
`verify`. Dangling symlinks are recorded too. `rollback`/`recover` recreate
each recorded symlink after the regular files are installed (see *Rollback
and safety snapshots*).

The manifest writer and verifier share one grammar: GNU `sha256sum` escapes
filenames containing backslash or newline with a leading backslash, which the
path verifier rejects. Rather than writing a manifest that could never
verify (a permanently dead snapshot), `snapshot` refuses such names
fail-closed with a clear error, removes its staging directory, and leaves
existing state untouched. Legal-but-unusual names (for example spaces) still
roundtrip through snapshot, verify and rollback.

`verify TAG` re-checks every manifest entry before a snapshot is used. A
corrupt or incomplete snapshot is never applied — `rollback`, `upgrade` and
upgrade recovery through `recover` all call this check first (fail-closed).
Manifest paths are validated
before hashing or applying: absolute paths and any `..` component are rejected.
After one conventional leading `./` is stripped, whole `.` components (including
`a/./b`, a second leading `./`, or trailing `/.`) and empty components such as
`a//b` are also rejected as non-canonical spellings. They are not normalized
before validation; both validation and installation use the same relative
string, so a crafted manifest cannot write outside the target root or bypass
lexical protected-path checks. Manifests are NUL-delimited internally, so
filenames containing spaces are handled correctly.

### Rollback and safety snapshots

`rollback TAG` first creates an `auto-pre-rollback-<UTC>` snapshot of the
current state, then restores every manifest entry atomically (stage with
`mktemp` in the destination directory, `cp -p`, `rename(2)`), preserving file
modes. After the regular files (and `new-files` deletions), every symlink
recorded in the snapshot's `symlinks` metadata is recreated with `ln -s`,
preserving type and target verbatim. Each recreation is validated fail-closed:
the path must pass the relative-path grammar and destination symlink
containment, and the target must resolve inside the target root — absolute
targets must normalize under the root, relative targets resolve against the
link's directory, and the resolved target's own components are walked too, so
an internal-looking first hop cannot chain out of the root. Escaping targets
are rejected before anything is written; internal targets (including dangling
ones) are allowed. The journal records `state=rolled-back` and the tag used.
Safety tags get a numeric suffix on collision, so two rollbacks in the same
second never clash. `--force` swaps snapshots via rename-aside/install/delete
rather than deleting first, so a failed move cannot destroy the previous
snapshot.

### State lock and crash-window self-heal

**All commands** (`init`, `list`, `verify`, `log`, `snapshot`, `rollback`,
`upgrade`, `recover`, `net-recover`, `backup`, `restore`) serialize on an
atomic `mkdir` lock at `var/lib/sane/reliability/lock`, acquired once at the
top-level command entry. Every command writes or auto-initializes state, so
all writes happen under the lock; the read commands `list` and `verify` may
block up to the lock timeout while a mutator holds it. The holder writes its
PID to `lock/pid`. Acquisition retries every 0.1 s and fails closed after 30 s
(`timed out waiting for reliability lock`); the
`SANE_RELIABILITY_LOCK_TIMEOUT` environment variable overrides the timeout in
seconds for tests — the production default stays 30 s. The auto-init behavior
of `list`, `verify` and `log` is unchanged: they still create the state
directories on a fresh root, now under the lock.

Nested mutator calls inside one process (`recover` invoking the network
recovery internally, `rollback`/`upgrade` invoking the snapshot helper)
reuse the held lock: the lock is reentrant by PID, and only the top-level
acquisition owns the EXIT-trap release. The lock is released on every exit
path (success, `die`, `set -e` abort, HUP/INT/TERM) and only while
`lock/pid` still equals the exiting process's PID. A SIGKILLed holder
leaves the lock behind; that is what stale detection is for.

Stale locks: if `kill -0` on the recorded PID fails (dead or garbage PID),
the lock is stolen by atomically renaming it to `lock.stale.<pid>` and
removing the aside; a process that loses the rename race loops and
re-evaluates. A lock without a PID file gets a 1 s grace window (the holder
may be between `mkdir` and the PID write) before it is treated as crash
residue and stolen. Limits: stale detection is `kill -0` based, so a
**reused PID** of a dead holder can look alive and delay acquisition up to
the timeout — fail-closed, and a live same-user holder's lock is never
wrongfully stolen. `kill -0` also fails with `EPERM` across users, so the
tool assumes single-user/root operation on the state it protects.

Crash-window self-heal: `snapshot --force` swaps via rename-aside /
install / delete with a **deterministic** aside name `.old.<tag>` (the tag
is validated, so it is filename-safe). A crash between the two renames
would otherwise lose the old snapshot, so every lock acquisition — every
command, including `recover`, the boot path — first runs
`heal_snapshot_swaps`: for each `.old.<tag>`, if the live tag is missing the
aside is renamed back; if the live tag exists the aside is redundant and
removed. Orphaned `.tmp.*` staging directories are removed too — the
exclusive lock guarantees they belong to no live writer. Because read
commands now take the lock as well, a `list` or `verify` heals crash residue
exactly like a mutator (and releases the lock again on exit).

### Upgrades and recovery

An upgrade payload is a directory containing the files to install and a
`manifest.sha256` generated with `sha256sum` from inside that directory:

```
(cd payload && find . -type f ! -name manifest.sha256 -print0 \
    | LC_ALL=C sort -z | xargs -0 -r sha256sum > manifest.sha256)
```

`upgrade PAYLOAD_DIR`:

1. reads the payload manifest **once** into a staged copy under
   `var/lib/sane/reliability/staging/` and verifies it (fast-fail
   `payload integrity check failed`), rejecting any destination that would
   traverse a symlink escaping the target root (see *Symlink containment*).
   Every later consumer — validation, the path-list builder and the apply
   loop — reads that same staged copy, so a same-user writer swapping
   `payload/manifest.sha256` after the pre-check cannot redirect the upgrade
   (the staged copy is removed on every exit path),
2. takes an automatic `auto-pre-upgrade-<UTC>` snapshot covering **every
   payload target path** in addition to the identity/config files and the
   `spm` database: target files that already exist are copied into the
   snapshot (symlink targets are recorded in the `symlinks` metadata), and
   target files that do not yet exist are recorded in a `new-files` list
   inside the snapshot,
3. writes `state=in-progress` plus that tag to the journal,
4. installs each payload file atomically (installation is **not** restricted
   to the identity/config files). Immediately before each copy the payload
   file is **re-hashed** and compared against the staged manifest, and the
   destination symlink containment is re-checked: a file changed after the
   pre-check aborts the upgrade (`payload changed during upgrade`) and the
   recorded snapshot is restored. After `cp` into the private `.sane-rel.*`
   temp file, that **staged copy is hashed again** against the manifest hash,
   the temp file is removed on mismatch (`recover_internal` +
   `payload changed during upgrade`), and only a verified copy is renamed
   into place — so a writer racing the source between the hash and the copy
   cannot install unverified bytes,
5. writes `state=done` and logs the rollback tag.

Fault injection (tests only): `SANE_RELIABILITY_FAULT=payload-swap` fires
after the pre-check and before the apply loop, appending bytes to one payload
file to simulate a same-user writer racing the upgrade; the verify-at-use
re-hash must catch it and recover. `SANE_RELIABILITY_FAULT=payload-swap-late`
fires inside the apply loop **after** the source re-hash and **before** `cp`,
so the post-copy staged-copy hash is the gate that catches it. Both hooks
follow the `sane-net` `SANE_NET_FAULT` pattern: exact string match against the
environment variable, a complete no-op for any other value or when unset, and
they write only into the payload directory — never into tool state.

If any step fails, the recorded snapshot is restored immediately. `rollback`
and `recover` restore every snapshot file **and delete the `new-files`** the
upgrade introduced, so the filesystem and the `spm` database stay consistent
with the pre-upgrade state. New-file deletion honours symlink containment. On
the next boot (or manually), `recover` re-reads the journal: `in-progress` with
a snapshot tag triggers an automatic upgrade rollback and sets
`state=recovered`; network `net-in-progress` follows the separate retry flow
below. `done`, `idle`, `rolled-back` and `recovered` are no-ops.

Self-state protection: an upgrade payload may not target the reliability
state itself (`var/lib/sane/reliability/`, including the journal and
snapshots) or the tool binary (`usr/bin/sane-reliability`). Such a payload
is rejected with a specific error before any file is written — no safety
snapshot, no journal change, no partial install. The restriction applies to
**payload targets only**; the internal pre-upgrade snapshot mechanism (the
extra target list and `new-files` recording) is deliberately not blocked.

### Symlink containment

Manifest path validation is textual (no absolute paths, no `..`), but a
destination can still escape the target root through a symlinked directory
component. Before any write, `upgrade`, `rollback` and `recover` walk **every
component** of each destination path under `--root`. Each component that is a
symlink is resolved with `readlink` (chains are followed with a bounded hop
count, and `.`/`..` are collapsed with pure POSIX parameter expansion — no GNU
`realpath` dependency, so the behaviour is identical on the BusyBox runtime).
If any resolved path leaves the target root, the operation is rejected
fail-closed and nothing is written. Symlinks that resolve **inside** the target
root remain allowed. The same containment check guards `new-files` deletion so
a rollback never removes a file through an escaping symlink.

### Network recovery

`net-recover [--iface IFACE]` recovers DNS and connectivity independently of an
upgrade snapshot. The interface defaults to `eth0`; the only accepted option
is `--iface IFACE`. Interface names are restricted to at most 15 ASCII
alphanumeric, `_`, `.` or `-` characters and may not start with `-`. Invalid
arguments are rejected before the journal or resolver is changed.

A valid recovery runs in this order:

1. initializes the reliability directories and logs the recovery start;
2. atomically writes `state=net-in-progress` plus `net-iface=IFACE` to the
   journal before changing the resolver, without an upgrade snapshot tag;
3. stages `etc/resolv.conf.default` in the destination directory, applies mode
   `0644`, and atomically renames it to `etc/resolv.conf` under the target root;
4. runs `SANE_ROOT="$ROOT" sane-net reconnect IFACE` through `PATH`;
5. runs `SANE_ROOT="$ROOT" sane-net check IFACE` through `PATH`;
6. writes `state=recovered`, retains `net-iface=IFACE`, and logs completion
   only after both network commands succeed.

`SANE_ROOT` is an inline environment assignment on each individual invocation,
not a global export. It scopes file paths such as resolver configuration, the
DHCP PID file and the udhcpc event script to the target root. It does **not**
virtualize the network stack: `reconnect`, `default.script` and `check` still
operate on the named host interface, including link/address/route operations,
and launch udhcpc. Production use therefore requires real root/network
privileges (for example `CAP_NET_ADMIN`) and an intentionally selected
interface. Tests simulate these operations with PATH stubs and temporary state.
`check` must observe link UP, a global IPv4 address and a default route for
that interface, plus a usable resolver, before recovery can complete.
`check` is authoritative for DNS validity: if the restored default resolver or
the DHCP lease contains an invalid nameserver (a hostname or a malformed IP
address), `check` fails, `net-recover` logs an `ERROR`, and the journal stays
`net-in-progress` with its `net-iface`. `state=recovered` is never written while
DNS is invalid.

A missing or unreadable default resolver, staging/rename failure, failed
reconnect, or failed check produces a nonzero exit and an `ERROR` entry in
`reliability.log`. The journal deliberately remains `net-in-progress` with its
`net-iface` so the operation is visibly unfinished. If either network command
fails, the default resolver has already been restored, but `state=recovered`
is not written. An invalid interface is rejected before entering the
`net-in-progress` state.

Running plain `recover` with `state=net-in-progress` reads and validates the
recorded interface, then invokes `cmd_net_recover --iface IFACE`; it does not
require a snapshot tag. A retry with a working `sane-net` reconnect and check
returns zero and finishes with `state=recovered` and the same `net-iface`.
Missing or invalid recorded interfaces fail without invoking `sane-net`.
For compatibility with the old CLI, a tagless `state=in-progress` journal is
also treated as interrupted network recovery. This is an explicit ambiguity
boundary: a tagless `in-progress` journal could be a legacy network recovery
or an upgrade that lost its snapshot tag, and the tool assumes the legacy
network meaning. `recover` logs a `WARN`
migration, uses the recorded `net-iface` if present (otherwise `eth0`), and
runs `cmd_net_recover`, which rewrites it to the new journal format. When
`net-iface` is absent or empty, it first logs `WARN legacy journal missing
net-iface, defaulting to eth0` before selecting `eth0`; a recorded interface
keeps the migration WARN and is used as-is. A legacy
interface must still pass validation. `in-progress` with a snapshot tag keeps
the existing upgrade rollback path. A modern `net-in-progress` journal without
a valid `net-iface` remains an error; it is never silently defaulted to eth0.

### Runtime recovery boot service

Recovery is no longer host-side only: the target image installs a boot service
that runs journal-driven recovery before user services. The service is
`reliability:once`, defined as:

```
reliability:once:/bin/sh -c '/usr/bin/sane-reliability --root / recover || echo "reliability: recover failed; continuing boot" >&2'
```

with `timeout=0`, which disables ninit's default 30 s once-service timeout so a
slow recovery is not killed mid-transaction.

Ordering: `network:once` and `recovery:once` (account recovery) carry
`requires=reliability`; `firstboot` carries `requires=recovery`; `tty1`/console
carry `requires=firstboot`. Consequently `reliability` runs **before** network,
account recovery, firstboot and getty.

Failure behaviour: ninit marks a once service `FAILED` on a nonzero exit and
cancels its transitive dependents, so the wrapper deliberately exits `0` even
when `recover` fails, emitting `reliability: recover failed; continuing boot`
to stderr. Boot therefore continues to account recovery/firstboot — a recovery
failure must **not** lock boot. A successful recovery is logged by
`sane-reliability` itself (`INFO ... recovered`); a failure is logged `ERROR` in
`/var/log/sane/reliability.log` in addition to the wrapper's stderr line.

#### Spawn-failure boundary

The fail-open wrapper guards the **exit code** of `recover`, not the spawn
of the service itself. If the reliability service cannot be spawned at all
(for example `/bin/sh` cannot be executed), ninit marks `reliability`
`FAILED` and cancels its transitive dependents — including `network`,
`recovery`, `firstboot` and the getty/console chain. ninit's rescue mode
covers configuration failures (broken config, missing dependencies,
cycles), not runtime spawn failures. This boundary is accepted: a broken
`/bin/sh` would also fail getty directly, so the console would be
unavailable regardless of where the reliability service sits in the graph.

Install: `/usr/bin/sane-reliability` is installed mode `0755` by
`build-rootfs.sh`, `make-image.sh` and `sane-install.sh` (the latter two use
`$SUDO`). This complements the existing ninit rescue-shell contract documented
in [boot-pipeline.md](boot-pipeline.md#7-failure-recovery--rescue-shell-contract).

### Logging

`log INFO|WARN|ERROR "message"` appends
`<UTC timestamp> <LEVEL> <message>` to `/var/log/sane/reliability.log` (mode
`0644`). When the log reaches 64 KiB it is rotated to `.1` before the new
entry is written. Reliability commands log their own lifecycle events.

### Backup and restore

`backup ARCHIVE.tar.gz` archives the reliability state and log directory from
the target root; it refuses to overwrite unless `--force` is given. The
state lock is process-local runtime state, never backup material. Backup
therefore enumerates the persistent members **explicitly**:
`var/lib/sane/reliability/snapshots`, `var/lib/sane/reliability/staging`,
`var/lib/sane/reliability/journal` and `var/log/sane`. `lock/` and
`lock.stale.*` are excluded by construction, so a restore can never
resurrect a holder PID (possibly reused by an unrelated process) in another
root. All four members exist because backup calls `init` first. This is also
the reason for enumeration instead of an exclusion pattern: the shipped
BusyBox tar (v1.37.0, Ubuntu 1:1.37.0-7ubuntu1 build) supports neither
`--exclude` nor `-X`, so an exclusion-pattern backup fails at runtime on the
target while passing host-side GNU tar tests. **Constraint:** every future
persistent state path must be added to this member list in `cmd_backup` AND
to this paragraph; omitting it silently excludes that state from backups.
Trust boundary: `ARCHIVE` is an operator-controlled host path, intentionally
**not** confined to `--root` — it may legitimately live outside the target
root. Backup/restore are administrative, root-only operations in production;
the archive path is trusted operator input, while the archive *content*
remains fully validated.

`restore` extracts to a temporary directory and rejects absolute/traversal
member names. Archives made by old tool versions still carry `lock/` entries:
restore does not reject them — it strips every `lock*` entry from the staging
directory right after extraction, before validation and install. The live
restore lock lives under the target root (not staging), so it is untouched
and released normally on exit; the next mutator acquires the lock immediately
instead of waiting on an archived PID. Restore then walks every symlink chain
with a bounded hop count (40) against the staging root: absolute targets and
chains resolving outside the staging root are rejected fail-closed before
anything is installed, while internal relative chains (including `..` that
normalizes back inside the staging root) are allowed. It then verifies every
snapshot manifest inside the archive and copies the state and logs into the
target root.

Restore **resets the journal**: after the copy it forces `state=idle`
(state only, no snapshot tag or interface), never trusting the archived
journal. Consequence: an archive captured mid-upgrade carries a legitimate
`state=in-progress` + `snapshot=X`, and restore **discards that in-progress
state** — the next `recover` is a no-op and snapshot X is never applied.
Restore is therefore **not** a mid-upgrade operation; use `rollback` or
`recover` to finish or undo an interrupted upgrade.

## Testing

`scripts/test-reliability.sh` exercises every command against a temporary
target root (no root privileges, no host state touched). Its assertions cover
snapshot integrity, force semantics, tag validation, mode-preserving rollback
with safety snapshots, payload verification and path traversal, destination
symlink containment (escaping top-level/nested/root-component/chain symlinks
rejected with nothing written outside the root, internal-root symlinks allowed),
pre-upgrade snapshot completeness and `new-files` deletion on rollback/recover
including a mid-transaction failure, journal-driven
recovery, network resolver recovery and reconnect failures, log levels and
rotation, and backup/restore validation. Network recovery is tested both with
controlled `sane-net` stubs and with the real repository `sane-net`, using only
`ip`, `udhcpc` and `sleep` stubs. The udhcpc stub parses `-s` and executes the
real root-aware `default.script` for a lease event; the suite verifies target
DNS/domain installation, event address/route mutations and real `deconfig`
restoration of the default resolver. The integration also checks per-interface IPv4/default
route queries, target-resolver recovery, before/after host resolver SHA-256,
and retry after reconnect or check failures. Legacy journal migration is also
covered. Invalid-DNS regressions prove that a hostname or malformed IP
nameserver blocks `state=recovered`: a strict stub check verifies the
fail-closed journal/log behavior immediately, and a guarded real-integration
case exercises the authoritative `sane-net check` once it validates nameservers
as real IP addresses. `scripts/test-network-fault.sh`
stages all writable paths under another temporary root and uses stubbed network
tools to verify fail-before-side-effect injection, reconnect retry/backoff,
default-resolver restoration after DHCP failures, and connectivity checks.
The reliability suite also covers the state lock (live-holder contention
fails closed within a test-shortened `SANE_RELIABILITY_LOCK_TIMEOUT` for
mutators **and** for `init`/`list`/`verify`/`log`, retry after release, stale
dead/garbage-PID steal, pidless grace steal, no lock left behind on any failed
operation, and the nested `recover` → network recovery path finishing without
self-deadlock), crash-window swap self-heal (injected rename failures between
the two swap moves, manual crash state, redundant-aside discard, orphan
staging cleanup, read commands healing under the lock like mutators), restore
journal-trust and symlink-chain containment, backup/restore lock hygiene
(archive excludes `lock*`, old/crafted archives carrying a live-PID `lock/`
and `lock.stale.*` are accepted but stripped, the next mutator never waits on
an archived PID, contended restore fails closed), symlink preservation
(STATE_FILES, spm DB and payload-target symlinks survive snapshot → upgrade →
rollback with type and target intact; dangling and absolute-internal targets
preserved; crafted escaping targets rejected fail-closed), the shared
manifest grammar (backslash/newline filenames refuse the snapshot cleanly;
spaced names roundtrip), whole-dot tag rejection with `.hidden` still legal,
persistent and listed while the internal `.tmp.*`/`.old.*` namespaces are
rejected even with `--force`, verify-at-use (the
`SANE_RELIABILITY_FAULT=payload-swap` hook aborts and recovers to exact
pre-upgrade bytes, `payload-swap-late` is caught by the post-`cp` staged-copy
hash, other values are no-ops, bad-hash payloads keep the legacy pre-check
contract with zero writes, and a sha256sum-shim manifest swap after the
pre-check cannot redirect the
upgrade), upgrade self-state protection with zero-write assertions, and root
canonicalization (symlinked, dangling-symlink and fresh-leaf roots).
Neither suite changes the host `/etc` or host network state.

Run both suites with:

```
sh scripts/test-network-fault.sh
sh scripts/test-reliability.sh
```

The reliability suite is wired
into `make test`, `make test-reliability`, and CI.

## Scope and boundaries

- The toolkit is usable host-side/build-time (like `spm` payload construction)
  **and** at runtime: the target image installs the `reliability:once` boot
  service that runs `recover` before user services (see *Runtime recovery boot
  service*). It does not replace PID 1 or alter the initramfs boot contract; it
  adds an ordered once-service within the existing ninit pipeline.
- Manual snapshots cover the identity/config files and the `spm` database, not
  arbitrary user data under `/home` or whole disk images. A pre-upgrade snapshot
  additionally covers every payload target path (and records new files for
  deletion on rollback). A full-image rollback is out of scope for Phase C.
- `restore` replaces the reliability state and forces the journal to idle,
  discarding any archived in-progress state (see *Backup and restore*); it
  does not roll back already committed payload files; use `rollback` for
  that.
- All commands are serialized by the state lock; a concurrent command fails
  closed after the lock timeout rather than interleaving writes. Stale
  detection is PID-liveness based and carries the pid-reuse and cross-user
  limits described in *State lock and crash-window self-heal*.
- All destructive operations require an explicit tag, archive, or `--force`;
  malformed inputs fail before any file is modified.
