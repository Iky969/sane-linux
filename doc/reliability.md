# Reliability (Phase C)

Phase C adds a host-side, fail-closed reliability toolkit for S.A.N.E target
roots selected by an absolute `--root DIR`. The tool is POSIX `sh`. Snapshot
and upgrade commands have no dependencies beyond coreutils and `sha256sum`;
`net-recover` additionally resolves `sane-net` through `PATH` and passes
`SANE_ROOT="$ROOT"` explicitly to both network subcommands. An unset
`SANE_ROOT` makes `sane-net` default to `/`; consequently, host paths under
`/etc` are selected only when the effective target root is `/`.

State lives under the target root:

| Path | Purpose |
|---|---|
| `/var/lib/sane/reliability/snapshots/<tag>/` | Verified state snapshots |
| `/var/lib/sane/reliability/staging/` | Reserved for staged payloads |
| `/var/lib/sane/reliability/journal` | Upgrade/recovery state (`0600`) |
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
UTC creation time. Tags accept `[A-Za-z0-9._-]`, max 64 chars, and may not
start with `-`. Overwriting an existing tag requires `--force`.

`verify TAG` re-checks every manifest entry before a snapshot is used. A
corrupt or incomplete snapshot is never applied — `rollback`, `upgrade` and
upgrade recovery through `recover` all call this check first (fail-closed).
Manifest paths are validated
before hashing or applying: absolute paths and any `..` component are rejected,
so a crafted manifest cannot write outside the target root. Manifests are
NUL-delimited internally, so filenames containing spaces are handled correctly.

### Rollback and safety snapshots

`rollback TAG` first creates an `auto-pre-rollback-<UTC>` snapshot of the
current state, then restores every manifest entry atomically (stage with
`mktemp` in the destination directory, `cp -p`, `rename(2)`), preserving file
modes. The journal records `state=rolled-back` and the tag used. Safety tags
get a numeric suffix on collision, so two rollbacks in the same second never
clash. `--force` swaps snapshots via rename-aside/install/delete rather than
deleting first, so a failed move cannot destroy the previous snapshot.

### Upgrades and recovery

An upgrade payload is a directory containing the files to install and a
`manifest.sha256` generated with `sha256sum` from inside that directory:

```
(cd payload && find . -type f ! -name manifest.sha256 -print0 \
    | LC_ALL=C sort -z | xargs -0 -r sha256sum > manifest.sha256)
```

`upgrade PAYLOAD_DIR`:

1. verifies the payload manifest,
2. takes an automatic `auto-pre-upgrade-<UTC>` snapshot,
3. writes `state=in-progress` plus that tag to the journal,
4. installs each payload file atomically,
5. writes `state=done` and logs the rollback tag.

If any step fails, the recorded snapshot is restored immediately. On the next
boot (or manually), `recover` re-reads the journal: `in-progress` with a
snapshot tag triggers an automatic upgrade rollback and sets
`state=recovered`; network `net-in-progress` follows the separate retry flow
below. `done`, `idle`, `rolled-back` and `recovered` are no-ops. This is the
host-side counterpart of the existing ninit rescue-shell contract documented
in [boot-pipeline.md](boot-pipeline.md#7-failure-recovery--rescue-shell-contract).

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
also treated as interrupted network recovery: `recover` logs a `WARN`
migration, uses the recorded `net-iface` if present (otherwise `eth0`), and
runs `cmd_net_recover`, which rewrites it to the new journal format. When
`net-iface` is empty, it first logs `WARN legacy journal missing net-iface,
defaulting to eth0` before selecting `eth0`; a recorded interface keeps the
migration WARN and is used as-is. A legacy
interface must still pass validation. `in-progress` with a snapshot tag keeps
the existing upgrade rollback path. A modern `net-in-progress` journal without
a valid `net-iface` remains an error; it is never silently defaulted to eth0.

### Logging

`log INFO|WARN|ERROR "message"` appends
`<UTC timestamp> <LEVEL> <message>` to `/var/log/sane/reliability.log` (mode
`0644`). When the log reaches 64 KiB it is rotated to `.1` before the new
entry is written. Reliability commands log their own lifecycle events.

### Backup and restore

`backup ARCHIVE.tar.gz` archives the reliability state and log directory from
the target root; it refuses to overwrite unless `--force` is given. `restore`
extracts to a temporary directory, rejects absolute/traversal member names and
absolute or escaping symlinks, verifies every snapshot manifest inside the
archive, then copies the state and logs into the target root.

## Testing

`scripts/test-reliability.sh` exercises every command against a temporary
target root (no root privileges, no host state touched). Its assertions cover
snapshot integrity, force semantics, tag validation, mode-preserving rollback
with safety snapshots, payload verification and path traversal, journal-driven
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
Neither suite changes the host `/etc` or host network state.

Run both suites with:

```
sh scripts/test-network-fault.sh
sh scripts/test-reliability.sh
```

The reliability suite is wired
into `make test`, `make test-reliability`, and CI.

## Scope and boundaries

- The toolkit is host-side/build-time, like `spm` payload construction. It does
  not add a new PID 1 service and does not alter the initramfs boot contract.
- Snapshots cover configuration and the `spm` database, not arbitrary user
  data under `/home` or whole disk images. A full-image rollback is out of
  scope for Phase C.
- `restore` replaces the reliability state but does not roll back already
  committed payload files; use `rollback` for that.
- All destructive operations require an explicit tag, archive, or `--force`;
  malformed inputs fail before any file is modified.
