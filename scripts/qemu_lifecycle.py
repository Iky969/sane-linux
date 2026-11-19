#!/usr/bin/env python3
"""Boot/lifecycle regression runner for S.A.N.E Linux.

Exercises the account setup state machine against a persistent disk image in
QEMU. All console interaction goes through a pty; no tmux/expect dependency.
"""
from __future__ import annotations

import argparse
import os
import pty
import re
import tempfile
import select
import socket
import string
import subprocess
import sys
import time
from pathlib import Path

ROOT_PW = "LifecycleRoot2026"
USER_PW = "LifecycleUser2026"
USER = "sane"
REPO_ROOT = Path(__file__).resolve().parent.parent
RELIABILITY_JOURNAL = "/var/lib/sane/reliability/journal"

# A usable password hash is a complete SHA-512 crypt value, not a bare "$6$"
# prefix left behind by an interrupted passwd. Mirrors valid_sha512_hash() in
# scripts/sane-accounts so both suites judge a shadow file the same way.
_HASH_CHARS = frozenset(string.ascii_letters + string.digits + "./")


def valid_sha512_hash(value: str) -> bool:
    if not value.startswith("$6$"):
        return False
    parts = value[3:].split("$")
    if len(parts) != 2:
        return False
    salt, checksum = parts
    if not (1 <= len(salt) <= 16) or not set(salt) <= _HASH_CHARS:
        return False
    if len(checksum) != 86 or not set(checksum) <= _HASH_CHARS:
        return False
    return True


def run(cmd, *, capture=True, check=False, stdin=None):
    p = subprocess.run(cmd, input=stdin, text=capture, stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None)
    if check and p.returncode:
        raise RuntimeError(f"{' '.join(cmd)} failed ({p.returncode}): {p.stdout or ''}")
    return p


def sudo(cmd):
    return (["sudo", "-n"] if os.geteuid() != 0 else []) + cmd


class Image:
    """Persistent disk image, edited by mounting the root partition on demand.

    Never keep the partition mounted while QEMU runs: guest and host would
    write the same filesystem concurrently and the host would see stale cache.
    """
    def __init__(self, path: Path, logdir: Path):
        self.path = path
        self.mnt = logdir / "rootfs"
        self.mnt.mkdir(parents=True, exist_ok=True)
        # Override when the image layout changes (e.g. an extra boot partition).
        self.part = os.environ.get("SANE_ROOT_PART", "p2")

    def _mount(self):
        loop = run(sudo(["losetup", "--find", "--show", "--partscan", str(self.path)]),
                   check=True).stdout.strip()
        run(sudo(["mount", "-o", "rw", loop + self.part, str(self.mnt)]), check=True)
        return loop

    def _unmount(self, loop):
        run(sudo(["umount", str(self.mnt)]), check=False)
        run(sudo(["losetup", "-d", loop]), check=False)

    def close(self):
        pass

    def refresh(self):
        # Nothing is held mounted between operations; remount is implicit.
        pass

    def _host(self, path):
        return self.mnt / path.lstrip("/")

    def cat(self, path):
        loop = self._mount()
        try:
            return run(sudo(["cat", str(self._host(path))]), check=True).stdout
        finally:
            self._unmount(loop)

    def rm(self, path):
        loop = self._mount()
        try:
            run(sudo(["rm", "-f", str(self._host(path))]), check=False)
        finally:
            self._unmount(loop)

    def write(self, path, content, mode="0644"):
        # mkstemp() in a private 0700 directory: predictable /tmp names let a
        # local attacker pre-plant a symlink and redirect our privileged write.
        loop = self._mount()
        try:
            target = self._host(path)
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="sane-lifecycle-") as d:
                fd, tmpname = tempfile.mkstemp(dir=d)
                try:
                    os.write(fd, content.encode())
                    os.close(fd)
                    run(sudo(["install", "-o", "0", "-g", "0", "-m", mode,
                              tmpname, str(target)]), check=True)
                finally:
                    if os.path.exists(tmpname):
                        os.unlink(tmpname)
        finally:
            self._unmount(loop)

    def exists(self, path):
        loop = self._mount()
        try:
            return self._host(path).exists()
        finally:
            self._unmount(loop)

    def shadow(self):
        return self.cat("/etc/shadow")

    def run_tool(self, args):
        """Run scripts/sane-reliability against the mounted target root."""
        loop = self._mount()
        try:
            tool = REPO_ROOT / "scripts" / "sane-reliability"
            return run(sudo(["sh", str(tool), "--root", str(self.mnt)] + list(args)),
                       check=True).stdout
        finally:
            self._unmount(loop)


class Boot:
    def __init__(self, image: Path, logdir: Path, name: str, timeout=150):
        self.image = image
        self.log = logdir / f"{name}.log"
        self.buf = ""
        self.pos = 0
        self.timeout = timeout
        self.monitor_path = str(self.log.with_suffix(".monitor.sock"))
        if os.path.exists(self.monitor_path):
            os.unlink(self.monitor_path)
        master, slave = pty.openpty()
        self.master = master
        # Match the other QEMU harnesses in this repo (test-image-boot.sh,
        # run-qemu.sh): the default qemu64 CPU is too old for modern
        # toolchains, and a guest that dies before printing anything makes
        # every console-based check fail on an empty buffer.
        accel = (["-enable-kvm", "-cpu", "host"]
                 if os.access("/dev/kvm", os.W_OK) else ["-cpu", "max"])
        self.cmd = ["qemu-system-x86_64", "-M", "q35", "-m", "768", "-smp", "2",
                    "-no-reboot", "-nographic", "-monitor",
                    f"unix:{self.monitor_path},server,nowait",
                    "-drive", f"file={image},format=raw,if=virtio", "-boot", "order=c"] + accel
        self.proc = subprocess.Popen(
            self.cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)
        self._dead_diag_printed = False

    def _print_dead_diag(self):
        """Surface a QEMU startup failure in the CI log, not just the log file."""
        if self._dead_diag_printed:
            return
        self._dead_diag_printed = True
        tail = self.buf[-800:].replace("\r", "\\r").replace("\n", "\\n")
        print(f"[diag] {self.log.name}: QEMU exited rc={self.proc.returncode}; "
              f"cmd={' '.join(self.cmd)}; console tail={tail!r}", flush=True)

    def send(self, line):
        os.write(self.master, (line + "\n").encode())

    def expect(self, pattern, timeout=None):
        """Match against output not yet consumed by a previous expect."""
        rx = re.compile(pattern, re.S)
        deadline = time.monotonic() + (timeout or self.timeout)
        while time.monotonic() < deadline:
            m = rx.search(self.buf, self.pos)
            if m:
                self.pos = m.end()
                return True
            if self.proc.poll() is not None:
                self._print_dead_diag()
                break
            r, _, _ = select.select([self.master], [], [], 0.5)
            if r:
                try:
                    data = os.read(self.master, 65536)
                except OSError:
                    break
                if not data:
                    break
                self.buf += data.decode("utf-8", "replace")
        m = rx.search(self.buf, self.pos)
        if m:
            self.pos = m.end()
            return True
        return False

    def has(self, pattern):
        return bool(re.search(pattern, self.buf, re.S))

    def save(self):
        self.log.write_text(self.buf)
        return str(self.log)

    def stop(self):
        self.save()
        if self.proc.poll() is None:
            # Ask the guest to power down cleanly so ext4 commits its journal.
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(2)
                s.connect(self.monitor_path)
                s.sendall(b"system_powerdown\n")
                s.close()
            except OSError:
                pass
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
        try:
            os.close(self.master)
        except OSError:
            pass
        if os.path.exists(self.monitor_path):
            os.unlink(self.monitor_path)


class Runner:
    def __init__(self, image, logdir):
        self.image = Image(image, logdir)
        self.logdir = logdir
        self.results = []

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail))
        print(f"{'ok  ' if ok else 'FAIL'} - {name}" + (f" [{detail}]" if detail and not ok else ""))
        return bool(ok)

    def _shadow_passwords(self):
        passwords = {}
        for line in self.image.shadow().splitlines():
            fields = line.split(":")
            if len(fields) >= 2:
                passwords[fields[0]] = fields[1]
        return passwords

    def passwords_hashed(self):
        """Both accounts must hold a complete SHA-512 hash, not a bare prefix."""
        passwords = self._shadow_passwords()
        return all(valid_sha512_hash(passwords.get(name, "")) for name in ("root", USER))

    def stop(self, boot):
        boot.stop()
        self.image.refresh()

    def setup(self, boot, *, expect_recovery=False, wrong_first=False):
        if expect_recovery and not boot.expect(r"S\.A\.N\.E account recovery"):
            return False
        if not boot.expect(r"=== S\.A\.N\.E Linux first boot ==="):
            return False
        if wrong_first:
            boot.expect(r"New password for root:")
            boot.send(ROOT_PW + "WRONG")
            boot.expect(r"Retype password for root:")
            boot.send(USER_PW + "WRONG")
            if not boot.expect(r"ERROR: password was rejected|ERROR: passwords do not match"):
                return False
            # The for-loop below consumes the fresh "New password for root:" prompt.
        for user, pw in (("root", ROOT_PW), ("sane", USER_PW)):
            boot.expect(rf"New password for {user}:")
            boot.send(pw)
            boot.expect(rf"Retype password for {user}:")
            boot.send(pw)
            if not boot.expect(rf"Password set for {user}\."):
                return False
        if not boot.expect(r"First-boot setup complete"):
            return False
        # Give ext4 a moment to commit the marker and shadow before we power off.
        time.sleep(8)
        return True

    def login(self, boot, *, wrong=False):
        if not boot.expect(r"login:"):
            return False
        boot.send(USER)
        if not boot.expect(r"Password:"):
            return False
        if wrong:
            boot.send("definitely-wrong")
            if not boot.expect(r"Login incorrect"):
                return False
            return self.login(boot)
        boot.send(USER_PW)
        boot.send("echo LIFECYCLE_LOGIN_OK")
        return boot.expect(r"LIFECYCLE_LOGIN_OK")

    def fresh(self):
        for stale in ("/etc/passwd+", "/etc/shadow+", "/etc/.sane-firstboot-done"):
            if self.image.exists(stale):
                self.image.rm(stale)
        self.image.write("/etc/shadow",
                         "root:!:19700:0:99999:7:::\nsane:!:19700:0:99999:7:::\n",
                         mode="0600")
        self.image.write("/etc/passwd", "root:x:0:0:root:/root:/bin/sh\nsane:x:1000:1000:sane:/home/sane:/bin/sh\n")

    def ensure_setup(self, label="setup"):
        """Make login-only scenarios self-contained: set up first if needed."""
        if (self.image.exists("/etc/.sane-firstboot-done") and
                self.passwords_hashed()):
            return True
        self.fresh()
        b = Boot(self.image.path, self.logdir, label)
        try:
            return self.setup(b)
        finally:
            self.stop(b)

    def scenario_1_no_default_credentials(self):
        self.fresh()
        shadow = self.image.shadow()
        self.check("S1 first boot ships no usable default password",
                   "root:!" in shadow and "sane:!" in shadow)
        self.check("S1 firstboot marker absent", not self.image.exists("/etc/.sane-firstboot-done"))
        b = Boot(self.image.path, self.logdir, "s1-firstboot")
        try:
            ok = self.setup(b)
            self.check("S1 setup completes on first boot", ok)
            self.check("S1 marker written after setup", self.image.exists("/etc/.sane-firstboot-done"),
                       b.save())
            self.check("S1 passwords are hashed after setup", self.passwords_hashed())
        finally:
            self.stop(b)

    def scenario_2_interrupted_setup(self):
        self.fresh()
        b = Boot(self.image.path, self.logdir, "s2-interrupted")
        try:
            interrupted = b.expect(r"New password for root:")
            self.check("S2 setup prompt reached before interruption", interrupted)
            self.stop(b)
        finally:
            if b.proc.poll() is None:
                self.stop(b)
        self.check("S2 no marker after interrupted setup", not self.image.exists("/etc/.sane-firstboot-done"))
        b2 = Boot(self.image.path, self.logdir, "s2-resume")
        try:
            ok = self.setup(b2)
            self.check("S2 setup resumes after interruption", ok, b2.save())
            self.check("S2 marker written after resumed setup", self.image.exists("/etc/.sane-firstboot-done"))
        finally:
            self.stop(b2)

    def scenario_3_reboot_before_setup(self):
        self.fresh()
        b = Boot(self.image.path, self.logdir, "s3-first")
        try:
            reached = b.expect(r"New password for root:")
            b.send(ROOT_PW)
            self.stop(b)
        finally:
            if b.proc.poll() is None:
                self.stop(b)
        self.check("S3 reboot before setup leaves no marker", not self.image.exists("/etc/.sane-firstboot-done"))
        b2 = Boot(self.image.path, self.logdir, "s3-reboot")
        try:
            ok = self.setup(b2)
            self.check("S3 setup restarts cleanly after reboot", ok, b2.save())
        finally:
            self.stop(b2)

    def scenario_4_wrong_password(self):
        self.fresh()
        b = Boot(self.image.path, self.logdir, "s4-setup")
        try:
            ok = self.setup(b, wrong_first=True)
            self.check("S4 weak/mismatched password is rejected and retried", ok, b.save())
        finally:
            self.stop(b)
        b2 = Boot(self.image.path, self.logdir, "s4-login")
        try:
            ok = self.login(b2, wrong=True)
            self.check("S4 bad login is rejected then good login succeeds", ok, b2.save())
        finally:
            self.stop(b2)

    def scenario_5_normal_login(self):
        self.check("S5 setup prerequisite is self-contained",
                   self.ensure_setup("s5-setup"))
        b = Boot(self.image.path, self.logdir, "s5-login")
        try:
            ok = self.login(b)
            self.check("S5 normal login after setup works", ok, b.save())
            self.check("S5 firstboot does not repeat", not b.has(r"=== S\.A\.N\.E Linux first boot ==="))
        finally:
            self.stop(b)

    def scenario_6_repeated_reboots(self):
        self.check("S6 setup prerequisite is self-contained",
                   self.ensure_setup("s6-setup"))
        for i in range(1, 4):
            b = Boot(self.image.path, self.logdir, f"s6-reboot{i}")
            try:
                ok = self.login(b)
                self.check(f"S6 login works on reboot {i}", ok, b.save())
                self.check(f"S6 no setup prompt on reboot {i}",
                           not b.has(r"=== S\.A\.N\.E Linux first boot ==="))
            finally:
                self.stop(b)

    def scenario_7_recovery(self):
        self.fresh()
        b = Boot(self.image.path, self.logdir, "s7-setup")
        try:
            ok = self.setup(b)
            self.check("S7 baseline setup completed", ok)
        finally:
            self.stop(b)
        self.image.write("/etc/shadow", "corrupted\n", mode="0600")
        b2 = Boot(self.image.path, self.logdir, "s7-recovery")
        try:
            ok = self.setup(b2, expect_recovery=True)
            self.check("S7 corrupt account config triggers recovery and re-setup", ok, b2.save())
            self.check("S7 shadow rebuilt with hashes", self.passwords_hashed())
        finally:
            self.stop(b2)


    def scenario_8_reliability_recover_after_reboot(self):
        self.check("S8 setup prerequisite is self-contained",
                   self.ensure_setup("s8-setup"))
        # Prepare an interrupted upgrade: a verified snapshot of the old state,
        # a payload file already changed to the new version, and a journal that
        # still says in-progress. The reliability boot service must roll back.
        self.image.write("/etc/hostname", "S.A.N.E\n")
        self.image.run_tool(["init"])
        self.image.run_tool(["snapshot", "pre-upgrade"])
        self.image.write("/etc/hostname", "INTERRUPTED-UPGRADE\n")
        self.image.write(RELIABILITY_JOURNAL,
                         "state=in-progress\nsnapshot=pre-upgrade\n", mode="0600")
        self.check("S8 interrupted upgrade prepared",
                   self.image.cat("/etc/hostname").strip() == "INTERRUPTED-UPGRADE"
                   and "state=in-progress" in self.image.cat(RELIABILITY_JOURNAL))
        b = Boot(self.image.path, self.logdir, "s8-reboot")
        try:
            ok = self.login(b)
            self.check("S8 boot continues to login after reliability recover", ok, b.save())
        finally:
            self.stop(b)
        self.check("S8 payload file restored to old version",
                   self.image.cat("/etc/hostname").strip() == "S.A.N.E")
        self.check("S8 journal marked recovered",
                   "state=recovered" in self.image.cat(RELIABILITY_JOURNAL))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", type=Path)
    ap.add_argument("--logdir", type=Path, default=Path("/tmp/sane-lifecycle-logs"))
    ap.add_argument("--scenario", action="append", type=int, choices=range(1, 9),
                    help="run only this scenario number (1-8), repeatable")
    args = ap.parse_args()
    args.logdir.mkdir(parents=True, exist_ok=True)
    r = Runner(args.image.resolve(), args.logdir)
    scenarios = {
        1: r.scenario_1_no_default_credentials,
        2: r.scenario_2_interrupted_setup,
        3: r.scenario_3_reboot_before_setup,
        4: r.scenario_4_wrong_password,
        5: r.scenario_5_normal_login,
        6: r.scenario_6_repeated_reboots,
        7: r.scenario_7_recovery,
        8: r.scenario_8_reliability_recover_after_reboot,
    }
    wanted = args.scenario or list(scenarios)
    try:
        for n in wanted:
            print(f"\n=== Scenario {n} ===")
            scenarios[n]()
    finally:
        r.image.close()
    failed = [name for name, ok, _ in r.results if not ok]
    print(f"\nBoot lifecycle: {len(r.results) - len(failed)}/{len(r.results)} checks passed")
    if failed:
        print("Failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
