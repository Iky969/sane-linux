#!/usr/bin/env bash
# scripts/test-serial-console.sh -- Automated Interactive Serial Console Verification
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
IMAGE_FILE="${1:-$REPO_ROOT/distro/sane.img}"
TIMEOUT_SECS="${2:-30}"

[ -f "$IMAGE_FILE" ] || {
    printf '[FAIL] Disk image %s not found\n' "$IMAGE_FILE" >&2
    exit 1
}

python3 - "$IMAGE_FILE" "$TIMEOUT_SECS" <<'PYEOF'
import sys, subprocess, time, select, os, fcntl

img_path = sys.argv[1]
timeout = int(sys.argv[2])

qemu_cmd = [
    "qemu-system-x86_64",
    "-drive", f"file={img_path},format=raw,if=virtio",
    "-snapshot",
    "-m", "256M",
    "-serial", "stdio",
    "-display", "none",
    "-no-reboot"
]

if os.path.exists("/dev/kvm") and os.access("/dev/kvm", os.R_OK | os.W_OK):
    qemu_cmd.extend(["-enable-kvm", "-cpu", "host"])
else:
    qemu_cmd.extend(["-cpu", "max"])

proc = subprocess.Popen(
    qemu_cmd,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    bufsize=0
)

fl = fcntl.fcntl(proc.stdout.fileno(), fcntl.F_GETFL)
fcntl.fcntl(proc.stdout.fileno(), fcntl.F_SETFL, fl | os.O_NONBLOCK)

buffer = ""
command_sent = False
test_passed = False
deadline = time.time() + timeout

SENTINEL = "SANE_SERIAL_INTERACTIVE_ECHO_PASS"

while time.time() < deadline:
    r, _, _ = select.select([proc.stdout], [], [], 0.2)
    if r:
        chunk = proc.stdout.read(4096)
        if chunk:
            text = chunk.decode("utf-8", errors="replace")
            sys.stdout.write(text)
            sys.stdout.flush()
            buffer += text

            if "crash-loop" in buffer or "marked failed" in buffer:
                print("\n[FAIL] Console crash-loop detected in serial stream!", file=sys.stderr)
                proc.kill()
                sys.exit(1)

            if not command_sent and ("main loop ready" in buffer or "/ #" in buffer or "started console" in buffer):
                time.sleep(0.5)
                cmd = f"echo {SENTINEL}\n"
                proc.stdin.write(cmd.encode("utf-8"))
                proc.stdin.flush()
                command_sent = True

            if command_sent and SENTINEL in buffer:
                test_passed = True
                proc.stdin.write(b"poweroff\n")
                proc.stdin.flush()
                break

    if proc.poll() is not None:
        break

try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()

if not test_passed:
    print(f"\n[FAIL] Interactive serial console test timed out or failed to execute command within {timeout}s", file=sys.stderr)
    sys.exit(1)

print("\n[PASS] Serial interactive console input/output verified successfully!")
sys.exit(0)
PYEOF
