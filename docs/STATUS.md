# Status

Last updated 2026-11-25. Everything here is one of three labels: **verified on one radio**,
**host-verified**, **UNPROVEN**. A label is not upgraded by inference.

## In one line

The design has been used only on a 2020 Explorer ST with private tooling. Host tests cover the
packaged installer and HMI contracts, but this installer has **not been run on a radio**.

## Component state

| Part | State |
|---|---|
| Slot library `libyafc.so` | **host-verified**: freestanding, defines no Screen symbol, patches only the camera's own two GOT slots after four identity checks, and passes `toolchain/lint-so.sh`. **UNPROVEN** on a radio. |
| Identity checks (program headers, text hash, GOT slots) | **UNPROVEN** on any build but the observed one. |
| Active path (RAM mailbox and geometry before the real post) | Covered by the host suite; **UNPROVEN** live in this edition. |
| Per-view rectangles and presets | **Host-verified** as fragments on stock-like fixtures; the private development build's observations do not establish this edition. |
| `camera.conf` (view, layout and HMI defaults) | Installer seeds it only when absent. **UNPROVEN** on a unit. |
| Failure counter plus `DISABLE` | **host-verified** as code and as a host test. **UNPROVEN**: it has never been made to fire on a unit. |
| Installer, five modes | Host tests cover retained bytes, overlay paths, mount replay and failure receipts. Rehearsal never publishes or initializes config. **UNPROVEN** on a unit. |
| Loader probe | **host-verified** as a build; its own output format is documented from the source. **UNPROVEN** on a unit. |
| HMI fragments and USB image path | Host tests use synthetic stock-like QML, JavaScript stubs and mock image mounts. The public fragments and image recipe are **UNPROVEN** on a radio. |
| Live view mailbox and compose band | **host-verified** (parser cases in the host suite). **Verified on one radio** in the private development build, not in this edition. |
| View selectors, Zoomed View sync, "Please wait..." cover | **host-verified** as fragments on stock-like fixtures. **Verified on one radio** in the private development build (rear selector, Zoomed View, front selector, cover); front crops were checked by eye only. **UNPROVEN** in this edition and on any other firmware. |
| Boot hook | **removed**. It was dropped when the design moved to the slot library; there is nothing to install at boot. |

## What is verified on one radio

- `/apps` is read-only; `/fs/mp/apps/usr/lib` is writable and on the camera's library path.
- The camera requires `libRCN_DiagnosticsLib.so` from that directory.
- The camera owns the Screen window named `RVC_app`; one observed portrait configuration used a
  `720 x 1900` UYVY buffer, a `720 x 480` viewport and an `800 x 480` destination at `(0, 71)`,
  rotation 90.
- The HMI sits above the camera window, with a transparent opening.
- An ordinary external helper cannot set properties on the camera's window.
- Fullscreen rear video appeared early, before SYNC finished starting. The 360 view, parking
  sensors and view-selection buttons appeared later, as the interface loaded.

These are one unit's observations, not a specification.

## What is not established

- Any run of the public edition on a radio, including USB HMI image build and publication.
- Loader binding of `libyafc.so` inside the camera on the observed build. This is exactly what the
  probe is for.
- Whether the camera keeps post-and-flip through the composed rectangle without a stall, and how
  a stall would look.
- Whether the failure counter fires under a real failing boot.
- The current popup view table, Zoomed View controls, cover, selectors and settings rows in the
  public fragments. Private-build observations do not establish the public edition.
- Whether a warm-start re-read of `camera.conf` is needed.

## Next steps, in order

1. Build the stick, rehearse (`RUN-YAFC-REHEARSE`), and read `install.log`. Rehearsal does not publish HMI changes.
2. Prove the counter on purpose - a throwaway build that fails, or a temporarily invalid config -
   with the restore known, and confirm `DISABLE` appears and clears.
3. `RUN-YAFC-INSTALL`, reboot, and watch the camera. One dry run first.
4. Calibrate the picture: run the `SV_*` values through the config and compare against the observed
   HMI values, one variable at a time, with the vehicle stationary.
5. Only then, record the on-unit results here and update the labels.

## Documentation set

See the table in [../README.md](../README.md). This repository keeps no session log; the git
history and [CHANGELOG.md](CHANGELOG.md) are the record.
