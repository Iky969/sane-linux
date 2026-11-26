---
name: Bug report
about: Report reproducible incorrect behavior in ninit, spm, the installer or the image
title: "bug: "
labels: bug
assignees: Iky969
---

## What happened

Describe the observed behavior and what you expected instead.

## Commit and environment

- Commit SHA: `git rev-parse HEAD`
- Host distro / kernel: `uname -a`
- Component: ninit / spm / installer / image / accounts / network / reliability
- Execution context: real hardware / VM (BIOS or UEFI) / chroot+unshare / container
- QEMU mode, if relevant: KVM or TCG (`-cpu max`)

## Reproduction

1. ...
2. ...

## Evidence

- Console or serial log (attach the file, do not paste only a screenshot).
- Relevant `/etc/init.conf`, `/etc/fstab`, or package manifest snippet.
- `readelf`/`strace`/sanitizer output when applicable.

Security vulnerabilities must NOT be filed here — use the private channel in
[SECURITY.md](../../SECURITY.md).
