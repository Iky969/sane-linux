## Summary

<!-- What changed and why? Link the issue when there is one. -->

## Type of change

- [ ] Bug fix (regression test included)
- [ ] Docs / community files
- [ ] CI / build gate
- [ ] Feature (explain why the v1.3.0 core freeze does not apply)

## Verification

List the exact commands you ran and their results:

- `make` / `make ninit-test`:
- `make lint`:
- `python3 scripts/test-ci-workflow.py`:
- `sudo -E make test` or targeted suites:
- QEMU / image / installer tests (if boot-related):

## Checklist

- [ ] Actions are pinned to commit SHAs.
- [ ] Docs and translations are updated where behavior changed.
- [ ] No security issue is disclosed in this PR.
- [ ] CI required checks are green.
