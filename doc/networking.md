# Networking (Phase B)

S.A.N.E networking is intentionally userspace-only: `ninit` does not manage
networks. A single POSIX `sh` utility, `/usr/bin/sane-net`, configures
interfaces through the static BusyBox `ip`, `udhcpc`, and `curl` applets.

## Commands

```
sane-net link IFACE [up|down]                 show or set link state
sane-net static IFACE IP/CIDR GW [DNS ...]    static address + DNS
sane-net dhcp IFACE                           start udhcpc (background)
sane-net dns SERVER [SERVER ...]              write /etc/resolv.conf atomically
sane-net dns default                          restore /etc/resolv.conf.default
sane-net wifi IFACE SSID PSK                  WPA2 config + wpa_supplicant
sane-net status [IFACE]                       addresses, routes, DNS
sane-net tls-check URL                        HTTPS check with the CA bundle
sane-net reconnect IFACE [SECONDS]            wait for carrier, restart DHCP
sane-net check [IFACE]                        verify link UP, IPv4, route, DNS
```

All DNS input is validated as a literal IPv4 or IPv6 address before being
written; hostnames, empty strings, and malformed addresses are rejected. This
both prevents a malformed DHCP response from injecting shell syntax into
`resolv.conf` and guarantees that any resolver `sane-net` writes will pass its
own `check` (writer and checker share the same validation).

## Target-root paths

`SANE_ROOT` prefixes every resolver, Wi-Fi configuration, CA-bundle, DHCP pid,
and DHCP event-script path used by `sane-net`. An unset or empty value preserves
the classic absolute paths. `SANE_ROOT=/` does the same, and all trailing slashes
are stripped from every other value, so `SANE_ROOT=/target/` (or `/target///`)
uses paths such as `/target/etc/resolv.conf`, `/target/run/udhcpc-eth0.pid`, and
`/target/usr/share/udhcpc/default.script` without a double slash. This is path
redirection, not a `chroot`; tests use it to keep all file I/O in a temporary root.
A companion test hook, `SANE_PROC` (default `/proc`), lets the fault suite point
the DHCP process-identity reads at a fake process tree so PID-reuse behavior is
exercised deterministically and without privilege.

**Scope:** `SANE_ROOT` redirects *file paths only*. The `ip` link/address/route
mutations and the `udhcpc` client still act on the host's real interfaces, so
`dhcp`, `static`, `wifi`, `reconnect`, and the reliability `net-recover` flow
require the usual network privileges regardless of `SANE_ROOT`. Only the
resolver/pid/config/script files are confined to the target root.

## Resolver handling

- `/etc/resolv.conf` is always replaced **atomically** via `mktemp` + `mv`,
  mode `0644`. Readers never observe a half-written file.
- Both direct resolver writes and default restoration remove their temporary
  file and fail nonzero if `chmod` or `mv` fails, leaving the old resolver in
  place. `dns default` reports the helper's specific error on one line.
- The image ships `/etc/resolv.conf.default` (1.1.1.1, 8.8.8.8). The udhcpc
  event script restores it on `deconfig`, so a lost lease cannot leave the
  system with a stale resolver.
- The `bound`/`renew` script writes `domain` (when supplied) and all `dns`
  servers, and ignores entries that are not valid IPv4/IPv6 addresses. It uses
  the same validation as `sane-net`, so a lease it writes always passes
  `sane-net check` (a hostname nameserver from a DHCP server is dropped).

## DHCP and reconnect

Boot runs `network:once:/bin/sh -c "... sane-net dhcp eth0"` from
`/etc/init.conf`. `sane-net dhcp` brings the link up and starts
`udhcpc -b -R` with `-s /usr/share/udhcpc/default.script`, storing the pid in
`/run/udhcpc-<iface>.pid`.

`sane-net reconnect IFACE [SECONDS]` polls the link for carrier, bringing it
up each iteration, then restarts DHCP. The carrier limit defaults to 30 seconds
and accepts canonical nonnegative decimal values (including `0`); leading-zero
forms such as `00`, `01`, `08`, and `09` are rejected. No carrier within the
limit is a clear, fail-closed error.

Once carrier is up, DHCP is attempted at most 3 times. Before **every** attempt
(including the first, so a client left over from boot is also handled) any
previous client for the interface is stopped. `ROOT/run/udhcpc-IFACE.pid` is
read, and a canonical numeric PID other than the shell's own is considered.
`kill -0` alone is not treated as proof of identity: the PID's executable name
and start time are read from `/proc` and must identify a `udhcpc` process, and
that identity is re-verified immediately before SIGTERM and again before any
SIGKILL escalation, so a reused PID can never redirect a signal at a non-DHCP
process. A verified client is sent SIGTERM, waited on for a bounded interval,
then SIGKILL only if still alive; the attempt proceeds only once that PID is
confirmed gone (otherwise fail closed). A pidfile whose PID is gone, malformed,
self, or reused by a different executable is cleaned without signalling; an
alive but unverifiable client fails closed so no second client is started on
top of it. Every
`udhcpc` exit 0 is followed by a bounded lease post-check: at most 5 polls, one
second apart, for a global IPv4 address and a default route on that interface.
As soon as both appear, the full `sane-net check IFACE` runs. A missing
address/route or failed full check makes that DHCP attempt fail; the default
resolver is restored and a short backoff precedes the next attempt. A resolver
restore failure is itself a hard error, and persistent DHCP/post-check failure
exits nonzero.

`sane-net check [IFACE]` (default `eth0`) accepts no more than one interface
argument. It is IPv4-only and verifies all four of: link UP, a global IPv4
address on the interface, a default route on that same interface, and
`/etc/resolv.conf` containing at least one `nameserver` that is a valid IPv4 or
IPv6 address (the same validation used when writing the resolver), and it rejects
any invalid `nameserver` entry. It exits 0 only when all four hold and prints a
clear message for each failed condition. It does not establish IPv6 connectivity.

## Wi-Fi

`sane-net wifi IFACE SSID PSK` writes `/etc/wpa_supplicant.conf` atomically
with mode `0600`, then starts `wpa_supplicant -B -D wext`. SSIDs are restricted
to `[a-zA-Z0-9._-]` and PSKs must be at least 8 characters. The statically
linked `wpa_supplicant` and `wpa_cli` are built by
`packages/wpa-supplicant/build.sh` (pinned source, SHA-256 verified, musl +
LibreSSL, no `INTERP`) and installed by `build-rootfs.sh` and the package
loops in the image/installer. A missing binary is a hard error rather than a
half-configured interface.

**Limitation:** this recipe enables only the WEXT (`-D wext`) backend.
`nl80211`/`cfg80211` in wpa_supplicant 2.10 needs external `libnl`, which is
not part of this single-tarball recipe, so cfg80211-only adapters are not
supported yet.

## Outbound TLS

`ca-certificates` and static `curl` are installed by `scripts/build-rootfs.sh`.
`sane-net tls-check URL` uses `curl --cacert /etc/ssl/certs/ca-certificates.crt`
so TLS verification never depends on a dynamic CA lookup. A missing CA bundle
or a non-`https://` URL is a hard error.

`static` fails closed when `ip addr add` or `ip route add` fails. Its
idempotency checks query the requested interface, including a default-route
query scoped with `dev IFACE`, so another interface's route cannot suppress a
needed route mutation. `dns default` restores the baseline through the same
atomic `mktemp` + `mv` path as all other resolver writes.

## Fault injection

`SANE_NET_FAULT` lets tests exercise failure paths without a real network.
When it is set to one of the values below, the matching operation fails
closed BEFORE the external tool runs or the resolver is written; any other
value (or an unset variable) never triggers a fault:

| Value | Operation that fails closed |
| --- | --- |
| `ip-link` | any `ip link set` mutation (`link up`/`down`, `static`, `dhcp`, `wifi`, `reconnect`) |
| `ip-addr` | `ip addr add` in `static` |
| `route-add` | `ip route add` in `static` |
| `udhcpc` | the DHCP start in `dhcp` and `reconnect` |
| `resolv-write` | every resolver write/restore, including `dns default` |

Faults are injected before side effects: a faulted operation leaves the
existing `/etc/resolv.conf` untouched and records no `ip`/`udhcpc` call for
the faulted step. The `resolv-write` check lives in the default-restore helper
as well as the direct resolver writer, covering both `dns default` and resolver
restoration during reconnect without a duplicate `cmd_dns` hook.

## Testing

`scripts/test-network.sh` (60 assertions) stubs `ip`, `udhcpc`, `curl`, and
`wpa_supplicant` through `PATH` and redirects all writable paths into a temp
root, so no host network or host `/etc` is touched. It is wired into
`make test`, `make test-network`, and CI.

`scripts/test-network-fault.sh` (137 assertions) uses the same temporary-root
approach for fault injection, cleanup-after-write-failure, DHCP retry/backoff,
bounded and delayed lease post-checks, nameserver validation (valid IPv4/IPv6
accepted; hostnames, malformed and empty values rejected; writer output passes
`check`), DHCP client lifecycle before the first attempt and on retry, and
process-identity/PID-reuse safety (a reused or different-executable PID is never
signalled, identity is re-checked before SIGKILL, and an alive-but-unverifiable
client fails closed) via a fake `SANE_PROC` tree. It also covers reconnect
argument validation and real-binary `SANE_ROOT` coverage. Its real-binary
checks also assert that the host resolver checksum is unchanged.
