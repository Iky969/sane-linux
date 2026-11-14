# S.A.N.E Package Format Specification (`.spm.tar.xz`)

*[English](package-format.md)*

This document defines the canonical specification for S.A.N.E Package Manager (`spm`) packages. All packages targeting S.A.N.E Linux must conform strictly to this format to ensure determinism, cryptographic verification, resource-bounded extraction, and fail-closed security.

---

## 1. Package Overview & Extension

S.A.N.E packages are deterministic tar archives compressed using `xz` (LZMA2) or `gzip`.

| Property | Primary Specification | Compatibility Fallback |
|---|---|---|
| **File Extension** | `.spm.tar.xz` | `.spm.tar.gz` |
| **Naming Convention** | `<name>-<version>-<release>-<arch>.spm.tar.xz` or `<name>-<version>-<arch>.spm.tar.xz` | `<name>-<version>-<release>-<arch>.spm.tar.gz` |
| **Compression Algorithm** | XZ (LZMA2) with bounded dictionary | Gzip (Deflate) |
| **Magic Bytes** | `\xfd7zXZ` (Hex: `FD 37 7A 58 5A 00`) | `\x1f\x8b` (Hex: `1F 8B`) |
| **Target Architecture** | `x86_64` (or `all` for architecture-independent packages) | `x86_64` / `all` |
| **Resource Ceiling** | `< 8 MB` decompression RAM (`xz -d`) | `< 1 MB` decompression RAM (`gzip -d`) |

### Example Package Filenames
- `busybox-1.36.1-1-x86_64.spm.tar.xz`
- `ninit-1.1.0-1-x86_64.spm.tar.xz`
- `sane-hello-0.1.0-1-x86_64.spm.tar.xz`
- `limine-static-12.9.6-1-x86_64.spm.tar.xz`

---

## 2. Archive Directory Layout

Every `.spm` package consists of two top-level directories:

```
<pkg-name>-<version>-<release>-<arch>.spm.tar.xz
├── ./x/                          # Payload root directory (maps directly to / on target rootfs)
│   ├── bin/
│   │   └── busybox
│   ├── usr/
│   │   ├── bin/
│   │   │   └── sane-hello
│   │   └── share/
│   │       └── ninit/
│   │           └── services/
│   │               └── sane-hello.service  # Optional declarative service snippet
│   └── etc/
│       └── sane-hello.conf
└── ./.META/                      # Package metadata directory
    ├── package                   # Package manifest (key=value)
    ├── files                     # Normalized file manifest (relative to payload root)
    ├── sha256                    # Cryptographic SHA-256 manifest
    ├── depends                   # Line-separated dependency list (or empty)
    ├── service                   # (Optional) Service configuration descriptor
    └── signature                 # (Reserved for future cryptographic signing)
```

### Invariant Rules for Top-Level Entries
1. **Mandatory Prefix**: Every entry in the archive must begin strictly with `./x/` or `./.META/`.
2. **Forbidden Root Paths**: No archive entry may start with a leading slash `/` or bare path components without the `./` prefix.
3. **No Intermediate Top-Level Entries**: Entries outside `./x/` and `./.META/` (such as `./install.sh`, `./root/`, `./tmp/`) are strictly invalid and will cause immediate package rejection.

---

## 3. Metadata Directory (`./.META/`)

The `./.META/` directory contains all metadata required for dependency resolution, installation tracking, file ownership verification, and integrity auditing.

### 3.1 Package Manifest (`./.META/package`)

The `package` manifest is formatted as POSIX-compliant key-value pairs (`<key>=<value>`), parseable using standard POSIX shell tools (`grep`, `sed`, `awk`) without requiring heavyweight external JSON/YAML parsers.

#### Required & Optional Fields

| Field | Required | Allowed Values / Format | Description |
|---|---|---|---|
| `name` | Yes | `^[a-z0-9][a-z0-9-]*$` | Package name. Lowercase alphanumeric and hyphens only. |
| `version` | Yes | SemVer or upstream string (e.g. `1.36.1`, `0.1.0`) | Upstream package version. |
| `release` | Yes | Integer (e.g. `1`, `2`) | Package build iteration. Defaults to `1`. |
| `arch` | Yes | `x86_64`, `all` | Target machine architecture. |
| `description` | Yes | Single-line UTF-8 string | Human-readable synopsis of package functionality. |
| `dependencies` | No | Comma- or space-separated list of package names | Declared package dependencies (mirrors `./.META/depends`). |
| `base` | Yes | `true` or `false` | Distinguishes core base packages from user packages. |

#### Manifest Example (`./.META/package`)
```ini
name=sane-hello
version=0.1.0
release=1
arch=x86_64
description=Minimal test package for S.A.N.E Linux
dependencies=busybox
base=false
```

#### Base Package Semantics (`base=true` vs `base=false`)
- **`base=true`**: Reserved strictly for foundational distro components (`busybox`, `ninit`, `kernel`, `limine-static`). During initial bootstrap or system provisioning, `spm` allows base packages to claim pre-existing rootfs files that are not yet recorded in `/var/lib/spm/providers`.
- **`base=false`**: Standard user-space applications, utilities, and optional daemons. A package with `base=false` is forbidden from overwriting any file already claimed by another package or pre-existing unmanaged system files without explicit operator override.

---

### 3.2 File Manifest (`./.META/files`)

The `files` manifest records all filesystem entities provided by the package payload.

#### Invariants:
- Paths are normalized and strictly relative to the target root (`/`), with the leading `./x/` prefix stripped.
- Directory paths must end with a trailing slash (`/`).
- Regular files and symlinks do not have a trailing slash.
- Entries must be sorted lexicographically in byte order (`LC_ALL=C sort`).
- Entries must not contain `..` path segments, double slashes (`//`), or leading slashes.

#### Example (`./.META/files`):
```
etc/
etc/sane-hello.conf
usr/
usr/bin/
usr/bin/sane-hello
usr/share/
usr/share/ninit/
usr/share/ninit/services/
usr/share/ninit/services/sane-hello.service
```

---

### 3.3 Checksum Manifest (`./.META/sha256`)

The `sha256` manifest records cryptographic SHA-256 digests for all regular files inside `./x/`.

#### Format:
Standard Coreutils / BSD `sha256sum` format: `<64-character-hex-hash>  <relative_path>` (separated by two spaces).

#### Invariants:
- The path corresponds to the normalized path listed in `./.META/files`.
- Directories and symlinks are excluded from `sha256` (symlink targets are verified via the tar archive header, and directories are filesystem structures).
- Verification is **fail-closed**: every regular file unpacked must match its recorded SHA-256 digest exactly before installation is committed. Any mismatch halts installation immediately with zero writes committed to persistent state.

#### Example (`./.META/sha256`):
```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  etc/sane-hello.conf
8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4  usr/bin/sane-hello
b5bb9d8014a0f9b1d61e21e796d78dccdf1352f23cd32812f4850b878ae4944c  usr/share/ninit/services/sane-hello.service
```

---

### 3.4 Dependency List (`./.META/depends`)

Contains one dependency package name per line. Empty or omitted if the package has no dependencies.

#### Example (`./.META/depends`):
```
busybox
ninit
```

---

## 4. Payload Directory (`./x/`) & Symlink Rules

The `./x/` directory represents the payload root. When extracted by `spm`, `./x/usr/bin/sane-hello` maps directly to `/usr/bin/sane-hello` on the target system.

### 4.1 BusyBox Applets & Absolute Symlinks

S.A.N.E relies on a static BusyBox binary (`/bin/busybox`) providing over 400 Unix applets (`/bin/sh`, `/bin/ls`, `/usr/bin/env`, etc.). These applets are created as symlinks pointing to `/bin/busybox` or `busybox`.

To support standard Linux distributions and BusyBox packages:
1. **Absolute Symlink Targets are Permitted**: A symlink entry whose target is an absolute system path within the target root (e.g. `./x/bin/sh -> /bin/busybox` or `./x/usr/bin/cut -> /bin/busybox`) is **explicitly valid**.
2. **Relative Internal Symlink Targets are Permitted**: Internal relative symlink targets (e.g. `./x/bin/sh -> busybox` or `./x/usr/bin/vi -> ../../bin/busybox`) that resolve inside the payload boundaries are **valid**.

### 4.2 Strict Prohibition: Path Traversal & Escape

Security against malicious archives (anti-tar-slip) is strictly enforced:

1. **Relative Path Traversal Prohibited**: No archive entry name (file, directory, or symlink name) may contain `..` directory traversal components (e.g. `./x/bin/../../etc/shadow` is strictly banned).
2. **Symlink Escape Banned**: Symlinks must never point to files outside the target system root, and no directory symlink may redirect subsequent archive extractions outside the destination directory.
3. **Leading Root Slashes Banned**: Archive member names must not start with `/`.

### 4.3 Anti-Traversal Extraction Guard Contract

During package extraction, `spm` and packaging tools must enforce the following security invariant:

> **Extraction Guard Rule**: `spm` MUST NEVER follow pre-existing symlinks on the host/guest filesystem during extraction, nor extract through any symlink that points outside the destination root directory.

#### Extraction Implementation Rules:
- When extracting into a destination root (`$DESTDIR` or `/`), `spm` must either:
  1. Extract into an isolated staging directory (`/var/lib/spm/staging/<txid>/`) and audit resolved canonical paths before committing; OR
  2. Use `tar -x` with `--no-same-owner` and path validation, or invoke `symlink(2)` and `open(2)` with `O_NOFOLLOW | O_EXCL` flags.
- If a destination path already exists as a symlink pointing outside `$DESTDIR`, extraction must abort immediately (**fail-closed**), raising a security error.

---

## 5. Compression Parameters & Resource Ceiling

S.A.N.E is designed for extreme resource efficiency, guaranteeing full operation within a **< 30 MB RAM envelope**.

### 5.1 Memory Ceiling (< 8 MB RAM)

Standard `xz` compression using default high presets (such as `-9` or dictionary sizes >= 32 MB) requires 32 MB to 64 MB of RAM just to decompress, which exceeds the entire memory budget of S.A.N.E.

Therefore, `.spm.tar.xz` packages must be compressed with bounded dictionary sizes:
- **Maximum Decompression Memory**: `< 8 MB RAM`.
- **Target Dictionary Size**: `<= 4 MiB` (e.g. `-D 4MiB` or preset `-6e` with bounded memory options).
- **BusyBox Compatibility**: BusyBox `unxz` / `tar -J` dynamically allocates dictionary buffer based on the stream header. Bounding the dictionary to 4 MiB guarantees decompression memory remains below 8 MiB in user-space.

### 5.2 Deterministic Tar Packing Contract

To ensure 100% byte-for-byte reproducible package builds across different hosts and environments:

```bash
# Recommended deterministic tar command
tar \
  --sort=name \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  --mtime="@${SOURCE_DATE_EPOCH:-0}" \
  --mode="go=rX,u+rw,a-s" \
  -cf "$PKG_TAR" \
  ./.META ./x

# Bounded xz compression (< 8 MB decompression memory)
xz -T0 -6e --memory-calc --memory-limit=8MiB "$PKG_TAR"
# Or using dictionary ceiling:
# xz -T0 --lzma2=dict=4MiB "$PKG_TAR"
```

#### Determinism Invariants:
1. **Sorted File Order**: Archive members are strictly sorted by filename (`--sort=name`).
2. **Normalized Ownership**: UID 0 and GID 0 (`root:root`) with `--numeric-owner`.
3. **Clamped Timestamps**: Timestamps clamped to `SOURCE_DATE_EPOCH` (or Unix epoch `@0`).
4. **Standard Permissions**: Directories set to `0755`, executables to `0755`, regular files to `0644`.

---

## 6. Service Integration with `ninit`

Packages may provide declarative service definitions for `ninit`:

1. **Service File Location**: `./x/usr/share/ninit/services/<name>.service`
2. **Metadata Link**: Optional `./.META/service` referencing the service file.
3. **Service File Format**:
   ```
   <name>:<mode>:<command>[:requires=<dependencies>][:memory_max=<mem>][:cpu_max=<cpu>][:pids_max=<pids>][:timeout=<sec>]
   ```
   Example:
   ```
   sane-hello:once:/usr/bin/sane-hello:memory_max=8M:timeout=10
   ```
4. **Lifecycle**: Upon installation, `spm` appends or links the service definition into the system configuration (`/etc/init.conf` or `/etc/init.conf.d/`). Upon package uninstallation, `spm` sends IPC commands to `ninit` via `/run/initctl` to stop the service before removing binaries.

---

## 7. Package Verification Checklist

A valid `.spm.tar.xz` archive must pass all tests in the verification pipeline:

- [ ] Archive expands to exactly two top-level directories: `./x/` and `./.META/`.
- [ ] No path contains `..` components or starts with a bare `/`.
- [ ] `./.META/package` contains valid `name`, `version`, `release`, `arch`, `description`, and `base`.
- [ ] `./.META/files` matches all payload files in `./x/` exactly (with `./x/` stripped).
- [ ] `./.META/sha256` matches calculated SHA-256 digests for all regular files in `./x/`.
- [ ] Symlink targets within `./x/` do not traverse outside the package or target root.
- [ ] Archive decompresses successfully within the `< 8 MB` memory ceiling in BusyBox `unxz`.
