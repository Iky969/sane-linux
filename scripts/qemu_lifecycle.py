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
import select
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT_PW = "LifecycleRoot2026"
USER_PW = "LifecycleUser2026"
USER = "sane"


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

    def _mount(self):
        loop = run(sudo(["losetup", "--find", "--show", "--partscan", str(self.path)]),
                   check=True).stdout.strip()
        run(sudo(["mount", "-o", "rw", loop + "p2", str(self.mnt)]), check=True)
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
        target = self._host(path)
        tmp = Path("/tmp") / f"lifecycle-{os.getpid()}-{path.replace('/', '_')}"
        tmp.write_text(content)
        loop = self._mount()
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            run(sudo(["install", "-o", "0", "-g", "0", "-m", mode, str(tmp), str(target)]),
                check=True)
        finally:
            self._unmount(loop)
            tmp.unlink(missing_ok=True)

    def exists(self, path):
        loop = self._mount()
        try:
            return self._host(path).exists()
        finally:
            self._unmount(loop)

    def shadow(self):
        return self.cat("/etc/shadow")


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
        self.proc = subprocess.Popen(
            ["qemu-system-x86_64", "-M", "q35", "-m", "768", "-smp", "2",
             "-no-reboot", "-nographic", "-monitor", f"unix:{self.monitor_path},server,nowait",
             "-drive", f"file={image},format=raw,if=virtio", "-boot", "order=c"],
            stdin=slave, stdout=slave, stderr=slave, close_fds=True)
        os.close(slave)

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
            shadow = self.image.shadow()
            self.check("S1 passwords are hashed after setup", "root:$6$" in shadow and "sane:$6$" in shadow)
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
        b = Boot(self.image.path, self.logdir, "s5-login")
        try:
            ok = self.login(b)
            self.check("S5 normal login after setup works", ok, b.save())
            self.check("S5 firstboot does not repeat", not b.has(r"=== S\.A\.N\.E Linux first boot ==="))
        finally:
            self.stop(b)

    def scenario_6_repeated_reboots(self):
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
            shadow = self.image.shadow()
            self.check("S7 shadow rebuilt with hashes", "root:$6$" in shadow and "sane:$6$" in shadow)
        finally:
            self.stop(b2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image", type=Path)
    ap.add_argument("--logdir", type=Path, default=Path("/tmp/sane-lifecycle-logs"))
    ap.add_argument("--scenario", action="append", help="run only this scenario number (1-7)")
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
    }
    wanted = [int(s) for s in args.scenario] if args.scenario else list(scenarios)
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
