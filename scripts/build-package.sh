#!/usr/bin/env bash
# scripts/build-package.sh -- S.A.N.E Package Builder CLI
#
# Builds deterministic, SHA-256 integrity-checked .spm.tar.xz (or .spm.tar.gz)
# packages from a staging directory following the S.A.N.E Package Specification.
#
# CLI Contract:
#   scripts/build-package.sh --source <staging_dir> --output <output_dir> [--base] [--gz]

set -euo pipefail

# Print error message and exit
die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Print info message
log() {
    printf '==> %s\n' "$*"
}

usage() {
    cat <<'EOF'
Usage: scripts/build-package.sh --source <staging_dir> --output <output_dir> [OPTIONS]

Options:
  -s, --source <dir>   Path to package staging directory containing ./x/ and ./.META/
  -o, --output <dir>   Directory where the built package archive will be placed
  -b, --base           Mark package as base system package (base=true)
  -z, --gz             Compress archive using gzip instead of xz
  -h, --help           Show this help message and exit

Required Staging Layout:
  <staging_dir>/
  ├── x/               Payload tree (installed into target rootfs /)
  └── .META/
      └── package      Manifest containing name, version, arch, description, base
EOF
}

SOURCE_DIR=""
OUTPUT_DIR=""
IS_BASE=false
USE_GZ=false

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--source)
            [ $# -ge 2 ] || die "Option '$1' requires an argument"
            SOURCE_DIR="$2"
            shift 2
            ;;
        -o|--output)
            [ $# -ge 2 ] || die "Option '$1' requires an argument"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -b|--base)
            IS_BASE=true
            shift
            ;;
        -z|--gz)
            USE_GZ=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (see --help for usage)"
            ;;
    esac
done

# Validate required arguments
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
[ -n "$SOURCE_DIR" ] || die "Missing required option: --source <staging_dir>"
[ -n "$OUTPUT_DIR" ] || die "Missing required option: --output <output_dir>"

[ -d "$SOURCE_DIR" ] || die "Source staging directory does not exist: $SOURCE_DIR"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"

mkdir -p "$OUTPUT_DIR" || die "Failed to create output directory: $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

# 1. Validate payload and metadata root structure (reject symlinks before mutation)
[ ! -L "$SOURCE_DIR/x" ] || die "Payload directory must not be a symlink: $SOURCE_DIR/x"
[ -d "$SOURCE_DIR/x" ] || die "Missing payload directory: $SOURCE_DIR/x"
[ ! -L "$SOURCE_DIR/.META" ] || die "Metadata directory must not be a symlink: $SOURCE_DIR/.META"
[ -d "$SOURCE_DIR/.META" ] || die "Missing metadata directory: $SOURCE_DIR/.META"
[ ! -L "$SOURCE_DIR/.META/package" ] || die "Package manifest must not be a symlink: $SOURCE_DIR/.META/package"

# Shared read-only policy check BEFORE any source mutation (mkdir/touch/chmod
# below must never follow a symlinked .META or service path). The validator
# lives in spm, invoked from this script's own directory: one symlink policy,
# one snippet grammar for builder and installer.
sh "$SCRIPT_DIR/spm" validate-source "$SOURCE_DIR" || die "Source rejected by spm validate-source"

mkdir -p "$SOURCE_DIR/.META"

# 2. Validate .META/package manifest
MANIFEST="$SOURCE_DIR/.META/package"
[ -f "$MANIFEST" ] || die "Missing package manifest: $MANIFEST"

get_manifest_val() {
    local key="$1"
    grep -E "^[[:space:]]*${key}=" "$MANIFEST" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r\n' || true
}

PKG_NAME="$(get_manifest_val "name")"
PKG_VERSION="$(get_manifest_val "version")"
PKG_ARCH="$(get_manifest_val "arch")"
PKG_RELEASE="$(get_manifest_val "release")"
PKG_BASE="$(get_manifest_val "base")"
PKG_DESC="$(get_manifest_val "description")"
PKG_DEPS="$(get_manifest_val "dependencies")"

[ -n "$PKG_NAME" ] || die "Missing mandatory field 'name' in $MANIFEST"
[ -n "$PKG_VERSION" ] || die "Missing mandatory field 'version' in $MANIFEST"
[ -n "$PKG_ARCH" ] || die "Missing mandatory field 'arch' in $MANIFEST"
[ -n "$PKG_DESC" ] || die "Missing mandatory field 'description' in $MANIFEST"

# Validate field formats
[[ "$PKG_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "Invalid package name '$PKG_NAME': must match ^[a-z0-9][a-z0-9-]*$ (lowercase alphanumeric and hyphens only, underscores rejected)"
[[ "$PKG_VERSION" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid package version '$PKG_VERSION'"
[ "$PKG_ARCH" = "x86_64" ] || [ "$PKG_ARCH" = "all" ] || die "Invalid package arch '$PKG_ARCH': must be strictly 'x86_64' or 'all'"

# Handle release field
if [ -z "$PKG_RELEASE" ]; then
    PKG_RELEASE="1"
fi
[[ "$PKG_RELEASE" =~ ^[0-9]+$ ]] || die "Invalid package release '$PKG_RELEASE': must be an integer"

# Handle base field
if [ "$IS_BASE" = true ]; then
    PKG_BASE="true"
elif [ -z "$PKG_BASE" ]; then
    PKG_BASE="false"
fi

if [ "$PKG_BASE" != "true" ] && [ "$PKG_BASE" != "false" ]; then
    die "Invalid base field value '$PKG_BASE': must be 'true' or 'false'"
fi

# Validate and sync dependencies= and .META/depends
[ ! -L "$SOURCE_DIR/.META/depends" ] || die "Dependency file must not be a symlink: $SOURCE_DIR/.META/depends"
[ ! -L "$SOURCE_DIR/.META/files" ] || die "Files manifest must not be a symlink: $SOURCE_DIR/.META/files"
[ ! -L "$SOURCE_DIR/.META/sha256" ] || die "Checksum manifest must not be a symlink: $SOURCE_DIR/.META/sha256"

norm_deps_list() {
    tr ', \t\r' '\n' | awk 'NF { print }' | LC_ALL=C sort -u
}

validate_dep_names() {
    local d
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        [[ "$d" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid dependency name '$d'"
    done
}

deps_from_manifest=""
if [ -n "$PKG_DEPS" ]; then
    deps_from_manifest="$(printf '%s\n' "$PKG_DEPS" | norm_deps_list)"
    validate_dep_names <<< "$deps_from_manifest"
fi

deps_from_file=""
if [ -f "$SOURCE_DIR/.META/depends" ]; then
    deps_from_file="$(norm_deps_list < "$SOURCE_DIR/.META/depends")"
    if [ -n "$deps_from_file" ]; then
        validate_dep_names <<< "$deps_from_file"
    fi
fi

if [ -n "$deps_from_manifest" ] && [ -n "$deps_from_file" ]; then
    if [ "$deps_from_manifest" != "$deps_from_file" ]; then
        die "Dependency mismatch between .META/package dependencies= and .META/depends"
    fi
elif [ -n "$deps_from_manifest" ] && [ -z "$deps_from_file" ]; then
    printf '%s\n' "$PKG_DEPS" | tr ', \t\r' '\n' | awk 'NF && !seen[$0]++ { print }' > "$SOURCE_DIR/.META/depends"
elif [ -z "$deps_from_manifest" ] && [ -n "$deps_from_file" ]; then
    PKG_DEPS="$(awk 'NF && !seen[$0]++ { out = (out ? out "," $0 : $0) } END { print out }' "$SOURCE_DIR/.META/depends")"
else
    [ -f "$SOURCE_DIR/.META/depends" ] || touch "$SOURCE_DIR/.META/depends"
fi

# Update/sync .META/package
cat > "$MANIFEST.tmp" <<EOF
name=$PKG_NAME
version=$PKG_VERSION
release=$PKG_RELEASE
arch=$PKG_ARCH
description=$PKG_DESC
EOF
if [ -n "$PKG_DEPS" ]; then
    printf 'dependencies=%s\n' "$PKG_DEPS" >> "$MANIFEST.tmp"
fi
printf 'base=%s\n' "$PKG_BASE" >> "$MANIFEST.tmp"
mv -fT "$MANIFEST.tmp" "$MANIFEST"

# 3. Path safety audit -- delegated to spm validate-source above (single
# policy). The private symlink helper below remains for the post-pack archive
# structural audit only; that invariant is unchanged.
log "Staging tree path safety validated by spm: $SOURCE_DIR"

# Helper to verify a symlink does not escape target root
verify_symlink_safety() {
    local link_rel="$1"
    local target="$2"

    local dir_part
    dir_part="$(dirname "$link_rel")"

    if [[ "$target" == /* ]]; then
        # Absolute symlinks are permitted for rootfs targets (e.g. /bin/busybox)
        # but must not contain directory traversal components
        if [[ "$target" =~ (^|/)\.\.(/|$) ]]; then
            die "Path traversal detected in absolute symlink: $link_rel -> $target"
        fi
        case "$target" in
            /etc/shadow*|/etc/passwd*|/etc/sudoers*|/etc/gshadow*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/root|/root/*|/home|/home/*)
                die "Symlink escape attack: forbidden system target $target"
                ;;
            /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/share/*|/lib/*|/usr/lib/*|/boot/*|/opt/*)
                return 0
                ;;
            *)
                die "Symlink escape attack: absolute target outside allowed system directories: $link_rel -> $target"
                ;;
        esac
    fi

    # For relative symlinks, calculate directory depth under payload root
    local depth=0
    if [ "$dir_part" != "." ]; then
        local IFS='/'
        local -a addr
        read -ra addr <<< "$dir_part"
        depth=${#addr[@]}
    fi

    local cur_depth=$depth
    local IFS='/'
    local -a parts
    read -ra parts <<< "$target"
    for p in "${parts[@]}"; do
        if [ "$p" = ".." ]; then
            cur_depth=$((cur_depth - 1))
            if [ $cur_depth -lt 0 ]; then
                die "Relative symlink escapes target root: $link_rel -> $target"
            fi
        elif [ -n "$p" ] && [ "$p" != "." ]; then
            cur_depth=$((cur_depth + 1))
        fi
    done
    return 0
}

# Source-side x/ path and symlink audit is delegated to spm validate-source
# (called before any source mutation). Post-pack archive audit below still
# uses the private helper, unchanged.

# 4. Service snippet mode normalization -- only AFTER validate-source passed.
# Content auditing and vocabulary are exclusively spm's shared validator.
SERVICE_DIR="$SOURCE_DIR/x/usr/share/ninit/services"
if [ -d "$SERVICE_DIR" ] && [ ! -L "$SERVICE_DIR" ]; then
    log "Normalizing validated ninit service snippet modes in $SERVICE_DIR..."
    while IFS= read -r -d '' sfile; do
        [ -f "$sfile" ] && [ ! -L "$sfile" ] || continue
        chmod 0644 "$sfile"
    done < <(find "$SERVICE_DIR" -mindepth 1 -maxdepth 1 -print0)
fi

# T1: a device node, FIFO or socket in the source payload must never reach
# the archive. Reject them here, before .META/files is generated (the old
# `find ! -type d` below would have listed them as payload entries).
special_files=$(find -H "$SOURCE_DIR/x" ! -type f ! -type d ! -type l 2>/dev/null || true)
[ -z "$special_files" ] || die "Special file (device/FIFO/socket) in package payload: $special_files"
special_files=$(find -H "$SOURCE_DIR/.META" ! -type f ! -type d 2>/dev/null || true)
[ -z "$special_files" ] || die "Special file in package metadata: $special_files"

# Static ELF verification across ELF payloads (fail-closed)
while IFS= read -r -d '' pfile; do
    magic="$(od -N 4 -An -tx1 "$pfile" 2>/dev/null | tr -d ' \n' || true)"
    if [ "$magic" = "7f454c46" ]; then
        command -v readelf >/dev/null 2>&1 || die "readelf is required to verify ELF payloads: $pfile"
        readelf -h "$pfile" >/dev/null 2>&1 || die "Invalid ELF binary in package payload: $pfile"
        if readelf -lW "$pfile" 2>/dev/null | grep -E -q '(^|[[:space:]])INTERP([[:space:]]|$)|PT_INTERP'; then
            die "Dynamically linked ELF (PT_INTERP) is forbidden in package payload: $pfile"
        fi
        rel_pfile="${pfile#"$SOURCE_DIR/x/"}"
        case "$rel_pfile" in
            bin/*|sbin/*|usr/bin/*|usr/sbin/*)
                if readelf -lW "$pfile" 2>/dev/null | grep -E -q '[[:space:]]DYNAMIC[[:space:]]'; then
                    die "Dynamically linked ELF (DYNAMIC) is forbidden in executable payload: $pfile"
                fi
                ;;
        esac
    fi
done < <(find -H "$SOURCE_DIR/x" -type f -print0)

# 5. Auto-generate .META/files
log "Generating .META/files manifest..."
(
    cd "$SOURCE_DIR/x"
    {
        find . -mindepth 1 -type d | sed 's|^\./||' | sed 's|$|/|'
        find . -mindepth 1 ! -type d | sed 's|^\./||'
    } | LC_ALL=C sort > "$SOURCE_DIR/.META/files"
)

# Verify .META/files is clean
while IFS= read -r fline; do
    [ -n "$fline" ] || continue
    if [[ "$fline" =~ ^/ ]] || [[ "$fline" =~ // ]] || printf '%s\n' "$fline" | grep -qE '(^|/)\.\.(/|$)'; then
        die "Invalid entry in generated .META/files: $fline"
    fi
    if [[ "$fline" == */ ]]; then
        [ ! -L "$SOURCE_DIR/x/${fline%/}" ] && [ -d "$SOURCE_DIR/x/$fline" ] || die "Directory entry in .META/files does not exist: $fline"
    else
        [ -f "$SOURCE_DIR/x/$fline" ] || [ -L "$SOURCE_DIR/x/$fline" ] || die "File entry in .META/files does not exist: $fline"
    fi
done < "$SOURCE_DIR/.META/files"

# 6. Auto-generate .META/sha256
log "Generating .META/sha256 checksums..."
(
    cd "$SOURCE_DIR/x"
    find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
        sha256sum "$f"
    done > "$SOURCE_DIR/.META/sha256"
)

# 7. Construct package filenames
if [ "$USE_GZ" = true ]; then
    PKG_EXT="spm.tar.gz"
else
    PKG_EXT="spm.tar.xz"
fi

PKG_FILE_CANONICAL="${OUTPUT_DIR}/${PKG_NAME}-${PKG_VERSION}-${PKG_RELEASE}-${PKG_ARCH}.${PKG_EXT}"
PKG_FILE_SHORT="${OUTPUT_DIR}/${PKG_NAME}-${PKG_VERSION}-${PKG_ARCH}.${PKG_EXT}"
TMP_PKG="${OUTPUT_DIR}/.tmp-${PKG_NAME}-$$.${PKG_EXT}"

log "Packing deterministic archive for $PKG_NAME ($PKG_EXT)..."

# Ensure clean temp file cleanup on exit
cleanup() {
    rm -f "$TMP_PKG" 2>/dev/null || true
}
trap cleanup EXIT

# 8. Create deterministic tarball
# Packing contract:
#   --sort=name : sorted directory entries
#   --owner=0 --group=0 --numeric-owner : root:root UID/GID 0
#   --mtime=@0 : Unix epoch timestamp
#   --mode="u+rw,go-w,a-s" : preserve 0600/0700 secrets, normalize 0664->0644 / 0775->0755, strip setuid/setgid
#   --hard-dereference : avoid packing tar hardlinks from scratch tree copies
TAR_BASE_CMD=(
    tar
    --sort=name
    --owner=0
    --group=0
    --numeric-owner
    --mtime="@${SOURCE_DATE_EPOCH:-0}"
    --mode="u+rw,go-w,a-s"
    --hard-dereference
    -cf -
    -C "$SOURCE_DIR"
    ./.META ./x
)

if [ "$USE_GZ" = true ]; then
    "${TAR_BASE_CMD[@]}" | gzip -n -9 > "$TMP_PKG"
else
    # Single-threaded xz (-T1) for bit-for-bit determinism regardless of stream size or host CPU count;
    # moderate dictionary size (4 MiB) bounds decompression RAM to < 8 MB
    "${TAR_BASE_CMD[@]}" | xz -T1 --lzma2=dict=4MiB > "$TMP_PKG"
fi

# 9. Post-pack archive audit (tar-slip & invariant verification)
log "Verifying archive security and anti-tar-slip invariants..."

# Verify all entry paths
while IFS= read -r member; do
    [ -n "$member" ] || continue
    # Reject leading slashes
    if [[ "$member" =~ ^/ ]]; then
        rm -f "$TMP_PKG"
        die "Archive audit failed: member has leading slash: $member"
    fi
    # Reject path traversal components
    if printf '%s\n' "$member" | grep -qE '(^|/)\.\.(/|$)'; then
        rm -f "$TMP_PKG"
        die "Archive audit failed: member contains traversal component: $member"
    fi
    # Reject entries outside ./.META/ or ./x/
    if [[ ! "$member" =~ ^\./(\.META|x)(/|$) ]]; then
        rm -f "$TMP_PKG"
        die "Archive audit failed: unexpected root entry: $member"
    fi
done < <(tar -tf "$TMP_PKG")

# Verify symlink targets, hardlinks, and special files inside archive
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
        h*|-*" -> "*)
            rm -f "$TMP_PKG"
            die "Archive audit failed: hard links are forbidden: $line"
            ;;
        b*|c*|p*|s*|\?*)
            rm -f "$TMP_PKG"
            die "Archive audit failed: special files are forbidden: $line"
            ;;
    esac
    # Reject any symlink in ./.META/ or for ./.META or ./x itself
    if [[ "$line" =~ ^l.*[[:space:]](\./\.META(/[^[:space:]]+)?|\./x/?)[[:space:]]-\> ]]; then
        rm -f "$TMP_PKG"
        die "Archive audit failed: symlinks are forbidden for ${BASH_REMATCH[1]}"
    fi
    # Symlink line format in tar -tvf: lrwxrwxrwx ... ./x/path -> target
    if [[ "$line" =~ ^l.*[[:space:]](\./x/[^[:space:]]+)[[:space:]]-\>[[:space:]](.+)$ ]]; then
        link_path="${BASH_REMATCH[1]}"
        link_target="${BASH_REMATCH[2]}"
        rel_link="${link_path#\./x/}"
        verify_symlink_safety "$rel_link" "$link_target"
    fi
done < <(tar -tvf "$TMP_PKG")

# 10. Atomic commit
mv -fT "$TMP_PKG" "$PKG_FILE_CANONICAL"
trap - EXIT

# Provide short alias if different
if [ "$PKG_FILE_CANONICAL" != "$PKG_FILE_SHORT" ]; then
    ln -f "$PKG_FILE_CANONICAL" "$PKG_FILE_SHORT" 2>/dev/null || cp -p "$PKG_FILE_CANONICAL" "$PKG_FILE_SHORT"
fi

log "SUCCESS: Package created -> $PKG_FILE_CANONICAL"
if [ "$PKG_FILE_CANONICAL" != "$PKG_FILE_SHORT" ]; then
    log "Alias created -> $PKG_FILE_SHORT"
fi
