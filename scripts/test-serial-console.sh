#!/usr/bin/env bash
# scripts/test-serial-console.sh -- Automated Interactive Serial Console Verification
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
IMAGE_FILE="${1:-$REPO_ROOT/distro/sane.img}"
TIMEOUT_SECS="${2:-45}"

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
state = 0  # 0: wait login, 1: wait pass, 2: wait prompt, 3: wait sentinel, 4: wait whoami, 5: wait doas root, 6: wait shutdown
last_idx = 0
doas_pw_sent = False
test_passed = False
start_time = time.time()
deadline = start_time + timeout

SENTINEL = "SANE_SERIAL_INTERACTIVE_ECHO_PASS"

while time.time() < deadline:
    r, _, _ = select.select([proc.stdout], [], [], 0.1)
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

    # State Machine
    recent = buffer[last_idx:]

    if state == 0:
        if "login:" in recent.lower():
            time.sleep(0.2)
            proc.stdin.write(b"sane\n")
            proc.stdin.flush()
            state = 1
            last_idx = len(buffer)
        elif ("main loop ready" in buffer or "/ #" in buffer or "started console" in buffer) and time.time() > start_time + 10:
            time.sleep(0.5)
            proc.stdin.write(f"echo {SENTINEL}\n".encode("utf-8"))
            proc.stdin.flush()
            state = 3
            last_idx = len(buffer)

    elif state == 1:
        if "password:" in recent.lower():
            time.sleep(0.2)
            proc.stdin.write(b"sane\n")
            proc.stdin.flush()
            state = 2
            last_idx = len(buffer)

    elif state == 2:
        if "$" in recent or "#" in recent:
            time.sleep(0.2)
            proc.stdin.write(f"echo {SENTINEL}\n".encode("utf-8"))
            proc.stdin.flush()
            state = 3
            last_idx = len(buffer)

    elif state == 3:
        if SENTINEL in recent:
            time.sleep(0.2)
            proc.stdin.write(b"whoami\n")
            proc.stdin.flush()
            state = 4
            last_idx = len(buffer)

    elif state == 4:
        if "sane" in recent:
            time.sleep(0.2)
            proc.stdin.write(b"doas whoami\n")
            proc.stdin.flush()
            state = 5
            doas_pw_sent = False
            last_idx = len(buffer)

    elif state == 5:
        if "password:" in recent.lower() and not doas_pw_sent:
            time.sleep(0.2)
            proc.stdin.write(b"sane\n")
            proc.stdin.flush()
            doas_pw_sent = True
        elif "root" in recent:
            time.sleep(0.2)
            proc.stdin.write(b"doas poweroff\n")
            proc.stdin.flush()
            state = 6
            last_idx = len(buffer)

    elif state == 6:
        if "password:" in recent.lower():
            time.sleep(0.2)
            proc.stdin.write(b"sane\n")
            proc.stdin.flush()
        if "power down" in recent.lower() or "system halted" in recent.lower() or "reboot: power down" in recent.lower():
            test_passed = True
            break

    if proc.poll() is not None:
        if state == 6:
            test_passed = True
        break

try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()

if proc.poll() is not None and state == 6:
    test_passed = True

if not test_passed:
    print(f"\n[FAIL] Interactive serial console test timed out or failed in state {state} within {timeout}s", file=sys.stderr)
    sys.exit(1)

print("\n[PASS] Serial interactive console input/output verified successfully!")
sys.exit(0)
PYEOF
