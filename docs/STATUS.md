# Status

Last updated 2026-11-27. Everything here is one of three labels: **verified on one radio**,
**host-verified**, **UNPROVEN**. A label is not upgraded by inference.

## In one line

The packaged installer was run on one 2020 Explorer ST (10-inch portrait): install, uninstall and
reinstall all completed, and the owner saw every front and rear view, the view selector, Zoomed
View, the Hero icon and the "Please wait" cover work after the install. That is **verified on one
radio**. Every other vehicle and firmware, `RUN-YAFC-RECOVER`, the DISABLE kill switch live,
rehearsal on a radio, and the QNX items below stay **UNPROVEN**.

## Component state

| Part | State |
|---|---|
| Slot library `libyafc.so` | **host-verified**: freestanding, defines no Screen symbol, patches only the camera's own two GOT slots after four identity checks, and passes `toolchain/lint-so.sh`. **UNPROVEN** on a radio. |
| Identity checks (program headers, text hash, GOT slots) | **UNPROVEN** on any build but the observed one. |
| Active path (RAM mailbox and geometry before the real post) | Covered by the host suite; **UNPROVEN** live in this edition. |
| Per-view rectangles and presets | **Host-verified** as fragments on stock-like fixtures; the private development build's observations do not establish this edition. |
| `camera.conf` (view, layout and HMI defaults) | Installer seeds it only when absent. **UNPROVEN** on a unit. |
| Failure counter plus `DISABLE` | **host-verified** as code and as a host test. **UNPROVEN**: it has never been made to fire on a unit. |
| Installer, six modes | Host tests cover retained bytes, overlay paths, mount replay, journaling, rollback, and failure receipts. Rehearsal never publishes or initializes config. Recovery restores journaled state. Install is all-or-nothing (exit 8/9/10 leave the slot untouched). **Verified on one radio** (2026-11-27): install, uninstall and reinstall ran to completion on one 2020 Explorer ST, with receipts on the stick. The earlier 2026-11-26 run stopped at the overlay check and its two mount-line defects are fixed. Other firmware is **UNPROVEN**. |
| Ownership model (recorded stock digest, own-slot-only) | Host-verified. Only the one recorded stock digest accepted as unowned. **UNPROVEN** on a unit. |
| Shadowing-overlay refusal | Host-verified as mock mounts. The mock now reproduces the radio's trailing-space mount line and refuses a second mount of an image already on the slot. The inspection runs after the mount stack is reduced, because the radio refuses to mount an image that is already mounted. **UNPROVEN** on a unit. |
| Request-ID receipts | Host-verified: per-request report directory, timestamp key, `.running` marker consumed only on DONE. **Verified on one radio** (2026-11-27): the install, uninstall and reinstall runs each wrote their own `request-<ID>/` receipts. |
| Session/ready handshake (popup/native) | Host-verified: the fragment code reads and writes the session, mailbox and ready files; the native writes session and ready after a post. **Verified on one radio** (2026-11-27): Zoomed View stayed correct after the fix, so the popup kept renewing while Ford's report differed. The ready-file `LEASE_MS` expiry itself was not observed and is **UNPROVEN**. |
| QNX behaviours | DL_DEBUG=libs trace format, dladdr paths, -o before mount order, file-image mount listing, busy layers after restart: **UNPROVEN** on a radio. A second read-only mount of an image already mounted at `/fs/mp` is **verified on one radio to fail** with `Resource busy`; the installer now inspects only unmounted candidates. The radio's `mount` line ends in a trailing space when there is no mode flag: **verified on one radio**. |
| Loader probe | **host-verified** as a build; its own output format is documented from the source. **UNPROVEN** on a unit. |
| HMI fragments and USB image path | Host tests use synthetic stock-like QML, JavaScript stubs and mock image mounts. **Verified on one radio** (2026-11-27): the published overlay built from the radio's own files was in use after the install. Other firmware is **UNPROVEN**. |
| Hero icon artwork | Host tests cover ten original 50x50 RGBA PNGs (day/night, five states), the payload digests, staging into the mock image, read-back and packaged bytes. **Verified on one radio** (2026-11-27): the owner saw the Hero icon on the radio after the install. |
| Live view mailbox and compose band | **host-verified** (parser cases in the host suite). **Verified on one radio** (2026-11-27): the published layout held after the install and the compose band behaved as intended. A record now holds until a newer record replaces it, the session changes, `DISABLE` is set, or the popup writes `compose=0`; `LEASE_MS` only gates the ready file. |
| View selectors, Zoomed View sync, "Please wait..." cover | **Verified on one radio** (2026-11-27): the owner saw every front and rear view, the view selector, Zoomed View and the "Please wait" cover work after the install; front crops were checked by eye only. **UNPROVEN** on any other firmware. |
| `scale_quality` (Screen property 56) | **host-verified**: default 2 when the key is absent, 0 sends nothing, 1 is fastest; applied to the camera window and the second view, and the camera window gets Ford's default back when composition ends or `DISABLE` is set. Seeded `camera.conf` documents it. **UNPROVEN** on a radio. |
| On-screen installer notices | **host-verified**: the dispatcher and the worker each write the popup text and call `utserviceutility`, bounded to 5 seconds, with success, failure, removed, rehearsal, recover, disabled and no-marker messages; a fake `utserviceutility` is used in the tests. **UNPROVEN** whether the text appears on radios other than the one. |
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

- Any run of the public edition on a radio other than the one 2020 Explorer ST, including the USB
  HMI image build and publication there.
- Loader binding of `libyafc.so` inside the camera on the observed build. This is exactly what the
  probe is for.
- Whether the camera keeps post-and-flip through the composed rectangle without a stall, and how
  a stall would look.
- Whether the failure counter fires under a real failing boot.
- The popup view table, Zoomed View controls, cover, selectors and settings rows on any firmware
  but the one observed. The 2026-11-27 radio run covered that one build only.
- Whether a warm-start re-read of `camera.conf` is needed.

## Next steps, in order

1. Rehearse on another unit (`RUN-YAFC-REHEARSE`) and read `install.log`. Rehearsal does not publish HMI changes and has not been run on a radio.
2. Run the probe on a unit to confirm the `DL_DEBUG=libs` trace format, `dladdr` paths, and
   loaded-from resolution.
3. Prove the counter on purpose — a throwaway build that fails, or a temporarily invalid config —
   with the restore known, and confirm `DISABLE` appears and clears.
4. Exercise `RUN-YAFC-RECOVER` on a radio, and the DISABLE kill switch live.
5. Repeat install on other firmware and record the result, including whether the on-screen notice
   text appears.
6. Calibrate the picture: run the `SV_*` values through the config and compare against the observed
   HMI values, one variable at a time, with the vehicle stationary.
7. Only then, record the on-unit results here and update the labels.

## Documentation set

See the table in [../README.md](../README.md). This repository keeps no session log; the git
history and [CHANGELOG.md](CHANGELOG.md) are the record.
