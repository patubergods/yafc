# Testing

Two levels: what a host can prove, and what only a unit can. The gap between them is real and this
repository does not paper over it.

## On a host

| Command | What it proves |
|---|---|
| `sh toolchain/test/run-host-test.sh` | the hook's logic in **both** builds: the LD_PRELOAD interposer and the slot build. Set `SS_RVC_STOCK` to a copy of the camera binary to also check the recorded text hash against a real file (without it that check is skipped and says so). |
| `sh toolchain/probe/test-emulated.sh` | the probe against an emulated loader: the GOT chain resolves, and the read-only variant refuses to write. |
| `python3 -I tools/test-install.py` | all five modes, mounted-image refusal, exact stack replay, slot rollback, config seeding, publication and deletion failures, build cleanup, marker dispatch, and the stale-binary packaging guard. Runs fragment JavaScript against fake QML services using Node.js. |
| `sh tools/test-apply-hmi-fragments.sh` | the HMI applier: idempotent, and it refuses a source that does not match the anchors. |
| `sh tools/test-make-release.sh` | the release assembly, with a stub payload so no cross toolchain is needed: only install and uninstall zips, one correct marker each, the stick layout at the zip root, no `.running` or private tokens, warning and evidence wording in `START-HERE.txt`, and `SHA256SUMS` that verify and match across two runs. |

Run them in WSL Ubuntu from the repository root. The installer suite needs `dash`, `openssl`,
`tar`, Node.js and Python 3. If WSL has no `node`, the suite uses Windows `node.exe` on PATH.
Its mock mounts expose actual staged file contents; they do not
establish QNX mount behavior, Ford QML rendering, live video or vehicle safety.

## The loader probe

The probe answers one question that no host test can: **does the loader bind our library inside
the camera, and does the camera really require it?**

It is a small `ET_EXEC` placed in the slot for the duration of a check. It runs on the unit, opens
the real libraries, and prints what it found:

- one line per hook point, with the file name each import actually resolved to and a `same=yes`
  when the resolution is the one expected;
- a `loaded from:` line on the standard error naming the file the loader bound for the slot.

The shipped probe cap is **one PID and one dlopen**. Read its output as: the `loaded from:` line
tells you which file won the slot, and the `slot ... fname=... same=yes` lines tell you what the
camera's own imports resolve to. If the `loaded from:` line names our file but no `slot` line
follows, the library was bound but its start-up code stood down - and it will have said why in
`/fs/rwdata/yafc/post.log`.

## The counter drill

The failure counter is the one part whose failure mode is silent, so prove it on purpose:

1. Build the library with `OUT=~/yafc-log sh toolchain/build-slot.sh --log-only`.
2. Install it (the log-only build never patches the GOT, so the picture cannot change).
3. Start the camera three times in a row, each time bringing it up and taking it down so no run
   reaches 60 good posts.
4. On the third start, `/fs/rwdata/yafc/DISABLE` must appear and `post.log` must say
   `slot refused: strikes`.
5. `rm /fs/rwdata/yafc/DISABLE` re-arms it.

If `DISABLE` does not appear, the counter does not work and no persistent install should rely on
it. Record the result either way.

## The ladder

| Rung | What runs | What it can prove |
|---|---|---|
| Host suite | the tables above | logic, arithmetic, write order, refusals |
| Probe on the unit | `slotprobe` in the slot | the loader binds us, and what it binds |
| Rehearsal | `RUN-YAFC-REHEARSE` | re-writes the current slot bytes and builds and reads back the HMI image without publishing; **UNPROVEN** on a unit |
| Real install | `RUN-YAFC-INSTALL` | the library and USB HMI image on that unit - **UNPROVEN** until run on a unit |

## Only a unit can show

- whether the composed picture is right, on that vehicle, in that view;
- whether the camera keeps posting without a stall through a mode switch;
- the real HMI values for 360, Zoomed View and ship-config shapes;
- whether the counter fires under a real failing boot.

## See also

[STATUS.md](STATUS.md) - the current state of each of these.
