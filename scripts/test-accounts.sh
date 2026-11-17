#!/bin/sh
# scripts/test-accounts.sh -- Phase A account lifecycle & policy regression tests.
# Runs without root against a temporary target rootfs. No host /etc is touched.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ACCOUNTS="$REPO_ROOT/scripts/sane-accounts"

PASS=0
FAIL=0
T=

pass() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1" >&2; }

check() {
	desc=$1; shift
	if "$@"; then pass "$desc"; else fail "$desc"; fi
}

expect_ok() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

expect_fail() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

base() {
	[ -n "$T" ] && rm -rf -- "$T"
	T=$(mktemp -d)
	mkdir -p "$T/etc" "$T/home" "$T/usr/bin"
	printf 'stub' > "$T/usr/bin/doas"
	chmod 4755 "$T/usr/bin/doas"
	sh "$ACCOUNTS" --root "$T" init >/dev/null
}

cleanup() { [ -n "$T" ] && rm -rf -- "$T"; }
trap cleanup EXIT HUP INT TERM

command -v openssl >/dev/null 2>&1 || { printf 'SKIP: openssl not available\n'; exit 77; }
check "sane-accounts is present and executable" test -f "$ACCOUNTS"

base

# --- baseline -------------------------------------------------------------
check "init writes passwd" test -f "$T/etc/passwd"
check "init writes group"  test -f "$T/etc/group"
check "init writes shadow" test -f "$T/etc/shadow"
check "init writes doas.conf" test -f "$T/etc/doas.conf"
check "passwd mode 0644"  test "$(stat -c %a "$T/etc/passwd")" = 644
check "group mode 0644"   test "$(stat -c %a "$T/etc/group")" = 644
check "shadow mode 0600"  test "$(stat -c %a "$T/etc/shadow")" = 600
check "doas.conf mode 0600" test "$(stat -c %a "$T/etc/doas.conf")" = 600
check "baseline has root and sane accounts" sh -c \
	"grep -q '^root:' '$T/etc/passwd' && grep -q '^sane:' '$T/etc/passwd'"
check "wheel group contains sane" sh -c \
	"grep -q '^wheel:x:10:root,sane$' '$T/etc/group'"
expect_ok "validate passes on baseline" sh "$ACCOUNTS" --root "$T" validate

# --- user lifecycle --------------------------------------------------------
expect_ok "add-user with explicit uid" sh "$ACCOUNTS" --root "$T" add-user alice 1005
check "add-user writes passwd entry" sh -c \
	"grep -q '^alice:x:1005:1005:' '$T/etc/passwd'"
check "add-user creates matching group" sh -c \
	"grep -q '^alice:x:1005:$' '$T/etc/group'"
check "add-user creates locked shadow entry" sh -c \
	"grep -q '^alice:!:19700:0:99999:7:::$' '$T/etc/shadow'"
check "add-user creates home with 0750" test "$(stat -c %a "$T/home/alice")" = 750
expect_fail "unlock of account without a password hash rejected" \
	sh "$ACCOUNTS" --root "$T" unlock alice
check "failed unlock leaves the locked hash unchanged" sh -c \
	"grep -q '^alice:!:19700:0:99999:7:::$' '$T/etc/shadow'"
expect_fail "duplicate account name rejected" sh "$ACCOUNTS" --root "$T" add-user alice
expect_fail "duplicate uid rejected" sh "$ACCOUNTS" --root "$T" add-user bob 1005
expect_fail "reserved root account rejected" sh "$ACCOUNTS" --root "$T" add-user root
expect_fail "path traversal name rejected" sh "$ACCOUNTS" --root "$T" add-user ../evil
expect_fail "uppercase name rejected" sh "$ACCOUNTS" --root "$T" add-user BadName
expect_fail "bad uid rejected" sh "$ACCOUNTS" --root "$T" add-user carol abc
expect_fail "uid 999 rejected" sh "$ACCOUNTS" --root "$T" add-user carol 999
expect_fail "uid 65535 rejected" sh "$ACCOUNTS" --root "$T" add-user carol 65535

expect_ok "add-user into existing wheel group" sh "$ACCOUNTS" --root "$T" add-user dave 1006 wheel
check "wheel membership appended" sh -c \
	"grep -q '^wheel:x:10:root,sane,dave$' '$T/etc/group'"
expect_ok "del-user removes group membership" sh "$ACCOUNTS" --root "$T" del-user dave
check "wheel membership removed" sh -c \
	"grep -q '^wheel:x:10:root,sane$' '$T/etc/group'"
check "del-user removes passwd entry" sh -c \
	"! grep -q '^dave:' '$T/etc/passwd'"

# --- password management ---------------------------------------------------
expect_fail "empty password rejected" sh "$ACCOUNTS" --root "$T" set-password alice ''
expect_fail "unknown user password rejected" sh "$ACCOUNTS" --root "$T" set-password nobody secret
expect_ok "set-password updates shadow" sh "$ACCOUNTS" --root "$T" set-password alice secret
stored=$(awk -F: '$1=="alice"{print $2}' "$T/etc/shadow")
case "$stored" in
	\$6\$*) pass "set-password produces SHA-512 crypt hash" ;;
	*) fail "set-password produced unexpected hash: $stored" ;;
esac
rest=${stored#\$6\$}
salt=${rest%%\$*}
expected=$(printf '%s' 'secret' | openssl passwd -6 -salt "$salt" -stdin)
check "stored hash verifies against password" test "$stored" = "$expected"
check "shadow stays 0600 after password change" test "$(stat -c %a "$T/etc/shadow")" = 600
expect_ok "validate accepts active SHA-512 password" sh "$ACCOUNTS" --root "$T" validate

expect_ok "lock account" sh "$ACCOUNTS" --root "$T" lock alice
check "lock adds '!' marker" sh -c "grep -q '^alice:!' '$T/etc/shadow'"
expect_ok "validate accepts locked account" sh "$ACCOUNTS" --root "$T" validate
expect_ok "unlock account" sh "$ACCOUNTS" --root "$T" unlock alice
check "unlock removes '!' marker" sh -c "! grep -q '^alice:!' '$T/etc/shadow'"
expect_ok "del-user removes home when asked" sh "$ACCOUNTS" --root "$T" del-user alice --remove-home
check "home removed with --remove-home" test ! -d "$T/home/alice"
expect_fail "del-user root rejected" sh "$ACCOUNTS" --root "$T" del-user root
expect_fail "del-user unknown rejected" sh "$ACCOUNTS" --root "$T" del-user nobody

# --- fail-closed validation ------------------------------------------------
base
chmod 0644 "$T/etc/shadow"
expect_fail "validate rejects world-readable shadow" sh "$ACCOUNTS" --root "$T" validate

base
sed -i 's/^sane:\$6\$/sane:plaintext/' "$T/etc/shadow"
expect_fail "validate rejects non-SHA512 password" sh "$ACCOUNTS" --root "$T" validate

base
printf 'evil:x:0:0:evil:/root:/bin/sh\n' >> "$T/etc/passwd"
expect_fail "validate rejects second uid 0" sh "$ACCOUNTS" --root "$T" validate

base
printf 'clone:x:1000:1000:clone:/home/clone:/bin/sh\n' >> "$T/etc/passwd"
expect_fail "validate rejects duplicate uid" sh "$ACCOUNTS" --root "$T" validate

base
chmod 0644 "$T/etc/doas.conf"
expect_fail "validate rejects permissive doas.conf mode" sh "$ACCOUNTS" --root "$T" validate

base
printf 'permit nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail "validate rejects passwordless doas grant" sh "$ACCOUNTS" --root "$T" validate

base
chmod 0755 "$T/usr/bin/doas"
expect_fail "validate rejects non-setuid doas binary" sh "$ACCOUNTS" --root "$T" validate

base
printf 'root:x:0:\n' > "$T/etc/group"
expect_fail "validate rejects missing wheel group" sh "$ACCOUNTS" --root "$T" validate

base
rm -f "$T/etc/shadow"
expect_fail "validate rejects missing shadow" sh "$ACCOUNTS" --root "$T" validate

base
awk -F: 'BEGIN{OFS=":"} $1=="sane" {$2=""} {print}' "$T/etc/shadow" > "$T/etc/shadow.tmp"
mv "$T/etc/shadow.tmp" "$T/etc/shadow"
expect_fail "validate rejects an empty password field" sh "$ACCOUNTS" --root "$T" validate

base
printf 'clone:x:10:clone:/home/clone:/bin/sh\n' >> "$T/etc/group"
expect_fail "validate rejects duplicate gid" sh "$ACCOUNTS" --root "$T" validate

base
printf 'blocked' > "$T/home/bob"
expect_fail "add-user aborts when home path is a file" sh "$ACCOUNTS" --root "$T" add-user bob 1007
check "failed add leaves no passwd entry" sh -c "! grep -q '^bob:' '$T/etc/passwd'"
check "failed add leaves no shadow entry" sh -c "! grep -q '^bob:' '$T/etc/shadow'"
check "failed add leaves no group entry" sh -c "! grep -q '^bob:' '$T/etc/group'"

printf '\nPhase A account tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
