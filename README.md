# YAFC — Yet Another Fullscreen Camera

A fullscreen camera presentation for Ford SYNC 3 (QNX, ARMv7) that runs **inside the factory
camera process** instead of replacing it. On the developer's 2020 Explorer ST, fullscreen rear
video appeared early, before SYNC finished starting. The 360 view, parking sensors and
view-selection buttons appeared later as the interface loaded. The packaged installer has not
been run on a radio, and behavior on other vehicles is unproven.

> **WARNING: use at your own risk.** YAFC is an unofficial, free hobby project with **no warranty,
> no support and no liability**. It modifies your vehicle's SYNC 3 unit and its camera system, and
> it can fail, "brick" the unit, or show a wrong or missing camera picture. It is for **off-road,
> parked or closed-course experimentation only, not for public roads.** Never rely on it to decide
> whether it is safe to move. Read the full [DISCLAIMER](docs/DISCLAIMER.md) first. If you do
> not agree, do not use it.

**The rear camera is safety-critical.** A failure can obscure or interrupt it. Read
[SAFETY.md](docs/SAFETY.md) and [RECOVERY.md](docs/RECOVERY.md) before a first trial.

**Just want to install it?** The install and uninstall downloads and instructions are in
[EASY-INSTALL.md](docs/EASY-INSTALL.md). The rest of this page is the detail.

## What it does, in one paragraph

The factory launcher puts a writable directory on the camera's library search path, and the
camera binary requires one library from it. YAFC builds that library. Its start-up code decides
whether it is inside the camera — by the shape and content of the running program — and, if it
is, redirects exactly two of that program's Screen calls to its own. It exports no Screen
symbols of its own and it never touches any other process, so every other program that loads the
slot keeps working, and every failed check leaves the factory behaviour alone. The unit's own
library is preserved beside YAFC's under a second name, and the installer makes that copy on the
unit: nothing Ford ships is redistributed here. See
[ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install from source

1. `sh toolchain/build-slot.sh` and `sh toolchain/probe/build-probe.sh` — build the library and
   the loader probe (needs clang, lld, LLVM tools, Python 3, ARM cross GCC and binutils).
2. `sh tools/make-usb.sh <mount-point>` — assemble the stick. It arrives **unarmed**.
3. On the stick, create **one** marker: `RUN-YAFC-REHEARSE` first. It rewrites the current slot
   bytes and checks an HMI image without publishing it or changing settings.
4. Insert the stick. The jailbreak's USB hook runs `SyncMyMod/autoinstall.sh`, which renames the
   marker and runs the installer. Read `yafc-install/install.log`, `DONE` or `FAILED`.
5. When rehearsal passes, `RUN-YAFC-INSTALL` writes and probes the library, then builds and
   publishes the HMI overlay from the unit's own stock files. If the probe fails, it puts the
   original library back. Check the receipt, reboot, and inspect the camera while parked.

Full details, including the exact write order and what each receipt means:
[INSTALL.md](docs/INSTALL.md).

## Undo

- **Fast:** create `/fs/rwdata/yafc/DISABLE` on the unit (or arm `RUN-YAFC-DISABLE`) and
  restart SYNC so the library and popup stand down.
- **HMI only:** arm `RUN-YAFC-REMOVE-HMI`. It deletes the overlay and leaves the library alone.
- **Complete:** arm `RUN-YAFC-REMOVE`. It deletes the overlay before restoring the unit's own
  library if a preserved copy exists. Restart SYNC to reload the stock files.
- **A stuck unit:** a soft reset (hold Power + Seek-Right about ten seconds) restores the boot
  layering. Details in [RECOVERY.md](docs/RECOVERY.md).

## Documentation

| File | What is in it |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | What is verified, what is unproven, and the current component state |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The slot mechanism, the identity checks, the failure counter |
| [docs/CAMERA-PIPELINE.md](docs/CAMERA-PIPELINE.md) | The frame buffer, the windows, the per-view rectangles, the timings |
| [docs/INSTALL.md](docs/INSTALL.md) | Build, stage, install, verify, write order |
| [docs/RECOVERY.md](docs/RECOVERY.md) | Kill switch, removal, soft reset |
| [docs/HMI-PATCH.md](docs/HMI-PATCH.md) | The on-screen edits, as fragments applied to your own files |
| [docs/TESTING.md](docs/TESTING.md) | The host suite, the loader probe, and what only a unit can show |
| [docs/BUILD.md](docs/BUILD.md) | Cross-building and running the tests |
| [docs/SAFETY.md](docs/SAFETY.md) | The safety position, plainly |
| [docs/ROADMAP.md](docs/ROADMAP.md) | What is next |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Dated changes |
| [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) | How to work on this |

## Evidence labels

Every claim in this repository is one of:

- **verified on one radio** — observed on one unit. Not a support claim.
- **host-verified** — checked on a host, not on a radio.
- **UNPROVEN** — no adequate evidence yet.

Host tests do not establish loader behaviour, live video or vehicle safety.

## Requires FMods, which is not included

YAFC runs on a unit with the **FMods jailbreak, USB installer and FMods Tools** already set up
([fmods.net](https://www.fmods.net/)). The FMods USB hook runs this project's
`SyncMyMod/autoinstall.sh`. No fullscreen CarPlay or Android Auto mod is required. Nothing from
FMods is included here. This project is not affiliated with or endorsed by FMods or Ford. See
[NOTICE](NOTICE).

## Scope and licence

MIT. See [LICENSE](LICENSE). It covers only the files in this repository: our own code, with no
Ford binary, no Ford QML and no third-party mod. The installer works on the unit's own files.

## Acknowledgements

Thanks to **Kaz Wolfe** ([github.com/KazWolfe](https://github.com/KazWolfe)) for help with key
parts of the functionality, and for the independent implementation of the child-window geometry
rule this project's window placement follows. Thanks also to **FMods**, the SYNC 3 modding
platform this mod is installed on top of.

No third-party camera mod is included. Ford's binaries and QML stay on their owner's unit.

## How this was written

Most of this project - the code, the tests, the installer and the documentation - was written by
large language models working under the owner's direction, including models from Anthropic,
OpenAI and DeepSeek, and others. The owner chose the goals, ran the checks and decided what to
keep. That is also why the evidence labels above are strict: a model's account of how a system
behaves is not evidence. Read the code and the tests before you trust either, and do not rely on
this mod for safe maneuvering.
