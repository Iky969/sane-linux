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
# set SANE_WEAK_DEFAULT_CREDS=1 to generate RANDOM per-run passwords instead
# (K1: no deterministic root/root + sane/sane credentials exist any more).
# The passwords are written to SANE_TEST_CREDS_FILE, or to a mktemp-generated
# sane-test-creds.XXXXXX file under ${TMPDIR:-/tmp} (mode 0600, outside the
# image), so a test that needs to log in can read them; they are never
# committed. NEVER use that flag for images intended for distribution.
set -eu

TARGET=${1:-}
SUDO=${2:-}
# CDPATH= is an intentional env-prefix: it stops CDPATH from redirecting cd.
# shellcheck disable=SC1007
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
	# CI/test only (K1): random per-run passwords, set via set-password on
	# top of the locked --firstboot baseline. Verified: set-password
	# replaces the '!' lock marker with a usable hash, so no unlock step
	# is needed after init --firstboot.
	printf 'WARNING: provisioning random per-run CI/test credentials (see SANE_TEST_CREDS_FILE)\n' >&2
	if [ -n "${SANE_TEST_CREDS_FILE:-}" ]; then
		CREDS_FILE="$SANE_TEST_CREDS_FILE"
		CLEANUP_CREDS=0
	else
		CREDS_FILE=$(mktemp "${TMPDIR:-/tmp}/sane-test-creds.XXXXXX") || { printf "FAIL: failed to create credentials file\n" >&2; exit 1; }
		CLEANUP_CREDS=1
	fi
	# Remove a mktemp-generated creds file on exit/error; never delete an
	# explicitly provided SANE_TEST_CREDS_FILE.
	if [ "${CLEANUP_CREDS:-0}" -eq 1 ]; then
		trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "${CLEANUP_CREDS:-0}" -eq 1 ]; then rm -f "$CREDS_FILE"; fi' EXIT HUP INT TERM
	fi
	ROOT_PASS=$(openssl rand -base64 18 2>/dev/null || head -c 18 /dev/urandom | base64)
	SANE_PASS=$(openssl rand -base64 18 2>/dev/null || head -c 18 /dev/urandom | base64)
	# Write atomically with mode 0600; umask guards the creation.
	( umask 077; printf 'root:%s\nsane:%s\n' "$ROOT_PASS" "$SANE_PASS" > "$CREDS_FILE" )
	chmod 0600 "$CREDS_FILE"
	printf '%s' "$ROOT_PASS" | $SUDO sh "$ACCOUNTS" --root "$TARGET" set-password root
	printf '%s' "$SANE_PASS" | $SUDO sh "$ACCOUNTS" --root "$TARGET" set-password sane
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
