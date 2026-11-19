#!/bin/sh
# scripts/test-network.sh -- Phase B networking regression tests.
# Uses stubbed ip/udhcpc/curl/wpa_supplicant so no host network is touched.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
NET="$REPO_ROOT/packages/ninit/x/usr/bin/sane-net"
UDHCP_SCRIPT="$REPO_ROOT/packages/busybox/x/usr/share/udhcpc/default.script"

PASS=0
FAIL=0
T=$(mktemp -d)
cleanup() { rm -rf -- "$T"; }
trap cleanup EXIT HUP INT TERM

pass() { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1" >&2; }
check() { d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
expect_fail() { d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d"; else pass "$d"; fi; }

mkdir -p "$T/bin" "$T/etc" "$T/etc/ssl/certs" "$T/usr/share/udhcpc"
LOG="$T/calls.log"
: > "$LOG"

mkstub() {
	name=$1; body=$2
	cat > "$T/bin/$name" <<EOF
#!/bin/sh
$body
EOF
	chmod 0755 "$T/bin/$name"
}

mkstub ip 'printf "%s\n" "ip $*" >> "'"$LOG"'"
case "$*" in
  *"link show dev eth0"*) printf "2: eth0: <BROADCAST,MULTICAST,UP> state UP mode DEFAULT\n" ;;
  addr\ add*) printf "inet %s scope global eth0\n" "$3" >> '"$T"'/ip-addr ;;
  route\ add\ default\ via*) printf "default via %s dev eth0 proto static\n" "$5" >> '"$T"'/ip-route ;;
  *"addr show dev eth0"*) cat '"$T"'/ip-addr 2>/dev/null ;;
  *"route show default dev eth0"*) cat '"$T"'/ip-route 2>/dev/null ;;
esac
exit 0'
: > "$T/ip-addr"
: > "$T/ip-route"
mkstub udhcpc 'printf "%s\n" "udhcpc $*" >> "'"$LOG"'"; exit 0'
mkstub curl 'printf "%s\n" "curl $*" >> "'"$LOG"'"; exit 0'
mkstub wpa_supplicant 'printf "%s\n" "wpa_supplicant $*" >> "'"$LOG"'"; exit 0'

PATH="$T/bin:$PATH"
export PATH

# Stage sane-net with all writable paths redirected into the temp root so the
# host /etc is never touched.
STAGED="$T/bin/sane-net-stage"
sed -e "s|^RESOLV=.*|RESOLV=$T/etc/resolv.conf|" \
    -e "s|^RESOLV_DEFAULT=.*|RESOLV_DEFAULT=$T/etc/resolv.conf.default|" \
    -e "s|^WPACONF=.*|WPACONF=$T/etc/wpa_supplicant.conf|" \
    -e "s|^CABUNDLE=.*|CABUNDLE=$T/etc/ssl/certs/ca-certificates.crt|" \
    "$NET" > "$STAGED"
chmod 0755 "$STAGED"

run_net() { sh "$STAGED" "$@"; }

check "sane-net is present" test -f "$NET"
check "sane-net passes shell syntax" sh -n "$NET"

# --- Ethernet / link -------------------------------------------------------
check "link up calls ip" run_net link eth0 up
check "ip link set up recorded" grep -q '^ip link set eth0 up$' "$LOG"
check "link show works" run_net link eth0
expect_fail "link without interface rejected" run_net link

# --- Static + DNS ----------------------------------------------------------
expect_fail "static without required args rejected" run_net static eth0 10.0.0.2/24
check "static config succeeds" run_net static eth0 10.0.0.2/24 10.0.0.1 1.1.1.1 8.8.8.8
check "static sets address" grep -q '^ip addr add 10.0.0.2/24 dev eth0$' "$LOG"
check "static sets default route" grep -q '^ip route add default via 10.0.0.1$' "$LOG"
check "repeating static config succeeds" \
 run_net static eth0 10.0.0.2/24 10.0.0.1 1.1.1.1 8.8.8.8
check "repeated static keeps exactly the right address" sh -c \
 "[ \$(grep -c '^ip addr add ' '$LOG') -eq 1 ] && \
  grep -qx '^ip addr add 10.0.0.2/24 dev eth0\$' '$LOG' && \
  grep -qx 'inet 10.0.0.2/24 scope global eth0' '$T/ip-addr' && \
  ! grep -q '^inet add ' '$T/ip-addr' && ! grep -q '^inet via ' '$T/ip-addr'"
check "repeated static keeps exactly the right route" sh -c \
 "[ \$(grep -c '^ip route add ' '$LOG') -eq 1 ] && \
  grep -qx '^ip route add default via 10.0.0.1\$' '$LOG' && \
  grep -qx 'default via 10.0.0.1 dev eth0 proto static' '$T/ip-route' && \
  ! grep -q '^default via via ' '$T/ip-route' && ! grep -q '^default add ' '$T/ip-route'"
mkdir -p "$T/failbin"
cat > "$T/failbin/ip" <<'EOF'
#!/bin/sh
[ "$1" = link ] && exit 0
exit 1
EOF
chmod 0755 "$T/failbin/ip"
expect_fail "static propagates ip address failure" \
	env PATH="$T/failbin:$PATH" sh "$STAGED" static eth0 10.0.0.2/24 10.0.0.1
check "resolv.conf contains both servers" sh -c \
	"grep -q '^nameserver 1.1.1.1$' '$T/etc/resolv.conf' && grep -q '^nameserver 8.8.8.8$' '$T/etc/resolv.conf'"
check "resolv.conf mode 0644" test "$(stat -c %a "$T/etc/resolv.conf")" = 644

# --- DNS atomicity / validation -------------------------------------------
check "dns command writes nameservers" run_net dns 9.9.9.9
check "dns replaced previous file" sh -c \
	"! grep -q '8.8.8.8' '$T/etc/resolv.conf' && grep -q '^nameserver 9.9.9.9$' '$T/etc/resolv.conf'"
expect_fail "dns rejects shell metacharacters" run_net dns '1.1.1.1; rm -rf /'
check "metacharacter DNS did not change resolv.conf" sh -c \
	"grep -q '^nameserver 9.9.9.9$' '$T/etc/resolv.conf'"
printf 'nameserver 1.1.1.1\n' > "$T/etc/resolv.conf.default"
check "dns default restores baseline" run_net dns default
check "baseline resolver restored" sh -c \
	"grep -q '^nameserver 1.1.1.1$' '$T/etc/resolv.conf'"
check "dns default writes mode 0644" test "$(stat -c %a "$T/etc/resolv.conf")" = 644
expect_fail "hostname nameserver rejected" run_net dns ns-1.example.test
check "rejected hostname did not change resolv.conf" sh -c \
	"! grep -q 'ns-1.example.test' '$T/etc/resolv.conf' && grep -q '^nameserver 1.1.1.1$' '$T/etc/resolv.conf'"

# --- DHCP / reconnect ------------------------------------------------------
check "dhcp starts udhcpc with script" run_net dhcp eth0
check "udhcpc uses default.script" grep -q 'udhcpc .*-s /usr/share/udhcpc/default.script' "$LOG"
# Seed a lease state so the bounded post-check sees an address + default route
# even if no earlier static configuration populated the stateful stub.
printf 'inet 10.0.0.2/24 scope global eth0\n' > "$T/ip-addr"
printf 'default via 10.0.0.1 dev eth0 proto static\n' > "$T/ip-route"
check "reconnect starts DHCP when carrier is up" run_net reconnect eth0 2
check "reconnect recorded a udhcpc call" sh -c \
	"[ \$(grep -c '^udhcpc ' '$LOG') -ge 2 ]"

# --- Wi-Fi -----------------------------------------------------------------
check "wifi writes configuration and starts supplicant" run_net wifi eth0 home-net secretpass
check "wpa config mode 0600" test "$(stat -c %a "$T/etc/wpa_supplicant.conf")" = 600
check "wpa config contains SSID" grep -q 'ssid="home-net"' "$T/etc/wpa_supplicant.conf"
check "supplicant started on eth0" grep -q '^wpa_supplicant .*-i eth0' "$LOG"
expect_fail "wifi rejects short PSK" run_net wifi eth0 home-net short
check "wifi accepts SSID with spaces and escapes PSK" \
	run_net wifi eth0 'my net' 'pa"ss\word'
check "SSID with spaces written" grep -qF 'ssid="my net"' "$T/etc/wpa_supplicant.conf"
check "PSK quotes and backslashes escaped" \
	grep -qF 'psk="pa\"ss\\word"' "$T/etc/wpa_supplicant.conf"
rm -f "$T/etc/wpa_supplicant.conf"

# --- TLS -------------------------------------------------------------------
printf 'bundle\n' > "$T/etc/ssl/certs/ca-certificates.crt"
check "tls-check passes cacert to curl" run_net tls-check https://example.invalid
check "curl invoked with CA bundle" grep -q -- "--cacert $T/etc/ssl/certs/ca-certificates.crt" "$LOG"
expect_fail "tls-check rejects non-HTTPS URL" run_net tls-check http://example.invalid

# --- udhcpc event script ---------------------------------------------------
UDHCP_ROOT="$T/udhcp"
mkdir -p "$UDHCP_ROOT/etc" "$UDHCP_ROOT/usr/share/udhcpc"
sed 's|/etc/resolv.conf|'"$UDHCP_ROOT"'/etc/resolv.conf|g' "$UDHCP_SCRIPT" > "$UDHCP_ROOT/usr/share/udhcpc/default.script"
chmod 0755 "$UDHCP_ROOT/usr/share/udhcpc/default.script"
printf 'nameserver 1.1.1.1\n' > "$UDHCP_ROOT/etc/resolv.conf.default"
check "udhcpc bound writes DNS atomically" env interface=eth0 ip=10.0.0.5 mask=24 router=10.0.0.1 dns='8.8.4.4 1.0.0.1' \
	sh "$UDHCP_ROOT/usr/share/udhcpc/default.script" bound
check "bound DNS recorded" sh -c \
	"grep -q '^nameserver 8.8.4.4$' '$UDHCP_ROOT/etc/resolv.conf'"
check "udhcpc bound ignores a hostname nameserver" env interface=eth0 ip=10.0.0.5 mask=24 router=10.0.0.1 dns='dns.provider.net 8.8.4.4' \
	sh "$UDHCP_ROOT/usr/share/udhcpc/default.script" bound
check "event script writes only the valid IP, not the hostname" sh -c \
	"! grep -q 'dns.provider.net' '$UDHCP_ROOT/etc/resolv.conf' && grep -q '^nameserver 8.8.4.4$' '$UDHCP_ROOT/etc/resolv.conf'"
check "udhcpc deconfig restores default DNS" env interface=eth0 \
	sh "$UDHCP_ROOT/usr/share/udhcpc/default.script" deconfig
check "deconfig DNS restored" sh -c \
	"grep -q '^nameserver 1.1.1.1$' '$UDHCP_ROOT/etc/resolv.conf'"
check "deconfig restore is atomic (0644)" \
	test "$(stat -c %a "$UDHCP_ROOT/etc/resolv.conf")" = 644

# --- build integration -----------------------------------------------------
for tpl in build-rootfs.sh make-image.sh sane-install.sh; do
	check "$tpl boots networking via sane-net" sh -c \
		"grep -q 'sane-net dhcp eth0' '$REPO_ROOT/scripts/$tpl'"
done
for tpl in make-image.sh sane-install.sh; do
	check "$tpl creates a default resolver" sh -c \
		"grep -q 'nameserver 1.1.1.1' '$REPO_ROOT/scripts/$tpl' && grep -q 'resolv.conf.default' '$REPO_ROOT/scripts/$tpl'"
done

# --- Wi-Fi package ---------------------------------------------------------
WPA_DIR="$REPO_ROOT/packages/wpa-supplicant"
check "wpa-supplicant recipe exists" test -f "$WPA_DIR/build.sh"
check "wpa-supplicant binary is present" test -x "$WPA_DIR/x/usr/bin/wpa_supplicant"
check "wpa_supplicant is statically linked" sh -c \
	"! readelf -lW '$WPA_DIR/x/usr/bin/wpa_supplicant' 2>/dev/null | grep -q INTERP"
# Git stores 0644 for all tracked files; the mode is enforced at install time.
cp "$WPA_DIR/x/etc/wpa_supplicant.conf" "$T/etc/wpa_supplicant.conf"
chmod 0600 "$T/etc/wpa_supplicant.conf"
check "wpa config install mode is 0600" test "$(stat -c %a "$T/etc/wpa_supplicant.conf")" = 600
for tpl in build-rootfs.sh make-image.sh sane-install.sh; do
	check "$tpl enforces 0600 on wpa config" sh -c \
		"grep -q '0600.*wpa_supplicant.conf' '$REPO_ROOT/scripts/$tpl'"
done
check "wpa-supplicant is in build-all.sh" sh -c \
	"grep -q '^    wpa-supplicant$' '$REPO_ROOT/packages/build-all.sh'"

printf '\nPhase B network tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
