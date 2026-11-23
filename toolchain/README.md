# YAFC toolchain

Builds `libyafc.so`, the library that takes the slot in the camera process's link path and
composes the fullscreen camera view inside that process. Cross-built for the ARMv7 radio;
freestanding, with no QNX headers and no vendor files in this repository.

The rear camera is safety-critical. A failure can obscure or interrupt its image. Do not rely
on a modified image for safety. Read [../docs/SAFETY.md](../docs/SAFETY.md) and
[../docs/RECOVERY.md](../docs/RECOVERY.md) before any trial.

## Build

Requires clang, lld, LLVM tools (`llvm-strip`), Python 3, the ARM cross GCC and binutils. Run
from this directory:

```sh
OUT=/tmp/yafc-build sh build-slot.sh            # the supported build
OUT=/tmp/yafc-build sh build-slot.sh --log-only # logs and gates only; writes no Screen slot
```

`OUT` (default `$HOME/yafc-build`) holds intermediates. The result, `libyafc.so`, and its
SHA-1 list land in `bin/`. The link uses a stub `libc.so.3` and a stub for the preserved
library; both are generated here and carry symbol names only. The radio's real libraries bind
at load time. `fix-bindnow.py` converts the eager-binding tag to the form this loader accepts.
`lint-so.sh` checks the ELF structure, imports and exports.

The build deliberately does **not** produce the preserved copy of the radio's own library and
does not require one. That copy is made on the unit by the installer, from the radio's own
file, so no vendor binary is redistributed. See [../docs/INSTALL.md](../docs/INSTALL.md).

## What the library does

It defines no `screen_*` symbols. Its constructor runs in every process that loads the slot and
does nothing in all of them except the camera: identity is checked from the main executable's
load layout and a hash of its text, then a kill-switch file, then a failure counter, and only
then are the process's own two Screen call slots required to still hold the real library's
addresses before being overwritten. Any mismatch, and every error path, leaves stock behaviour.
Posts then place the camera band and maintain a child window that shares the camera buffer for
the second view. See [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the mechanism and
[../docs/CAMERA-PIPELINE.md](../docs/CAMERA-PIPELINE.md) for the geometry.

The `--log-only` build does all of the checks and logging and never writes a call slot. It is
the safe first trial on a new unit.

## Host test

```sh
sh test/run-host-test.sh /tmp/yafc-host-test
```

Compiles the real source twice (the slot build and the LD_PRELOAD build) against fake Screen
functions that record every call, then drives the real hooks. **Host-verified**: both builds
report `ALL PASS (0 failures)` — 76 recorded checks in the interposer build and 120 in the slot
build, 196 in total — covering call sequencing, the config contract, every refusal path, the
kill switch, the failure counter, the two-thread race, mode switches and the child window's
hide/show lifecycle. Set `SS_RVC_STOCK` to a copy of the camera binary to additionally check
the recorded text hash; without it those checks are skipped and the run says so.

The host test cannot show that the QNX loader accepts the result, that the picture is right, or
anything about a vehicle. Those are **UNPROVEN** here.

## Loader probe (`probe/`)

A separate set of artifacts for measuring loader behaviour on a unit without touching the
camera: `slotprobe` prints where each of its own Screen and diagnostics calls resolved, and the
three small libraries beside it are the controls. Build with
`sh probe/build-probe.sh` (needs the same toolchain); `probe/SHA256SUMS` covers the results.
Run it per [../docs/TESTING.md](../docs/TESTING.md). It is a native binary, so ask before
running it, and it needs no camera stop.

## Evidence labels

- **verified on one radio**: observed on one unit; not a support claim.
- **host-verified**: checked on a host, not on the radio.
- **UNPROVEN**: no adequate evidence yet.

**UNPROVEN across this directory**: whether the loader on any given unit accepts the library
and its preserved dependency; whether the composed picture appears or survives a view change on
a unit; whether a failure counter ever trips in practice; and every timing claim.

## Acknowledgements

The child-window geometry rule used by `bay_apply_geometry()` comes from Kaz Wolfe's
independent implementation, <https://github.com/KazWolfe> — thanks for the help with key parts
of this. See [../README.md](../README.md) for the full acknowledgement.
