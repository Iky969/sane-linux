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

mkdir -p "$T/bin" "$T/etc" "$T/etc/ssl/certs" "$T/run" "$T/proc"
CALLS="$T/network-calls.log"
IP_CALLS="$T/ip-calls.log"
UDHCPC_CALLS="$T/udhcpc-calls.log"
UDHCPC_COUNT="$T/udhcpc-count"
SLEEP_CALLS="$T/sleep-calls.log"
RESOLVER_OBSERVED="$T/resolver-before-dhcp.log"
POSTCHECK_STARTS="$T/postcheck-starts.log"
CARRIER="$T/carrier"
ADDR_PRESENT="$T/address-present"
ADDR_POLLS="$T/address-polls"
ROUTE_PRESENT="$T/route-present"
ROUTE_DEV="$T/route-dev"
LIVE_PIDS="$T/live-pids"
KILL_CALLS="$T/kill-calls.log"
SELF_PID_FILE="$T/self-pid"

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
    st=$(cat "'"$CARRIER"'")
    if [ "${STUB_IP_STYLE:-iproute2}" = busybox ]; then
      if [ "$st" = up ]; then
        printf "2: ${3:-eth0}: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast qlen 1000\n"
      elif [ "$st" = nocarrier ]; then
        printf "2: ${3:-eth0}: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc pfifo_fast qlen 1000\n"
      else
        printf "2: ${3:-eth0}: <BROADCAST,MULTICAST> mtu 1500 qdisc pfifo_fast qlen 1000\n"
      fi
    else
      if [ "$st" = up ]; then
        printf "2: ${3:-eth0}: <BROADCAST,MULTICAST,UP> state UP mode DEFAULT\n"
      else
        printf "2: ${3:-eth0}: <BROADCAST,MULTICAST> state DOWN mode DEFAULT\n"
      fi
    fi
    ;;
  "link set")
    printf "ip %s\n" "$*" >> "'"$CALLS"'"
    if [ "${STUB_LINK_SET_FAIL:-0}" = 1 ]; then exit 1; fi
    if [ "${STUB_LINK_RECOVER:-1}" = 1 ] && [ "${4:-}" = up ]; then
      printf "up\n" > "'"$CARRIER"'"
    fi
    ;;
  "-4 addr")
    count=$(cat "'"$ADDR_POLLS"'")
    count=$((count + 1))
    printf "%s\n" "$count" > "'"$ADDR_POLLS"'"
    if [ "$count" -ge "${STUB_ADDR_DELAY:-0}" ] && [ "$(cat "'"$ADDR_PRESENT"'")" = yes ]; then
      printf "    inet 10.0.0.2/24 scope global eth0\n"
    fi
    ;;
  "addr show")
    if [ "$(cat "'"$ADDR_PRESENT"'")" = yes ]; then
      printf "    inet 10.0.0.2/24 scope global eth0\n"
    fi
    ;;
  "route show")
    route_dev=$(cat "'"$ROUTE_DEV"'")
    if [ "$(cat "'"$ROUTE_PRESENT"'")" = yes ] && [ "${5:-}" = "$route_dev" ]; then
      printf "default via 10.0.0.1 dev %s\n" "$route_dev"
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
pidfile=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) pidfile=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "${STUB_PID_MODE:-}" in
  self) printf "%s\n" "$PPID" > "'"$SELF_PID_FILE"'"; printf "%s\n" "$PPID" > "$pidfile" ;;
  malformed) printf "not-a-pid\n" > "$pidfile" ;;
  stale) printf "49999\n" > "$pidfile" ;;
esac
if [ "${STUB_DHCP_LIVE:-0}" = 1 ]; then
  newpid=$((41000 + count))
  if [ -s "'"$LIVE_PIDS"'" ]; then
    overlap=0
    while IFS= read -r lp; do
      [ -n "$lp" ] || continue
      if [ "$(cat "'"$T"'/proc/$lp/comm" 2>/dev/null)" = udhcpc ]; then overlap=1; fi
    done < "'"$LIVE_PIDS"'"
    if [ "$overlap" = 1 ]; then
      printf "overlap\n" >> "'"$CALLS"'"
      exit 90
    fi
  fi
  printf "%s\n" "$newpid" > "$pidfile"
  printf "%s\n" "$newpid" >> "'"$LIVE_PIDS"'"
  mkdir -p "'"$T"'/proc/$newpid"
  printf "udhcpc\n" > "'"$T"'/proc/$newpid/comm"
  printf "%s (udhcpc) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 100 %s 1000 0\n" "$newpid" "$((10000 + newpid))" > "'"$T"'/proc/$newpid/stat"
  printf "live %s\n" "$newpid" >> "'"$CALLS"'"
fi
queries=$(wc -l < "'"$IP_CALLS"'")
printf "attempt=%s queries=%s\n" "$count" "$queries" >> "'"$POSTCHECK_STARTS"'"
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
mkstub kill 'printf "kill %s\n" "$*" >> "'"$KILL_CALLS"'"
printf "kill %s\n" "$*" >> "'"$CALLS"'"
sig=$1
pid=$2
if [ "$sig" = "-0" ]; then
  grep -qx "$pid" "'"$LIVE_PIDS"'" 2>/dev/null
  exit $?
fi
if ! grep -qx "$pid" "'"$LIVE_PIDS"'" 2>/dev/null; then
  exit 1
fi
case "$sig:$pid" in
  "-TERM:${STUB_IGNORE_TERM:-}")
    if [ "${STUB_REUSE_AFTER_TERM:-0}" = 1 ]; then
      printf "other\n" > "'"$T"'/proc/$pid/comm"
    fi
    exit 0 ;;
  "-KILL:${STUB_IGNORE_KILL:-}") exit 0 ;;
esac
grep -vx "$pid" "'"$LIVE_PIDS"'" > "'"$LIVE_PIDS"'.next" 2>/dev/null || true
mv "'"$LIVE_PIDS"'.next" "'"$LIVE_PIDS"'"
printf "dead %s\n" "$pid" >> "'"$CALLS"'"
exit 0'
mkstub curl 'printf "curl %s\n" "$*" >> "'"$CALLS"'"; exit 0'
mkstub wpa_supplicant 'printf "wpa_supplicant %s\n" "$*" >> "'"$CALLS"'"; exit 0'
mkstub sleep 'printf "sleep %s\n" "$*" >> "'"$SLEEP_CALLS"'"; printf "sleep %s\n" "$*" >> "'"$CALLS"'"; exit 0'

PATH="$T/bin:$BASE_PATH"
export PATH
# Fake /proc tree so process-identity checks are deterministic and unprivileged.
export SANE_PROC="$T/proc"

# Redirect every writable path. The stubs consume /run paths as strings only;
# no command is allowed to touch the host resolver, routes, links or DHCP state.
STAGED="$T/sane-net"
sed -e "s|^ROOT=.*|ROOT=$T|" \
    -e "s|^SYS_NET=.*|SYS_NET=$T/sys-net|" \
    -e "s|^RESOLV=.*|RESOLV=$T/etc/resolv.conf|" \
    -e "s|^RESOLV_DEFAULT=.*|RESOLV_DEFAULT=$T/etc/resolv.conf.default|" \
    -e "s|^WPACONF=.*|WPACONF=$T/etc/wpa_supplicant.conf|" \
    -e "s|^WPARUN=.*|WPARUN=$T/run/wpa_supplicant|" \
    -e "s|^CABUNDLE=.*|CABUNDLE=$T/etc/ssl/certs/ca-certificates.crt|" \
    "$NET" > "$STAGED"
chmod 0755 "$STAGED"

reset_stubs() {
	: > "$CALLS"
	: > "$IP_CALLS"
	: > "$UDHCPC_CALLS"
	: > "$SLEEP_CALLS"
	: > "$RESOLVER_OBSERVED"
	: > "$POSTCHECK_STARTS"
	: > "$KILL_CALLS"
	: > "$LIVE_PIDS"
	: > "$SELF_PID_FILE"
	rm -f "$T/etc"/.resolv.conf.*
	rm -f "$T/run"/udhcpc-*.pid
	rm -rf "$T/proc"
	mkdir -p "$T/proc"
	printf '0\n' > "$UDHCPC_COUNT"
	printf 'up\n' > "$CARRIER"
	printf 'no\n' > "$ADDR_PRESENT"
	printf '0\n' > "$ADDR_POLLS"
	printf 'no\n' > "$ROUTE_PRESENT"
	printf 'eth0\n' > "$ROUTE_DEV"
	printf 'nameserver 127.0.0.1\n' > "$T/etc/resolv.conf"
	printf 'nameserver 1.1.1.1\n' > "$T/etc/resolv.conf.default"
}

run_net() { sh "$STAGED" "$@"; }
resolver_unchanged() { grep -q '^nameserver 127.0.0.1$' "$T/etc/resolv.conf" && \
	[ "$(wc -l < "$T/etc/resolv.conf")" -eq 1 ]; }
no_temp_files() { ! ls "$T/etc"/.resolv.conf.* >/dev/null 2>&1; }

FAILBIN="$T/failbin"
mkdir -p "$FAILBIN"
REAL_CHMOD=$(command -v chmod)
REAL_MV=$(command -v mv)
set_fail_tool() {
	tool=$1
	rm -f "$FAILBIN/chmod" "$FAILBIN/mv"
	ln -s "$REAL_CHMOD" "$FAILBIN/chmod"
	ln -s "$REAL_MV" "$FAILBIN/mv"
	rm -f "$FAILBIN/$tool"
	printf '#!/bin/sh\nexit 1\n' > "$FAILBIN/$tool"
	chmod 0755 "$FAILBIN/$tool"
}

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
expect_fail "dhcp fails closed when the link cannot be brought up" \
	sh -c "env STUB_LINK_SET_FAIL=1 sh '$STAGED' dhcp eth0 >/dev/null 2>'$T/dhcp-link.err'"
check "dhcp link failure names the interface" grep -q 'cannot bring up eth0' "$T/dhcp-link.err"
check "dhcp link failure never starts udhcpc" sh -c "! grep -q '^udhcpc ' '$UDHCPC_CALLS'"

reset_stubs
expect_fail "wifi fails closed when the link cannot be brought up" \
	sh -c "env STUB_LINK_SET_FAIL=1 sh '$STAGED' wifi eth0 home-net secretpass >/dev/null 2>'$T/wifi-link.err'"
check "wifi link failure names the interface" grep -q 'cannot bring up eth0' "$T/wifi-link.err"
check "wifi link failure never starts the supplicant" sh -c "! grep -q '^wpa_supplicant ' '$CALLS'"

reset_stubs
expect_fail "resolv-write fault aborts DNS update" \
	env SANE_NET_FAULT=resolv-write sh "$STAGED" dns 9.9.9.9
check "resolv-write fault leaves resolver bytes unchanged" resolver_unchanged
check "resolv-write fault leaves no temporary resolver" no_temp_files

reset_stubs
set_fail_tool chmod
expect_fail "DNS write chmod failure exits nonzero" \
	env PATH="$FAILBIN:$PATH" sh "$STAGED" dns 9.9.9.9
check "DNS write chmod failure leaves resolver unchanged" resolver_unchanged
check "DNS write chmod failure removes temporary resolver" no_temp_files

reset_stubs
set_fail_tool mv
expect_fail "DNS write rename failure exits nonzero" \
	env PATH="$FAILBIN:$PATH" sh "$STAGED" dns 9.9.9.9
check "DNS write rename failure leaves resolver unchanged" resolver_unchanged
check "DNS write rename failure removes temporary resolver" no_temp_files

reset_stubs
set_fail_tool chmod
expect_fail "default DNS chmod failure exits nonzero" \
	env PATH="$FAILBIN:$PATH" sh "$STAGED" dns default
check "default DNS chmod failure leaves resolver unchanged" resolver_unchanged
check "default DNS chmod failure removes temporary resolver" no_temp_files

reset_stubs
set_fail_tool mv
expect_fail "default DNS rename failure exits nonzero" \
	env PATH="$FAILBIN:$PATH" sh "$STAGED" dns default
check "default DNS rename failure leaves resolver unchanged" resolver_unchanged
check "default DNS rename failure removes temporary resolver" no_temp_files

reset_stubs
expect_fail "resolv-write fault aborts default DNS restore" \
	env SANE_NET_FAULT=resolv-write sh "$STAGED" dns default
check "default DNS fault leaves resolver unchanged" resolver_unchanged
check "default DNS fault leaves no temporary resolver" no_temp_files

reset_stubs
rm -f "$T/etc/resolv.conf.default"
expect_fail "dns default fails when the default resolver is missing" \
	sh -c "sh '$STAGED' dns default >/dev/null 2>'$T/dns-default.err'"
check "missing default resolver prints exactly one stderr line" \
	test "$(wc -l < "$T/dns-default.err")" -eq 1

reset_stubs
rm -f "$T/etc/resolv.conf.default"
expect_fail "reconnect fails when DHCP and resolver restore fail" \
	sh -c "env STUB_UDHCPC_FAILS=1 sh '$STAGED' reconnect eth0 6 >/dev/null 2>'$T/reconnect-restore.err'"
check "reconnect reports the resolver restore failure branch" \
	grep -q '^sane-net: DHCP failed on eth0 and restoring the default resolver failed$' \
		"$T/reconnect-restore.err"

# --- Reconnect retry and recovery ------------------------------------------
reset_stubs
printf 'down\n' > "$CARRIER"
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
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
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
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

# --- Bounded DHCP lease post-check -----------------------------------------
reset_stubs
expect_fail "address-less lease post-check retries then fails closed" \
	run_net reconnect eth0 6
printf 'attempt=1 queries=1\nattempt=2 queries=6\nattempt=3 queries=11\n' > "$T/expected-postcheck"
check "address-less post-check uses five queries before each retry" \
	cmp -s "$T/expected-postcheck" "$POSTCHECK_STARTS"
check "address-less post-check stops after five final queries" \
	test "$(grep -c '^ip -4 addr show dev eth0 scope global$' "$IP_CALLS")" -eq 15
check "address-less retries observe the restored default resolver" \
	sh -c "grep -q '^attempt=2 resolver=default$' '$RESOLVER_OBSERVED' && grep -q '^attempt=3 resolver=default$' '$RESOLVER_OBSERVED'"
check "address-less failure leaves the default resolver restored" \
	sh -c "cmp -s '$T/etc/resolv.conf' '$T/etc/resolv.conf.default'"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
expect_fail "route-less lease post-check retries then fails closed" \
	run_net reconnect eth0 6
printf 'attempt=1 queries=1\nattempt=2 queries=11\nattempt=3 queries=21\n' > "$T/expected-postcheck"
check "route-less post-check uses five query pairs before each retry" \
	cmp -s "$T/expected-postcheck" "$POSTCHECK_STARTS"
check "route-less post-check stops after five final query pairs" \
	sh -c "test \"\$(grep -c '^ip -4 addr show dev eth0 scope global$' '$IP_CALLS')\" -eq 15 && test \"\$(grep -c '^ip route show default dev eth0$' '$IP_CALLS')\" -eq 15"
check "route-less retries observe the restored default resolver" \
	sh -c "grep -q '^attempt=2 resolver=default$' '$RESOLVER_OBSERVED' && grep -q '^attempt=3 resolver=default$' '$RESOLVER_OBSERVED'"
check "route-less failure leaves the default resolver restored" \
	sh -c "cmp -s '$T/etc/resolv.conf' '$T/etc/resolv.conf.default'"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_ok "delayed lease address succeeds after bounded polling" \
	env STUB_ADDR_DELAY=2 sh "$STAGED" reconnect eth0 6
check "delayed address runs post-check then full connectivity check" \
	sh -c "test \"\$(cat '$ADDR_POLLS')\" -eq 3 && test \"\$(grep -c '^ip route show default dev eth0$' '$IP_CALLS')\" -eq 2"
check "delayed address waits for exactly one poll interval" \
	test "$(cat "$SLEEP_CALLS")" = "sleep 1"
check "delayed address needs only one DHCP attempt" \
	test "$(cat "$UDHCPC_COUNT")" -eq 1

# --- DHCP client lifecycle on retry (P2a) ----------------------------------
reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_ok "reconnect stops the previous DHCP client before retrying" \
	env STUB_DHCP_LIVE=1 STUB_ADDR_DELAY=6 SANE_ROOT="$T" sh "$STAGED" reconnect eth0 6
check "retry reaches a second DHCP attempt" test "$(cat "$UDHCPC_COUNT")" -eq 2
check "old client is TERMed then dead before the new udhcpc argv" sh -c '
	term=$(grep -n "^kill -TERM 41001$" "'"$CALLS"'" | sed -n "1s/:.*//p")
	dead=$(grep -n "^dead 41001$" "'"$CALLS"'" | sed -n "1s/:.*//p")
	new=$(grep -n "^udhcpc " "'"$CALLS"'" | sed -n "2s/:.*//p")
	[ -n "$term" ] && [ -n "$dead" ] && [ -n "$new" ] && [ "$term" -lt "$dead" ] && [ "$dead" -lt "$new" ]'
expect_fail "kill -0 on the old client PID fails after the retry" env kill -0 41001
check "at most one DHCP client is live" test "$(wc -l < "$LIVE_PIDS")" -eq 1
check "no client overlap was recorded" sh -c "! grep -q '^overlap$' '$CALLS'"

reset_stubs
expect_fail "TERM-resistant client is escalated to KILL before retry" \
	env STUB_DHCP_LIVE=1 STUB_IGNORE_TERM=41001 SANE_ROOT="$T" sh "$STAGED" reconnect eth0 6
check "TERM then KILL precede the new udhcpc argv" sh -c '
	term=$(grep -n "^kill -TERM 41001$" "'"$CALLS"'" | sed -n "1s/:.*//p")
	kill=$(grep -n "^kill -KILL 41001$" "'"$CALLS"'" | sed -n "1s/:.*//p")
	new=$(grep -n "^udhcpc " "'"$CALLS"'" | sed -n "2s/:.*//p")
	[ -n "$term" ] && [ -n "$kill" ] && [ -n "$new" ] && [ "$term" -lt "$kill" ] && [ "$kill" -lt "$new" ]'
check "a bounded wait separates TERM and KILL" sh -c '
	term=$(grep -n "^kill -TERM 41001$" "'"$CALLS"'" | sed -n "1s/:.*//p")
	kill=$(grep -n "^kill -KILL 41001$" "'"$CALLS"'" | sed -n "1s/:.*//p")
	sed -n "${term},${kill}p" "'"$CALLS"'" | grep -q "^sleep "'

reset_stubs
expect_fail "unkillable client fails closed without starting a new client" \
	sh -c "env STUB_DHCP_LIVE=1 STUB_IGNORE_TERM=41001 STUB_IGNORE_KILL=41001 SANE_ROOT='$T' sh '$STAGED' reconnect eth0 6 >/dev/null 2>'$T/stop-fail.err'"
check "only the first DHCP client was started before fail-closed" \
	test "$(cat "$UDHCPC_COUNT")" -eq 1
check "stop failure names the interface" \
	grep -q 'cannot stop previous DHCP client on eth0' "$T/stop-fail.err"

for pidmode in self malformed stale; do
	reset_stubs
	printf 'yes\n' > "$ADDR_PRESENT"
	printf 'yes\n' > "$ROUTE_PRESENT"
	expect_ok "reconnect with a $pidmode pidfile retries safely" \
		env STUB_PID_MODE="$pidmode" STUB_ADDR_DELAY=6 SANE_ROOT="$T" sh "$STAGED" reconnect eth0 6
	check "$pidmode pidfile never sends TERM or KILL" \
		sh -c "! grep -Eq '^kill -(TERM|KILL) ' '$KILL_CALLS'"
done

# --- Nameserver validation (TODO-1) ----------------------------------------
reset_stubs
expect_ok "dns accepts a valid IPv4 nameserver" run_net dns 1.1.1.1
expect_ok "dns accepts a valid IPv6 nameserver" run_net dns 2001:db8::1
check "IPv6 nameserver written" grep -q '^nameserver 2001:db8::1$' "$T/etc/resolv.conf"
expect_ok "dns accepts multiple nameservers" run_net dns 1.1.1.1 8.8.8.8
check "both nameservers written" sh -c \
	"grep -q '^nameserver 1.1.1.1$' '$T/etc/resolv.conf' && grep -q '^nameserver 8.8.8.8$' '$T/etc/resolv.conf'"
expect_fail "dns rejects a hostname nameserver" run_net dns invalid.example
expect_fail "dns rejects malformed IPv4" run_net dns 256.1.1.1
expect_fail "dns rejects malformed IPv6" run_net dns 1::2::3
expect_fail "dns rejects an empty nameserver" run_net dns ""
expect_fail "dns with no server argument is rejected" run_net dns

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"; printf 'yes\n' > "$ROUTE_PRESENT"
expect_ok "a resolv.conf written by sane-net passes its own check" \
	sh -c "sh '$STAGED' dns 9.9.9.9 && sh '$STAGED' check eth0"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"; printf 'yes\n' > "$ROUTE_PRESENT"
printf 'nameserver invalid.example\n' > "$T/etc/resolv.conf"
expect_fail "check rejects a hostname nameserver" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"; printf 'yes\n' > "$ROUTE_PRESENT"
printf 'nameserver 2001:db8::1\n' > "$T/etc/resolv.conf"
expect_ok "check accepts a valid IPv6 nameserver" run_net check eth0

# --- DHCP client identity / PID reuse (TODO-2) -----------------------------
reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"; printf 'yes\n' > "$ROUTE_PRESENT"
printf '41001\n' > "$T/run/udhcpc-eth0.pid"
printf '41001\n' > "$LIVE_PIDS"
mkdir -p "$T/proc/41001"
printf 'sleep\n' > "$T/proc/41001/comm"
printf '41001 (sleep) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 100 999 1000 0\n' > "$T/proc/41001/stat"
expect_ok "reconnect succeeds without signalling a reused non-DHCP PID" run_net reconnect eth0 6
check "no TERM or KILL sent to the reused PID" \
	sh -c "! grep -Eq '^kill -(TERM|KILL) 41001' '$KILL_CALLS'"
check "reused pidfile was cleaned" test ! -f "$T/run/udhcpc-eth0.pid"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"; printf 'yes\n' > "$ROUTE_PRESENT"
printf '41001\n' > "$T/run/udhcpc-eth0.pid"
printf '41001\n' > "$LIVE_PIDS"
if sh "$STAGED" reconnect eth0 6 >/dev/null 2>"$T/unverifiable.err"; then
	fail "alive but unverifiable client fails closed"
else
	pass "alive but unverifiable client fails closed"
fi
check "unverifiable identity names the interface" \
	grep -q 'cannot verify previous DHCP client identity on eth0' "$T/unverifiable.err"
check "no new DHCP client started when identity is unverifiable" \
	test "$(cat "$UDHCPC_COUNT")" -eq 0
check "no signal sent to an unverifiable PID" \
	sh -c "! grep -Eq '^kill -(TERM|KILL) ' '$KILL_CALLS'"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"; printf 'yes\n' > "$ROUTE_PRESENT"
expect_ok "identity change before SIGKILL avoids killing the reused PID" \
	env STUB_DHCP_LIVE=1 STUB_IGNORE_TERM=41001 STUB_REUSE_AFTER_TERM=1 STUB_ADDR_DELAY=6 \
		SANE_ROOT="$T" sh "$STAGED" reconnect eth0 6
check "no SIGKILL was sent after the identity changed" \
	sh -c "! grep -q '^kill -KILL 41001' '$KILL_CALLS'"
check "a second DHCP attempt still proceeds after identity change" \
	test "$(cat "$UDHCPC_COUNT")" -eq 2

# --- DHCP lifecycle before the first attempt (TODO-3) ----------------------
reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"; printf 'yes\n' > "$ROUTE_PRESENT"
printf '41001\n' > "$T/run/udhcpc-eth0.pid"
printf '41001\n' > "$LIVE_PIDS"
mkdir -p "$T/proc/41001"
printf 'udhcpc\n' > "$T/proc/41001/comm"
printf '41001 (udhcpc) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 100 51001 1000 0\n' > "$T/proc/41001/stat"
expect_ok "reconnect stops a boot-left client before the first attempt" run_net reconnect eth0 6
check "boot-left client was TERMed" grep -q '^kill -TERM 41001' "$KILL_CALLS"
check "boot-left client is dead afterwards" sh -c "! grep -qx 41001 '$LIVE_PIDS'"
check "boot-left client stopped before the new udhcpc argv" sh -c '
	term=$(grep -n "^kill -TERM 41001" "'"$CALLS"'" | sed -n "1s/:.*//p")
	new=$(grep -n "^udhcpc " "'"$CALLS"'" | sed -n "1s/:.*//p")
	[ -n "$term" ] && [ -n "$new" ] && [ "$term" -lt "$new" ]'

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
printf 'yes\n' > "$ROUTE_PRESENT"
expect_fail "check fails without a global IPv4 address" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
printf 'eth1\n' > "$ROUTE_DEV"
expect_fail "check ignores a default route on another interface" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_fail "check rejects extra arguments" run_net check eth0 extra

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'no\n' > "$ROUTE_PRESENT"
expect_fail "check fails without a default route" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
: > "$T/etc/resolv.conf"
expect_fail "check fails without a nameserver" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
printf 'nameserver -invalid\n' > "$T/etc/resolv.conf"
expect_fail "check rejects a nameserver not starting alphanumeric" run_net check eth0

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_fail "reconnect rejects noncanonical leading-zero limit 08" run_net reconnect eth0 08

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_fail "reconnect rejects noncanonical leading-zero limit 09" run_net reconnect eth0 09

# --- Real-binary SANE_ROOT handling ----------------------------------------
ROOTFS="$T/rootfs"
HOST_RESOLV_BEFORE=$(sha256sum /etc/resolv.conf)
mkdir -p "$ROOTFS/etc"
reset_stubs
expect_ok "real binary writes DNS below trailing-slash SANE_ROOT" \
	env SANE_ROOT="$ROOTFS/" sh "$NET" dns 9.9.9.9
check "SANE_ROOT DNS write lands in the target root" \
	grep -q '^nameserver 9.9.9.9$' "$ROOTFS/etc/resolv.conf"
check "SANE_ROOT DNS write leaves the staged resolver untouched" resolver_unchanged

reset_stubs
expect_ok "real binary strips all trailing slashes from SANE_ROOT" \
	env SANE_ROOT="$ROOTFS///" sh "$NET" dns 8.8.4.4
check "multi-slash SANE_ROOT DNS write lands in the target root" \
	grep -q '^nameserver 8.8.4.4$' "$ROOTFS/etc/resolv.conf"

reset_stubs
expect_ok "real binary DHCP honors trailing-slash SANE_ROOT" \
	env SANE_ROOT="$ROOTFS/" sh "$NET" dhcp eth0
check "SANE_ROOT DHCP uses normalized pid and script paths" \
	test "$(cat "$UDHCPC_CALLS")" = "udhcpc -b -R -p $ROOTFS/run/udhcpc-eth0.pid -i eth0 -s $ROOTFS/usr/share/udhcpc/default.script"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
printf 'nameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
expect_ok "real binary reconnect honors trailing-slash SANE_ROOT" \
	env SANE_ROOT="$ROOTFS/" sh "$NET" reconnect eth0 2
check "SANE_ROOT reconnect uses normalized pid and script paths" \
	test "$(cat "$UDHCPC_CALLS")" = "udhcpc -b -R -p $ROOTFS/run/udhcpc-eth0.pid -i eth0 -s $ROOTFS/usr/share/udhcpc/default.script"
HOST_RESOLV_AFTER=$(sha256sum /etc/resolv.conf)
check "real SANE_ROOT tests leave host resolver bytes unchanged" \
	test "$HOST_RESOLV_BEFORE" = "$HOST_RESOLV_AFTER"

# --- BusyBox ip link format fault/recovery & P2 hardening (P1-18) ----------
reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_ok "BusyBox format: check succeeds on <...,UP,LOWER_UP>" \
	env STUB_IP_STYLE=busybox sh "$STAGED" check eth0

reset_stubs
printf 'nocarrier\n' > "$CARRIER"
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_fail "BusyBox format: check fails on <NO-CARRIER,...,UP>" \
	env STUB_IP_STYLE=busybox sh "$STAGED" check eth0
expect_ok "BusyBox format: reconnect recovers from NO-CARRIER to LOWER_UP" \
	env STUB_IP_STYLE=busybox sh "$STAGED" reconnect eth0 3
reset_stubs
printf 'nocarrier\n' > "$CARRIER"
expect_fail "BusyBox format: reconnect fails closed when NO-CARRIER persists" \
	env STUB_IP_STYLE=busybox STUB_LINK_RECOVER=0 sh "$STAGED" reconnect eth0 2

reset_stubs
printf '41001\n' > "$T/run/udhcpc-eth0.pid"
printf '41001\n' > "$LIVE_PIDS"
mkdir -p "$T/proc/41001"
printf 'udhcpc\n' > "$T/proc/41001/comm"
printf '41001 (udhcpc) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 20 0 1 0 100 51001 1000 0\n' > "$T/proc/41001/stat"
expect_ok "dhcp stops previous udhcpc client before starting new one" \
	env SANE_ROOT="$T" sh "$STAGED" dhcp eth0
check "dhcp TERMed previous udhcpc client" grep -q '^kill -TERM 41001' "$KILL_CALLS"
check "dhcp waited/killed previous client before new udhcpc" sh -c "! grep -qx 41001 '$LIVE_PIDS'"

reset_stubs
printf 'yes\n' > "$ADDR_PRESENT"
printf 'yes\n' > "$ROUTE_PRESENT"
expect_ok "reconnect with SECONDS=0 succeeds when carrier is already up" \
	run_net reconnect eth0 0
printf 'down\n' > "$CARRIER"
expect_fail "reconnect with SECONDS=0 fails without sleeping when carrier is down" \
	env STUB_LINK_RECOVER=0 sh "$STAGED" reconnect eth0 0
check "reconnect SECONDS=0 made no sleep call" test ! -s "$SLEEP_CALLS"

reset_stubs
expect_fail "static rejects invalid DNS before mutating link/addr/route" \
	run_net static eth0 10.0.0.2/24 10.0.0.1 invalid.example
check "static invalid DNS made no ip calls" test ! -s "$IP_CALLS"

reset_stubs
expect_ok "real binary foreground DHCP (-f) honors trailing-slash SANE_ROOT" \
	env SANE_ROOT="$ROOTFS/" sh "$NET" dhcp -f eth0
check "SANE_ROOT foreground DHCP passes -f -R and normalized paths" \
	test "$(cat "$UDHCPC_CALLS")" = "udhcpc -f -R -p $ROOTFS/run/udhcpc-eth0.pid -i eth0 -s $ROOTFS/usr/share/udhcpc/default.script"

reset_stubs
set_fail_tool chmod
expect_fail "wifi chmod failure exits nonzero" \
	env PATH="$FAILBIN:$PATH" sh "$STAGED" wifi eth0 home-net secretpass
check "wifi chmod failure leaves no temporary config with PSK" sh -c \
	"! ls '$T/etc'/.wpa_supplicant.* >/dev/null 2>&1"

printf '\nNetwork fault tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
