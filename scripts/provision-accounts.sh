#!/bin/sh
# provision-accounts.sh -- single source of truth for S.A.N.E identity files.
#
# Usage: provision-accounts.sh TARGET_ROOT [SUDO_PREFIX]
#
# Writes /etc/passwd, /etc/group, /etc/shadow, /etc/doas.conf via
# sane-accounts and installs both account utilities into the target root.
#
# By default accounts are locked and /etc/.sane-firstboot-done is absent, so
# sane-firstboot will demand new passwords on first boot. For CI/test images,
# set SANE_WEAK_DEFAULT_CREDS=1 to keep the deterministic root/root + sane/sane
# credentials and mark first boot as already complete. NEVER use that flag for
# images intended for distribution.
set -eu

TARGET=${1:-}
SUDO=${2:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

[ -n "$TARGET" ] || { printf 'FAIL: target root required\n' >&2; exit 1; }
[ -d "$TARGET/etc" ] || { printf 'FAIL: no /etc in %s\n' "$TARGET" >&2; exit 1; }

ACCOUNTS="$SCRIPT_DIR/sane-accounts"
FIRSTBOOT="$SCRIPT_DIR/sane-firstboot"
RECOVERY="$SCRIPT_DIR/sane-account-recovery"
[ -f "$ACCOUNTS" ] || ACCOUNTS=/usr/bin/sane-accounts
[ -f "$FIRSTBOOT" ] || FIRSTBOOT=/usr/bin/sane-firstboot
[ -f "$RECOVERY" ] || RECOVERY=/usr/bin/sane-account-recovery

# Baseline: no public password, accounts locked until first boot.
$SUDO sh "$ACCOUNTS" --root "$TARGET" --force --firstboot init

if [ "${SANE_WEAK_DEFAULT_CREDS:-0}" = "1" ]; then
	printf 'WARNING: provisioning CI/test credentials (root/root, sane/sane)\n' >&2
	$SUDO sh "$ACCOUNTS" --root "$TARGET" --force init
	printf 'done\n' | $SUDO tee "$TARGET/etc/.sane-firstboot-done" >/dev/null
	$SUDO chmod 0600 "$TARGET/etc/.sane-firstboot-done"
fi

# Make the lifecycle CLI and first-boot helper available on the installed system.
$SUDO mkdir -p "$TARGET/usr/bin"
$SUDO install -m 0755 "$ACCOUNTS" "$TARGET/usr/bin/sane-accounts"
$SUDO install -m 0755 "$FIRSTBOOT" "$TARGET/usr/bin/sane-firstboot"
$SUDO install -m 0755 "$RECOVERY" "$TARGET/usr/bin/sane-account-recovery"

# Recheck the resulting policy (owner checks are skipped when sudo is used for
# writes because the files may legitimately be owned by the build user).
$SUDO sh "$ACCOUNTS" --root "$TARGET" --skip-owner-check --skip-chown validate >/dev/null
