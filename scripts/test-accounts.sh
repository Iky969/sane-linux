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
expect_fail "unknown user password rejected" set_pw nobody secret
expect_ok "set-password updates shadow" set_pw alice secret
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
sed -i 's/^sane:\$6\$/sane:plaintext/' "$T/etc/shadow"
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
	sh "$ACCOUNTS" --root "$T" init --force
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
SANE_WEAK_DEFAULT_CREDS=1 sh "$REPO_ROOT/scripts/provision-accounts.sh" "$T" >/dev/null 2>&1
check "weak-creds mode writes an active root hash" sh -c \
	"! grep -q '^root:!' '$T/etc/shadow'"
check "weak-creds mode marks first boot complete" test -f "$T/etc/.sane-firstboot-done"

# First boot must not be killed by ninit's 30s once-service timeout.
for tpl in build-rootfs.sh make-image.sh sane-install.sh; do
	check "firstboot in $tpl has :timeout=0" sh -c \
		"grep -q '^firstboot:once:.*:timeout=0$' '$REPO_ROOT/scripts/$tpl'"
	check "recovery service in $tpl precedes firstboot" sh -c \
		"grep -q '^recovery:once:.*sane-account-recovery.*:timeout=0$' '$REPO_ROOT/scripts/$tpl' && \
		 grep -q '^firstboot:once:.*:requires=recovery:timeout=0$' '$REPO_ROOT/scripts/$tpl'"
done

check "firstboot clears stale passwd temp files" sh -c \
	"grep -q 'rm -f /etc/passwd+ /etc/shadow+' '$REPO_ROOT/scripts/sane-firstboot'"

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

printf '\n--- reliability:once fail-open wrapper (extracted wiring) ---\n'
# Extract the LIVE reliability:once command from build-rootfs.sh instead of
# hardcoding a copy, so wiring drift is caught here. Only the absolute tool
# path is redirected to a stub; the /bin/sh -c structure, the fail-open
# || echo branch and :timeout=0 stay verbatim. The stub performs no host
# operations (it only exits with the requested code).
rel_line=$(grep '^reliability:once:' "$REPO_ROOT/scripts/build-rootfs.sh")
check "reliability:once wiring present in build-rootfs.sh" test -n "$rel_line"
check "reliability:once wiring carries timeout=0" sh -c \
	"grep -q '^reliability:once:.*:timeout=0\$' '$REPO_ROOT/scripts/build-rootfs.sh'"
check "reliability:once wiring byte-identical across the 3 builders" sh -c \
	"grep -h 'reliability:once' '$REPO_ROOT/scripts/build-rootfs.sh' '$REPO_ROOT/scripts/make-image.sh' '$REPO_ROOT/scripts/sane-install.sh' | sort -u | md5sum | grep -q '^5f794f774c3989b8282b0a493ea2584b'"
rel_cmd=${rel_line#reliability:once:}
rel_cmd=${rel_cmd%:timeout=0}
rel_stub_cmd=$(printf '%s\n' "$rel_cmd" | sed "s|/usr/bin/sane-reliability|$T/stub-reliability|")

run_rel_wrapper() {
	printf '#!/bin/sh\nexit %s\n' "$1" > "$T/stub-reliability"
	chmod +x "$T/stub-reliability"
	REL_ERR=$(eval "$rel_stub_cmd" 2>&1 >/dev/null)
	REL_RC=$?
}

run_rel_wrapper 1
check "fail-open wrapper exits 0 when recover fails" test "$REL_RC" -eq 0
case "$REL_ERR" in
	*'reliability: recover failed; continuing boot'*)
		pass "fail-open wrapper cites continue-boot notice on stderr" ;;
	*) fail "fail-open wrapper missing continue-boot notice: $REL_ERR" ;;
esac

run_rel_wrapper 0
check "wrapper exits 0 when recover succeeds" test "$REL_RC" -eq 0
check "wrapper stays silent when recover succeeds" test -z "$REL_ERR"

printf '\n--- recover data-loss boundary (root+sane only, by design) ---\n'
base_firstboot
set_pw root 'LifecyclePass1!'
set_pw sane 'LifecyclePass2!'
sh "$ACCOUNTS" --root "$T" add-user extra 1010 --skip-chown >/dev/null
printf 'garbage\n' > "$T/etc/passwd"
expect_ok "recover rebuilds corrupted passwd with an extra account present" \
	sh "$ACCOUNTS" --root "$T" $VFLAGS recover
expect_ok "validate passes after the data-loss rebuild" sh "$ACCOUNTS" --root "$T" $VFLAGS validate
check "recover restores root and sane" sh -c \
	"grep -q '^root:' '$T/etc/passwd' && grep -q '^sane:' '$T/etc/passwd'"
check "recover preserves the usable root and sane hashes" sh -c \
	"grep -q '^root:[\$]6[\$]' '$T/etc/shadow' && grep -q '^sane:[\$]6[\$]' '$T/etc/shadow'"
check "extra account passwd entry is lost by design" sh -c \
	"! grep -q '^extra:' '$T/etc/passwd'"
check "extra account group is lost by design" sh -c \
	"! grep -q '^extra:' '$T/etc/group'"
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

printf '\nPhase A account tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
