# ROAST REPORT — S.A.N.E Linux

*Date: 2026-11-20 · Branch: `update/reliability-recovery` @ `483b14f` · Working tree: clean*

**Method:** source read (`ninit.c`, `scripts/sane-*`, `scripts/spm`, CI), live execution of the
project's own suites, shellcheck sweep, and hand-built adversarial probes against
`sane-reliability` and `spm` in temp roots. Everything marked EXECUTED below actually ran on
this machine; everything marked CODE-READ is analysis, not observation.

**Limitations:** verification was done inline (no isolated subagent re-verification), and the
QEMU-boot paths were not run here (root+KVM harness). One run never exhausts a repo. Severity
labels are conservative on purpose — this is a roast, not a pissing contest.

---

## The Numbers

| Metric | Value | Verdict |
|---|---|---|
| ninit.c (PID 1, hand-rolled) | 3,139 lines, one file | Ambitious. Dense. Working. |
| Shell tooling | 19,293 lines across `scripts/` | The distro is a shell script with a C kernel in it |
| Own test suites (run here) | reliability 315/0 · accounts 165/0 · network 60/0 · spm 31/0 · `make lint` PASS | Genuinely exercised. Respect. |
| shellcheck diagnostics | 269 across `scripts/` | Zero enforced anywhere |
| `make lint` coverage | English-ness of log strings + `-Wformat=2` | A spellchecker guarding a castle |
| Git payload | 529 tracked files under `packages/`, 49 MB | Your VCS is also your CDN, apparently |

---

## F1 — sane-reliability manufactures snapshots it can never verify (EXECUTED)

**The asymmetry:** `write_manifest` (scripts/sane-reliability:232) lets `sha256sum` escape
weird filenames with a leading backslash (GNU convention), and `do_snapshot` copies
`var/lib/spm` **wholesale, without any name validation** (scripts/sane-reliability:265-268).
But the verifier path runs every name through `valid_rel_path` (scripts/sane-reliability:131),
which rejects backslashes via `*'\'*`. The writer accepts what the verifier rejects.

**Reproduced, start to finish:**

    # root with var/lib/spm/installed/weird/back\slash
    $ sane-reliability --root $R snapshot t1    → SNAPSHOT-OK
    $ sane-reliability --root $R verify t1      → unsafe manifest path: ./var/lib/spm/installed/weird/back\\slash
    $ sane-reliability --root $R rollback t1    → same death

Snapshot created, integrity check and rollback **permanently** dead. The "Phase C reliability
toolkit" poisons its own recovery mechanism, then refuses to use it. The 315-test suite never
tests the writer→verifier roundtrip on a legal-but-weird spm DB name. Fail-closed, yes — it's
a self-DoS, not an exploit. **Severity: low (robustness), but it's the reliability tool
reliably unreliabling itself, which is comedy gold.**

**Reachability, honestly stated:** the sanctioned pipeline filters this — `spm install` dies on
"Invalid characters detected in .META/files" for backslash, and newline names get split by
`tar -tf` line-reading and rejected as non-`./x/` entries. So today this needs a spm DB
populated by other means. Two tools, two name grammars, zero shared tests for the seam.

## F2 — spm and ninit speak different config languages (CODE-READ)

`scripts/spm:639` documents service-snippet options as ":deps=..., :user=..., :group=...":
its validator regex `(:[a-zA-Z0-9_=., -]+)*` happily passes **any** `:key=value`.
`ninit.c:1087-1104` understands exactly: `requires, memory_max, cpu_max, pids_max, timeout,
grace, user, group`. A package shipping `:deps=foo` sails through spm validation, boots, and
ninit prints "unknown option" and **silently drops the dependency constraint** (ninit.c:1183).
No shared grammar, no cross-tool test, no spm-side rejection of unknown keys. The contract
between your package manager and your init system is enforced by a regex that validates
nothing about the other side.

## F3 — ninit: typo your service mode, get `once` (CODE-READ)

`ninit.c:1214-1218`: an unknown mode is a *warning*, then the service defaults to `once`.
Write `respwan` and your daemon runs once and is never respawned — the exact failure mode an
init system exists to prevent, triggered by a typo, discovered hours later when the service
is dead. Meanwhile over-long *names* are hard-rejected fail-closed (ninit.c:1287). So: a
127-char name is fatal, but the lifecycle mode — the thing that decides whether your service
stays alive — fails open. Priorities, people.

## F4 — "Fail-closed" is a claim, not a property: verify-once, copy-blind (CODE-READ)

`sane-reliability` header promises: "a malformed or unverifiable input never modifies the
target." The upgrade flow (scripts/sane-reliability:533-585) verifies the payload manifest
**once** at line 538, then the apply loop (566-581) re-reads `manifest.sha256` from disk and
copies files **without re-hashing anything**. The symlink pre-pass (`check_dest_symlinks`,
line 540) validates a manifest that may no longer be the one the apply loop reads. Between
verify and apply, a same-user writer can swap payload contents or plant an escaping symlink
parent — the copy proceeds through it. Same-user threat model, so this is hardening, not a
vuln (and the lock comment at :750-754 honestly documents the single-user assumption). But
the header sells a property the code doesn't implement: the input is verified *before* use,
never *at* use.

## F5 — The lock that isn't: "read-only" commands that write (CODE-READ)

The dispatcher (scripts/sane-reliability:795-799) runs `init|list|verify|log` lock-free, and
the comment at :700 calls them "the lock-free read-only commands (init/list/verify/log)".
`cmd_init` (121-129) **creates directories, journals, and chmods** — it is not read-only, and
it runs concurrently with any lock-holding mutator, including a mid-upgrade journal
rewriter. Today's writes are idempotent enough that nothing explodes, but the documented
invariant is wrong, and "benign race" is how every future nasty race describes its childhood.
Bonus wart: `cmd_backup` tars the **live lock directory** into the archive; restoring it
copies a stale `pid` over the live lock, so `release_lock`'s pid check no-ops and the lock
dir lingers until the next stale-steal. Self-healing, yes. By design, no.

## F6 — 49 MB of binaries in git, "cryptographic verification" via self-referential hashes (EXECUTED counts, CODE-READ trust model)

`packages/` ships 529 tracked files — `vmlinuz-virt`, `busybox`, `curl`, `doas`, `openssl`,
and ~200 libressl headers — as committed blobs next to `.META/sha256` files. The README
brags spm has "cryptographic verification": what actually ships is SHA-256 of payload files
checked against a hash list **inside the same archive**. That's corruption detection, not
authentication — anyone who can tamper with the payload can rehash. To its credit,
SECURITY.md plainly says cryptographic signature verification is "not yet implemented". The
README and SECURITY.md disagree about the same feature; the truth is in the boring document,
as usual.

## F7 — `make lint` is a moat, not a gate (EXECUTED)

CI's lint step polices (a) that log strings are in English and (b) `-Wformat=2`. Meanwhile a
plain `shellcheck` sweep finds **269 diagnostics**: 221× SC3043 (`local` in `#!/bin/sh` —
yes, including spm, the "POSIX-compliant" package manager, which uses `local` 221 times),
31× SC2015 (`A && B || C` is not if-else — mostly benign here, but nobody checked), 9×
SC2086 unquoted expansions, 5× SC2115 (`rm -rf "$var/"`-class), 10× SC2012 (parsing `ls`).
Zero of this is in CI. A 2,427-line test suite for spm and no shellcheck job — you built a
cathedral of tests and hung a "beware of dog" sign written in Python.

## F8 — Audit history lives in .gitignore'd files and commit-message poetry (EXECUTED)

`.gitignore` burns the paper trail: `LAPORAN-*.md`, `AUDIT-*.md`, `PLAN-*.md` are all
ignored. The surviving record of each audit is the **commit message**, which reads like an
audit report: *"root mode 167/0 measured via sudo. Lead inversion probe: the exact audit
repro is now blocked with full zero-write (45/0). Host resolver sha and builder wiring md5
unchanged; read-only files untouched."* Beautiful. Also unrepeatable — those numbers are
attached to no artifact anyone can re-run. Your audit trail is a git log written by a swarm
with a flair for forensics, and every actual report self-destructs on checkout.

## F9 — What held up under fire (because a roast that never concedes is just noise)

- **The headline P2 fix is real.** I hand-built payloads targeting
  `./var/./lib/sane/reliability/journal` and `./var//lib/sane/reliability/journal` — both
  rejected ("unsafe manifest path"), journal untouched at `state=idle`. Commit `483b14f`
  does what it says.
- **CI is embarrassing for a hobby distro, in a good way:** SHA-pinned actions, gitleaks,
  `-Werror` static check, 12 test suites, actual QEMU boots, recipe-drift checks.
- **The spawn path in ninit is disciplined:** CLOEXEC everywhere including the fallback
  `fcntl` dance, one fork attempt per event-loop pass with monotonic EAGAIN backoff, a
  cgroup-before-exec handshake, explicit control-fd closure in the child (ninit.c:1626-1721).
- **`httpsget.c` (242 lines) verifies hostnames** via `mbedtls_ssl_set_hostname` +
  `ssl_get_verify_result`. Small, and does the thing people skip.
- **SECURITY.md is honest** — explicit scope, explicit out-of-scope, explicit "not yet
  implemented" list. Rare. Annoying to roast. Keep it.

---

## The fixes, smallest first

1. **F1:** make `valid_rel_path` understand (or make `write_manifest` reject) escaped names —
   one grammar for the tool, plus a roundtrip test: snapshot → verify on a DB containing
   backslash/newline names.
2. **F2:** spm's snippet validator should accept exactly ninit's option vocabulary — reject
   `:deps=` and friends at package time with a message naming the ninit-side spelling.
3. **F3:** unknown mode in ninit → reject the entry (you already do this for long names).
4. **F4:** re-hash each payload file inside the apply loop (you're already forking `cp`;
   a `sha256sum` check per file is the same order of cost) or document the single-user
   race in the header instead of claiming fail-closed.
5. **F5:** move `cmd_init`'s writes under the lock, or stop calling init/list/verify/log
   read-only. And exclude `lock/` from `cmd_backup`'s tar list.
6. **F7:** one `shellcheck` step in `ci.yml`. Sixty seconds. 269 findings to start.
7. **F6:** stop calling archive-internal hashes "cryptographic verification" in the README;
   SECURITY.md already tells the truth — copy its homework.

---

## OPINION (as requested, the knife)

S.A.N.E Linux is what happens when someone reads the systemd source tree, gets angry, and
decides anger is a build system. Three thousand lines of hand-rolled PID 1 in one C file. A
package manager in POSIX sh that calls itself "deterministic, offline-first" while using
`local` 221 times in a file claiming POSIX compliance. Test suites with more lines than most
people's *entire project*, all green, watched by a CI rig that boots the actual kernel in
QEMU — and a lint step whose main job is making sure error messages are in English. The
priorities are deranged and I say that with something close to admiration.

Here's the pattern I actually want the developers to feel: **this project's bugs are all
seams**. Inside every tool, the discipline is real — the spawn path is careful, the parser
rejects like a bouncer, the state machine has essays written about it. But between tools?
spm validates a grammar ninit doesn't speak (F2). sane-reliability writes manifests its own
verifier can't read (F1). The README promises crypto the SECURITY.md disowns (F6). The
"fail-closed" banner waves over a verify-once-copy-blind pipeline (F4). Nobody is testing
the borders, because every test lives inside one country. The 315-test reliability suite has
a blind spot exactly the shape of the thing reliability tools are *for*: the day something
weird gets into the state they're protecting.

And the meta-chaos: the audit reports that drove all this hardening are gitignored, so the
commit messages are doing the job of a documentation system, one "Host resolver sha ...
md5 unchanged" at a time. You have swarm-written commit prose with forensic metrics attached
to no artifact. That's not an audit trail; that's a campfire story with checksums.

Is it good? Yes — annoyingly, verifiably good in the places it counts, which is why the
seams sting. It's a serious project cosplaying as a weekend distro, and its biggest
un-patched vulnerability is the gap between what its banners claim and what its borders
enforce. Fix the seams. Then go outside. The kernel will respawn you in 2 seconds with
exponential backoff either way.

*— glm, deployed via hoho, roasted with love and a shellcheck install*

---

# PART II — deepseek

*Same branch, same commit `483b14f`, clean tree, different model and a fresh set of knives.
Part I above stands; nothing here replaces it. Where it overlaps, it sharpens: F5 noticed that
`backup` tars the live lock and called the result "self-healing". Below is the version with a
stopwatch on it.*

**Environment:** Debian 13 host, gcc 14.2.0, no `/dev/kvm` (TCG), uid 1000, passwordless sudo.
**Method:** build, boot in QEMU, run the project's own exit criteria, then adversarial probes
against `sane-reliability`, `sane-accounts`, `spm` and `build-package.sh` in throwaway roots.
Anything labelled EXECUTED has real output pasted below. CODE-READ is analysis.

**Headline:** the suite is genuinely green — `make test` reports **679 passing assertions, 0
failures**, including 315 in the reliability suite, and `make lint` passes. The bugs below all
live where that suite does not look, which is the same seam Part I identified, now with
receipts.

## Scoreboard

| Metric | Value |
|---|---|
| Product surface reviewed | `ninit.c` 3,139 lines · `spm` 1,360 · reliability/account tools 1,558 |
| Test surface | **12,600 lines** of test shell (~2.1 lines of test per product line), 183 `sleep`s |
| Suite result on this box | 679 ok / 0 failed (reliability 315/0) + `make lint` green |
| Tracked files | 612 total · **529 under `packages/`** · 38 committed ELF blobs · 297 headers/objects |
| `.git` | 27 MB |
| `make rootfs` result | boots in TCG, reaches `main loop ready` in 3.97 s — and ships a network service that cannot run |
| Longest commit message | 436 words (1,573 words across the last five) |

---

## X1 — `restore` re-arms the state lock with a corpse's PID, then locks you out (EXECUTED)

`cmd_backup` tars the entire reliability state, including `lock/` and `lock/pid`
(`scripts/sane-reliability:611-612`). `cmd_restore` then `cp -a`s that state over the **live**
state dir (`:681`), overwriting the PID file of the lock the restore process is currently
holding. `release_lock` (`:732-736`) compares the file against `$$`, sees a stranger, and
leaves the lock behind. `heal_snapshot_swaps` doesn't touch locks. The next mutator reads the
archived PID and asks `kill -0` whether it's alive.

If that PID is dead: a one-second steal, self-heals, as Part I said. If it is **alive** — a
recycled PID, a long-lived shell, a root-owned process when you run as root — `kill -0` says
"live holder", and the tool waits out `SANE_RELIABILITY_LOCK_TIMEOUT` and dies:

    $ sane-reliability --root $T restore /tmp/b3.tar.gz   # archive holds a live pid in lock/pid
    lock pid after restore: 843769
    $ time sane-reliability --root $T snapshot blocked
    sane-reliability: timed out waiting for reliability lock: /tmp/reltest3/var/lib/sane/reliability/lock
    real    0m30.930s          rc=1

Every backup the tool itself produces triggers this, because every backup holds the lock it is
about to archive. `doc/reliability.md:100-106` promises a live same-user holder is never
stolen; the archive confuses "holder" with "recording of an old holder". The 1205-line
reliability suite tests lock contention (`scripts/test-reliability.sh:798-827`) and restore
(`:488-587`) in separate rooms and never introduces them.

**Fix (smallest):** exclude `lock` from the tar (`--exclude=lock`), or rewrite `lock/pid` with
`$$` after the copy and before the journal reset. One line either way; add a two-line test that
restores a crafted archive and immediately runs a mutator.

## X2 — `spm` upgrade strips setuid, which bricks `doas`, which fires the recovery service (EXECUTED)

`spm` rejects setuid/setgid archives on purpose (`scripts/spm:788-806`, `:948-955`),
`build-package.sh` strips them from every tarball (`--mode=go=rX,u+rw,a-s`, `:326-331`), and
`packages/doas/build.sh` installs the binary `0755` (`:32`, `:92`, `:112`). The setuid bit is
applied afterwards, by hand, in three different builders (`build-rootfs.sh:442`,
`make-image.sh:424`, `sane-install.sh:442`). The package database therefore records `doas` as a
plain 0755 file while the disk says 4755.

Installing the package again — a repair, a forced reinstall, any future version bump — does
`mv -f` over the live binary (`spm:1063`) and **the setuid bit evaporates**, because the source
file never had one:

    $ spm --root $T install demo-1.0...           # ships 0755
    v1 mode: 755
    $ chmod 4755 $T/usr/bin/demo                  # what every builder does
    setuid applied: 4755
    $ spm --root $T install demo-2.0...           # upgrade
    after upgrade: 755

For `doas` the second act is worse, because `sane-accounts validate` hard-requires 4755
(`scripts/sane-accounts:519-525`):

    $ sane-accounts --root $T --skip-owner-check validate
    FAIL: doas mode 755 (expected 4755 setuid root)          rc=1

At the next boot the `recovery` service (`build-rootfs.sh:435`) sees the failure, runs
`recover`, and — as X6 details — rebuilds `/etc/passwd` and `/etc/group` from the template and
resets `/etc/doas.conf`. Validation still fails, so `sane-account-recovery:57-60` drops an
unauthenticated root shell on the console. A package reinstall ends with a console shell on
every boot and no working escalation tool.

The 2,427-line spm suite asserts that setuid archives are *rejected* (`test-spm.sh:1792-1803`);
not one test asserts that a 4755 file on disk survives an upgrade.

**Fix:** either teach the format to carry mode bits (drop the blanket rejection), or have spm
apply a per-package mode list, or — cheapest — special-case the one setuid file: `chmod 4755`
after install when the package ships `usr/bin/doas`, and assert it in the suite. Then teach
`validate` to report it as a warning instead of tearing the identity files down.

## X3 — `make rootfs` produces a network service that calls a binary it never installs (EXECUTED)

`build-rootfs.sh` writes `network:once:... sane-net dhcp eth0` (`:434`) and installs `ninit`,
`sane-reliability`, the account tools — but not `sane-net` or `sane-ctl`, which live in the
`ninit` package's payload (`packages/ninit/x/usr/bin/`) and are only installed by the *image*
path via spm. The freshly built rootfs:

    $ ls distro/rootfs/usr/bin/
    curl  doas  sane-account-recovery  sane-accounts  sane-firstboot  sane-reliability  wpa_cli  wpa_supplicant
    $ sudo chroot distro/rootfs /bin/sh -c 'command -v sane-net; sane-net dhcp eth0; echo exit=$?'
    sane-net: MISSING from rootfs
    /bin/sh: sane-net: not found
    exit=127

Why nobody notices: `run-qemu.sh` attaches no NIC, so the `if [ -d /sys/class/net/eth0 ]` guard
skips the call; and the modules that *would* create `eth0` are compiled for
`6.6.134-0-virt` while `run-qemu.sh` defaults to the **host** kernel (`uname -r` here:
`6.12.117+deb13-cloud-amd64`), so vermagic refuses them anyway. The kernel package ships
`virtio_net.ko`/`virtio_blk.ko` without `virtio_pci.ko`/`virtio_ring.ko`, so even on a matching
kernel there is nothing for the virtio device to bind to. Three independent reasons the network
in the shipped rootfs is decorative, and the harness is configured to look away from all of
them. `sane-ctl` is missing from the same rootfs, so the emergency console cannot start or
stop anything either.

**Fix:** copy `sane-net` and `sane-ctl` in `install_networking`/`install_ninit` (or build the
rootfs from the ninit package like the image does), add one `run-qemu.sh` scenario with
`-nic user,model=e1000`, modprobe `e1000`, and assert the network service exits 0 *while
actually calling sane-net*.

## X4 — A CRLF `init.conf` disables the whole boot with no diagnostic (EXECUTED)

The config parser strips `\n` but not `\r` (`ninit.c:1045`; same in the fstab reader,
`:2709`), and `trim()` (`:175`) only handles option tokens — so the CR lands inside the command
string. Every service dies with 127, the log names the wrong culprit, and ninit never says
"parse error":

    $ printf 'hello:once:/bin/echo hi\r\nshell:respawn:/bin/sh\r\n' > $R/etc/init.conf
    ...
    ninit: started hello (pid 2)
    [service] sh: /bin/echo: not found
    ninit: hello (pid 2) exit status=0x7f00
    ninit: hello: state RUNNING -> FAILED
    [service] sh: /bin/sh\r: not found
    ninit: shell: crash-loop #1, respawn delay increased to 4 seconds

The panic-friendly parts of the parser (line length, dependency cycles, duplicate names) are
fail-closed; the one thing a user is most likely to introduce with a text editor fails open
into a crash loop. `trim()` already knows how to eat `\r` — it just never sees the command.

**Fix:** `line[strcspn(line, "\r\n")] = 0;` in both readers. Two characters.

## X5 — Documented snapshot tags `.` and `..` are unusable (EXECUTED)

`doc/reliability.md:54-55` documents the tag alphabet as `[A-Za-z0-9._-]`; `valid_tag`
(`scripts/sane-reliability:113-119`) implements exactly that, so `.` and `..` pass. Then
`do_snapshot` builds `$SNAPS/.` and `$SNAPS/..` and tries to `mv` them:

    $ sane-reliability --root $T snapshot .
    sane-reliability: snapshot already exists: .
    $ sane-reliability --root $T snapshot . --force
    mv: cannot move '.../snapshots/.' to '.../snapshots/.old..': Device or resource busy
    sane-reliability: cannot move old snapshot aside
    $ sane-reliability --root $T snapshot .. --force
    same EBUSY

Both always fail. No data damage, but the tag grammar advertises two values the implementation
cannot store. `heal_snapshot_swaps` guards `''|.|..` for the aside names (`:706-708`), which
shows someone thought about the collision — just not in `valid_tag`.

**Fix:** reject `.`/`..` in `valid_tag`, or special-case the target path. One test.

## X6 — `recover` deletes users and policy to fix a permission bit (EXECUTED)

`cmd_recover` (`sane-accounts:549-582`) re-runs `init --force`, which rewrites `passwd`,
`group`, `shadow` and `doas.conf` from the template, then copies back only the two hard-coded
hashes. Any other account, group membership, custom doas rule, or customized `doas.conf` is
gone — triggered by any validation failure, including a `chmod 644 doas.conf`:

    $ sane-accounts --root $T validate
    FAIL: doas.conf mode 644 (expected 600)
    ...
    $ sane-accounts --root $T recover
    recover: preserved usable password hashes        ← true, and misleading
    $ cat $T/etc/passwd
    root:x:0:0:root:/root:/bin/sh
    sane:x:1000:1000:S.A.N.E User:/home/sane:/bin/sh   # alice: gone
    $ cat $T/etc/doas.conf
    permit persist :wheel                             # custom rule: gone

Alice's home stays on disk, orphaned; the next `add-user` recycles uid 1001 and hands her
files to a stranger. The recovery is wired into every boot (`build-rootfs.sh:435`), so an
upgraded-but-unrepaired `doas` (X2) turns this into a recurring event. The success message
reports the narrow thing it preserved, not the wide thing it destroyed.

**Fix:** merge instead of rewrite — restore only the files that fail validation, and preserve
non-baseline passwd/group lines and the existing `doas.conf` when only its mode is wrong.

## X7 — `:group=` alone still runs the service as root (EXECUTED)

`need_drop` is set for either option (`ninit.c:1230`, `:1243`), but `parsed_uid` only comes
from `:user=`; `setresuid(0,0,0)` then "drops" to root. In a namespace:

    who:once:/bin/busybox id:group=nogroup
    [service] uid=0(root) gid=65534(nogroup) groups=65534(nogroup)

README:35 sells "drops privileges cleanly to unprivileged users/**groups**". A service declared
`:group=www-data` is root with a different GID and full read/write everywhere. `setgroups(1,
&gid)` also discards supplementary groups, so `:user=` doesn't get wheel et al. — a documented
gap would be fine; the current sentence implies otherwise.

**Fix:** document "user only" (or require `:user=` whenever `:group=` is present), and say in
the same breath that supplementary groups are dropped.

## X8 — The official builder and the official installer disagree about the format (EXECUTED)

Two grammars, no shared tests (the seam Part I F2 named, one layer lower):

    $ build-package.sh --source ... (symlink x/usr/share/hostname-link -> /etc/hostname)
    ==> SUCCESS: Package created
    $ spm --root $T install ...
    ERROR: Symlink escape attack: absolute target outside allowed system directories: /etc/hostname

    $ build-package.sh --source ... (snippet "respawn:/bin/sh -c 'echo hi'")
    ==> SUCCESS
    $ spm --root $T install ...
    ERROR: Invalid service snippet syntax ... must match '[(<name>):](once|respawn):<cmd> [<args>...]'

`build-package.sh:170-180` allows absolute symlinks to any non-traversing path; `spm:331-343`
whitelists only `/bin /sbin /usr/... /lib /boot /opt` and rejects `/etc`, `/var`, `/home`.
`sane-net` is shipped as `/usr/bin` so the distro's own packages dodge it, but the first
package that wants `/etc` gets a build-time green and an install-time red. Likewise, quoted
arguments are normal in the very `init.conf` the snippets mirror, yet the installer's regex
(`spm:640`) forbids quotes while the builder's audit doesn't.

**Fix:** one validator, called by both, with the union of allowed targets and the real
token grammar; point `build-package.sh` at it instead of its private copy.

## X9 — `make lint`'s format verifier cannot fail for its own subject (EXECUTED)

`verify-format-strings.py` promises compiler-backed checking of `init_log` format specifiers by
injecting `__attribute__((format(printf, 1, 2)))`. It injects with a regex that requires a
*declaration* ending in `;` (`:28-33`), but `ninit.c` only has the definition
(`static void init_log(const char *fmt, ...)` at `:146`, immediately followed by `{`). The
substitution silently no-ops, the compile is clean, and the script prints a green tick. Proof:
change a `%d` to `%s` and ask both the lint and a raw compile:

    $ sane-linux ... (init_log("... (%s)", MAX_LINE) where MAX_LINE is int)
    ✅ Compiler format check passed (-Wformat=2 clean, 0 warnings/errors)
    $ gcc -fsyntax-only -Wall -Wextra -Wformat=2 ninit.c | grep -c format
    0

The code itself is format-clean — adding the attribute for real produces zero warnings — so
this is not a lurking bug, it's a green light wired to nothing. The same script's sibling,
`lint-log-patterns.py`, claims assertions are cross-checked against `ninit.c` (docstring items
3-4) but only greps for Indonesian words; appending `check_in "bogus" "$LOG" "this marker
exists nowhere in ninit"` to `smoke-test.sh` still returns PASSED.

**Fix:** add the prototype (`static void init_log(const char *fmt, ...)
__attribute__((format(printf, 1, 2)));`) to the source and have the script assert the attribute
is present before pretending to verify it; either implement or delete the docstring claims.

## X10 — Dot-prefixed snapshots work but `list` hides them (EXECUTED)

`cmd_list` skips any entry starting with `.` (`sane-reliability:333`) to hide `.tmp.*` and
`.old.*`. A user-chosen `.v1` snapshot is therefore invisible while being fully usable:

    $ sane-reliability --root $T snapshot .hidden   → ok
    $ sane-reliability --root $T list               → TAG CREATED (nothing)
    $ sane-reliability --root $T verify .hidden     → verified: .hidden

**Fix:** skip only `.tmp.*` / `.old.*` / `.journal.*`.

## X11 — `add-user` hits a uid ceiling with a free-looking table (EXECUTED)

`next_id` returns `max(uid)+1` (`sane-accounts:154-157`) and the range check is `<= 65534`
(`:226`). With `nobody` (65534) present — it is in every Debian, and a natural first import —
the next id is 65535 and the tool refuses:

    $ sane-accounts --root $T add-user nobody 65534 --skip-chown   # ok
    $ sane-accounts --root $T add-user bob --skip-chown
    sane-accounts: uid out of range: 65535

Thousands of ids are free; the tool says the well is dry. It's also not just a boundary: the
same monotonic rule skips any gap below the maximum, so imported high-uid service accounts
push every new human above them (and into 65535). `next_id` for groups has the same shape but
no ceiling check at all.

**Fix:** scan upward from 1000 for the first free id instead of `max+1`; drop the 65534 cliff.

## X12 — `make rootfs` cannot ship a correct `doas`, with or without sudo (EXECUTED)

`build-rootfs.sh` only `chown`s when it can (`:258`, `:456`, both `|| true`), and at the very
end chowns the whole `distro/` tree back to `$SUDO_USER` (`:597-599`). Two failure modes, both
of which I ran:

    # plain `make rootfs` (README:69), uid 1000
    1000:1000 4755 distro/rootfs/usr/bin/doas      # setuid to sane (uid 1000), no elevation

    # `sudo make rootfs` — SUDO_USER=admin
    1000:1000  755 distro/rootfs/usr/bin/doas      # chown -R clears the setuid bit entirely

`chown` on a regular file clears `S_ISUID`, so the "safe" sudo path is the worse one: the tool
ships `0755` and `sane-accounts validate` will demand 4755 on first boot. On a host whose uid
isn't 1000, `/etc/shadow` (600), `/root` and `/home/sane` also ship owned by the builder
instead of root, so `sane` can't write its own home. `make_dev_nodes` warns about non-root;
ownership — the part that actually breaks doas — is silent.

**Fix:** `chown -R 0:0` the rootfs *after* the final cleanup (or chown the identity files and
doas explicitly and don't sweep them back), and fail loudly instead of `|| true` when not
root.

## Documentation vs. code

| Claim | Reality |
|---|---|
| README:36 — sane-ctl can `reload` | No `reload` in `sane-ctl`, no `reload` in ninit; usage line omits it too |
| README:74 — "six automated test suites", "the first five" in namespaces | Seven bullets, and `make test` runs **twelve** targets; three need no root at all |
| README:35 — drops privileges to "users/groups" | Group-only stays uid 0 (X7) |
| SECURITY.md:55 — runs "**without** privilege dropping" | Contradicts README and `ninit.c` FEAT-62 entirely |
| doc/package-manager.md:21 — daemons "integrate solely via" `/usr/share/ninit/services/` | Nothing reads that directory; spm validates snippets and no component installs them into `/etc/init.conf` |
| doc/account-security.md:39 — firstboot leans on ninit's 30 s once timeout | Every relevant service is wired `:timeout=0` (`build-rootfs.sh:433-436`) |
| doc/reliability.md:54 — tags accept `.` | `.` and `..` do not work (X5) |
| README.id.md vs README.md | Already diverged (18 vs 21 headings, both carrying the "six suites" line) |

## Design limits worth naming

- **No ptys anywhere.** No `devpts` mount in ninit, `build-rootfs.sh`, `make-image.sh` or the
  installer's initramfs. `vi`, `script`, `screen`, anything that opens `/dev/ptmx`, fails on a
  distro that otherwise boots cleanly. `tty1` works only because it's a real tty.
- **No fsck, no initramfs `rd.` handling, no reload.** `ninit` mounts `/` `remount,rw` and hopes.
  Config changes are reboot-only. 64 services is a compile-time `#define` and a hard cap with a
  warning, not a fail.
- **`/tmp` and `/run` mount exec+suid.** Both tmpfs with flags 0 (`ninit.c:446-447`).
- **Fire-and-forget control channel.** `sane-ctl start`/`restart` write to the FIFO and exit 0
  without reading anything (`sane-ctl:78-87`); a typo'd service name is indistinguishable from
  success. `stop` alone polls. If ninit is dead, the `printf > fifo` blocks forever — no timeout.
- **The package manager cannot express a mode.** X2 is the symptom; the format has no mode
  field at all, which is why three builders hand-chmod the same file and the DB disagrees with
  the disk.
- **No signature, by design.** SHA-256 comes from the archive it describes; Part I F6 has the
  full argument. `build-package.sh` also refuses spaces in names (`[a-zA-Z0-9._/+-]`), setuid,
  hardlinks and special files — a package format that can't ship a pty helper or a device node.
- **`local`, `flock`, `realpath`, `mktemp` in the "POSIX" tool**, and `-D wext` for Wi-Fi
  (`sane-net:257`) on a tree where every modern driver is nl80211. `-D nl80211,wext` and the
  problem is gone.
- **Reports are gitignored** (`.gitignore`: `LAPORAN-*`, `AUDIT-*`, `PLAN-*`) while commit
  messages run to 436 words. Part I F8 called it a campfire story with checksums; both my runs
  landed in untracked `ROAST-REPORT*.md` files, which is its own little demonstration.

## What held up (again, because it matters)

- 679/0 on the suite, `make lint` green, boot to `main loop ready` in 3.97 s on TCG, clean
  shutdown, no panic — the boring parts of an init system all work.
- `ninit`'s spawn path: CLOEXEC on both pipe ends including the `fcntl` fallback, one fork per
  loop pass, monotonic EAGAIN backoff, cgroup-before-exec handshake, control fds closed in the
  child (`ninit.c:1509-1692`). No complaints.
- `sane-reliability`'s symlink containment and manifest validation are real; Part I's F1
  roundtrip is the only hole and it's fail-closed.
- `sane-net`'s DHCP client identity check (comm + `/proc/PID/stat` starttime, re-verified
  before TERM and before KILL) is better than most vendors' init scripts.
- `qemu_lifecycle.py` unmounts between operations instead of holding a loop mount under QEMU,
  which is the mistake everyone makes first.

## Fix list, smallest first

1. `line[strcspn(line, "\r\n")] = 0;` in `parse_config` and `mount_fstab` (X4).
2. `--exclude=lock` on the backup tar, plus a restore-then-mutate test (X1).
3. `chmod 4755` after installing a package that ships `usr/bin/doas`, and assert it (X2).
4. Install `sane-net`/`sane-ctl` in `build-rootfs.sh`; add an e1000 NIC scenario (X3).
5. Reject `.`/`..` in `valid_tag`; skip only `.tmp.*`/`.old.*` in `list` (X5, X10).
6. `recover`: preserve passwd/group lines and the existing `doas.conf` (X6).
7. `add-user`: first-free-id scan from 1000 (X11).
8. One shared snippet/symlink validator for builder + installer (X8).
9. Actually declare `init_log` with `__attribute__((format(printf,1,2)))`; assert it in the lint
   (X9).
10. `chown -R 0:0` the rootfs, and make non-root builds loud (X12).
11. Fix README:74/36/35, SECURITY.md:55, package-manager.md:21 (doc table).
12. One shellcheck job. Part I said 269 findings; they're still there.

---

## OPINION

Part I landed on the right metaphor and I'll extend it: this codebase is a series of very
well-guarded rooms with the doors between them hanging off their hinges. Each tool, read alone,
is disciplined to a degree that is honestly unusual for a hobby distro — the spawn path, the
symlink walks, the DHCP PID identity check. Then `build-package.sh` and `spm` disagree about
what a valid package is, `sane-accounts` and the build system disagree about who owns `doas`,
`backup` and `restore` disagree about whether a lock is state, and the lint and the compiler
disagree about whether `init_log` is a printf function. Nothing here is an exploit. Everything
here is a seam, and seams are where a distro actually dies: not from a stack overflow in the
parser, but from a `chmod` that the package manager has no vocabulary for.

The funniest one is X2, and it is funny because it is *architecturally honest*: a format that
can't express setuid, three builders quietly patching around it with `chmod`, a validator that
screams when the patch is missing, and a boot service whose response to any validation failure
is to delete the users. Follow that chain once and you get a machine that boots to an
unauthenticated root shell because someone upgraded `doas`. Twenty lines of bookkeeping — one
mode field, one `chmod`, one merge in `recover` — turn it into a non-event.

X1 and X3 are the same shape from opposite directions. X1 is the reliability tool corrupting
the state it protects with a copy of its own lock — self-DoS via backup, the one operation you
reach for after a disaster. X3 is a boot service shipped against a binary that isn't in the
image, hidden by a harness that never plugs in a NIC and modules that can't load on the kernel
the harness uses. In both cases the tests are green because they were written by the same
people who wrote the assumption.

And X9 is the one that should annoy the authors most, because they clearly *care* about format
strings — there's a whole Python script with `-Wformat=2 -Werror` in it. It just checks a
function the compiler doesn't know is a printf function, and it will stay green while a `%s`
eats an `int`. A lint that cannot fail is a mood, not a gate.

Would I run it? On a VM, yes, and I'd enjoy it — it boots in four seconds, shuts down cleanly,
and the parts that supervise processes are better than the average systemd unit file. On
hardware I cared about, not until X2 and X6 are fixed, because "package reinstall" should not
be a boot-to-root-shell primitive. On a machine with a serial console and nothing to lose?
Absolutely. That's the correct niche for a 3,000-line PID 1 with a 12,000-line test suite: a
lab, loudly.

The project's own banner is the tell. `=== ninit start (PID 1) v1.2.0 ===` — a version number
in a boot banner is a promise that someone is counting. Count the seams instead. Then close
them, and the banner can stay.

*— deepseek, second pass, same commit, no KVM and no mercy*
