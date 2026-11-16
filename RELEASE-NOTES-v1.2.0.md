# S.A.N.E Linux v1.2.0 Release Notes

## 1. Overview
S.A.N.E Linux v1.2.0 is a major milestone release delivering production-grade init lifecycle control, fail-closed privilege drop semantics, a full POSIX-compliant package manager (`spm`) with atomic transactions and hardened archive validation, guest offline installer support for BIOS and UEFI GPT systems, immutable upstream kernel toolchain pinning, and root-owned deterministic initramfs generation.

---

## 2. Core Init System (`ninit` v1.2.0)
- **Interactive cttyhack Console**: Automatic terminal allocation via `cttyhack` on `/dev/console` for reliable interactive root shells across serial, virtual, and physical consoles.
- **Fail-Closed Privilege Drop Parser**:
  - Secure `:user=` and `:group=` directives in service declarations (`/etc/ninit.services`).
  - Resolves user and group identities via `/etc/passwd` and `/etc/group` with support for both symbolic names and numeric IDs.
  - Enforces strict privilege drop to unprivileged credentials prior to executing service payloads, failing closed on unknown users/groups or permission errors.
- **`sane-ctl` IPC Lifecycle Control via `/run/initctl`**:
  - Unified command-line utility to control daemon lifecycles: `start`, `stop`, `restart`, `status`, and `reload`.
  - Non-blocking FIFO IPC protocol on `/run/initctl` with state tracking in `/run/ninit-<service>.state`.
  - Synchronous polling loops with 5-second timeouts and deterministic exit codes.
- **Stop Grace Period Escalation**:
  - Main loop timer sweep tracking monotonic start timestamps (`stop_t0`) for stopping services.
  - Automatic escalation to `SIGKILL` and cgroup process termination (`cgroup_kill_service`) when a service process group does not terminate within its configured grace window (`:grace=N`).
- **`sane-net` Utility**: Lightweight network configuration utility for managing network device state and addressing.

---

## 3. S.A.N.E Package Manager (`spm` 1.2.0)
- **POSIX sh Implementation**: Clean POSIX `/bin/sh` implementation for maximum portability in minimal initramfs and rescue environments without bash dependency.
- **Atomic Staged Deployment**:
  - Isolated staging area (`/var/lib/spm/staging/tx-*`) unpacked and validated before modifying the live filesystem.
  - Atomic replacement via `rename(2)` (`mv -f`), avoiding Linux `ETXTBSY` ("Text file busy") when replacing active running daemon binaries.
- **Archive Security Hardening**:
  - **Pre-extraction inspection**:
    - **Hardlink rejection**: Archive inspection via `tar -tvf` rejects hardlink members (`h...`), failing closed with `die "Archive contains forbidden hard link: ..."`.
    - **Setuid/setgid rejection**: Pre-extraction mode inspection rejects files with setuid/setgid bits (`04000`/`02000`), failing closed with `die "Archive contains forbidden setuid/setgid file: ..."`.
    - **Duplicate archive member rejection**: Verifies uniqueness of archive member paths via `tar -tf`, failing closed with `die "Archive contains duplicate member path: ..."`.
    - **Duplicate manifest rejection**: Checks `.META/files` for duplicate entries, rejecting with `die "Archive metadata .META/files contains duplicate entry: ..."`.
    - **Dependency name validation**: Strict regex validation (`^[a-zA-Z0-9_-]+$`) in both `.META/depends` and manifest `dependencies=`, rejecting paths, slashes, spaces, and shell metacharacters with `die "Invalid dependency name '$dep'"`.
  - **Post-extraction audit**:
    - Recursive audit in staging (`find $STAGING_DIR/x \( -perm -4000 -o -perm -2000 \)`) ensuring zero setuid/setgid binaries exist before commit.
  - **Path traversal & symlink escape guards**: Comprehensive validation against tar-slip attacks (`../`) and forbidden host symlink targets (`/etc/shadow`, `/proc`, etc.).
  - **Cryptographic integrity**: 1:1 bidirectional parity between `.META/files`, `.META/sha256`, and payload files with fail-closed SHA-256 verification.
- **Power-Cut Journal Recovery**:
  - Automatic transaction recovery (`recover_interrupted_journals`) invoked early on exclusive lock acquisition.
  - Scans for leftover `.journal` directories in `/var/lib/spm/staging/tx-*`, rolls back filesystem modifications using backup snapshots, restores package database state, and cleans staging directories.
- **Reverse Dependency & Bottom-Up Removal**:
  - Reverse dependency tracking in `/var/lib/spm/rdeps/` preventing uninstallation of shared libraries or packages required by active dependents.
  - Safe bottom-up pruning of empty directory hierarchies while preserving shared base directories.

---

## 4. Distro Builder, Image Generation & Installer
- **Guest Offline Live Installer (`sane-install.sh`)**:
  - Fully offline, reproducible installation from live environment to target disk.
  - Supports dual BIOS (MBR/GPT via Limine BIOS stage) and UEFI (ESP FAT32 + Limine EFI).
  - Safety guards: verifies target block device is not active root or mounted host volume.
- **Cleanup Safety Guard**:
  - Anti-`rm -rf` guard checking mountpoints (`findmnt` / `/proc/mounts`) before attempting unmount or directory cleanup.
- **Initramfs CPIO Ownership Normalization**:
  - Portable owner reset (`--owner=+0:+0` for GNU cpio, `-R 0:0` for BusyBox cpio) ensuring 100% root:root (UID 0, GID 0) ownership in `initramfs.cpio.gz`.
  - Completely eliminates host builder UID/GID leakage.
- **Immutable Upstream Kernel Toolchain Pinning**:
  - Pinned Alpine Linux netboot kernel and modloop to release `v3.20.10` (`be523954...` and `a6ed1699...` checksums) preventing upstream mirror drift.

---

## 5. Architectural Caveats: ESP /boot (vfat), Symlinks & Cross-Device Links (EXDEV)
- **VFAT / FAT32 Limitation on ESP**:
  - In UEFI systems, the EFI System Partition (ESP) formatted with FAT32 / VFAT is mounted at `/boot` (or `/boot/efi`).
  - **Zero Symlink / Hardlink Support**: The FAT32 filesystem architecture does NOT support POSIX symbolic links or hardlinks. Packages or deployment scripts providing bootloader binaries, kernels, or initramfs images directly inside `/boot` must strictly use regular files.
  - **Cross-Device Rename Failure (`EXDEV`)**: Linux `rename(2)` cannot move files across different filesystem mount boundaries (e.g., from `/var/lib/spm/staging` on ext4 root partition to `/boot` on the ESP vfat partition). The system kernel raises `EXDEV` ("Invalid cross-device link").
  - **Guidance for Package Authors & System Deployers**:
    - Kernel and bootloader installation scripts must perform staging and copy operations within the same filesystem or explicitly handle cross-device copying when updating `/boot`.
    - Never attempt to symlink `/boot/vmlinuz` to a versioned kernel binary on a FAT32 ESP partition.
