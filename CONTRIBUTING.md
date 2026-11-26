# Contributing to S.A.N.E Linux

Thanks for helping. This project is small and deliberately reviewable: `ninit`
is a single C file and the rest is POSIX shell, so changes should stay focused.

## Before you start

- Read [SECURITY.md](SECURITY.md). Never open a public issue for a vulnerability.
- `ninit` and the `spm` engine are **feature-frozen** for the v1.3.0 cycle; bug
  fixes and tests are welcome, new core features are not.
- For a new feature or a design change, open an issue first so we can agree on
  the approach before code is written.

## Development loop

```bash
make                       # static build (-Wall -Werror)
make ninit-test            # isolated test binary
make lint                  # log/format linters + ShellCheck gate
python3 scripts/test-ci-workflow.py
sudo -E make test          # full battery (root required)
```

Use `make rootfs`, `make image` and `make test-lifecycle` when a change touches
boot, installer or image code. See [doc/build-and-test.md](doc/build-and-test.md).

## Commit and PR conventions

- Conventional commits: `fix:`, `feat:`, `docs:`, `ci:`, `test:`, `chore:`.
- One logical change per commit; include a regression test for every fix.
- GitHub Actions are pinned to commit SHAs. If you add an action, pin it too.
- Fill in the PR template, list the commands you ran and their results, and
  keep CI green before requesting review. Do not merge on a red or pending
  required check.

## Reporting bugs

Use the bug report template and include the commit SHA, host distro/kernel,
exact reproduction steps and console logs. Boot failures should include the
serial-console log and QEMU CPU mode (`-cpu max` under TCG).

## Licensing

Your contribution is licensed under the project MIT license. Bundled upstream
components remain under their own licenses; see
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
