#!/bin/sh
# scripts/test-reliability.sh -- Phase C reliability regression suite.
# Runs without root against a temporary target rootfs. No host state is touched.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TOOL="$REPO_ROOT/scripts/sane-reliability"

PASS=0
FAIL=0
T=

pass() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1" >&2; }

check() { desc=$1; shift; if "$@"; then pass "$desc"; else fail "$desc"; fi; }
expect_ok() { desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
expect_fail() { desc=$1; shift; if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi; }

base() {
	[ -n "$T" ] && rm -rf -- "$T"
	T=$(mktemp -d)
	mkdir -p "$T/etc" "$T/var/lib/spm/installed/demo" "$T/var/log"
	printf 'network:once:/bin/true\n' > "$T/etc/init.conf"
	printf '1.0.0\n' > "$T/var/lib/spm/installed/demo/version"
	chmod 0644 "$T/etc/init.conf"
}

cleanup() { [ -n "$T" ] && rm -rf -- "$T"; }
trap cleanup EXIT HUP INT TERM

run() { sh "$TOOL" --root "$T" "$@"; }

base

# --- init ------------------------------------------------------------------
expect_ok "init creates the reliability state" run init
check "snapshot dir exists" test -d "$T/var/lib/sane/reliability/snapshots"
check "staging dir exists" test -d "$T/var/lib/sane/reliability/staging"
check "log dir exists" test -d "$T/var/log/sane"
check "journal starts idle" sh -c "grep -q '^state=idle$' '$T/var/lib/sane/reliability/journal'"
expect_ok "init is idempotent" run init

# --- snapshot / list / verify ----------------------------------------------
expect_ok "snapshot with a valid tag" run snapshot baseline
check "snapshot dir created" test -d "$T/var/lib/sane/reliability/snapshots/baseline"
check "snapshot keeps manifest" test -f "$T/var/lib/sane/reliability/snapshots/baseline/manifest.sha256"
check "snapshot keeps meta" test -f "$T/var/lib/sane/reliability/snapshots/baseline/meta"
check "snapshot copies /etc/init.conf" sh -c \
	"cmp -s '$T/etc/init.conf' '$T/var/lib/sane/reliability/snapshots/baseline/etc/init.conf'"
check "snapshot copies spm DB" sh -c \
	"cmp -s '$T/var/lib/spm/installed/demo/version' '$T/var/lib/sane/reliability/snapshots/baseline/var/lib/spm/installed/demo/version'"
expect_ok "verify accepts an intact snapshot" run verify baseline
expect_fail "invalid tag rejected" run snapshot ../escape
expect_fail "duplicate tag rejected" run snapshot baseline
expect_ok "force replaces an existing tag" run snapshot baseline --force

base
run init
run snapshot baseline
expect_ok "list prints the snapshot tag" sh -c "run() { sh '$TOOL' --root '$T' \"\$@\"; }; run list | grep -q baseline"
printf 'corrupted\n' > "$T/var/lib/sane/reliability/snapshots/baseline/etc/init.conf"
expect_fail "verify rejects a corrupted snapshot" run verify baseline

base
run init
expect_fail "verify unknown snapshot rejected" run verify missing

# --- rollback ---------------------------------------------------------------
base
run init
run snapshot golden
printf 'network:once:/bin/false\n' > "$T/etc/init.conf"
chmod 0600 "$T/etc/init.conf"
expect_ok "rollback restores a file" run rollback golden
check "rollback restored content" sh -c \
	"grep -q '^network:once:/bin/true$' '$T/etc/init.conf'"
check "rollback restored mode" test "$(stat -c %a "$T/etc/init.conf")" = 644
check "rollback journal records state" sh -c \
	"grep -q '^state=rolled-back$' '$T/var/lib/sane/reliability/journal'"
check "rollback made a safety snapshot" sh -c \
	"ls -d '$T/var/lib/sane/reliability/snapshots'/auto-pre-rollback-* >/dev/null 2>&1"
expect_fail "rollback to unknown tag rejected" run rollback missing

base
run init
run snapshot broken
printf 'bad\n' > "$T/var/lib/sane/reliability/snapshots/broken/etc/init.conf"
expect_fail "rollback rejects a corrupted snapshot" run rollback broken

# --- upgrade / recover ------------------------------------------------------
base
run init
mkdir -p "$T/payload/etc"
printf 'network:once:/bin/sleep 5\n' > "$T/payload/etc/init.conf"
expect_fail "upgrade rejects payload without manifest" run upgrade "$T/payload"
(cd "$T/payload" && sha256sum etc/init.conf > manifest.sha256)
expect_ok "upgrade with a valid payload" run upgrade "$T/payload"
check "upgrade committed the new file" sh -c \
	"grep -q '/bin/sleep 5' '$T/etc/init.conf'"
check "upgrade created a pre-upgrade snapshot" sh -c \
	"ls -d '$T/var/lib/sane/reliability/snapshots'/auto-pre-upgrade-* >/dev/null 2>&1"
check "upgrade journal records done" sh -c \
	"grep -q '^state=done$' '$T/var/lib/sane/reliability/journal'"
expect_ok "recover is a no-op after a successful upgrade" run recover

base
run init
run snapshot before
printf 'network:once:/bin/false\n' > "$T/etc/init.conf"
printf 'state=in-progress\nsnapshot=before\n' > "$T/var/lib/sane/reliability/journal"
expect_ok "recover restores the recorded snapshot" run recover
check "recover restored content" sh -c \
	"grep -q '/bin/true' '$T/etc/init.conf'"
check "recover journal records recovered" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal'"

base
run init
run snapshot broken2
printf 'bad\n' > "$T/var/lib/sane/reliability/snapshots/broken2/etc/init.conf"
printf 'state=in-progress\nsnapshot=broken2\n' > "$T/var/lib/sane/reliability/journal"
expect_fail "recover rejects a corrupted snapshot" run recover

# --- network recovery -------------------------------------------------------
setup_net_recovery() {
	base
	run init
	mkdir -p "$T/bin"
	printf 'nameserver 1.1.1.1\n' > "$T/etc/resolv.conf.default"
	printf 'nameserver 192.0.2.1\n' > "$T/etc/resolv.conf"
	chmod 0600 "$T/etc/resolv.conf.default"
	: > "$T/net-recover.calls"
	cat > "$T/bin/sane-net" <<EOF
#!/bin/sh
printf 'sane-net %s SANE_ROOT=%s\n' "\$*" "\${SANE_ROOT:-}" >> '$T/net-recover.calls'
[ "\${SANE_ROOT:-}" = '$T' ] || exit 92
grep -q '^state=net-in-progress\$' '$T/var/lib/sane/reliability/journal' || exit 90
grep -q "^net-iface=\${2:-}\$" '$T/var/lib/sane/reliability/journal' || exit 93
: > '$T/network-saw-net-in-progress'
grep -q '^nameserver 1.1.1.1\$' '$T/etc/resolv.conf' || exit 91
case "\${1:-}" in
  reconnect) [ "\${NET_RECONNECT_FAIL:-0}" != 1 ] || exit 42 ;;
  check) [ "\${NET_CHECK_FAIL:-0}" != 1 ] || exit 43 ;;
  *) exit 44 ;;
esac
exit 0
EOF
	chmod 0755 "$T/bin/sane-net"
}

run_net_recover() {
	env PATH="$T/bin:$PATH" sh "$TOOL" --root "$T" net-recover "$@"
}

run_net_recover_fail() {
	env PATH="$T/bin:$PATH" NET_RECONNECT_FAIL=1 \
		sh "$TOOL" --root "$T" net-recover "$@"
}

run_net_recover_check_fail() {
	env PATH="$T/bin:$PATH" NET_CHECK_FAIL=1 \
		sh "$TOOL" --root "$T" net-recover "$@"
}

run_recover_with_net_stub() {
	env PATH="$T/bin:$PATH" sh "$TOOL" --root "$T" recover
}

setup_net_recovery
expect_ok "net-recover succeeds with default eth0" run_net_recover
check "net-recover restores the default resolver" sh -c \
	"cmp -s '$T/etc/resolv.conf' '$T/etc/resolv.conf.default'"
check "net-recover installs resolver with mode 0644" \
	test "$(stat -c %a "$T/etc/resolv.conf")" = 644
check "net-recover leaves journal recovered with interface" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "net-recover records net-in-progress before network calls" \
	test -f "$T/network-saw-net-in-progress"
check "net-recover reconnects then checks with target SANE_ROOT" sh -c \
	"sed -n '1p' '$T/net-recover.calls' | grep -qx 'sane-net reconnect eth0 SANE_ROOT=$T' && sed -n '2p' '$T/net-recover.calls' | grep -qx 'sane-net check eth0 SANE_ROOT=$T' && test \"\$(wc -l < '$T/net-recover.calls')\" -eq 2"
check "net-recover logs successful recovery" sh -c \
	"grep -q ' INFO .*recover' '$T/var/log/sane/reliability.log'"

setup_net_recovery
expect_ok "net-recover accepts an explicit interface" run_net_recover --iface wlan1
check "net-recover forwards the explicit interface to both calls" sh -c \
	"grep -qx 'sane-net reconnect wlan1 SANE_ROOT=$T' '$T/net-recover.calls' && grep -qx 'sane-net check wlan1 SANE_ROOT=$T' '$T/net-recover.calls'"
check "net-recover preserves explicit interface in recovered journal" \
	grep -q '^net-iface=wlan1$' "$T/var/lib/sane/reliability/journal"

setup_net_recovery
printf 'state=in-progress\n' > "$T/var/lib/sane/reliability/journal"
expect_ok "recover migrates a tagless legacy journal to eth0" \
	run_recover_with_net_stub
check "legacy migration records recovered default interface" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal' && ! grep -q '^snapshot=' '$T/var/lib/sane/reliability/journal'"
check "legacy migration logs a WARN and uses default network calls" sh -c \
	"grep -q ' WARN .*legacy.*eth0' '$T/var/log/sane/reliability.log' && grep -qx 'sane-net reconnect eth0 SANE_ROOT=$T' '$T/net-recover.calls' && grep -qx 'sane-net check eth0 SANE_ROOT=$T' '$T/net-recover.calls'"
check "legacy empty net-iface logs the explicit defaulting WARN" \
	grep -q ' WARN legacy journal missing net-iface, defaulting to eth0' "$T/var/log/sane/reliability.log"
check "legacy migration never creates a snapshot" \
	sh -c "test -z \"\$(ls -A '$T/var/lib/sane/reliability/snapshots')\""

setup_net_recovery
printf 'state=in-progress\nnet-iface=wlan7\n' > "$T/var/lib/sane/reliability/journal"
expect_ok "recover honors a legacy recorded interface" run_recover_with_net_stub
check "legacy interface migration finishes recovered" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=wlan7$' '$T/var/lib/sane/reliability/journal'"
check "legacy interface migration reconnects and checks recorded iface" sh -c \
	"grep -qx 'sane-net reconnect wlan7 SANE_ROOT=$T' '$T/net-recover.calls' && grep -qx 'sane-net check wlan7 SANE_ROOT=$T' '$T/net-recover.calls'"
check "legacy recorded interface does not log the defaulting WARN" \
	sh -c "! grep -q 'legacy journal missing net-iface' '$T/var/log/sane/reliability.log'"

setup_net_recovery
expect_fail "net-recover fails closed when reconnect fails" run_net_recover_fail
check "failed reconnect leaves network journal and interface" sh -c \
	"grep -q '^state=net-in-progress$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "failed reconnect still restores the default resolver" sh -c \
	"cmp -s '$T/etc/resolv.conf' '$T/etc/resolv.conf.default'"
check "failed reconnect logs an ERROR and skips check" sh -c \
	"grep -q ' ERROR .*reconnect.*eth0' '$T/var/log/sane/reliability.log' && ! grep -q '^sane-net check ' '$T/net-recover.calls'"
expect_ok "recover retries interrupted reconnect without a snapshot" \
	run_recover_with_net_stub
check "recover finishes reconnect retry with recovered interface" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "recover reruns reconnect and then check" sh -c \
	"test \"\$(grep -c '^sane-net reconnect eth0 SANE_ROOT=$T$' '$T/net-recover.calls')\" -eq 2 && test \"\$(grep -c '^sane-net check eth0 SANE_ROOT=$T$' '$T/net-recover.calls')\" -eq 1"

setup_net_recovery
expect_fail "net-recover fails closed when check fails" \
	run_net_recover_check_fail --iface wlan9
check "failed check leaves network journal with retry interface" sh -c \
	"grep -q '^state=net-in-progress$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=wlan9$' '$T/var/lib/sane/reliability/journal'"
check "failed check logs ERROR without marking recovered" sh -c \
	"grep -q ' ERROR .*check.*wlan9' '$T/var/log/sane/reliability.log' && ! grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal'"
expect_ok "recover retries the recorded interface after check failure" \
	run_recover_with_net_stub
check "recover after check failure records recovered interface" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=wlan9$' '$T/var/lib/sane/reliability/journal'"
check "recover after check failure repeats reconnect and check" sh -c \
	"test \"\$(grep -c '^sane-net reconnect wlan9 SANE_ROOT=$T$' '$T/net-recover.calls')\" -eq 2 && test \"\$(grep -c '^sane-net check wlan9 SANE_ROOT=$T$' '$T/net-recover.calls')\" -eq 2"
check "interrupted network recovery has no snapshot tag" \
	sh -c "! grep -q '^snapshot=' '$T/var/lib/sane/reliability/journal'"

setup_net_recovery
rm -f "$T/etc/resolv.conf.default"
expect_fail "net-recover rejects a missing default resolver" run_net_recover
check "missing resolver leaves current resolver unchanged" sh -c \
	"grep -q '^nameserver 192.0.2.1$' '$T/etc/resolv.conf'"
check "missing resolver leaves network journal and interface" sh -c \
	"grep -q '^state=net-in-progress$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "missing resolver logs an ERROR and skips network calls" sh -c \
	"grep -q ' ERROR ' '$T/var/log/sane/reliability.log' && test ! -s '$T/net-recover.calls'"

setup_net_recovery
expect_fail "net-recover rejects an unsafe interface" run_net_recover --iface bad/iface
check "invalid interface has no recovery side effects" sh -c \
	"grep -q '^state=idle$' '$T/var/lib/sane/reliability/journal' && test ! -s '$T/net-recover.calls'"
expect_fail "net-recover rejects unknown options" run_net_recover --force
printf 'state=net-in-progress\n' > "$T/var/lib/sane/reliability/journal"
expect_fail "recover rejects a missing network interface" \
	run_recover_with_net_stub
check "missing network interface stays safe and unrecovered" sh -c \
	"test ! -s '$T/net-recover.calls' && grep -q '^state=net-in-progress$' '$T/var/lib/sane/reliability/journal'"
printf 'state=net-in-progress\nnet-iface=bad/iface\n' > "$T/var/lib/sane/reliability/journal"
expect_fail "recover rejects an invalid recorded network interface" \
	run_recover_with_net_stub
check "invalid recovery interface has no network calls" test ! -s "$T/net-recover.calls"

# --- Invalid DNS must block recovery (strict stub check) --------------------
setup_invalid_dns_recovery() {
	base
	run init
	mkdir -p "$T/bin"
	printf 'nameserver 1.1.1.1\n' > "$T/etc/resolv.conf.default"
	printf 'nameserver 192.0.2.1\n' > "$T/etc/resolv.conf"
	: > "$T/net-recover.calls"
	cat > "$T/bin/sane-net" <<EOF
#!/bin/sh
printf 'sane-net %s SANE_ROOT=%s\n' "\$*" "\${SANE_ROOT:-}" >> '$T/net-recover.calls'
[ "\${SANE_ROOT:-}" = '$T' ] || exit 92
valid_ip() {
  case "\$1" in
    *:*) return 0 ;;
  esac
  set -- \$(printf '%s' "\$1" | tr '.' ' ')
  [ "\$#" -eq 4 ] || return 1
  for o in "\$@"; do
    case "\$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "\$o" -le 255 ] || return 1
  done
  return 0
}
case "\${1:-}" in
  reconnect) exit 0 ;;
  check)
    [ -f '$T/etc/resolv.conf' ] || exit 1
    found=0
    while IFS= read -r line; do
      case "\$line" in
        'nameserver '*)
          ns=\${line#nameserver }
          found=1
          valid_ip "\$ns" || exit 1
          ;;
      esac
    done < '$T/etc/resolv.conf'
    [ "\$found" -eq 1 ] || exit 1
    exit 0
    ;;
  *) exit 44 ;;
esac
EOF
	chmod 0755 "$T/bin/sane-net"
}

setup_invalid_dns_recovery
printf 'nameserver not-an-ip\n' > "$T/etc/resolv.conf.default"
expect_fail "net-recover blocks recovery on an invalid DNS hostname" run_net_recover
check "invalid DNS hostname leaves net-in-progress journal" sh -c \
	"grep -q '^state=net-in-progress$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "invalid DNS hostname logs ERROR and never writes recovered" sh -c \
	"grep -q ' ERROR .*check.*eth0' '$T/var/log/sane/reliability.log' && ! grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal'"

setup_invalid_dns_recovery
printf 'nameserver 999.1.1.1\n' > "$T/etc/resolv.conf.default"
expect_fail "net-recover blocks recovery on a malformed IPv4 nameserver" run_net_recover
check "malformed IPv4 leaves net-in-progress journal" sh -c \
	"grep -q '^state=net-in-progress$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "malformed IPv4 logs ERROR and never writes recovered" sh -c \
	"grep -q ' ERROR .*check.*eth0' '$T/var/log/sane/reliability.log' && ! grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal'"

# --- Real sane-net and udhcpc event integration -----------------------------
# Only ip, udhcpc and sleep are stubs. sane-net and default.script are real.
DHCP_SCRIPT_SOURCE="$REPO_ROOT/packages/busybox/x/usr/share/udhcpc/default.script"
setup_real_net_recovery() {
	base
	run init
	mkdir -p "$T/realbin" "$T/usr/share/udhcpc"
	printf 'nameserver 1.1.1.1\n' > "$T/etc/resolv.conf.default"
	printf 'nameserver 192.0.2.10\n' > "$T/etc/resolv.conf"
	: > "$T/real-network.calls"
	printf 'no\n' > "$T/dhcp-address-present"
	printf 'no\n' > "$T/dhcp-route-present"
	ln -s "$REPO_ROOT/packages/ninit/x/usr/bin/sane-net" "$T/realbin/sane-net"
	ln -s "$DHCP_SCRIPT_SOURCE" "$T/usr/share/udhcpc/default.script"
	cat > "$T/realbin/ip" <<EOF
#!/bin/sh
printf 'ip %s\n' "\$*" >> '$T/real-network.calls'
case "\$*" in
  'link show dev eth0')
    printf '2: eth0: <BROADCAST,MULTICAST,UP> state UP mode DEFAULT\n' ;;
  'link set eth0 up') ;;
  'addr flush dev eth0')
    printf 'no\n' > '$T/dhcp-address-present' ;;
  'addr add 198.51.100.20/24 dev eth0')
    printf 'yes\n' > '$T/dhcp-address-present' ;;
  '-4 addr show dev eth0 scope global')
    [ "\$(cat '$T/dhcp-address-present')" = yes ] || exit 1
    printf '    inet 198.51.100.20/24 brd 198.51.100.255 scope global eth0\n' ;;
  'route add default via 198.51.100.1 dev eth0')
    printf 'yes\n' > '$T/dhcp-route-present' ;;
  'route show default dev eth0')
    [ "\$(cat '$T/dhcp-route-present')" = yes ] || exit 1
    printf 'default via 198.51.100.1 dev eth0\n' ;;
  *) exit 1 ;;
esac
exit 0
EOF
	cat > "$T/realbin/udhcpc" <<EOF
#!/bin/sh
printf 'udhcpc %s\n' "\$*" >> '$T/real-network.calls'
script=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -s) [ "\$#" -ge 2 ] || exit 31; script=\$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$script" ] || exit 32
[ "\$script" = '$T/usr/share/udhcpc/default.script' ] || exit 33
[ -f "\$script" ] || exit 34
[ "\${SANE_ROOT:-}" = '$T' ] || exit 35
env SANE_ROOT='$T' interface=eth0 ip=198.51.100.20 mask=24 \
  router=198.51.100.1 dns="\${DHCP_LEASE_DNS:-9.9.9.9 1.0.0.1}" domain=lease.test \
  sh "\$script" bound
EOF
	cat > "$T/realbin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
	chmod 0755 "$T/realbin/ip" "$T/realbin/udhcpc" "$T/realbin/sleep"
}

require_root_aware_dhcp() {
	# Fail safely if either real script can still resolve host /etc paths.
	grep -q 'SANE_ROOT' "$REPO_ROOT/packages/ninit/x/usr/bin/sane-net" && \
		grep -Eq 'RESOLV=.*ROOT|RESOLV=.*root' \
			"$REPO_ROOT/packages/ninit/x/usr/bin/sane-net" && \
		grep -q 'SANE_ROOT' "$DHCP_SCRIPT_SOURCE" && \
		grep -Eq 'RESOLV_CONF=.*ROOT|RESOLV_CONF=.*root' "$DHCP_SCRIPT_SOURCE" || {
		printf '%s\n' 'real networking lacks SANE_ROOT resolver support' >&2
		return 1
	}
}

run_real_net_recovery() {
	require_root_aware_dhcp || return 1
	env PATH="$T/realbin:$PATH" sh "$TOOL" --root "$T" net-recover
}

run_real_dhcp_deconfig() {
	require_root_aware_dhcp || return 1
	env PATH="$T/realbin:$PATH" SANE_ROOT="$T" interface=eth0 \
		sh "$T/usr/share/udhcpc/default.script" deconfig
}

setup_real_net_recovery
HOST_RESOLV_BEFORE=$(sha256sum /etc/resolv.conf)
expect_ok "real reconnect invokes default.script for a DHCP lease" \
	run_real_net_recovery
HOST_RESOLV_AFTER_BOUND=$(sha256sum /etc/resolv.conf)
check "real DHCP bound leaves host resolver checksum unchanged" \
	test "$HOST_RESOLV_BEFORE" = "$HOST_RESOLV_AFTER_BOUND"
check "real udhcpc parses and invokes the root-aware event script" \
	grep -q -- "-s $T/usr/share/udhcpc/default.script" "$T/real-network.calls"
check "real DHCP bound writes both lease nameservers" sh -c \
	"grep -q '^nameserver 9.9.9.9$' '$T/etc/resolv.conf' && grep -q '^nameserver 1.0.0.1$' '$T/etc/resolv.conf'"
check "real DHCP bound writes lease domain and removes old resolver" sh -c \
	"grep -q '^domain lease.test$' '$T/etc/resolv.conf' && ! grep -q '192.0.2.10' '$T/etc/resolv.conf'"
check "real event script performs temp-root address and route mutations" sh -c \
	"grep -qx 'ip addr add 198.51.100.20/24 dev eth0' '$T/real-network.calls' && grep -qx 'ip route add default via 198.51.100.1 dev eth0' '$T/real-network.calls'"
check "real post-check requires IPv4 on the requested interface twice" sh -c \
	"test \"\$(grep -cx 'ip -4 addr show dev eth0 scope global' '$T/real-network.calls')\" -ge 2"
check "real post-check uses per-interface default route twice" sh -c \
	"test \"\$(grep -cx 'ip route show default dev eth0' '$T/real-network.calls')\" -ge 2"
check "real integration never uses a bare route query" \
	sh -c "! grep -qx 'ip route show' '$T/real-network.calls'"
check "real integration recovered the expected interface" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
expect_ok "real default.script deconfig succeeds" run_real_dhcp_deconfig
check "real deconfig restores target default resolver" \
	sh -c "cmp -s '$T/etc/resolv.conf' '$T/etc/resolv.conf.default'"
check "real deconfig flushes the leased address in temp state" \
	grep -q '^no$' "$T/dhcp-address-present"
HOST_RESOLV_AFTER_DECONFIG=$(sha256sum /etc/resolv.conf)
check "bound and deconfig leave host resolver checksum unchanged" \
	test "$HOST_RESOLV_BEFORE" = "$HOST_RESOLV_AFTER_DECONFIG"

# Real integration: an invalid DNS lease must not be marked recovered.
# This stays RED until sane-net check validates nameservers as real IP addresses.
run_real_net_recovery_invalid_dns() {
	require_root_aware_dhcp || return 1
	env DHCP_LEASE_DNS='not-an-ip' PATH="$T/realbin:$PATH" \
		sh "$TOOL" --root "$T" net-recover
}

setup_real_net_recovery
printf 'nameserver not-an-ip\n' > "$T/etc/resolv.conf.default"
HOST_RESOLV_BEFORE_INVALID=$(sha256sum /etc/resolv.conf)
expect_fail "real sane-net check rejects an invalid DNS lease" \
	run_real_net_recovery_invalid_dns
check "invalid DNS lease leaves net-in-progress journal" sh -c \
	"grep -q '^state=net-in-progress$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "invalid DNS lease logs ERROR and never writes recovered" sh -c \
	"grep -q ' ERROR ' '$T/var/log/sane/reliability.log' && ! grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal'"
HOST_RESOLV_AFTER_INVALID=$(sha256sum /etc/resolv.conf)
check "invalid DNS integration leaves host resolver checksum unchanged" \
	test "$HOST_RESOLV_BEFORE_INVALID" = "$HOST_RESOLV_AFTER_INVALID"

# --- logging ---------------------------------------------------------------
base
run init
expect_ok "log writes an INFO entry" run log INFO "upgrade started"
check "log line has timestamp and level" sh -c \
	"grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* INFO upgrade started$' '$T/var/log/sane/reliability.log'"
expect_fail "log rejects an invalid level" run log VERBOSE "nope"
expect_fail "log rejects an empty message" run log INFO ""

base
run init
dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\0' 'x' > "$T/var/log/sane/reliability.log"
expect_ok "log rotates an oversized file" run log INFO "after rotation"
check "rotated log exists" test -f "$T/var/log/sane/reliability.log.1"
check "current log only has the new entry" test "$(wc -l < "$T/var/log/sane/reliability.log")" = 1

# --- backup / restore -------------------------------------------------------
base
run init
run snapshot keepme
expect_ok "backup creates an archive" run backup "$T/backup.tar.gz"
check "archive is non-empty" test -s "$T/backup.tar.gz"
expect_fail "backup refuses to overwrite by default" run backup "$T/backup.tar.gz"
expect_ok "backup --force overwrites" run backup "$T/backup.tar.gz" --force

base
expect_fail "restore rejects a missing archive" run restore "$T/nope.tar.gz"

base
run init
run snapshot keepme
run backup "$T/backup.tar.gz"
T2=$(mktemp -d)
mkdir -p "$T2/etc"
expect_ok "restore into a fresh root" sh -c \
	"sh '$TOOL' --root '$T2' restore '$T/backup.tar.gz'"
check "restore brings back the snapshot" test -d \
	"$T2/var/lib/sane/reliability/snapshots/keepme"
check "restore brings back the log dir" test -d "$T2/var/log/sane"
rm -rf -- "$T2"

# --- security / fail-closed regressions ------------------------------------
# A manifest path must never escape the target root.
base
run init
mkdir -p "$T/payload"
OUT=$(mktemp "$(dirname "$T")/sane-rel-escape.XXXXXX")
name=${OUT##*/}
printf 'pwned\n' > "$T/$name"
printf '%s  ./../%s\n' "$(sha256sum "$T/$name" | cut -d' ' -f1)" "$name" > "$T/payload/manifest.sha256"
printf 'sentinel\n' > "$OUT"
expect_fail "upgrade rejects traversal path in payload manifest" run upgrade "$T/payload"
check "upgrade did not overwrite a file outside the target root" sh -c \
	"grep -q '^sentinel$' '$OUT'"
rm -f "$OUT"

base
run init
run snapshot baseline
OUT=$(mktemp "$(dirname "$T")/sane-rel-escape.XXXXXX")
name=${OUT##*/}
printf 'pwned\n' > "$T/var/lib/sane/reliability/$name"
printf '%s  ./../%s\n' \
	"$(sha256sum "$T/var/lib/sane/reliability/$name" | cut -d' ' -f1)" \
	"$name" > "$T/var/lib/sane/reliability/snapshots/baseline/manifest.sha256"
printf 'sentinel\n' > "$OUT"
expect_fail "verify rejects traversal path in snapshot manifest" run verify baseline
expect_fail "rollback rejects traversal path in snapshot manifest" run rollback baseline
check "rollback did not overwrite a file outside the target root" sh -c \
	"grep -q '^sentinel$' '$OUT'"
rm -f "$OUT"

# NUL-delimited manifest: filenames with spaces must survive.
base
run init
printf 'spaced\n' > "$T/var/lib/spm/installed/demo/has space.txt"
expect_ok "snapshot handles filenames with spaces" run snapshot spaced
expect_ok "verify handles filenames with spaces" run verify spaced

# Archive validation: unsafe members are rejected before extraction.
base
run init
run snapshot keepme
mkdir -p "$T/evil/var/lib/sane/reliability/snapshots" "$T/evil/var/log/sane"
ln -s /etc/passwd "$T/evil/var/lib/sane/reliability/snapshots/absolute"
printf 'log\n' > "$T/evil/var/log/sane/reliability.log"
tar -czf "$T/evil.tar.gz" -C "$T/evil" var
expect_fail "restore rejects an absolute symlink in the archive" run restore "$T/evil.tar.gz"
check "absolute symlink was not installed" test ! -L \
	"$T/var/lib/sane/reliability/snapshots/absolute"
python3 - "$T/traversal.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], 'w:gz') as tf:
    data = b'pwned\n'
    info = tarfile.TarInfo('var/lib/sane/reliability/snapshots/../../../escape.txt')
    info.size = len(data)
    tf.addfile(info, io.BytesIO(data))
PY
expect_fail "restore rejects a traversal member in the archive" run restore "$T/traversal.tar.gz"

# --- Restore hardening: journal trust + symlink chain containment -----------
# (a) An archive captured mid-upgrade carries state=in-progress + snapshot=X.
# Restore must force the journal to idle (state only) so the next recover
# cannot roll the freshly restored state back to X.
base
run init
run snapshot archx
printf 'mutated-after-snapshot\n' > "$T/etc/init.conf"
printf 'state=in-progress\nsnapshot=archx\n' > "$T/var/lib/sane/reliability/journal"
run backup "$T/inprogress.tar.gz"
T2=$(mktemp -d)
mkdir -p "$T2/etc"
printf 't2-original\n' > "$T2/etc/init.conf"
expect_ok "restore forces an archived in-progress journal to idle" sh -c \
	"sh '$TOOL' --root '$T2' restore '$T/inprogress.tar.gz'"
check "restored journal is idle without snapshot tag or interface" sh -c \
	"grep -q '^state=idle$' '$T2/var/lib/sane/reliability/journal' && ! grep -q '^snapshot=' '$T2/var/lib/sane/reliability/journal' && ! grep -q '^net-iface=' '$T2/var/lib/sane/reliability/journal'"
check "restore brings the archived snapshot itself" test -d \
	"$T2/var/lib/sane/reliability/snapshots/archx"
expect_ok "recover after restore is a no-op" sh -c \
	"sh '$TOOL' --root '$T2' recover"
check "no-op recover leaves the target file untouched" \
	grep -q '^t2-original$' "$T2/etc/init.conf"
check "no-op recover keeps the journal idle" \
	grep -q '^state=idle$' "$T2/var/lib/sane/reliability/journal"
check "archived snapshot was never applied after restore" sh -c \
	"! grep -q 'recovered from interrupted upgrade' '$T2/var/log/sane/reliability.log' && ! grep -q 'rollback to' '$T2/var/log/sane/reliability.log'"
rm -rf -- "$T2"

# (b) A relative symlink chain that escapes the staging root must be rejected
# with a specific reason, and nothing may be installed over existing state.
base
run init
run snapshot existing
mkdir -p "$T/evil/var/lib/sane/reliability/snapshots" "$T/evil/var/log/sane"
ln -s b "$T/evil/var/a"
ln -s ../../outside "$T/evil/var/b"
printf 'log\n' > "$T/evil/var/log/sane/reliability.log"
tar -czf "$T/evil-chain.tar.gz" -C "$T/evil" var
: > "$T/restore.err"
find "$T" -mindepth 1 ! -name before.list ! -name after.list | LC_ALL=C sort > "$T/before.list"
if sh "$TOOL" --root "$T" restore "$T/evil-chain.tar.gz" 2>"$T/restore.err"; then
	fail "restore rejects an escaping relative symlink chain"
else
	pass "restore rejects an escaping relative symlink chain"
fi
check "escaping chain rejection names the symlink chain reason" \
	grep -q 'unsafe symlink chain in archive' "$T/restore.err"
find "$T" -mindepth 1 ! -name before.list ! -name after.list | LC_ALL=C sort > "$T/after.list"
check "rejected chain restore installed nothing and kept existing state" \
	cmp -s "$T/before.list" "$T/after.list"
check "rejected chain restore left the journal idle" \
	grep -q '^state=idle$' "$T/var/lib/sane/reliability/journal"

# (c) An internal relative chain (including '..' that stays inside the staging
# root after normalization) must be accepted and installed.
base
mkdir -p "$T/good/var/lib/sane/reliability/snapshots/sub" "$T/good/var/log/sane"
ln -s sub/b "$T/good/var/lib/sane/reliability/snapshots/a"
ln -s ../c "$T/good/var/lib/sane/reliability/snapshots/sub/b"
printf 'internal-payload\n' > "$T/good/var/lib/sane/reliability/snapshots/c"
printf 'log\n' > "$T/good/var/log/sane/reliability.log"
tar -czf "$T/internal-chain.tar.gz" -C "$T/good" var
T2=$(mktemp -d)
expect_ok "restore accepts an internal relative symlink chain" sh -c \
	"sh '$TOOL' --root '$T2' restore '$T/internal-chain.tar.gz'"
check "internal chain symlinks installed with targets preserved" sh -c \
	"test -L '$T2/var/lib/sane/reliability/snapshots/a' && test -L '$T2/var/lib/sane/reliability/snapshots/sub/b' && [ \"\$(readlink '$T2/var/lib/sane/reliability/snapshots/a')\" = sub/b ] && [ \"\$(readlink '$T2/var/lib/sane/reliability/snapshots/sub/b')\" = ../c ]"
check "internal chain final file installed" \
	grep -q '^internal-payload$' "$T2/var/lib/sane/reliability/snapshots/c"
check "internal chain restore ends with an idle journal" \
	grep -q '^state=idle$' "$T2/var/lib/sane/reliability/journal"
rm -rf -- "$T2"

# Force replacement must not destroy the old snapshot before the new one is in place.
base
run init
run snapshot old
printf 'new\n' > "$T/etc/init.conf"
expect_ok "snapshot --force replaces an existing tag" run snapshot old --force
check "forced snapshot holds the new content" sh -c \
	"grep -q '^new$' '$T/var/lib/sane/reliability/snapshots/old/etc/init.conf'"
check "force leaves no stale backup directories" sh -c \
	"! ls -d '$T/var/lib/sane/reliability/snapshots'/.old.* >/dev/null 2>&1"

# Two safety snapshots in the same second must get distinct tags.
base
run init
run snapshot golden
expect_ok "first rollback succeeds" run rollback golden
expect_ok "second rollback in the same second succeeds" run rollback golden
check "two distinct safety snapshots exist" sh -c \
	"[ \$(ls -d '$T/var/lib/sane/reliability/snapshots'/auto-pre-rollback-* 2>/dev/null | wc -l) -ge 2 ]"

# --- P1-A: destination symlink containment ---------------------------------
# A payload/rollback destination must never traverse a symlink that resolves
# outside the target root. Internal-root symlinks remain allowed.
base
run init
OUTSIDE=$(mktemp -d)
rm -rf "$T/etc"
ln -s "$OUTSIDE" "$T/etc"
mkdir -p "$T/payload/etc"
printf 'pwned\n' > "$T/payload/etc/init.conf"
(cd "$T/payload" && sha256sum etc/init.conf > manifest.sha256)
expect_fail "upgrade rejects a top-level etc symlink escaping root" run upgrade "$T/payload"
check "escaping etc symlink wrote nothing outside root" test ! -e "$OUTSIDE/init.conf"
rm -rf "$OUTSIDE"

base
run init
OUTSIDE=$(mktemp -d)
ln -s "$OUTSIDE" "$T/etc/sub"
mkdir -p "$T/payload/etc/sub"
printf 'pwned\n' > "$T/payload/etc/sub/file"
(cd "$T/payload" && sha256sum etc/sub/file > manifest.sha256)
expect_fail "upgrade rejects a nested symlink escaping root" run upgrade "$T/payload"
check "nested symlink escape wrote nothing outside root" test ! -e "$OUTSIDE/file"
rm -rf "$OUTSIDE"

base
run init
OUTSIDE=$(mktemp -d)
ln -s "$OUTSIDE" "$T/usr"
mkdir -p "$T/payload/usr/bin"
printf 'pwned\n' > "$T/payload/usr/bin/prog"
(cd "$T/payload" && sha256sum usr/bin/prog > manifest.sha256)
expect_fail "upgrade rejects a root-component symlink escaping root" run upgrade "$T/payload"
check "root-component symlink escape wrote nothing outside root" test ! -e "$OUTSIDE/bin"
rm -rf "$OUTSIDE"

base
run init
OUTSIDE=$(mktemp -d)
rm -rf "$T/etc"
ln -s "$OUTSIDE" "$T/mid"
ln -s mid "$T/etc"
mkdir -p "$T/payload/etc"
printf 'pwned\n' > "$T/payload/etc/init.conf"
(cd "$T/payload" && sha256sum etc/init.conf > manifest.sha256)
expect_fail "upgrade rejects a symlink chain escaping root" run upgrade "$T/payload"
check "symlink chain escape wrote nothing outside root" test ! -e "$OUTSIDE/init.conf"
rm -rf "$OUTSIDE"

base
run init
run snapshot golden
OUTSIDE=$(mktemp -d)
rm -rf "$T/etc"
ln -s "$OUTSIDE" "$T/etc"
expect_fail "rollback rejects an escaping destination symlink" run rollback golden
check "rollback escape wrote nothing outside root" test ! -e "$OUTSIDE/init.conf"
rm -rf "$OUTSIDE"

base
run init
mkdir -p "$T/etc-real"
printf 'network:once:/bin/true\n' > "$T/etc-real/init.conf"
rm -rf "$T/etc"
ln -s etc-real "$T/etc"
mkdir -p "$T/payload/etc"
printf 'network:once:/bin/sleep 5\n' > "$T/payload/etc/init.conf"
(cd "$T/payload" && sha256sum etc/init.conf > manifest.sha256)
expect_ok "upgrade allows an internal-root etc symlink" run upgrade "$T/payload"
check "internal-root symlink upgrade wrote through the link" sh -c \
	"grep -q '/bin/sleep 5' '$T/etc-real/init.conf'"

# --- P1-B: pre-upgrade snapshot completeness / new-files -------------------
pre_upgrade_tag() {
	ls "$T/var/lib/sane/reliability/snapshots" | grep '^auto-pre-upgrade-' | head -n1
}

base
run init
mkdir -p "$T/usr/bin"
printf 'old-prog\n' > "$T/usr/bin/prog"
mkdir -p "$T/payload/usr/bin"
printf 'new-prog\n' > "$T/payload/usr/bin/prog"
(cd "$T/payload" && sha256sum usr/bin/prog > manifest.sha256)
expect_ok "upgrade replaces a file outside STATE_FILES" run upgrade "$T/payload"
check "upgrade installed the new non-state file" grep -q '^new-prog$' "$T/usr/bin/prog"
expect_ok "rollback restores the replaced non-state file" run rollback "$(pre_upgrade_tag)"
check "rollback restored the old non-state content" grep -q '^old-prog$' "$T/usr/bin/prog"

base
run init
mkdir -p "$T/payload/usr/bin"
printf 'brand-new\n' > "$T/payload/usr/bin/newprog"
(cd "$T/payload" && sha256sum usr/bin/newprog > manifest.sha256)
expect_ok "upgrade adds a new file" run upgrade "$T/payload"
check "upgrade created the new file" test -f "$T/usr/bin/newprog"
check "pre-upgrade snapshot records the new file" sh -c \
	"grep -qx 'usr/bin/newprog' '$T/var/lib/sane/reliability/snapshots/$(pre_upgrade_tag)/new-files'"
expect_ok "rollback after adding a new file succeeds" run rollback "$(pre_upgrade_tag)"
check "rollback deleted the newly added file" test ! -e "$T/usr/bin/newprog"

base
run init
mkdir -p "$T/usr/bin"
printf 'old-prog\n' > "$T/usr/bin/prog"
mkdir -p "$T/payload/usr/bin"
printf 'new-prog\n' > "$T/payload/usr/bin/prog"
printf 'new-file\n' > "$T/payload/usr/bin/added"
(cd "$T/payload" && sha256sum usr/bin/prog usr/bin/added > manifest.sha256)
expect_ok "upgrade installs a replacement and a new file" run upgrade "$T/payload"
printf 'state=in-progress\nsnapshot=%s\n' "$(pre_upgrade_tag)" \
	> "$T/var/lib/sane/reliability/journal"
expect_ok "recover rolls back an interrupted upgrade" run recover
check "recover restored the replaced file" grep -q '^old-prog$' "$T/usr/bin/prog"
check "recover deleted the newly added file" test ! -e "$T/usr/bin/added"
check "recover journal records recovered" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal'"

base
run init
mkdir -p "$T/usr/bin"
printf 'old-prog\n' > "$T/usr/bin/prog"
printf 'blocker\n' > "$T/usr/local"
mkdir -p "$T/payload/usr/bin" "$T/payload/usr/local/bin"
printf 'new-prog\n' > "$T/payload/usr/bin/prog"
printf 'late\n' > "$T/payload/usr/local/bin/late"
(cd "$T/payload" && sha256sum usr/bin/prog usr/local/bin/late > manifest.sha256)
expect_fail "upgrade fails mid-transaction and auto-recovers" run upgrade "$T/payload"
check "mid-transaction failure restored the replaced file" grep -q '^old-prog$' "$T/usr/bin/prog"
check "mid-transaction failure left no partial new file" test ! -e "$T/usr/local/bin/late"

# --- P2-3: state lock + crash-window swap self-heal --------------------------
# Mutators serialize on mkdir "$STATE/lock" (pid file, 30s default timeout,
# SANE_RELIABILITY_LOCK_TIMEOUT override for tests). Stale locks (dead pid)
# are stolen atomically; every exit path must release the lock.
base
run init
mkdir -p "$T/var/lib/sane/reliability/lock"
sleep 300 &
HOLDER_PID=$!
printf '%s\n' "$HOLDER_PID" > "$T/var/lib/sane/reliability/lock/pid"
LOCK_START=$(date +%s)
if env SANE_RELIABILITY_LOCK_TIMEOUT=1 sh "$TOOL" --root "$T" snapshot contended 2>"$T/lock.err"; then
	fail "concurrent writer fails closed while a live pid holds the lock"
else
	pass "concurrent writer fails closed while a live pid holds the lock"
fi
LOCK_END=$(date +%s)
LOCK_ELAPSED=$((LOCK_END - LOCK_START))
check "lock timeout names the lock in stderr" \
	grep -q 'timed out waiting for reliability lock' "$T/lock.err"
check "lock wait is bounded by the override, not instant or 30s" \
	test "$LOCK_ELAPSED" -ge 1 -a "$LOCK_ELAPSED" -le 4
check "live holder lock is untouched" \
	grep -qx "$HOLDER_PID" "$T/var/lib/sane/reliability/lock/pid"
check "contended snapshot was not created" test ! -d \
	"$T/var/lib/sane/reliability/snapshots/contended"
kill "$HOLDER_PID" 2>/dev/null
wait "$HOLDER_PID" 2>/dev/null
rm -rf -- "$T/var/lib/sane/reliability/lock"
expect_ok "writer retries successfully after the lock is released" run snapshot contended
check "retry created the snapshot" test -d \
	"$T/var/lib/sane/reliability/snapshots/contended"
check "no lock remains after the retry" test ! -e "$T/var/lib/sane/reliability/lock"

base
run init
mkdir -p "$T/var/lib/sane/reliability/lock"
sleep 0 &
STALE_PID=$!
wait "$STALE_PID" 2>/dev/null
printf '%s\n' "$STALE_PID" > "$T/var/lib/sane/reliability/lock/pid"
expect_ok "stale lock with a dead pid is stolen" run snapshot stolen
check "stolen-lock snapshot created" test -d \
	"$T/var/lib/sane/reliability/snapshots/stolen"
check "no lock.stale residue after the steal" sh -c \
	"! ls -d '$T/var/lib/sane/reliability/lock.stale.'* >/dev/null 2>&1"
check "no lock remains after the stale steal" test ! -e "$T/var/lib/sane/reliability/lock"

base
run init
mkdir -p "$T/var/lib/sane/reliability/lock"
printf 'not-a-pid\n' > "$T/var/lib/sane/reliability/lock/pid"
expect_ok "stale lock with a garbage pid is stolen" run snapshot garbage
check "garbage-pid steal created the snapshot" test -d \
	"$T/var/lib/sane/reliability/snapshots/garbage"

base
run init
mkdir -p "$T/var/lib/sane/reliability/lock"
expect_ok "pidless crash lock is stolen after the grace window" run snapshot pidless
check "pidless steal created the snapshot" test -d \
	"$T/var/lib/sane/reliability/snapshots/pidless"
check "no lock remains after the pidless steal" test ! -e "$T/var/lib/sane/reliability/lock"

base
run init
run snapshot keep
mkdir -p "$T/payload/etc"
printf 'x\n' > "$T/payload/etc/init.conf"
printf '%s  ./etc/init.conf\n' \
	"0000000000000000000000000000000000000000000000000000000000000000" \
	> "$T/payload/manifest.sha256"
expect_fail "failed upgrade (integrity) rejects the payload" run upgrade "$T/payload"
check "no lock left after the failed upgrade" test ! -e "$T/var/lib/sane/reliability/lock"
expect_fail "failed rollback (unknown tag) rejects" run rollback missing
check "no lock left after the failed rollback" test ! -e "$T/var/lib/sane/reliability/lock"
expect_fail "failed restore (missing archive) rejects" run restore "$T/nope.tar.gz"
check "no lock left after the failed restore" test ! -e "$T/var/lib/sane/reliability/lock"
expect_fail "failed snapshot (invalid tag) rejects" run snapshot ../escape
check "no lock left after the failed snapshot" test ! -e "$T/var/lib/sane/reliability/lock"

# (a) Inject a failure between the two swap renames (mv shim ala spm test 28):
# the install rename fails once; the undo rename passes, old snapshot intact.
base
run init
printf 'original-content\n' > "$T/etc/init.conf"
run snapshot victim
printf 'new-content\n' > "$T/etc/init.conf"
mkdir -p "$T/bin"
REAL_MV=$(command -v mv)
cat > "$T/bin/mv" <<EOF
#!/bin/sh
src=\$1; last=""
for arg in "\$@"; do last=\$arg; done
case "\$src" in
*/.tmp.*)
	case "\$last" in
	"$T/var/lib/sane/reliability/snapshots/"*)
		if [ ! -f "$T/mv-fail.done" ]; then
			: > "$T/mv-fail.done"
			echo "injected mv failure" >&2
			exit 1
		fi ;;
	esac ;;
esac
exec "$REAL_MV" "\$@"
EOF
chmod 0755 "$T/bin/mv"
if env PATH="$T/bin:$PATH" sh "$TOOL" --root "$T" snapshot victim --force >"$T/mv.out" 2>&1; then
	fail "forced snapshot fails closed when the install rename fails"
else
	pass "forced snapshot fails closed when the install rename fails"
fi
check "mv fault injection actually fired (not vacuous)" test -f "$T/mv-fail.done"
check "old snapshot intact after the failed install rename" \
	grep -q '^original-content$' "$T/var/lib/sane/reliability/snapshots/victim/etc/init.conf"
check "no .old aside left after the undo rename" sh -c \
	"! ls -d '$T/var/lib/sane/reliability/snapshots/.old.'* >/dev/null 2>&1"
check "no lock left after the failed forced snapshot" test ! -e "$T/var/lib/sane/reliability/lock"

# (a2) Both install and undo renames fail: the deterministic .old.<tag> aside
# survives the crash window and the next lock-holding mutator heals it.
base
run init
printf 'original-content\n' > "$T/etc/init.conf"
run snapshot victim
printf 'new-content\n' > "$T/etc/init.conf"
mkdir -p "$T/bin"
REAL_MV=$(command -v mv)
cat > "$T/bin/mv" <<EOF
#!/bin/sh
last=""
for arg in "\$@"; do last=\$arg; done
case "\$last" in
"$T/var/lib/sane/reliability/snapshots/victim")
	echo "injected mv failure" >&2
	exit 1 ;;
esac
exec "$REAL_MV" "\$@"
EOF
chmod 0755 "$T/bin/mv"
expect_fail "forced snapshot dies when install and undo renames both fail" \
	env PATH="$T/bin:$PATH" sh "$TOOL" --root "$T" snapshot victim --force
check "crash window left the deterministic aside" test -d \
	"$T/var/lib/sane/reliability/snapshots/.old.victim"
check "crash window lost the live tag" test ! -d \
	"$T/var/lib/sane/reliability/snapshots/victim"
check "no lock left after the crash-window failure" test ! -e "$T/var/lib/sane/reliability/lock"
expect_ok "recover heals the interrupted swap (boot path)" run recover
check "heal restored the old snapshot content" \
	grep -q '^original-content$' "$T/var/lib/sane/reliability/snapshots/victim/etc/init.conf"
check "heal removed the aside" test ! -e \
	"$T/var/lib/sane/reliability/snapshots/.old.victim"

# (b) Manual crash state: .old.T present, T missing, orphan .tmp.* staging.
base
run init
run snapshot golden
mkdir -p "$T/var/lib/sane/reliability/snapshots/.tmp.orphan"
printf 'junk\n' > "$T/var/lib/sane/reliability/snapshots/.tmp.orphan/junk"
mv "$T/var/lib/sane/reliability/snapshots/golden" \
	"$T/var/lib/sane/reliability/snapshots/.old.golden"
expect_ok "recover heals a manual crash state" run recover
check "heal restored the missing tag from the aside" \
	grep -q '^network:once:/bin/true$' "$T/var/lib/sane/reliability/snapshots/golden/etc/init.conf"
check "heal removed the orphan staging dir" test ! -e \
	"$T/var/lib/sane/reliability/snapshots/.tmp.orphan"

# Redundant aside (install completed before the crash): heal discards it.
base
run init
run snapshot golden2
mkdir -p "$T/var/lib/sane/reliability/snapshots/.old.golden2"
printf 'stale-aside\n' > "$T/var/lib/sane/reliability/snapshots/.old.golden2/marker"
expect_ok "mutator discards a redundant aside when the tag exists" run snapshot trigger
check "redundant aside removed" test ! -e \
	"$T/var/lib/sane/reliability/snapshots/.old.golden2"
check "live tag untouched by the discard" test -d \
	"$T/var/lib/sane/reliability/snapshots/golden2"

# Read-only commands never heal and never take the lock.
base
run init
run snapshot golden3
mv "$T/var/lib/sane/reliability/snapshots/golden3" \
	"$T/var/lib/sane/reliability/snapshots/.old.golden3"
expect_ok "list runs while a crash aside exists" run list
check "list did not heal the aside (read-only)" test -d \
	"$T/var/lib/sane/reliability/snapshots/.old.golden3"
check "list did not restore the tag (read-only)" test ! -d \
	"$T/var/lib/sane/reliability/snapshots/golden3"
check "list created no lock" test ! -e "$T/var/lib/sane/reliability/lock"
expect_ok "snapshot heals after read-only commands" run snapshot healtrigger
check "mutator heal restored golden3" test -d \
	"$T/var/lib/sane/reliability/snapshots/golden3"

# Addendum: nested mutator path (recover -> cmd_net_recover) must not
# self-deadlock on the lock; it finishes well under the short override.
setup_net_recovery
printf 'state=net-in-progress\nnet-iface=eth0\n' > "$T/var/lib/sane/reliability/journal"
NEST_START=$(date +%s)
if env PATH="$T/bin:$PATH" SANE_RELIABILITY_LOCK_TIMEOUT=2 sh "$TOOL" --root "$T" recover >"$T/nested.out" 2>&1; then
	pass "nested recover under a short lock timeout avoids self-deadlock"
else
	fail "nested recover under a short lock timeout avoids self-deadlock"
fi
NEST_END=$(date +%s)
NEST_ELAPSED=$((NEST_END - NEST_START))
check "nested recover finished under the lock timeout" test "$NEST_ELAPSED" -lt 2
check "nested recover completed the network journal" sh -c \
	"grep -q '^state=recovered$' '$T/var/lib/sane/reliability/journal' && grep -q '^net-iface=eth0$' '$T/var/lib/sane/reliability/journal'"
check "nested recover left no lock" test ! -e "$T/var/lib/sane/reliability/lock"
check "nested path really ran reconnect and check" sh -c \
	"grep -qx 'sane-net reconnect eth0 SANE_ROOT=$T' '$T/net-recover.calls' && grep -qx 'sane-net check eth0 SANE_ROOT=$T' '$T/net-recover.calls'"

# --- P3a: upgrade self-state protection (D7) ---------------------------------
# Payload targets under var/lib/sane/reliability/ and usr/bin/sane-reliability
# are rejected with zero writes; internal snapshot extra-list stays unblocked.
base
run init
mkdir -p "$T/payload/etc" "$T/payload/var/lib/sane/reliability"
printf 'network:once:/bin/sleep 5\n' > "$T/payload/etc/init.conf"
printf 'pwned-journal\n' > "$T/payload/var/lib/sane/reliability/journal"
(cd "$T/payload" && sha256sum etc/init.conf var/lib/sane/reliability/journal > manifest.sha256)
if sh "$TOOL" --root "$T" upgrade "$T/payload" 2>"$T/self.err"; then
	fail "upgrade rejects payload targeting the reliability journal"
else
	pass "upgrade rejects payload targeting the reliability journal"
fi
check "self-state rejection names the protected path" \
	grep -q 'payload targets protected reliability state: var/lib/sane/reliability/journal' "$T/self.err"
check "self-state rejection wrote nothing (zero-write)" sh -c \
	"grep -q '^network:once:/bin/true$' '$T/etc/init.conf' && grep -q '^state=idle$' '$T/var/lib/sane/reliability/journal' && ! ls -d '$T/var/lib/sane/reliability/snapshots'/auto-pre-upgrade-* >/dev/null 2>&1 && test ! -e '$T/var/lib/sane/reliability/lock'"

base
run init
mkdir -p "$T/usr/bin" "$T/payload/usr/bin"
printf 'original-tool\n' > "$T/usr/bin/sane-reliability"
printf 'evil-tool\n' > "$T/payload/usr/bin/sane-reliability"
(cd "$T/payload" && sha256sum usr/bin/sane-reliability > manifest.sha256)
if sh "$TOOL" --root "$T" upgrade "$T/payload" 2>"$T/self2.err"; then
	fail "upgrade rejects self-overwrite of usr/bin/sane-reliability"
else
	pass "upgrade rejects self-overwrite of usr/bin/sane-reliability"
fi
check "self-overwrite rejection names the protected tool path" \
	grep -q 'payload targets protected reliability state: usr/bin/sane-reliability' "$T/self2.err"
check "self-overwrite wrote nothing" sh -c \
	"grep -q '^original-tool$' '$T/usr/bin/sane-reliability' && test ! -e '$T/var/lib/sane/reliability/lock'"

base
run init
mkdir -p "$T/payload/etc"
printf 'network:once:/bin/sleep 5\n' > "$T/payload/etc/init.conf"
(cd "$T/payload" && sha256sum etc/init.conf > manifest.sha256)
expect_ok "normal upgrade outside protected paths still works (D7)" run upgrade "$T/payload"
check "normal upgrade committed the payload" grep -q '/bin/sleep 5' "$T/etc/init.conf"
check "normal upgrade kept the extra-list snapshot mechanism" sh -c \
	"ls -d '$T/var/lib/sane/reliability/snapshots'/auto-pre-upgrade-* >/dev/null 2>&1"

base
run init
mkdir -p "$T/payload/var/lib/sane/reliability-other"
printf 'sibling\n' > "$T/payload/var/lib/sane/reliability-other/file"
(cd "$T/payload" && sha256sum var/lib/sane/reliability-other/file > manifest.sha256)
expect_ok "upgrade allows a sibling prefix outside the protected dir" run upgrade "$T/payload"
check "sibling-prefix payload installed" \
	grep -q '^sibling$' "$T/var/lib/sane/reliability-other/file"

# --- P3b: ROOT canonicalization (D4) -----------------------------------------
# --root resolves to the canonical physical dir (cd -P + pwd); fresh roots
# (including dangling symlink roots) still work for init.
base
CANON=$(mktemp -d "$T/canon.XXXXXX")
ln -s "$CANON" "$T/rootlink"
expect_ok "init resolves a symlinked root to the canonical dir" sh -c \
	"sh '$TOOL' --root '$T/rootlink' init"
check "state created in the canonical target" test -d \
	"$CANON/var/lib/sane/reliability/snapshots"
check "init reports the canonical state path" sh -c \
	"sh '$TOOL' -v --root '$T/rootlink' init | grep -q 'reliability state initialised in $CANON/var/lib/sane/reliability'"
expect_ok "mutator works through the symlinked root" sh -c \
	"sh '$TOOL' --root '$T/rootlink' snapshot canon"
check "snapshot landed in the canonical target" test -d \
	"$CANON/var/lib/sane/reliability/snapshots/canon"

base
ln -s "$T/fresh-target" "$T/dangling"
expect_ok "init accepts a dangling symlink root (D4)" sh -c \
	"sh '$TOOL' --root '$T/dangling' init"
check "state created at the canonical target of the dangling root" test -d \
	"$T/fresh-target/var/lib/sane/reliability/snapshots"
check "dangling root symlink preserved" test -L "$T/dangling"
check "dangling root init reports the canonical path" sh -c \
	"sh '$TOOL' -v --root '$T/dangling' init | grep -q 'reliability state initialised in $T/fresh-target/var/lib/sane/reliability'"

base
mkdir -p "$T/real-ancestor"
ln -s "$T/real-ancestor" "$T/ancestor-link"
expect_ok "init accepts a fresh leaf under a symlinked ancestor" sh -c \
	"sh '$TOOL' --root '$T/ancestor-link/newroot' init"
check "state created at the canonical fresh leaf" test -d \
	"$T/real-ancestor/newroot/var/lib/sane/reliability/snapshots"
check "fresh leaf init reports the canonical path" sh -c \
	"sh '$TOOL' -v --root '$T/ancestor-link/newroot' init | grep -q 'reliability state initialised in $T/real-ancestor/newroot/var/lib/sane/reliability'"
expect_fail "relative --root still rejected" sh -c \
	"sh '$TOOL' --root relative-dir init"

printf '\nPhase C reliability tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
