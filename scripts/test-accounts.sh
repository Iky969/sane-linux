#!/bin/sh
# scripts/test-accounts.sh -- Phase A account lifecycle & policy regression tests.
# Runs without root against a temporary target rootfs. No host /etc is touched.
set -u

# Always exercise the production (no-public-password) provisioning path,
# even when CI sets SANE_WEAK_DEFAULT_CREDS for image/installer jobs.
unset SANE_WEAK_DEFAULT_CREDS 2>/dev/null || true

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
ACCOUNTS="$REPO_ROOT/scripts/sane-accounts"

VFLAGS=
if [ "$(id -u)" != 0 ]; then VFLAGS="--skip-owner-check"; fi

PASS=0
FAIL=0
T=

pass() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1" >&2; }

check() {
	desc=$1; shift
	if "$@"; then pass "$desc"; else fail "$desc"; fi
}

set_pw() {
	printf '%s' "$2" | sh "$ACCOUNTS" --root "$T" set-password "$1"
}

expect_ok() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

expect_fail() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

# Fail-closed with a reason: the command must exit non-zero AND its stderr
# must cite the given pattern, so a failure for an unrelated reason (e.g.
# the effective-rule check) cannot masquerade as the asserted rejection.
expect_fail_msg() {
	desc=$1; msg=$2; shift 2
	if err=$("$@" 2>&1 >/dev/null); then
		fail "$desc"
	elif printf '%s\n' "$err" | grep -q "$msg"; then
		pass "$desc"
	else
		fail "$desc"
	fi
}

base() {
	[ -n "$T" ] && rm -rf -- "$T"
	T=$(mktemp -d)
	mkdir -p "$T/etc" "$T/home" "$T/usr/bin"
	printf 'stub' > "$T/usr/bin/doas"
	chmod 4755 "$T/usr/bin/doas"
	sh "$ACCOUNTS" --root "$T" --firstboot init >/dev/null
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
expect_ok "validate passes on baseline" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# --- user lifecycle --------------------------------------------------------
expect_ok "add-user with explicit uid" sh "$ACCOUNTS" --root "$T" add-user alice 1005 --skip-chown
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
expect_fail "duplicate account name rejected" sh "$ACCOUNTS" --root "$T" add-user alice --skip-chown
expect_fail "duplicate uid rejected" sh "$ACCOUNTS" --root "$T" add-user bob 1005 --skip-chown
expect_fail "reserved root account rejected" sh "$ACCOUNTS" --root "$T" add-user root --skip-chown
expect_fail "path traversal name rejected" sh "$ACCOUNTS" --root "$T" add-user ../evil --skip-chown
expect_fail "uppercase name rejected" sh "$ACCOUNTS" --root "$T" add-user BadName --skip-chown
expect_fail "bad uid rejected" sh "$ACCOUNTS" --root "$T" add-user carol abc --skip-chown
expect_fail "uid 999 rejected" sh "$ACCOUNTS" --root "$T" add-user carol 999 --skip-chown
expect_fail "uid 65535 rejected" sh "$ACCOUNTS" --root "$T" add-user carol 65535 --skip-chown

expect_ok "add-user into existing wheel group" sh "$ACCOUNTS" --root "$T" add-user dave 1006 wheel --skip-chown
check "wheel membership appended" sh -c \
	"grep -q '^wheel:x:10:root,sane,dave$' '$T/etc/group'"
expect_ok "del-user removes group membership" sh "$ACCOUNTS" --root "$T" del-user dave
check "wheel membership removed" sh -c \
	"grep -q '^wheel:x:10:root,sane$' '$T/etc/group'"
check "del-user removes passwd entry" sh -c \
	"! grep -q '^dave:' '$T/etc/passwd'"

# --- password management ---------------------------------------------------
expect_fail "empty password rejected" set_pw alice ''
expect_fail "unknown user password rejected" set_pw nobody 'UnknownPass123!'
expect_fail "short password rejected (minimum 12)" set_pw alice 'short1'
expect_ok "12-character password accepted" set_pw alice '123456789012'
expect_ok "add-user for same-name password test" sh "$ACCOUNTS" --root "$T" add-user testuser1234 1007 --skip-chown
expect_fail "password equal to username rejected" set_pw testuser1234 'testuser1234'
expect_ok "set-password updates shadow" set_pw alice 'SecretPass123!'

stored=$(awk -F: '$1=="alice"{print $2}' "$T/etc/shadow")
case "$stored" in
	\$6\$*) pass "set-password produces SHA-512 crypt hash" ;;
	*) fail "set-password produced unexpected hash: $stored" ;;
esac
rest=${stored#\$6\$}
salt=${rest%%\$*}
expected=$(printf '%s' 'SecretPass123!' | openssl passwd -6 -salt "$salt" -stdin)
check "stored hash verifies against password" test "$stored" = "$expected"
check "shadow stays 0600 after password change" test "$(stat -c %a "$T/etc/shadow")" = 600
expect_ok "validate accepts active SHA-512 password" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

expect_ok "lock account" sh "$ACCOUNTS" --root "$T" lock alice
check "lock adds '!' marker" sh -c "grep -q '^alice:!' '$T/etc/shadow'"
expect_ok "validate accepts locked account" sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "unlock account" sh "$ACCOUNTS" --root "$T" unlock alice
check "unlock removes '!' marker" sh -c "! grep -q '^alice:!' '$T/etc/shadow'"
expect_ok "del-user removes home when asked" sh "$ACCOUNTS" --root "$T" del-user alice --remove-home
check "home removed with --remove-home" test ! -d "$T/home/alice"
expect_fail "del-user root rejected" sh "$ACCOUNTS" --root "$T" del-user root
expect_fail "del-user unknown rejected" sh "$ACCOUNTS" --root "$T" del-user nobody

# --- fail-closed validation ------------------------------------------------
base
chmod 0644 "$T/etc/shadow"
expect_fail "validate rejects world-readable shadow" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
sed -i 's/^sane:!:/sane:plaintext:/' "$T/etc/shadow"
expect_fail "validate rejects non-SHA512 password" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'evil:x:0:0:evil:/root:/bin/sh\n' >> "$T/etc/passwd"
expect_fail "validate rejects second uid 0" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'clone:x:1000:1000:clone:/home/clone:/bin/sh\n' >> "$T/etc/passwd"
expect_fail "validate rejects duplicate uid" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
chmod 0644 "$T/etc/doas.conf"
expect_fail "validate rejects permissive doas.conf mode" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail "validate rejects passwordless doas grant" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# nopass must be rejected in EVERY token position after 'permit', not just
# immediately after the keyword (options may be reordered). The stderr
# assertion proves the nopass scan fired, not some unrelated check.
base
printf 'permit persist nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects nopass after persist option" "grants 'nopass'" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit keepenv nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects nopass after keepenv option" "grants 'nopass'" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit setenv { PATH } nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects nopass after setenv block" "grants 'nopass'" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# Conversely, 'nopass' that is not a grant token must not fail the scan:
# comment text and setenv VALUES are not options. The setenv lines cannot
# satisfy the effective-rule regex, so those files also keep the valid base
# rule; the property under test is the nopass token scan, not that regex.
base
printf 'permit persist :wheel\n' > "$T/etc/doas.conf"
expect_ok "validate accepts plain permit persist :wheel" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel\n# permit nopass\n' > "$T/etc/doas.conf"
expect_ok "validate ignores nopass in a comment line" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel\npermit setenv X=nopass :wheel\n' > "$T/etc/doas.conf"
expect_ok "validate accepts nopass as a setenv value (X=nopass)" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel\npermit setenv { PATH=nopass } :wheel\n' > "$T/etc/doas.conf"
expect_ok "validate accepts nopass as a brace setenv value (PATH=nopass)" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel # nopass\n' > "$T/etc/doas.conf"
expect_ok "validate ignores nopass in an inline comment" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# P2-nopass boundary: the nopass scan must stop BEFORE the first 'cmd'/'as'
# token, exactly like the effective-rule scan. A command ARGUMENT named
# nopass is not a doas option; a false positive here fails validation and
# triggers a recovery rebuild of a perfectly valid policy.
base
printf 'permit :wheel cmd /usr/bin/echo nopass\n' > "$T/etc/doas.conf"
expect_ok "validate accepts nopass as a cmd argument (whole file)" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit nopass :wheel cmd /usr/bin/echo x\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects nopass option before the cmd terminator" \
	"grants 'nopass'" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit :wheel as root cmd /usr/bin/echo nopass\n' > "$T/etc/doas.conf"
expect_ok "validate accepts nopass as a cmd argument after as (whole file)" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit nopass :wheel as root\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects nopass option before the as terminator" \
	"grants 'nopass'" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit :wheel cmd /usr/bin/echo x # nopass\n' > "$T/etc/doas.conf"
expect_ok "validate ignores nopass in an inline comment after cmd arguments" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# Round 1.5 setenv-aware scan: "as" and "cmd" inside a setenv { } block are
# environment variable names, NOT the cmd/as option terminators. The scans
# must skip the whole block, then resume for nopass / :wheel.
base
printf 'permit setenv { as } nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects nopass after a setenv { as } block" \
	"grants 'nopass'" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit setenv { cmd } nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects nopass after a setenv { cmd } block" \
	"grants 'nopass'" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit setenv { as } :wheel\n' > "$T/etc/doas.conf"
expect_ok "validate accepts :wheel identity after a setenv { as } block" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit setenv { as } :wheel cmd /usr/bin/echo nopass\n' > "$T/etc/doas.conf"
expect_ok "validate accepts a cmd argument after a setenv { as } block" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# Multi-rule bypass: a valid wheel rule on one line must not mask a nopass
# grant hidden after a setenv block on another line.
base
printf 'permit persist :wheel\npermit setenv { as } nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects a multi-rule nopass grant after setenv { as }" \
	"grants 'nopass'" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel\npermit setenv { cmd } nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects a multi-rule nopass grant after setenv { cmd }" \
	"grants 'nopass'" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel\npermit setenv { as } :wheel cmd /usr/bin/echo nopass\n' > "$T/etc/doas.conf"
expect_ok "validate accepts a multi-rule cmd argument after setenv { as }" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel\npermit setenv { cmd } :wheel cmd /usr/bin/echo nopass\n' > "$T/etc/doas.conf"
expect_ok "validate accepts a multi-rule cmd argument after setenv { cmd }" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# Effective-rule scan (r1B-498): whole-file cases, no extra base rule.
# A valid doas rule may carry options the old fixed regex cannot parse
# (setenv braces); :wheel must be the identity, i.e. appear BEFORE the
# first 'cmd'/'as' terminator, not as a command argument.
base
printf 'permit setenv { PATH } :wheel\n' > "$T/etc/doas.conf"
expect_ok "validate accepts setenv-brace rule for :wheel (whole file)" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit persist :wheel as root\n' > "$T/etc/doas.conf"
expect_ok "validate accepts :wheel before the as terminator (whole file)" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit root cmd /bin/foo :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects :wheel as a cmd argument (whole file)" \
	"no effective permit rule" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'deny :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate rejects deny-only policy (whole file)" \
	"no effective permit rule" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf '# permit :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "validate does not count a commented permit rule (whole file)" \
	"no effective permit rule" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'permit setenv { PATH } nopass :wheel\n' > "$T/etc/doas.conf"
expect_fail_msg "nopass gate still wins over effective-rule scan (whole file)" \
	"grants 'nopass'" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
chmod 0755 "$T/usr/bin/doas"
expect_fail "validate rejects non-setuid doas binary" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'root:x:0:\n' > "$T/etc/group"
expect_fail "validate rejects missing wheel group" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
rm -f "$T/etc/shadow"
expect_fail "validate rejects missing shadow" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
awk -F: 'BEGIN{OFS=":"} $1=="sane" {$2=""} {print}' "$T/etc/shadow" > "$T/etc/shadow.tmp"
mv "$T/etc/shadow.tmp" "$T/etc/shadow"
expect_fail "validate rejects an empty password field" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'clone:x:10:clone:/home/clone:/bin/sh\n' >> "$T/etc/group"
expect_fail "validate rejects duplicate gid" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base
printf 'blocked' > "$T/home/bob"
expect_fail "add-user aborts when home path is a file" sh "$ACCOUNTS" --root "$T" add-user bob 1007 --skip-chown
check "failed add leaves no passwd entry" sh -c "! grep -q '^bob:' '$T/etc/passwd'"
check "failed add leaves no shadow entry" sh -c "! grep -q '^bob:' '$T/etc/shadow'"
check "failed add leaves no group entry" sh -c "! grep -q '^bob:' '$T/etc/group'"

# Force the passwd append to fail (512-byte file-size limit) after the home,
# the new group and the group entry were already created. This exercises the
# rollback path that normal tests cannot reach.
base
i=0
while [ "$i" -lt 11 ]; do
	printf '# pad 012345678901234567890123456789\n' >> "$T/etc/passwd"
	i=$((i + 1))
done
expect_fail "add-user rolls back when passwd write fails" \
	sh -c 'ulimit -f 1; trap "" XFSZ; exec sh "$1" --root "$2" add-user alice 1005 developers --skip-chown' \
	sh "$ACCOUNTS" "$T"
check "rollback removes passwd entry" sh -c "! grep -q '^alice:' '$T/etc/passwd'"
check "rollback removes shadow entry" sh -c "! grep -q '^alice:' '$T/etc/shadow'"
check "rollback removes the differently-named group" sh -c \
	"! grep -q '^developers:' '$T/etc/group'"
check "rollback removes the home directory" test ! -d "$T/home/alice"
check "rollback restores passwd mode 0644" test "$(stat -c %a "$T/etc/passwd")" = 644
check "rollback restores group mode 0644" test "$(stat -c %a "$T/etc/group")" = 644
check "rollback restores shadow mode 0600" test "$(stat -c %a "$T/etc/shadow")" = 600

# init must not destroy an already-provisioned account set.
base
printf 'extra:x:1009:1009:extra:/home/extra:/bin/sh\n' >> "$T/etc/passwd"
expect_fail "init refuses to overwrite existing identity files" \
	sh "$ACCOUNTS" --root "$T" init
check "failed init preserved the extra account" sh -c \
	"grep -q '^extra:' '$T/etc/passwd'"
expect_ok "init --force overwrites when explicitly asked" \
	sh "$ACCOUNTS" --root "$T" init --force --firstboot
# K1: plain init without --firstboot (or --allow-weak-defaults with runtime
# passwords) must refuse to write password accounts -- there is no
# deterministic hash left to fall back to.
T2=$(mktemp -d)
mkdir -p "$T2/etc"
expect_fail_msg "plain init without --firstboot is rejected" \
	"refusing to write password accounts" \
	sh "$ACCOUNTS" --root "$T2" init --force
rm -rf -- "$T2"
check "init --force replaced the account table" sh -c \
	"! grep -q '^extra:' '$T/etc/passwd'"

# First-boot mode ships no known password.
base
T2=$(mktemp -d)
mkdir -p "$T2/etc"
sh "$ACCOUNTS" --root "$T2" init --firstboot
check "firstboot init leaves root locked" sh -c \
	"grep -q '^root:!:19700:' '$T2/etc/shadow'"
check "firstboot init leaves sane locked" sh -c \
	"grep -q '^sane:!:19700:' '$T2/etc/shadow'"
check "firstboot init stores no active password" sh -c \
	"awk -F: '\$2 !~ /^!/ {bad=1} END{exit bad}' '$T2/etc/shadow'"
rm -rf -- "$T2"

# A private group still used as another account's primary GID must survive.
base
sh "$ACCOUNTS" --root "$T" add-user alice 1005 --skip-chown
sh "$ACCOUNTS" --root "$T" add-user bob 1006 alice --skip-chown
expect_ok "del-user keeps a private group still in use" \
	sh "$ACCOUNTS" --root "$T" del-user alice
check "shared private group survives" sh -c \
	"grep -q '^alice:x:1005:' '$T/etc/group'"
check "surviving account keeps its primary gid" sh -c \
	"grep -q '^bob:x:1006:1005:' '$T/etc/passwd'"

base
printf 'permit persist :admins\n' > "$T/etc/doas.conf"
expect_fail "validate rejects a doas rule that does not grant wheel" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

if [ "$(id -u)" -eq 0 ]; then
	base
	chown 1000:1000 "$T/etc/doas.conf"
	expect_fail "validate rejects non-root doas.conf owner" \
		sh "$ACCOUNTS" --root "$T" validate
	base
	chown 1000:1000 "$T/usr/bin/doas"
	expect_fail "validate rejects non-root doas binary owner" \
		sh "$ACCOUNTS" --root "$T" validate
fi

# Provisioning is the single source of truth for the three build paths.
base
mkdir -p "$T/usr/bin"
printf stub > "$T/usr/bin/doas"
chmod 4755 "$T/usr/bin/doas"
expect_ok "provision-accounts writes a locked baseline by default" \
	sh "$REPO_ROOT/scripts/provision-accounts.sh" "$T"
check "provisioned shadow has no active password" sh -c \
	"grep -q '^root:!:19700:' '$T/etc/shadow' && grep -q '^sane:!:19700:' '$T/etc/shadow'"
check "provisioned root has no first-boot marker" test ! -f "$T/etc/.sane-firstboot-done"
check "provision installs sane-accounts CLI" test -x "$T/usr/bin/sane-accounts"
check "provision installs sane-firstboot helper" test -x "$T/usr/bin/sane-firstboot"

base
mkdir -p "$T/usr/bin"
printf stub > "$T/usr/bin/doas"
chmod 4755 "$T/usr/bin/doas"
SANE_TEST_CREDS_FILE="$T/sane-test-creds" SANE_WEAK_DEFAULT_CREDS=1 sh "$REPO_ROOT/scripts/provision-accounts.sh" "$T" >/dev/null 2>&1
check "weak-creds mode writes an active root hash" sh -c \
	"! grep -q '^root:!' '$T/etc/shadow'"
check "weak-creds mode marks first boot complete" test -f "$T/etc/.sane-firstboot-done"
# K1: the weak-creds passwords are random per run, recorded only in a 0600
# file outside the image -- never the deterministic root/root + sane/sane.
check "weak-creds mode writes a credentials file outside the image" test -f "$T/sane-test-creds"
check "credentials file is mode 0600" test "$(stat -c %a "$T/sane-test-creds")" = 600
check "weak-creds passwords are not the old defaults" sh -c \
	"! grep -q '^root:root$' '$T/sane-test-creds' && ! grep -q '^sane:sane$' '$T/sane-test-creds'"
rm -f "$T/sane-test-creds"

# Some POSIX mktemp implementations require an explicit template. Use a
# wrapper that enforces that interface while delegating to the real utility.
T2=$(mktemp -d)
mkdir -p "$T2/bin" "$T2/tmp"
REAL_MKTEMP=$(command -v mktemp)
cat > "$T2/bin/mktemp" <<EOF
#!/bin/sh
[ "\$#" -eq 1 ] || { printf 'mktemp: template required\n' >&2; exit 1; }
case "\$1" in *XXXXXX) ;; *) printf 'mktemp: six X template required\n' >&2; exit 1 ;; esac
exec "$REAL_MKTEMP" "\$@"
EOF
chmod 0755 "$T2/bin/mktemp"
base
expect_ok "provision works with template-only mktemp" \
	env PATH="$T2/bin:$PATH" TMPDIR="$T2/tmp" SANE_WEAK_DEFAULT_CREDS=1 \
	sh "$REPO_ROOT/scripts/provision-accounts.sh" "$T"
check "template-form mktemp creates credentials in TMPDIR" sh -c \
	"find '$T2/tmp' -type f -name 'sane-test-creds.*' | grep -q ."
rm -rf -- "$T2"

# First boot must not be killed by ninit's 30s once-service timeout.
for tpl in build-rootfs.sh make-image.sh sane-install.sh; do
	check "firstboot in $tpl has :timeout=0" sh -c \
		"grep -q '^firstboot:once:.*:timeout=0$' '$REPO_ROOT/scripts/$tpl'"
	check "recovery service in $tpl precedes firstboot" sh -c \
		"grep -q '^recovery:once:.*sane-account-recovery.*:on_fail=rescue:timeout=0$' '$REPO_ROOT/scripts/$tpl' && \
		 grep -q '^firstboot:once:.*:requires=recovery:on_fail=rescue:timeout=0$' '$REPO_ROOT/scripts/$tpl'"
done

check "firstboot clears stale passwd temp files" sh -c \
	"grep -q 'rm -f /etc/passwd+ /etc/shadow+' '$REPO_ROOT/scripts/sane-firstboot'"

printf '\n--- first-free id allocation (X11) ---\n'
# next_id must scan upward from 1000 for the first FREE id, not return
# max+1: a high-uid import (nobody 65534) must not push new accounts into
# the 65535 ceiling, and gaps below the maximum must be reused.
base
expect_ok "add-user nobody at the top of the range" \
	sh "$ACCOUNTS" --root "$T" add-user nobody 65534 --skip-chown
expect_ok "add-user bob succeeds with nobody at 65534" \
	sh "$ACCOUNTS" --root "$T" add-user bob --skip-chown
check "bob gets the lowest free uid (1001), not 65535" sh -c \
	"grep -q '^bob:x:1001:1001:' '$T/etc/passwd'"

base
expect_ok "add-user alice above a gap" \
	sh "$ACCOUNTS" --root "$T" add-user alice 1002 --skip-chown
expect_ok "add-user bob succeeds with a gap at 1001" \
	sh "$ACCOUNTS" --root "$T" add-user bob --skip-chown
check "bob fills the gap (uid 1001)" sh -c \
	"grep -q '^bob:x:1001:1001:' '$T/etc/passwd'"

# A completely full 1000..65534 range must fail with a clean error, not
# with the generic 'uid out of range' from the max+1 implementation.
base
awk 'BEGIN{for(i=1001;i<=65534;i++) printf "u%d:x:%d:%d:u%d:/home/u%d:/bin/sh\n", i, i, i, i, i}' >> "$T/etc/passwd"
expect_fail_msg "add-user reports a full uid range cleanly" "no free uid" \
	sh "$ACCOUNTS" --root "$T" add-user bob --skip-chown
check "full-range failure leaves no bob entry" sh -c \
	"! grep -q '^bob:' '$T/etc/passwd'"

base
awk 'BEGIN{for(i=1001;i<=65534;i++) printf "g%d:x:%d:\n", i, i}' >> "$T/etc/group"
expect_fail_msg "add-user reports a full gid range cleanly" "no free gid" \
	sh "$ACCOUNTS" --root "$T" add-user bob 1001 newgrp --skip-chown
check "full-gid failure leaves no bob entry" sh -c \
	"! grep -q '^bob:' '$T/etc/passwd'"

printf '\n--- account recovery (boot lockout prevention) ---\n'
stub_doas() {
	mkdir -p "$T/usr/bin"
	printf stub > "$T/usr/bin/doas"
	chmod 4755 "$T/usr/bin/doas"
}
check "recovery CLI exists" test -x "$ACCOUNTS"

base_firstboot() {
	[ -n "$T" ] && rm -rf -- "$T"
	T=$(mktemp -d)
	mkdir -p "$T/etc" "$T/home" "$T/usr/bin"
	stub_doas
	sh "$ACCOUNTS" --root "$T" --firstboot init >/dev/null
}

base_firstboot
set_pw root 'LifecyclePass1!'
expect_ok "recover on healthy files is safe" sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after recover on healthy files" sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base_firstboot
set_pw root 'LifecyclePass1!'
printf 'garbage\n' > "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_fail "validate rejects corrupted shadow" sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover rebuilds corrupted shadow" sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after recover" sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "recover re-arms firstboot when shadow hash is lost" test ! -f "$T/etc/.sane-firstboot-done"
check "recover writes locked root shadow" sh -c \
	"grep -q '^root:!:19700:' '$T/etc/shadow'"

base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
printf 'garbage\n' > "$T/etc/doas.conf"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "recover rebuilds corrupted doas.conf" sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after doas recovery" sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "recover keeps firstboot marker when root hash survives" test -f "$T/etc/.sane-firstboot-done"
check "recover preserves root hash from valid shadow" sh -c \
	"grep -q '^root:[\$]6[\$]' '$T/etc/shadow'"

base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
printf ':broken:\n' > "$T/etc/passwd"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "recover rebuilds corrupted passwd" sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after passwd recovery" sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "recover keeps firstboot marker when passwd is repaired" test -f "$T/etc/.sane-firstboot-done"

# A hash truncated by an interrupted passwd must fail validation and must not
# be preserved by recover (otherwise firstboot stays marked done with no login).
base_firstboot
set_pw root 'LifecyclePass1!'
awk -F: -v OFS=: '$1=="root"{$2="$6$truncated"}1' "$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_fail "validate rejects truncated SHA-512 hash" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover rebuilds from truncated root hash" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover re-arms firstboot when root hash is truncated" \
	test ! -f "$T/etc/.sane-firstboot-done"

# fbri67: a surviving root hash must not keep the done marker when the daily
# account lost its hash. Otherwise firstboot never reruns and sane stays locked.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
awk -F: -v OFS=: '$1=="sane"{$2="!"}1' "$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_fail "validate rejects locked sane with firstboot done" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover re-arms when only sane hash is lost" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover clears done marker when sane hash is lost" \
	test ! -f "$T/etc/.sane-firstboot-done"
check "recover restores sane to locked baseline" sh -c \
	"grep -q '^sane:!:19700:' '$T/etc/shadow'"

# Round 1.5 recover: doas_policy_ok must detect nopass grants hidden after
# setenv blocks, including the multi-rule file the base tool preserves.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
printf 'permit setenv { as } nopass :wheel\n' > "$T/etc/doas.conf"
chmod 0644 "$T/etc/doas.conf"
expect_ok "recover succeeds on a single-rule setenv nopass violation" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover replaces a single-rule setenv nopass policy" sh -c \
	"grep -q '^permit persist :wheel$' '$T/etc/doas.conf' && ! grep -q 'nopass' '$T/etc/doas.conf'"
check "recover repairs doas.conf mode after a setenv policy rebuild" \
	test "$(stat -c %a "$T/etc/doas.conf")" = 600
expect_ok "validate passes after the single-rule setenv rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
printf 'permit persist :wheel\npermit setenv { as } nopass :wheel\n' > "$T/etc/doas.conf"
chmod 0644 "$T/etc/doas.conf"
expect_ok "recover succeeds on a multi-rule setenv nopass bypass" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover rebuilds a preserved multi-rule nopass bypass" sh -c \
	"grep -q '^permit persist :wheel$' '$T/etc/doas.conf' && ! grep -q 'nopass' '$T/etc/doas.conf'"
check "recover repairs mode for a multi-rule bypass rebuild" \
	test "$(stat -c %a "$T/etc/doas.conf")" = 600
expect_ok "validate passes after the multi-rule bypass rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

printf '\n--- recover merge semantics (X6) ---\n'
# recover must MERGE, not rewrite: a validation failure caused by a mode
# bit or one corrupt file must not destroy other accounts, memberships or
# a policy-compliant doas.conf.

# A: doas.conf mode 644 + extra account + custom rule -> content survives.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
expect_ok "merge setup: add alice into wheel" \
	sh "$ACCOUNTS" --root "$T" add-user alice 1005 wheel --skip-chown
expect_ok "merge setup: give alice an active password" set_pw alice 'AliceMerge1!'
alice_shadow_before=$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")
alice_hash_before=$(awk -F: '$1=="alice"{print $2}' "$T/etc/shadow")
printf 'permit persist :wheel cmd /usr/bin/echo hello\n' > "$T/etc/doas.conf"
chmod 0644 "$T/etc/doas.conf"
expect_fail "validate flags the permissive doas.conf mode before merge" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover succeeds on a mode-only doas.conf failure" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover preserves the extra account in passwd" sh -c \
	"grep -q '^alice:x:1005:10:' '$T/etc/passwd'"
check "recover preserves wheel membership for the extra account" sh -c \
	"grep -q '^wheel:x:10:root,sane,alice$' '$T/etc/group'"
check "recover keeps alice's shadow entry" sh -c \
	"grep -q '^alice:' '$T/etc/shadow'"
alice_shadow_after=$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")
alice_hash_after=$(awk -F: '$1=="alice"{print $2}' "$T/etc/shadow")
check "recover preserves alice's shadow hash byte-for-byte" \
	test "$alice_hash_after" = "$alice_hash_before"
check "recover preserves alice's whole shadow entry byte-for-byte" \
	test "$alice_shadow_after" = "$alice_shadow_before"
check "recover preserves the custom doas rule" sh -c \
	"grep -q '^permit persist :wheel cmd /usr/bin/echo hello$' '$T/etc/doas.conf'"
check "recover repairs doas.conf mode to 600" \
	test "$(stat -c %a "$T/etc/doas.conf")" = 600
expect_ok "validate passes after the merge recover" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# B: a policy-violating doas.conf must still be replaced by the baseline.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
printf 'permit persist nopass :wheel\n' > "$T/etc/doas.conf"
expect_ok "recover succeeds on a nopass policy violation" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover drops the nopass rule for the baseline" sh -c \
	"grep -q '^permit persist :wheel$' '$T/etc/doas.conf' && ! grep -q 'nopass' '$T/etc/doas.conf'"
check "recover keeps doas.conf mode 600 after policy rebuild" \
	test "$(stat -c %a "$T/etc/doas.conf")" = 600
expect_ok "validate passes after the policy rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# C: duplicate uid -> passwd rebuilt, valid extra entries restored.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
sh "$ACCOUNTS" --root "$T" add-user alice 1005 --skip-chown >/dev/null
sh "$ACCOUNTS" --root "$T" add-user bob 1006 --skip-chown >/dev/null
printf 'clone:x:1005:1005:clone:/home/clone:/bin/sh\n' >> "$T/etc/passwd"
expect_fail "validate flags the duplicate uid before rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover succeeds on a duplicate-uid passwd" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after the passwd rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "rebuild preserves the valid alice entry" sh -c \
	"grep -q '^alice:x:1005:1005:' '$T/etc/passwd'"
check "rebuild preserves the valid bob entry" sh -c \
	"grep -q '^bob:x:1006:1006:' '$T/etc/passwd'"
check "rebuild drops the conflicting clone entry" sh -c \
	"! grep -q '^clone:' '$T/etc/passwd'"
check "rebuild preserves the alice private group" sh -c \
	"grep -q '^alice:x:1005:' '$T/etc/group'"
check "rebuild keeps root and sane baseline entries" sh -c \
	"grep -q '^root:x:0:0:' '$T/etc/passwd' && grep -q '^sane:x:1000:1000:' '$T/etc/passwd'"

# D: a missing sane entry is restored without touching extra accounts.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
sh "$ACCOUNTS" --root "$T" add-user alice 1005 --skip-chown >/dev/null
awk -F: '$1!="sane"' "$T/etc/passwd" > "$T/etc/passwd.new"
mv "$T/etc/passwd.new" "$T/etc/passwd"
expect_ok "recover succeeds when the sane entry is missing" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover restores the sane baseline entry" sh -c \
	"grep -q '^sane:x:1000:1000:S.A.N.E User:/home/sane:/bin/sh$' '$T/etc/passwd'"
check "recover preserves alice while restoring sane" sh -c \
	"grep -q '^alice:x:1005:1005:' '$T/etc/passwd'"
check "recover keeps the firstboot marker when hashes survive" \
	test -f "$T/etc/.sane-firstboot-done"
expect_ok "validate passes after restoring sane" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# F: duplicate gid -> group rebuilt, valid extra groups restored.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
sh "$ACCOUNTS" --root "$T" add-user alice 1005 --skip-chown >/dev/null
printf 'clone:x:1005:\n' >> "$T/etc/group"
expect_fail "validate flags the duplicate gid before rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover succeeds on a duplicate-gid group" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after the group rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "group rebuild preserves the valid alice group" sh -c \
	"grep -q '^alice:x:1005:$' '$T/etc/group'"
check "group rebuild drops the conflicting clone group" sh -c \
	"! grep -q '^clone:' '$T/etc/group'"
check "group rebuild restores wheel with root and sane" sh -c \
	"grep -q '^wheel:x:10:root,sane$' '$T/etc/group'"

# G: recover reports the action taken for each file, not just the hashes.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
chmod 0644 "$T/etc/doas.conf"
sh "$ACCOUNTS" --root "$T" $VFLAGS recover > "$T/recover-out" 2>&1
check "recover reports doas.conf preserved per file" sh -c \
	"grep -q 'doas.conf preserved' '$T/recover-out'"
check "recover reports passwd merge action per file" sh -c \
	"grep -q 'passwd merged' '$T/recover-out'"
check "recover reports group merge action per file" sh -c \
	"grep -q 'group merged' '$T/recover-out'"
check "recover reports shadow merge action per file" sh -c \
	"grep -q 'shadow merged' '$T/recover-out'"

# H: sane's baseline uid occupied by an extra account -> conflict rebuild
# (a blind merge would append sane and create a duplicate uid, leaving a
# state that still fails validation).
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
awk -F: '$1!="sane"' "$T/etc/passwd" > "$T/etc/passwd.new"
mv "$T/etc/passwd.new" "$T/etc/passwd"
expect_ok "conflict setup: alice takes the freed uid 1000" \
	sh "$ACCOUNTS" --root "$T" add-user alice 1000 wheel --skip-chown
expect_ok "recover succeeds when sane's uid is occupied" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover restores sane at uid 1000 despite the conflict" sh -c \
	"grep -q '^sane:x:1000:1000:' '$T/etc/passwd'"
check "recover drops the conflicting uid-1000 extra entry" sh -c \
	"! grep -q '^alice:' '$T/etc/passwd'"
expect_ok "validate passes after the conflict rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

printf '\n--- shadow preservation (P1-1) ---\n'
# A structurally sound shadow must keep every extra entry byte-for-byte;
# only a genuinely corrupt one is rebuilt, then valid non-conflicting extra
# entries are appended again. root/sane hashes are repaired only when the old
# hash is usable; the firstboot marker contract stays exactly as before.

# B: a corrupt shadow (garbage line) is rebuilt, but usable root/sane hashes
# and the valid extra entry are carried back into the baseline.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
expect_ok "shadow setup: add alice to wheel" \
	sh "$ACCOUNTS" --root "$T" add-user alice 1005 wheel --skip-chown
expect_ok "shadow setup: give alice an active password" set_pw alice 'AliceCorrupt1!'
root_hash_before=$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")
sane_hash_before=$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")
alice_hash_corrupt_before=$(awk -F: '$1=="alice"{print $2}' "$T/etc/shadow")
printf 'garbage\n' >> "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_fail "validate rejects a shadow with a corrupt extra line" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover rebuilds a corrupt shadow with valid extras" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after the corrupt shadow rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "corrupt shadow recover keeps the firstboot marker" \
	test -f "$T/etc/.sane-firstboot-done"
check "corrupt shadow recover preserves the usable root hash" \
	test "$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")" = "$root_hash_before"
check "corrupt shadow recover preserves the usable sane hash" \
	test "$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")" = "$sane_hash_before"
check "corrupt shadow recover restores the valid alice hash" \
	test "$(awk -F: '$1=="alice"{print $2}' "$T/etc/shadow")" = "$alice_hash_corrupt_before"
check "corrupt shadow recover keeps alice in passwd" sh -c \
	"grep -q '^alice:x:1005:10:' '$T/etc/passwd'"
check "corrupt shadow recover drops the malformed shadow line" sh -c \
	"! grep -q '^garbage$' '$T/etc/shadow'"

# C: neither hash is usable -> baseline locked, marker removed, and a fresh
# firstboot can set both passwords and validate cleanly.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
printf 'done\n' > "$T/etc/.sane-firstboot-done"
awk -F: -v OFS=: '$1=="root" || $1=="sane" {$2="!"} 1' \
	"$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
expect_fail "validate rejects missing root/sane hashes with firstboot done" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover repairs missing hashes" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "P1-1 removes the firstboot marker when hashes are missing" \
	test ! -f "$T/etc/.sane-firstboot-done"
check "P1-1 restores the locked root baseline" sh -c \
	"grep -q '^root:!:19700:0:99999:7:::$' '$T/etc/shadow'"
check "P1-1 restores the locked sane baseline" sh -c \
	"grep -q '^sane:!:19700:0:99999:7:::$' '$T/etc/shadow'"
expect_ok "validate passes with the marker removed" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "firstboot helper is present to set passwords again" \
	test -x "$REPO_ROOT/scripts/sane-firstboot"
expect_ok "firstboot can set a new root password" set_pw root 'FirstPass123!'
expect_ok "firstboot can set a new sane password" set_pw sane 'FirstPass234!'
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "validate passes after a successful firstboot rerun" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# Empty fields are corrupt rather than locked markers. Recovery must rebuild
# them as locked accounts and re-arm firstboot instead of crashing or unlocking.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
awk -F: -v OFS=: '$1=="root" || $1=="sane" {$2=""} 1' \
	"$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_fail "validate rejects empty root/sane fields before recovery" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover handles empty root/sane fields" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "empty-field recovery locks root and sane" sh -c \
	"grep -q '^root:!:19700:' '$T/etc/shadow' && grep -q '^sane:!:19700:' '$T/etc/shadow'"
check "empty-field recovery removes the firstboot marker" \
	test ! -f "$T/etc/.sane-firstboot-done"
expect_ok "validate passes after empty-field recovery" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# D: a corrupt shadow with both an active and a locked extra hash. The rebuild
# must restore both byte-for-byte, drop a duplicate name and an invalid hash,
# and discard the line that made the file structurally corrupt.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
expect_ok "shadow rebuild setup: add alice and bob to wheel" sh -c \
	"sh '$ACCOUNTS' --root '$T' add-user alice 1005 wheel --skip-chown >/dev/null && \
	 sh '$ACCOUNTS' --root '$T' add-user bob 1006 wheel --skip-chown >/dev/null && \
	 sh '$ACCOUNTS' --root '$T' add-user mallory 1007 --skip-chown >/dev/null"
expect_ok "shadow rebuild setup: alice gets an active hash" set_pw alice 'AliceActive1!'
expect_ok "shadow rebuild setup: bob gets a locked hash" set_pw bob 'BobLocked123!'
expect_ok "shadow rebuild setup: lock bob" sh "$ACCOUNTS" --root "$T" lock bob
alice_active_before=$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")
bob_locked_before=$(awk -F: '$1=="bob"{print}' "$T/etc/shadow")
awk -F: -v OFS=: '$1=="mallory"{$2="plaintext"} 1' \
	"$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
printf '%s\ngarbage\n%s\n' "$alice_active_before" "$alice_active_before" >> "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_fail "validate rejects the corrupt shadow with mixed extra entries" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover rebuilds a shadow with active and locked extras" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after the mixed shadow rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "rebuild keeps the active extra entry byte-for-byte" \
	test "$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")" = "$alice_active_before"
check "rebuild keeps the locked extra entry byte-for-byte" \
	test "$(awk -F: '$1=="bob"{print}' "$T/etc/shadow")" = "$bob_locked_before"
check "rebuild keeps the lock marker on bob" sh -c \
	"grep -q '^bob:!' '$T/etc/shadow'"
check "rebuild drops a duplicate valid extra name" \
	test "$(grep -c '^alice:' "$T/etc/shadow")" -eq 1
check "rebuild drops an extra with an invalid active hash" sh -c \
	"! grep -q '^mallory:' '$T/etc/shadow'"
check "rebuild drops the corrupt garbage line" sh -c \
	"! grep -q '^garbage$' '$T/etc/shadow'"

printf '\n--- shadow field3 empty means aging disabled (C2) ---\n'
# shadow(5): an empty third field disables password aging. It is valid and
# must survive both merge and rebuild byte-for-byte; a non-digit field3 is
# still invalid and must be dropped.

# A: mode-only doas.conf failure must preserve an extra whose field3 is empty.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
expect_ok "field3 setup: add alice to wheel" \
	sh "$ACCOUNTS" --root "$T" add-user alice 1005 wheel --skip-chown
expect_ok "field3 setup: give alice an active password" set_pw alice 'AliceAging1!'
awk -F: -v OFS=: '$1=="alice"{$3=""} 1' \
	"$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
alice_field3_before=$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")
check "field3 setup: alice's third field is empty" sh -c \
	"awk -F: '\$1==\"alice\"{exit (\$3==\"\" ? 0 : 1)}' '$T/etc/shadow'"
printf 'permit persist :wheel cmd /usr/bin/echo hello\n' > "$T/etc/doas.conf"
chmod 0644 "$T/etc/doas.conf"
expect_fail "validate flags the permissive doas.conf mode with an empty field3" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover succeeds with an empty-field3 extra entry" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover keeps the empty-field3 alice line byte-identical" \
	test "$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")" = "$alice_field3_before"
check "recover leaves alice in passwd" sh -c \
	"grep -q '^alice:x:1005:10:' '$T/etc/passwd'"
expect_ok "validate passes after the empty-field3 merge" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# B: a corrupt shadow is rebuilt, and a valid empty-field3 extra is restored.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
expect_ok "field3 rebuild setup: add alice to wheel" \
	sh "$ACCOUNTS" --root "$T" add-user alice 1005 wheel --skip-chown
expect_ok "field3 rebuild setup: give alice an active password" set_pw alice 'AliceAging2!'
awk -F: -v OFS=: '$1=="alice"{$3=""} 1' \
	"$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
alice_field3_corrupt_before=$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")
root_hash_field3_before=$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")
sane_hash_field3_before=$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")
printf 'garbage\n' >> "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_fail "validate rejects a corrupt shadow with an empty-field3 extra" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "recover rebuilds a shadow with an empty-field3 extra" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after the empty-field3 rebuild" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "empty-field3 rebuild keeps the firstboot marker" \
	test -f "$T/etc/.sane-firstboot-done"
check "empty-field3 rebuild preserves the root hash" \
	test "$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")" = "$root_hash_field3_before"
check "empty-field3 rebuild preserves the sane hash" \
	test "$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")" = "$sane_hash_field3_before"
check "empty-field3 rebuild restores alice byte-identically" \
	test "$(awk -F: '$1=="alice"{print}' "$T/etc/shadow")" = "$alice_field3_corrupt_before"
check "empty-field3 rebuild drops the malformed line" sh -c \
	"! grep -q '^garbage$' '$T/etc/shadow'"

# C: a non-digit field3 is still invalid, so the extra entry is dropped.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
expect_ok "non-digit setup: add alice to wheel" \
	sh "$ACCOUNTS" --root "$T" add-user alice 1005 wheel --skip-chown
expect_ok "non-digit setup: give alice an active password" set_pw alice 'AliceBadAge1!'
awk -F: -v OFS=: '$1=="alice"{$3="bogus"} 1' \
	"$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "recover rejects a non-digit field3 extra" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "recover drops the non-digit field3 extra" sh -c \
	"! grep -q '^alice:' '$T/etc/shadow'"
expect_ok "validate passes after dropping the non-digit field3 extra" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "non-digit field3 rebuild keeps the firstboot marker" \
	test -f "$T/etc/.sane-firstboot-done"

check "provision installs account recovery helper" \
	test -f "$REPO_ROOT/scripts/sane-account-recovery"

printf '\n--- recovery boot wrapper (branch coverage) ---\n'
WRAPPER="$REPO_ROOT/scripts/sane-account-recovery"
check "recovery wrapper is present and readable" test -f "$WRAPPER"
: > "$T/cli-calls"
cat > "$T/stub-cli" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$T/cli-calls"
case "\$*" in
	*validate*) rc=0; [ -f "$T/validate-fail" ] && rc=1 ;;
	*recover*)  rc=0
	            [ -f "$T/recover-fail" ] && rc=1
	            rm -f "$T/validate-fail" ;;
	*) rc=1 ;;
esac
exit "\$rc"
STUB
chmod +x "$T/stub-cli"
cat > "$T/stub-shell" <<STUB
#!/bin/sh
printf 'fallback shell reached\n' >> "$T/cli-calls"
exit 42
STUB
chmod +x "$T/stub-shell"

run_wrapper() {
	SANE_ACCOUNTS_CLI="$T/stub-cli" \
	SANE_RECOVERY_SHELL="$T/stub-shell" \
	SANE_RECOVERY_BIN_DIR="$T" \
		sh "$WRAPPER"
}

: > "$T/cli-calls"
expect_ok "wrapper exits 0 when validation passes" run_wrapper
check "wrapper validates and does not recover when healthy" sh -c \
	"[ \$(wc -l < '$T/cli-calls') -eq 1 ] && grep -q 'validate' '$T/cli-calls'"

: > "$T/cli-calls"; touch "$T/validate-fail"
expect_ok "wrapper recovers when validation fails" run_wrapper
check "wrapper validates, recovers, then revalidates" sh -c \
	"[ \$(wc -l < '$T/cli-calls') -eq 3 ] && \
	 grep -q 'recover' '$T/cli-calls'"

: > "$T/cli-calls"; touch "$T/validate-fail" "$T/recover-fail"
run_wrapper >/dev/null 2>&1
check "wrapper drops to shell when rebuild fails" \
	test "$(grep -c 'fallback shell reached' "$T/cli-calls")" -eq 1

printf '\n--- reliability:once fail-closed wrapper (extracted wiring) ---\n'
# Extract the LIVE reliability:once command from build-rootfs.sh instead of
# hardcoding a copy, so wiring drift is caught here. Only the absolute tool
# path is redirected to a stub; the /bin/sh -c structure, the fail-closed
# || { echo ...; exit 1; } branch and :timeout=0 stay verbatim. The stub
# performs no host operations (it only exits with the requested code).
rel_line=$(grep '^reliability:once:' "$REPO_ROOT/scripts/build-rootfs.sh")
check "reliability:once wiring present in build-rootfs.sh" test -n "$rel_line"
check "reliability:once wiring carries on_fail=rescue and timeout=0" sh -c \
	"grep -q '^reliability:once:.*:on_fail=rescue:timeout=0\$' '$REPO_ROOT/scripts/build-rootfs.sh'"
check "reliability:once wiring byte-identical across the 3 builders" sh -c \
	"grep -h 'reliability:once' '$REPO_ROOT/scripts/build-rootfs.sh' '$REPO_ROOT/scripts/make-image.sh' '$REPO_ROOT/scripts/sane-install.sh' | sort -u | md5sum | grep -q '^e2945f26938e65bae7a08ce841763f08'"
check "network:once wiring byte-identical across the 3 builders" sh -c \
	"grep -h 'network:once' '$REPO_ROOT/scripts/build-rootfs.sh' '$REPO_ROOT/scripts/make-image.sh' '$REPO_ROOT/scripts/sane-install.sh' | sort -u | md5sum | grep -q '^77a839731687c05b1e0fe2e0f1d0810a'"
rel_cmd=${rel_line#reliability:once:}
rel_cmd=${rel_cmd%:on_fail=rescue:timeout=0}
rel_cmd=${rel_cmd%:timeout=0}
rel_stub_cmd=$(printf '%s\n' "$rel_cmd" | sed "s|/usr/bin/sane-reliability|$T/stub-reliability|")

run_rel_wrapper() {
	printf '#!/bin/sh\nexit %s\n' "$1" > "$T/stub-reliability"
	chmod +x "$T/stub-reliability"
	REL_ERR=$(eval "$rel_stub_cmd" 2>&1 >/dev/null)
	REL_RC=$?
}

run_rel_wrapper 1
check "fail-closed wrapper exits nonzero when recover fails" test "$REL_RC" -ne 0
case "$REL_ERR" in
	*'reliability: recover failed; boot enters rescue'*)
		pass "fail-closed wrapper cites the caller's exact stderr notice" ;;
	*) fail "fail-closed wrapper missing the caller's exact stderr notice: $REL_ERR" ;;
esac

run_rel_wrapper 0
check "wrapper exits 0 when recover succeeds" test "$REL_RC" -eq 0
check "wrapper stays silent when recover succeeds" test -z "$REL_ERR"

printf '\n--- recover corruption-loss boundary (merge semantics) ---\n'
# The corruption itself destroyed the extra passwd line (the file was
# overwritten with garbage), so recover cannot bring it back: the rebuild
# restores only lines still present and valid. The healthy group file is
# MERGED, so the extra group survives; shadow is always rebuilt from the
# locked baseline, so the extra shadow entry is still dropped by design.
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
sh "$ACCOUNTS" --root "$T" add-user extra 1010 --skip-chown >/dev/null
printf 'garbage\n' > "$T/etc/passwd"
expect_ok "recover rebuilds corrupted passwd with an extra account present" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after the corruption rebuild" sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "recover restores root and sane" sh -c \
	"grep -q '^root:' '$T/etc/passwd' && grep -q '^sane:' '$T/etc/passwd'"
check "recover preserves the usable root and sane hashes" sh -c \
	"grep -q '^root:[\$]6[\$]' '$T/etc/shadow' && grep -q '^sane:[\$]6[\$]' '$T/etc/shadow'"
check "extra passwd entry destroyed by the corruption stays lost" sh -c \
	"! grep -q '^extra:' '$T/etc/passwd'"
check "extra account group survives the healthy-group merge" sh -c \
	"grep -q '^extra:x:1010:$' '$T/etc/group'"
check "extra account shadow entry is lost by design" sh -c \
	"! grep -q '^extra:' '$T/etc/shadow'"
check "extra home directory survives as an orphan" test -d "$T/home/extra"

printf '\n--- recovery applet symlink guard (PR #31 policy) ---\n'
# The guard only runs when awk/mktemp are absent from PATH and a busybox
# binary exists. Restrict PATH to a dir holding just ln, and point the
# busybox path at a stub, so the loop runs hermetically inside $T and can
# never touch host /bin or /usr/bin.
mkdir -p "$T/gbin" "$T/pathbin"
ln -s "$(command -v ln)" "$T/pathbin/ln"
printf '#!/bin/sh\nexit 0\n' > "$T/stub-busybox"
chmod +x "$T/stub-busybox"
printf '#!/bin/sh\nexit 0\n' > "$T/guard-cli"
chmod +x "$T/guard-cli"

run_guard() {
	PATH="$T/pathbin" \
	SANE_RECOVERY_BUSYBOX="$T/stub-busybox" \
	SANE_RECOVERY_BIN_DIR="$T/gbin" \
	SANE_ACCOUNTS_CLI="$T/guard-cli" \
		/bin/sh "$WRAPPER"
}

# 1. anti-clobber: an existing regular file must survive byte-for-byte.
printf 'precious awk bytes\n' > "$T/gbin/awk"
cp "$T/gbin/awk" "$T/awk-expected"
expect_ok "applet guard run exits 0 with a regular file present" run_guard
check "regular file at BIN_DIR/awk is not replaced by a symlink" sh -c \
	"[ -f '$T/gbin/awk' ] && [ ! -L '$T/gbin/awk' ]"
check "regular file at BIN_DIR/awk keeps its bytes" cmp -s "$T/gbin/awk" "$T/awk-expected"

# 2. absent path: the busybox symlink is created (awk and mktemp).
rm -f "$T/gbin/awk" "$T/gbin/mktemp"
expect_ok "applet guard run exits 0 with absent paths" run_guard
check "absent BIN_DIR/awk becomes a busybox symlink" sh -c \
	"[ -L '$T/gbin/awk' ] && [ \"\$(readlink '$T/gbin/awk')\" = '$T/stub-busybox' ]"
check "absent BIN_DIR/mktemp becomes a busybox symlink" sh -c \
	"[ -L '$T/gbin/mktemp' ] && [ \"\$(readlink '$T/gbin/mktemp')\" = '$T/stub-busybox' ]"

# 3. dangling symlink: repaired to the busybox target.
rm -f "$T/gbin/awk"
ln -s "$T/no-such-target" "$T/gbin/awk"
expect_ok "applet guard run exits 0 with a dangling symlink" run_guard
check "dangling BIN_DIR/awk symlink is repaired" sh -c \
	"[ -L '$T/gbin/awk' ] && [ \"\$(readlink '$T/gbin/awk')\" = '$T/stub-busybox' ]"

# 4. correct symlink: left alone (same target AND same inode).
rm -f "$T/gbin/awk"
ln -s "$T/stub-busybox" "$T/gbin/awk"
awk_inode=$(stat -c %i "$T/gbin/awk")
expect_ok "applet guard run exits 0 with a correct symlink" run_guard
check "correct BIN_DIR/awk symlink keeps its target" sh -c \
	"[ -L '$T/gbin/awk' ] && [ \"\$(readlink '$T/gbin/awk')\" = '$T/stub-busybox' ]"
check "correct BIN_DIR/awk symlink is not recreated" \
	test "$(stat -c %i "$T/gbin/awk")" = "$awk_inode"

printf '\n--- lock preservation across recover merge & rebuild (sane.md) ---\n'
# Intentionally locked root or sane accounts carrying a valid SHA-512 hash
# ('!<hash>') must keep their lock prefix across both merge_shadow() and
# rebuild_shadow(), while remaining unlockable via sane-accounts unlock.

# 1. Locked root (valid SHA-512 hash) during merge recovery (mode-only doas.conf error)
base_firstboot
set_pw root 'LockedRootPass1!'
set_pw sane 'ActiveSanePass1!'
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "lock root with valid hash before merge recovery" \
	sh "$ACCOUNTS" --root "$T" lock root
root_locked_before=$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")
sane_unlocked_before=$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")
chmod 0644 "$T/etc/doas.conf"
expect_ok "merge recover succeeds with locked root hash" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "merge recover keeps lock marker on root" sh -c \
	"grep -q '^root:![\$]6[\$]' '$T/etc/shadow'"
check "merge recover keeps locked root hash byte-for-byte" \
	test "$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")" = "$root_locked_before"
check "merge recover leaves active sane hash unlocked" \
	test "$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")" = "$sane_unlocked_before"
check "merge recover keeps firstboot marker for locked valid root" \
	test -f "$T/etc/.sane-firstboot-done"
expect_ok "validate passes after merge recover with locked root" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate
expect_ok "locked root can still be explicitly unlocked later" \
	sh "$ACCOUNTS" --root "$T" unlock root

# 2. Locked sane (valid SHA-512 hash) during merge recovery
base_firstboot
set_pw root 'ActiveRootPass1!'
set_pw sane 'LockedSanePass1!'
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "lock sane with valid hash before merge recovery" \
	sh "$ACCOUNTS" --root "$T" lock sane
root_unlocked_before=$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")
sane_locked_before=$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")
chmod 0644 "$T/etc/doas.conf"
expect_ok "merge recover succeeds with locked sane hash" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "merge recover keeps lock marker on sane" sh -c \
	"grep -q '^sane:![\$]6[\$]' '$T/etc/shadow'"
check "merge recover keeps locked sane hash byte-for-byte" \
	test "$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")" = "$sane_locked_before"
check "merge recover leaves active root hash unlocked" \
	test "$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")" = "$root_unlocked_before"
expect_ok "validate passes after merge recover with locked sane" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# 3. Both root and sane locked with valid hashes during corrupt-shadow rebuild
base_firstboot
set_pw root 'RebuildLockedRoot1!'
set_pw sane 'RebuildLockedSane1!'
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "rebuild setup: lock root with valid hash" sh "$ACCOUNTS" --root "$T" lock root
expect_ok "rebuild setup: lock sane with valid hash" sh "$ACCOUNTS" --root "$T" lock sane
root_locked_rebuild=$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")
sane_locked_rebuild=$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")
printf 'corrupt-line\n' >> "$T/etc/shadow"
expect_ok "rebuild recover succeeds with locked root and sane" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "rebuild recover drops corrupt shadow line" sh -c \
	"! grep -q '^corrupt-line$' '$T/etc/shadow'"
check "rebuild recover keeps locked root hash byte-for-byte" \
	test "$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")" = "$root_locked_rebuild"
check "rebuild recover keeps locked sane hash byte-for-byte" \
	test "$(awk -F: '$1=="sane"{print $2}' "$T/etc/shadow")" = "$sane_locked_rebuild"
expect_ok "validate passes after rebuild recover with locked baselines" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS validate

# 4. Locked valid root + missing sane hash -> root keeps locked hash, sane becomes '!', marker cleared
base_firstboot
set_pw root 'RebuildLockedRoot2!'
set_pw sane 'TemporarySanePass1!'
printf 'done\n' > "$T/etc/.sane-firstboot-done"
expect_ok "partial setup: lock root with valid hash" sh "$ACCOUNTS" --root "$T" lock root
root_partial_locked=$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")
awk -F: -v OFS=: '$1=="sane"{$2="!"} 1' "$T/etc/shadow" > "$T/etc/shadow.new"
mv "$T/etc/shadow.new" "$T/etc/shadow"
expect_ok "partial recover succeeds when root is locked-valid and sane has no hash" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
check "partial recover preserves locked valid root hash" \
	test "$(awk -F: '$1=="root"{print $2}' "$T/etc/shadow")" = "$root_partial_locked"
check "partial recover keeps bare locked baseline for missing sane hash" sh -c \
	"grep -q '^sane:!:19700:' '$T/etc/shadow'"
check "partial recover clears firstboot marker when sane hash is missing" \
	test ! -f "$T/etc/.sane-firstboot-done"

printf '\nPhase A account tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
