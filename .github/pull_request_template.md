## Summary

What changes and why, in plain English. One short paragraph.

## Changes

- File or area: what changed.

## Evidence

Exact commands run and their results. Label every claim: **verified on one radio**,
**host-verified** or **UNPROVEN**. Do not upgrade a label without the observation behind it.

```
sh toolchain/test/run-host-test.sh /tmp/ht      # result:
sh tools/test-apply-hmi-fragments.sh            # result:
sh toolchain/probe/test-emulated.sh             # result:
python3 -I tools/test-install.py                # result:
```

## Risk and undo

- What this can break, and whether it touches the camera path.
- How to revert it (the exact command or step).

## Docs

- [ ] `docs/` pages updated (list them):
- [ ] `docs/CHANGELOG.md` entry added
- [ ] `docs/STATUS.md` labels still true
- [ ] No private paths, captures, credentials or personal data

## Not done / follow-ups

What is deliberately left out, and what needs a radio run.
