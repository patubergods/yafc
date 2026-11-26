# Status

Last updated 2026-11-25. Everything here is one of three labels: **verified on one radio**,
**host-verified**, **UNPROVEN**. A label is not upgraded by inference.

## In one line

The mechanism is settled and the host suite is green; the public edition has **never been run on a
radio**. The next evidence step is a deliberate check that the failure counter fires, then a
rehearsal, then a real install.

## Component state

| Part | State |
|---|---|
| Slot library `libyafc.so` | **host-verified**: freestanding, defines no Screen symbol, patches only the camera's own two GOT slots after four identity checks, and passes `toolchain/lint-so.sh`. **UNPROVEN** on a radio. |
| Identity checks (program headers, text hash, GOT slots) | **UNPROVEN** on any build but the observed one. |
| Active path (real post first, then geometry and visibility) | **host-verified** in the config pass-through and the window placement; **UNPROVEN** live. |
| Per-view rectangles and presets | **host-verified**. **UNPROVEN** for the 360 and Trailer views, which have not been observed on a radio. |
| `camera.conf` (View rules, layout, window defaults) | **host-verified**: written by the installer and by the config fragment; read once per RVC window. **UNPROVEN** warm. |
| Failure counter plus `DISABLE` | **host-verified** as code and as a host test. **UNPROVEN**: it has never been made to fire on a unit. |
| Installer, four modes | **host-verified**: every mode and every refusal, plus a rehearsal that writes the unit's own bytes through the real path (`yafc/tools/test-install.py`, all assertions pass). **UNPROVEN** on a unit. |
| Loader probe | **host-verified** as a build; its own output format is documented from the source. **UNPROVEN** on a unit. |
| HMI fragments | **host-verified**: the applier is idempotent and refuses a stale source. **UNPROVEN** on a radio composition. |
| Live view mailbox and compose band | **host-verified** (parser cases in the host suite). **Verified on one radio** in the private development build, not in this edition. |
| View selectors, Trailer zoom sync, "Please wait..." cover | **host-verified** as fragments on stock-like fixtures. **Verified on one radio** in the private development build (rear selector, Trailer, front selector, cover); front crops were checked by eye only. **UNPROVEN** in this edition and on any other firmware. |
| Boot hook | **removed**. It was dropped when the design moved to the slot library; there is nothing to install at boot. |

## What is verified on one radio

- `/apps` is read-only; `/fs/mp/apps/usr/lib` is writable and on the camera's library path.
- The camera requires `libRCN_DiagnosticsLib.so` from that directory.
- The camera owns the Screen window named `RVC_app`; one observed portrait configuration used a
  `720 x 1900` UYVY buffer, a `720 x 480` viewport and an `800 x 480` destination at `(0, 71)`,
  rotation 90.
- The HMI sits above the camera window, with a transparent opening.
- An ordinary external helper cannot set properties on the camera's window.

These are one unit's observations, not a specification.

## What is not established

- Any run of the public edition on a radio.
- Loader binding of `libyafc.so` inside the camera on the observed build. This is exactly what the
  probe is for.
- Whether the camera keeps post-and-flip through the composed rectangle without a stall, and how
  a stall would look.
- Whether the failure counter fires under a real failing boot.
- The HMI values for 360, Trailer and ship-config shapes - a config fragment ships, but nothing
  has exercised it.
- Whether a warm-start re-read of `camera.conf` is needed.

## Next steps, in order

1. Build the stick, rehearse (`RUN-YAFC-REHEARSE`), read `install.log`. **No picture change.**
2. Prove the counter on purpose - a throwaway build that fails, or a temporarily invalid config -
   with the restore known, and confirm `DISABLE` appears and clears.
3. `RUN-YAFC-INSTALL`, reboot, and watch the camera. One dry run first.
4. Calibrate the picture: run the `SV_*` values through the config and compare against the observed
   HMI values, one variable at a time, on a short car trip.
5. Only then, record the on-unit results here and update the labels.

## Documentation set

See the table in [../README.md](../README.md). This repository keeps no session log; the git
history and [CHANGELOG.md](CHANGELOG.md) are the record.
