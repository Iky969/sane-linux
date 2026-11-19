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

printf '\nPhase C reliability tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
