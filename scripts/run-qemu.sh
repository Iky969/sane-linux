#!/bin/sh
# run-qemu.sh -- boot the S.A.N.E distro rootfs (scripts/build-rootfs.sh) in QEMU
# with a serial console, then check the ninit boot markers.
#
# Pemakaian:
#   sh ./scripts/run-qemu.sh            # interactive; quit QEMU: Ctrl-A X
#   SECS=5 sh ./scripts/run-qemu.sh     # automatic 5-second boot + console report
#
# Variabel:
#   KERNEL=/path/vmlinuz   kernel to use; defaults to the host kernel when present,
#                          otherwise download Alpine vmlinuz-virt into the cache
#   KERNEL_MODE=auto       auto | host | alpine
#   ALPINE_BRANCH=v3.20    Alpine branch for the downloaded kernel
#   ALPINE_FLAVOR=virt     virt | lts
#   SECS=<seconds>         automatic mode (without this: interactive)
#   MEM=256                RAM guest (MB)
#   NO_REBOOT=1            1 = QEMU exits when the guest asks to reboot (automated test),
#                          0 = QEMU resets the machine so the ninit restart is visible
#   REBUILD=1              rebuild rootfs + initramfs before boot
#   CONSOLE_LOG=$DISTRO_DIR/qemu-console.log   guest serial console output
#   REPORT_ONLY=1          do not boot; run the report() checks against an
#                          existing CONSOLE_LOG (for log-fixture tests,
#                          see scripts/test-qemu-report.sh)
#
# Requires: qemu-system-x86_64 (apt-get install -y qemu-system-x86), curl, gzip.
#
# Catatan QEMU:
#   - Interactive mode uses `-nographic` (serial + monitor on stdio).
#   - Automatic mode uses `-display none -serial file:<log>` so the guest
#     console output is captured completely without depending on a TTY, and
#     the process is bounded by `timeout` for $SECS seconds.
#   - The kernel is booted as an initramfs: `-kernel <vmlinuz> -initrd <cpio.gz>`
#     with `rdinit=/sbin/init init=/sbin/init` (both are given so the chosen
#     init does not depend on the kernel variant).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

DISTRO_DIR=${DISTRO_DIR:-$REPO_ROOT/distro}
CACHE_DIR=${CACHE_DIR:-$DISTRO_DIR/cache}
ROOTFS=${ROOTFS:-$DISTRO_DIR/rootfs}
INITRAMFS=${INITRAMFS:-$DISTRO_DIR/initramfs.cpio.gz}
CONSOLE_LOG=${CONSOLE_LOG:-$DISTRO_DIR/qemu-console.log}
QEMU_LOG=$DISTRO_DIR/qemu.log

KERNEL=${KERNEL:-}
KERNEL_MODE=${KERNEL_MODE:-auto}
ALPINE_BRANCH=${ALPINE_BRANCH:-v3.20}
ALPINE_FLAVOR=${ALPINE_FLAVOR:-virt}
SECS=${SECS:-}
MEM=${MEM:-256}
NO_REBOOT=${NO_REBOOT:-1}
REBUILD=${REBUILD:-0}
APPEND="console=ttyS0 rdinit=/sbin/init init=/sbin/init panic=-1 loglevel=7"

log()  { printf '== %s\n' "$1"; }
info() { printf '   %s\n' "$1"; }
die()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "tool '$1' not found${2:+ ($2)}"; }

if [ "${REPORT_ONLY:-0}" = 1 ]; then
	# Report-only mode does not need QEMU/timeout/gzip — grep, sed, date suffice.
	:
else
	need qemu-system-x86_64 "apt-get install -y qemu-system-x86"
	need timeout
	need gzip
	need sha256sum "coreutils"
	need sleep "coreutils"
fi

# --------------------------------------------------------------- kernel
host_kernel() {
	hk=/boot/vmlinuz-$(uname -r)
	[ -r "$hk" ] && { printf '%s' "$hk"; return 0; }
	return 1
}

resolve_kernel() {
	if [ -n "$KERNEL" ]; then
		[ -r "$KERNEL" ] || die "kernel '$KERNEL' is not readable"
		return 0
	fi
	case $KERNEL_MODE in
	host)
		KERNEL=$(host_kernel) || die "/boot/vmlinuz-$(uname -r) not found (use KERNEL_MODE=alpine)"
		;;
	alpine)
		KERNEL=$CACHE_DIR/vmlinuz-$ALPINE_FLAVOR-$ALPINE_BRANCH
		;;
	auto)
		if KERNEL=$(host_kernel); then
			info "using host kernel: $KERNEL"
		else
			info "host kernel (/boot/vmlinuz-$(uname -r)) not found, switching to Alpine"
			KERNEL=$CACHE_DIR/vmlinuz-$ALPINE_FLAVOR-$ALPINE_BRANCH
		fi
		;;
	*)
		die "KERNEL_MODE='$KERNEL_MODE' unknown (auto|host|alpine)" ;;
	esac

	case $KERNEL in
	"$CACHE_DIR"/*)
		url="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/releases/x86_64/netboot/vmlinuz-$ALPINE_FLAVOR"
		if [ ! -s "$KERNEL" ]; then
			log "downloading Alpine kernel ($ALPINE_BRANCH, $ALPINE_FLAVOR)"
			mkdir -p "$CACHE_DIR"
			curl -fL --retry 3 --connect-timeout 15 -o "$KERNEL.part" "$url" \
				|| die "kernel download failed: $url"
			mv "$KERNEL.part" "$KERNEL"
		fi
		size=$(wc -c < "$KERNEL")
		[ "$size" -gt 500000 ] || die "downloaded kernel is too small ($size bytes)"
		sha=$(sha256sum "$KERNEL" | cut -d' ' -f1)
		printf '%s  %s\n' "$sha" "$(basename "$KERNEL")" > "$KERNEL.sha256"
		info "downloaded kernel: $KERNEL ($(du -h "$KERNEL" | cut -f1), sha256 $(printf '%s' "$sha" | cut -c1-16)…)"
		;;
	esac
}

ensure_initramfs() {
	if [ "$REBUILD" = 1 ] || [ ! -s "$INITRAMFS" ]; then
		log "building rootfs + initramfs first"
		DISTRO_DIR=$DISTRO_DIR ROOTFS=$ROOTFS INITRAMFS=$INITRAMFS \
			sh "$SCRIPT_DIR/build-rootfs.sh"
	fi
	[ -s "$INITRAMFS" ] || die "initramfs '$INITRAMFS' not found (run: sh ./scripts/build-rootfs.sh)"
}

# --------------------------------------------------------------- QEMU
run_qemu() { # $1 = auto | interactive
	mode=$1
	if [ "$mode" = auto ]; then
		set -- -display none -serial "file:$CONSOLE_LOG"
	else
		set -- -nographic
	fi
	if [ -w /dev/kvm ] 2>/dev/null; then
		info "KVM available: -enable-kvm -cpu host"
		set -- "$@" -enable-kvm -cpu host
	elif [ "$mode" = auto ]; then
		# TCG without -cpu uses qemu64, which lacks AVX etc.: a modern host
		# toolchain (e.g. Ubuntu x86-64-v3) raises SIGILL inside the guest and
		# the panic is far from the real cause. -cpu max = everything TCG can
		# emulate.
		info "TCG: -cpu max (the default qemu64 is too old for the host toolchain)"
		set -- "$@" -cpu max
	fi
	if [ "$NO_REBOOT" = 1 ]; then
		set -- "$@" -no-reboot
	else
		info "NO_REBOOT=0: a guest reboot resets the machine (QEMU does not exit)"
	fi
	if [ "$mode" = auto ]; then
		exec timeout -k 2 "$SECS" qemu-system-x86_64 -m "$MEM" "$@" \
			-kernel "$KERNEL" -initrd "$INITRAMFS" -append "$APPEND"
	fi
	exec qemu-system-x86_64 -m "$MEM" "$@" \
		-kernel "$KERNEL" -initrd "$INITRAMFS" -append "$APPEND"
}

# --------------------------------------------------------------- report
mark_ms() { # $1 = marker; print ms since $T0 when found
	if grep -q "$1" "$CONSOLE_LOG" 2>/dev/null; then
		printf '%s' "$(( ($(date +%s%N) - T0) / 1000000 ))"
	else
		printf ''
	fi
}

report() {
	fail_count=0
	check()  { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [ OK ]   %s\n' "$1"; else printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); fi; }
	absent() { if grep -q "$2" "$CONSOLE_LOG"; then printf '  [FAIL] %s\n' "$1"; fail_count=$((fail_count + 1)); else printf '  [ OK ]   %s\n' "$1"; fi; }

	printf '\n== QEMU console checks ==\n'
	check "banner 'ninit start (PID 1)' from guest" 'ninit start (PID 1)'
	check "event loop entered ('main loop ready')"          'main loop ready'
	check "service /etc/init.conf executed ('started console')" 'started console'

	# Console liveness. 'started console' is written by spawn_service() AT FORK,
	# not after a successful exec; a service that dies immediately (e.g. a
	# missing binary -> exit status=0x7f00) still emits it repeatedly through
	# the respawn path. Note: every ninit line appears TWICE on the console
	# (/dev/kmsg and stderr), so the count is unique PIDs, not the number of
	# lines.
	console_pids=$(grep -o 'started console (pid [0-9]\{1,\}' "$CONSOLE_LOG" 2>/dev/null | sed 's/.*pid //' | sort -u || true)
	console_pid_count=$(printf '%s\n' "$console_pids" | grep -c '[0-9]' || true)
	if [ "$console_pid_count" = 1 ]; then
		printf '  [ OK ]   console started with exactly one PID (%s) - no respawn loop\n' "$console_pids"
	else
		printf '  [FAIL] console has %s unique PIDs (restarted): %s\n' \
			"$console_pid_count" "$(printf '%s ' $console_pids)"
		fail_count=$((fail_count + 1))
	fi
	absent "console never exited ('console (pid N) exit status')" 'console (pid [0-9]*) exit status'
	# Scoped to the console: ANOTHER respawn service whose window was delayed is
	# normal behavior (see PR #6 review note); what is forbidden is the console
	# itself being respawned.
	absent "console was not respawn-delayed ('console: respawn delayed')" 'console: respawn delayed'

	absent "no kernel panic"                      'Kernel panic'
	if [ -n "${ready_ms:-}" ]; then
		printf '  [ OK ]   boot reached "main loop ready" in %s ms (TCG/emulation mode)\n' "$ready_ms"
	else
		printf '  [FAIL] "main loop ready" did not appear within %s seconds\n' "$SECS"
		fail_count=$((fail_count + 1))
	fi

	if [ "$fail_count" -eq 0 ]; then
		printf '\nRESULT: PASS (all checks)\n'
	else
		printf '\nRESULT: FAIL (%s checks)\n' "$fail_count"
		printf '\n-- tail of the QEMU log itself --\n'
		tail -n 15 "$QEMU_LOG" 2>/dev/null | sed 's/^/  | /'
	fi
}

# --------------------------------------------------------------- main
if [ "${REPORT_ONLY:-0}" = 1 ]; then
	[ -r "$CONSOLE_LOG" ] || die "REPORT_ONLY=1 requires a readable CONSOLE_LOG '$CONSOLE_LOG'"
	log "REPORT_ONLY=1: checking $CONSOLE_LOG without booting QEMU"
	T0=$(date +%s%N)
	ready_ms=$(mark_ms 'main loop ready')
	report
	[ "${fail_count:-1}" -eq 0 ] || exit 1
	exit 0
fi

resolve_kernel
ensure_initramfs

log "rootfs     : $ROOTFS"
log "initramfs  : $INITRAMFS"
log "kernel     : $KERNEL"
log "append     : $APPEND"

if [ -z "$SECS" ]; then
	log "running QEMU interactively (quit: Ctrl-A X)"
	printf '\n'
	run_qemu interactive
	exit 0
fi

log "automatic boot for ${SECS}s (console -> $CONSOLE_LOG)"
mkdir -p "$DISTRO_DIR"
: > "$CONSOLE_LOG"
: > "$QEMU_LOG"

T0=$(date +%s%N)
run_qemu auto >>"$QEMU_LOG" 2>&1 &
qemu_pid=$!
trap 'kill -TERM "$qemu_pid" 2>/dev/null || true' EXIT INT TERM

ready_ms=''
banner_ms=''
i=0
while [ "$i" -lt $((SECS * 20)) ]; do
	[ -z "$banner_ms" ] && banner_ms=$(mark_ms 'ninit start (PID 1)')
	if [ -z "$ready_ms" ]; then
		ready_ms=$(mark_ms 'main loop ready')
		[ -n "$ready_ms" ] && break
	fi
	sleep 0.05
	i=$((i + 1))
done

wait "$qemu_pid" 2>/dev/null || true   # timeout stops QEMU after $SECS seconds
kill -TERM "$qemu_pid" 2>/dev/null || true

[ -n "$banner_ms" ] && printf '   banner ninit detected after %s ms\n' "$banner_ms"
[ -n "$ready_ms" ]  && printf '   "main loop ready" after %s ms\n' "$ready_ms"

printf '\n== QEMU serial console (%s) ==\n' "$CONSOLE_LOG"
sed 's/^/  | /' "$CONSOLE_LOG"

report
[ "${fail_count:-1}" -eq 0 ] || exit 1
