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
```

All DNS input is validated (`[a-zA-Z0-9.:_-]` only) before being written, so a
malformed DHCP response cannot inject shell syntax into `resolv.conf`.

## Resolver handling

- `/etc/resolv.conf` is always replaced **atomically** via `mktemp` + `mv`,
  mode `0644`. Readers never observe a half-written file.
- The image ships `/etc/resolv.conf.default` (1.1.1.1, 8.8.8.8). The udhcpc
  event script restores it on `deconfig`, so a lost lease cannot leave the
  system with a stale resolver.
- The `bound`/`renew` script writes `domain` (when supplied) and all `dns`
  servers, and ignores invalid entries.

## DHCP and reconnect

Boot runs `network:once:/bin/sh -c "... sane-net dhcp eth0"` from
`/etc/init.conf`. `sane-net dhcp` brings the link up and starts
`udhcpc -b -R` with `-s /usr/share/udhcpc/default.script`, storing the pid in
`/run/udhcpc-<iface>.pid`.

`sane-net reconnect IFACE [SECONDS]` polls the link for carrier, bringing it
up each iteration, then restarts DHCP. It fails closed with a clear error if
no carrier appears within the limit (default 30 s).

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

`static` fails closed when `ip addr add` or `ip route add` fails (idempotent
checks prevent false failures on repeated runs). `dns default` restores the
baseline through the same atomic `mktemp` + `mv` path as all other resolver
writes.

## Testing

`scripts/test-network.sh` (55 assertions) stubs `ip`, `udhcpc`, `curl`, and
`wpa_supplicant` through `PATH` and redirects all writable paths into a temp
root, so no host network or host `/etc` is touched. It is wired into
`make test`, `make test-network`, and CI.
