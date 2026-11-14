#!/usr/bin/env bash
# scripts/build-package.sh -- S.A.N.E Package Builder CLI
#
# Builds deterministic, cryptographically verified .spm.tar.xz (or .spm.tar.gz)
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
[ -n "$SOURCE_DIR" ] || die "Missing required option: --source <staging_dir>"
[ -n "$OUTPUT_DIR" ] || die "Missing required option: --output <output_dir>"

[ -d "$SOURCE_DIR" ] || die "Source staging directory does not exist: $SOURCE_DIR"
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"

mkdir -p "$OUTPUT_DIR" || die "Failed to create output directory: $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

# 1. Validate payload structure
[ -d "$SOURCE_DIR/x" ] || die "Missing payload directory: $SOURCE_DIR/x"
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

[ -n "$PKG_NAME" ] || die "Missing mandatory field 'name' in $MANIFEST"
[ -n "$PKG_VERSION" ] || die "Missing mandatory field 'version' in $MANIFEST"
[ -n "$PKG_ARCH" ] || die "Missing mandatory field 'arch' in $MANIFEST"

# Validate field formats
[[ "$PKG_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid package name '$PKG_NAME': must be lowercase alphanumeric with hyphens or underscores"
[[ "$PKG_VERSION" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid package version '$PKG_VERSION'"
[[ "$PKG_ARCH" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid package arch '$PKG_ARCH'"

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

# Ensure .META/depends exists
[ -f "$SOURCE_DIR/.META/depends" ] || touch "$SOURCE_DIR/.META/depends"

# Update/sync .META/package
cat > "$MANIFEST.tmp" <<EOF
name=$PKG_NAME
version=$PKG_VERSION
release=$PKG_RELEASE
arch=$PKG_ARCH
description=${PKG_DESC:-$PKG_NAME package for S.A.N.E Linux}
base=$PKG_BASE
EOF
mv -f "$MANIFEST.tmp" "$MANIFEST"

# 3. Path safety audit on staging directory (anti-traversal guard)
log "Auditing staging tree for path safety in $SOURCE_DIR..."

# Audit .META directory: strictly regular files only, zero symlinks, zero traversal
while IFS= read -r -d '' entry; do
    rel="${entry#$SOURCE_DIR/.META/}"
    [ -n "$rel" ] || continue

    if echo "$rel" | grep -qE '(^|/)\.\.(/|$)'; then
        die "Path traversal detected in .META entry: $rel"
    fi

    if [ -L "$entry" ]; then
        die "Symlinks are strictly forbidden in .META directory: $rel"
    fi

    if [ ! -f "$entry" ] && [ ! -d "$entry" ]; then
        die "Special file detected in .META directory: $rel"
    fi
done < <(find "$SOURCE_DIR/.META" -mindepth 1 -print0)

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
        return 0
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

# Audit regular files, directories, and symlinks in staging tree
while IFS= read -r -d '' entry; do
    rel="${entry#$SOURCE_DIR/x/}"
    [ -n "$rel" ] || continue

    # Reject traversal components in file/directory path
    if echo "$rel" | grep -qE '(^|/)\.\.(/|$)'; then
        die "Path traversal detected in staging entry: $rel"
    fi

    # If it is a symlink, audit target
    if [ -L "$entry" ]; then
        target="$(readlink "$entry")"
        verify_symlink_safety "$rel" "$target"
    fi
done < <(find "$SOURCE_DIR/x" -mindepth 1 -print0)

# 4. Service snippet audit
SERVICE_DIR="$SOURCE_DIR/x/usr/share/ninit/services"
if [ -d "$SERVICE_DIR" ]; then
    log "Auditing ninit service snippets in $SERVICE_DIR..."
    while IFS= read -r -d '' sfile; do
        sname="$(basename "$sfile")"
        if [ -L "$sfile" ]; then
            die "Service file must not be a symlink: $sname"
        fi
        [ -f "$sfile" ] || die "Service file is not a regular file: $sname"
        [[ "$sname" == *.service ]] || die "Service file must end in .service: $sname"

        # Enforce 0644 non-executable permissions
        chmod 0644 "$sfile"

        # Audit content
        content="$(tr -d '\r\n' < "$sfile")"
        [ -n "$content" ] || die "Service file is empty: $sname"

        # Check for forbidden dangerous patterns
        for forbidden in "/run/initctl" "reboot" "poweroff" "halt" "kill" "signal"; do
            if echo "$content" | grep -qw "$forbidden"; then
                die "Forbidden keyword '$forbidden' detected in service snippet: $sname"
            fi
        done

        # Check for forbidden shell metacharacters
        if echo "$content" | grep -qE '[|><;&`$]'; then
            die "Forbidden shell metacharacters detected in service snippet: $sname"
        fi
    done < <(find "$SERVICE_DIR" -mindepth 1 -maxdepth 1 -print0)
fi

# 5. Auto-generate .META/files
log "Generating .META/files manifest..."
(
    cd "$SOURCE_DIR/x"
    find . ! -type d | sed 's|^\./||' | LC_ALL=C sort > "$SOURCE_DIR/.META/files"
)

# Verify .META/files is clean
while IFS= read -r fline; do
    [ -n "$fline" ] || continue
    if [[ "$fline" =~ ^/ ]] || echo "$fline" | grep -qE '(^|/)\.\.(/|$)'; then
        die "Invalid entry in generated .META/files: $fline"
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
#   --mode="go=rX,u+rw,a-s" : standardized permissions (executables 755, files 644)
TAR_BASE_CMD=(
    tar
    --sort=name
    --owner=0
    --group=0
    --numeric-owner
    --mtime="@${SOURCE_DATE_EPOCH:-0}"
    --mode="go=rX,u+rw,a-s"
    -cf -
    -C "$SOURCE_DIR"
    ./.META ./x
)

if [ "$USE_GZ" = true ]; then
    "${TAR_BASE_CMD[@]}" | gzip -n -9 > "$TMP_PKG"
else
    # Moderate dictionary size (4 MiB) bounding decompression RAM to < 8 MB
    "${TAR_BASE_CMD[@]}" | xz -T0 --lzma2=dict=4MiB > "$TMP_PKG"
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
    if echo "$member" | grep -qE '(^|/)\.\.(/|$)'; then
        rm -f "$TMP_PKG"
        die "Archive audit failed: member contains traversal component: $member"
    fi
    # Reject entries outside ./.META/ or ./x/
    if [[ ! "$member" =~ ^\./(\.META|x)(/|$) ]]; then
        rm -f "$TMP_PKG"
        die "Archive audit failed: unexpected root entry: $member"
    fi
done < <(tar -tf "$TMP_PKG")

# Verify symlink targets inside archive
while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Reject any symlink in ./.META/
    if [[ "$line" =~ ^l.*[[:space:]](\./\.META/[^[:space:]]+) ]]; then
        rm -f "$TMP_PKG"
        die "Archive audit failed: symlinks are forbidden in ./.META/: ${BASH_REMATCH[1]}"
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
mv -f "$TMP_PKG" "$PKG_FILE_CANONICAL"
trap - EXIT

# Provide short alias if different
if [ "$PKG_FILE_CANONICAL" != "$PKG_FILE_SHORT" ]; then
    ln -f "$PKG_FILE_CANONICAL" "$PKG_FILE_SHORT" 2>/dev/null || cp -p "$PKG_FILE_CANONICAL" "$PKG_FILE_SHORT"
fi

log "SUCCESS: Package created -> $PKG_FILE_CANONICAL"
if [ "$PKG_FILE_CANONICAL" != "$PKG_FILE_SHORT" ]; then
    log "Alias created -> $PKG_FILE_SHORT"
fi
