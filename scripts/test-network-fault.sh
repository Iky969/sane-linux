#!/bin/sh
# scripts/test-network-fault.sh -- fault-injection and recovery regressions.
# All writable paths and external network tools are confined to a temp root.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
NET="$REPO_ROOT/packages/ninit/x/usr/bin/sane-net"

PASS=0
FAIL=0
T=$(mktemp -d)
BASE_PATH=$PATH
cleanup() { rm -rf -- "$T"; }
trap cleanup EXIT HUP INT TERM

pass() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1" >&2; }
check() { d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
expect_ok() { d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
expect_fail() { d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }

mkdir -p "$T/bin" "$T/etc" "$T/etc/ssl/certs"
CALLS="$T/network-calls.log"
IP_CALLS="$T/ip-calls.log"
UDHCPC_CALLS="$T/udhcpc-calls.log"
UDHCPC_COUNT="$T/udhcpc-count"
SLEEP_CALLS="$T/sleep-calls.log"
RESOLVER_OBSERVED="$T/resolver-before-dhcp.log"
CARRIER="$T/carrier"
ADDR_PRESENT="$T/address-present"
ROUTE_PRESENT="$T/route-present"

mkstub() {
	name=$1; body=$2
	cat > "$T/bin/$name" <<EOF
#!/bin/sh
$body
EOF
	chmod 0755 "$T/bin/$name"
}

mkstub ip 'printf "ip %s\n" "$*" >> "'"$IP_CALLS"'"
case "${1:-} ${2:-}" in
  "link show")
    if [ "$(cat "'"$CARRIER"'")" = up ]; then
      printf "2: ${3:-eth0}: <BROADCAST,MULTICAST,UP> state UP mode DEFAULT\n"
    else
      printf "2: ${3:-eth0}: <BROADCAST,MULTICAST> state DOWN mode DEFAULT\n"
    fi
    ;;
  "link set")
    printf "ip %s\n" "$*" >> "'"$CALLS"'"
    if [ "${STUB_LINK_RECOVER:-1}" = 1 ] && [ "${4:-}" = up ]; then
      printf "up\n" > "'"$CARRIER"'"
    fi
    ;;
  "addr show")
    if [ "$(cat "'"$ADDR_PRESENT"'")" = yes ]; then
      printf "    inet 10.0.0.2/24 scope global eth0\n"
    fi
    ;;
  "route show")
    if [ "$(cat "'"$ROUTE_PRESENT"'")" = yes ]; then
      printf "default via 10.0.0.1 dev eth0\n"
    fi
    ;;
  "addr add"|"route add")
    printf "ip %s\n" "$*" >> "'"$CALLS"'"
    ;;
esac
exit 0'
mkstub udhcpc 'printf "udhcpc %s\n" "$*" >> "'"$CALLS"'"
printf "udhcpc %s\n" "$*" >> "'"$UDHCPC_CALLS"'"
count=$(cat "'"$UDHCPC_COUNT"'")
count=$((count + 1))
printf "%s\n" "$count" > "'"$UDHCPC_COUNT"'"
if [ "$count" -gt 1 ]; then
  if cmp -s "'"$T"'/etc/resolv.conf" "'"$T"'/etc/resolv.conf.default"; then
    resolver=default
  else
    resolver=not-default
  fi
  printf "attempt=%s resolver=%s\n" "$count" "$resolver" >> "'"$RESOLVER_OBSERVED"'"
fi
if [ "$count" -le "${STUB_UDHCPC_FAILS:-0}" ]; then
  printf "nameserver 192.0.2.250\n" > "'"$T"'/etc/resolv.conf"
  exit 1
fi
exit "${STUB_UDHCPC_EXIT:-0}"'
mkstub curl 'printf "curl %s\n" "$*" >> "'"$CALLS"'"; exit 0'
mkstub wpa_supplicant 'printf "wpa_supplicant %s\n" "$*" >> "'"$CALLS"'"; exit 0'
mkstub sleep 'printf "sleep %s\n" "$*" >> "'"$SLEEP_CALLS"'"; exit 0'

PATH="$T/bin:$BASE_PATH"
export PATH

# Redirect every writable path. The stubs consume /run paths as strings only;
# no command is allowed to touch the host resolver, routes, links or DHCP state.
STAGED="$T/sane-net"
sed -e "s|^RESOLV=.*|RESOLV=$T/etc/resolv.conf|" \
    -e "s|^RESOLV_DEFAULT=.*|RESOLV_DEFAULT=$T/etc/resolv.conf.default|" \
    -e "s|^WPACONF=.*|WPACONF=$T/etc/wpa_supplicant.conf|" \
    -e "s|^CABUNDLE=.*|CABUNDLE=$T/etc/ssl/certs/ca-certificates.crt|" \
    "$NET" > "$STAGED"
chmod 0755 "$STAGED"

reset_stubs() {
	: > "$CALLS"
	: > "$IP_CALLS"
	: > "$UDHCPC_CALLS"
	: > "$SLEEP_CALLS"
	: > "$RESOLVER_OBSERVED"
	printf '0\n' > "$UDHCPC_COUNT"
	printf 'up\n' > "$CARRIER"
	printf 'no\n' > "$ADDR_PRESENT"
	printf 'no\n' > "$ROUTE_PRESENT"
	printf 'nameserver 127.0.0.1\n' > "$T/etc/resolv.conf"
	printf 'nameserver 1.1.1.1\n' > "$T/etc/resolv.conf.default"
}

run_net() { sh "$STAGED" "$@"; }
resolver_unchanged() { grep -q '^nameserver 127.0.0.1$' "$T/etc/resolv.conf" && \
	[ "$(wc -l < "$T/etc/resolv.conf")" -eq 1 ]; }
no_temp_files() { ! ls "$T/etc"/.resolv.conf.* >/dev/null 2>&1; }

check "sane-net fault test source is present" test -f "$NET"
check "sane-net passes shell syntax" sh -n "$NET"

# --- Fail before the corresponding side effect -----------------------------
reset_stubs
expect_fail "ip-link fault aborts link setup" \
	env SANE_NET_FAULT=ip-link sh "$STAGED" link eth0 up
check "ip-link fault runs no link mutation" \
	sh -c "! grep -q '^ip link set eth0 up$' '$IP_CALLS'"

reset_stubs
printf 'yes\n' > "$ROUTE_PRESENT"
expect_fail "ip-addr fault aborts static address setup" \
	env SANE_NET_FAULT=ip-addr sh "$STAGED" static eth0 10.0.0.2/24 10.0.0.1 9.9.9.9
check "ip-addr fault runs no address mutation" \
	sh -c "! grep -q '^ip addr add ' '$IP_CALLS'"
check "ip-addr fault does not rewrite DNS" resolver_unchanged

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
expect_fail "route-add fault aborts default route setup" \
	env SANE_NET_FAULT=route-add sh "$STAGED" static eth0 10.0.0.2/24 10.0.0.1 9.9.9.9
check "route-add fault runs no route mutation" \
	sh -c "! grep -q '^ip route add ' '$IP_CALLS'"
check "route-add fault does not rewrite DNS" resolver_unchanged

reset_stubs
expect_fail "udhcpc fault aborts DHCP startup" \
	env SANE_NET_FAULT=udhcpc sh "$STAGED" dhcp eth0
check "udhcpc fault never invokes the DHCP client" \
	sh -c "! grep -q '^udhcpc ' '$UDHCPC_CALLS'"

reset_stubs
expect_fail "resolv-write fault aborts DNS update" \
	env SANE_NET_FAULT=resolv-write sh "$STAGED" dns 9.9.9.9
check "resolv-write fault leaves resolver bytes unchanged" resolver_unchanged
check "resolv-write fault leaves no temporary resolver" no_temp_files

# --- Reconnect retry and recovery ------------------------------------------
reset_stubs
printf 'down\n' > "$CARRIER"
expect_ok "reconnect retries until the link recovers" run_net reconnect eth0 4
check "reconnect polls the carrier more than once" \
	sh -c "[ \$(grep -c '^ip link show dev eth0$' '$IP_CALLS') -ge 2 ]"
check "reconnect attempts to bring the link up" \
	grep -q '^ip link set eth0 up$' "$CALLS"
check "reconnect starts DHCP after carrier recovery" \
	grep -q '^udhcpc .*-i eth0 ' "$CALLS"
check "recovered reconnect starts exactly one DHCP client" \
	sh -c "[ \$(cat '$UDHCPC_COUNT') -eq 1 ]"

reset_stubs
printf 'down\n' > "$CARRIER"
expect_fail "reconnect fails closed when carrier never recovers" \
	env STUB_LINK_RECOVER=0 sh "$STAGED" reconnect eth0 3
check "unrecovered reconnect never starts DHCP" \
	sh -c "! grep -q '^udhcpc ' '$UDHCPC_CALLS'"

reset_stubs
expect_ok "reconnect retries DHCP failures then recovers" \
	env STUB_UDHCPC_FAILS=2 sh "$STAGED" reconnect eth0 6
check "DHCP recovery reaches the third attempt" \
	sh -c "[ \$(cat '$UDHCPC_COUNT') -eq 3 ]"
check "DHCP retry two sees the restored default resolver" \
	grep -q '^attempt=2 resolver=default$' "$RESOLVER_OBSERVED"
check "DHCP retry three sees the restored default resolver" \
	grep -q '^attempt=3 resolver=default$' "$RESOLVER_OBSERVED"
check "DHCP retries wait through the sleep stub" \
	sh -c "[ \$(grep -c '^sleep ' '$SLEEP_CALLS') -ge 2 ]"
check "successful DHCP recovery leaves the default resolver" \
	sh -c "cmp -s '$T/etc/resolv.conf' '$T/etc/resolv.conf.default'"

reset_stubs
expect_fail "persistent DHCP failure exits nonzero" \
	env STUB_UDHCPC_FAILS=99 sh "$STAGED" reconnect eth0 3
check "persistent DHCP failure performs retries" \
	sh -c "[ \$(cat '$UDHCPC_COUNT') -ge 2 ]"
check "persistent DHCP failure restores the default resolver" \
	sh -c "cmp -s '$T/etc/resolv.conf' '$T/etc/resolv.conf.default'"
check "failed DHCP retries wait through the sleep stub" \
	sh -c "[ \$(grep -c '^sleep ' '$SLEEP_CALLS') -ge 1 ]"

# --- Connectivity check -----------------------------------------------------
reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_ok "check succeeds with link, address, route and DNS" run_net check eth0
check "check is read-only" sh -c "! grep -q '^ip link set ' '$IP_CALLS'"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
printf 'down\n' > "$CARRIER"
expect_fail "check fails when the link is down" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'no\n' > "$ROUTE_PRESENT"
expect_fail "check fails without a default route" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
: > "$T/etc/resolv.conf"
expect_fail "check fails without a nameserver" run_net check eth0

printf '\nNetwork fault tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
