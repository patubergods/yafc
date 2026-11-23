# Contributing

Short version: never replace a Ford file, test on a host before anything touches a unit, and give
every persistent write a written undo.

## The rules

1. **Never replace `/apps/SS_RVC` and never write to a read-only image.** The whole design exists
   to avoid it: the library goes into a writable directory the camera already searches.
2. **Never ship a Ford binary or Ford QML.** Fragments contain our own code plus short anchor
   strings; the applier edits the reader's own copy. The installer makes the preserved copy of the
   unit's own library on the unit.
3. **Every persistent write needs a known undo.** The three paths are in
   [RECOVERY.md](RECOVERY.md). If a change adds a fourth, document it in the same commit.
4. **Host tests before a unit step.** `sh toolchain/test/run-host-test.sh`,
   `sh toolchain/probe/test-emulated.sh`, `python3 -I tools/test-install.py`,
   `sh tools/test-apply-hmi-fragments.sh`.
5. **Label every claim.** `verified on one radio`, `host-verified`, `UNPROVEN`. Never upgrade a
   label without the observation behind it.
6. **Keep the interface between the library and the HMI in the configuration file.** One file,
   three consumers ([CAMERA-PIPELINE.md](CAMERA-PIPELINE.md)).
7. One marker at a time, and a fresh yes from the owner of the vehicle before anything runs on it.

## Working on the library

`toolchain/yafc-slot.c` is one source and two builds. The slot build is the supported one. The
constants at the top of the file (load address, text hash, GOT offsets) are build-specific and
each carries the evidence for its value; do not change one without re-deriving it from a copy of
the binary.

Every Screen entry point is resolved at run time and checked. A missing one must skip the feature
that needs it and log why, never abort in a process that is not the camera.

## Style

- ASCII. No emoji. Plain, terse technical English.
- Comments explain the why the code cannot show, in one line where possible.
- A shortcut with a known limit gets a comment saying what the limit is and when to upgrade.
