# Installing

The installer runs on the unit, under the jailbreak's USB hook. It never runs from a host against
a radio. Everything it needs is on the stick, and it arrives **unarmed**: the stick does nothing
until you create one marker.

Just want a file to put on a USB drive, with no build? Start at
[EASY-INSTALL.md](EASY-INSTALL.md); this page is the detail behind it.

Use is at your own risk, with no warranty, no support and no liability. See [SAFETY.md](SAFETY.md).

## Build

```
sh toolchain/build-slot.sh          # toolchain/bin/libyafc.so
sh toolchain/probe/build-probe.sh   # toolchain/probe/bin/slotprobe
sh tools/make-usb.sh <mount-point>  # the stick
```

`build-slot.sh` refuses a build that would not be safe in the slot (see [BUILD.md](BUILD.md)).
`make-usb.sh` writes a hash list (`yafc-payload/SHA256SUMS`) and refuses to overwrite an armed
stick.
It refuses an older slot binary that lacks the view mailbox. Rebuild before staging the stick.

## The stick layout

```
<stick>/
  SyncMyMod/autoinstall.sh      the dispatcher the USB hook runs
  yafc-install.sh               the installer
  yafc-payload/libyafc.so       the slot library
  yafc-payload/slotprobe        the loader probe
  yafc-payload/camera.conf      the default configuration
  yafc-payload/hmi/*.fragment   the on-screen edits
  yafc-payload/SHA256SUMS
  tools/apply-hmi-fragments.sh
  RUN-YAFC-*                    you create exactly one
```

## The five modes

Create **exactly one** marker at the stick root. The dispatcher refuses if it finds more than one.

| Marker | What it does |
|---|---|
| `RUN-YAFC-REHEARSE` | Writes the current slot bytes through the same path, and builds and verifies the HMI image without publishing it or seeding configuration. Do this first. |
| `RUN-YAFC-INSTALL` | Initializes `camera.conf` if absent, installs and probes the library, then builds and publishes the HMI image. |
| `RUN-YAFC-REMOVE` | Deletes the HMI image, then restores the unit's own library and deletes the preserved copy if present. |
| `RUN-YAFC-REMOVE-HMI` | Deletes the HMI image only. The library is untouched. |
| `RUN-YAFC-DISABLE` | Writes the kill switch. No mount work. |

The design has been used on one 2020 Explorer ST with private tooling. **UNPROVEN:** the
packaged installer, including its HMI image path, has not been run on a radio. Host mocks do
not establish that it works on a unit.

## What the installer does, in order

1. Renames the marker to `<marker>.running`, so a boot mid-install does not re-run it.
2. Reads the stick layout: the payload at the stick root.
3. Refuses if the base device or the recovery scripts do not check out.
4. Unmounts the image layers in the captured `/fs/mp` stack, leaving the base device.
5. On install, copies the staged config to `/fs/rwdata/yafc/camera.conf` only if it is absent.
   An existing configuration and any `DISABLE` marker stay intact.
6. On install, preserves the unit's own library as `libRCN_DiagnosticsOld.so` if needed, writes
   the new library and checks the loader probe. A probe failure restores the stock library.
   Rehearsal writes the current slot bytes instead and does not run the installed-pair probe.
7. With the overlays still unmounted, stages the four stock QML files, applies the complete set
   of fragments, and builds and reads back the image under `/fs/tmpfs/yafc-hmi`. The image
   preserves each path under `fordhmi/qml/`.
8. On install, copies the verified image to a temporary file in `/fs/images` outside the boot
   glob, verifies and syncs that copy, then atomically renames it over
   `/fs/images/overlay_00--yafc.img`. Rehearsal writes nothing to `/fs/images`.
9. Replays and checks the mount list, excluding the YAFC layer if removal deleted it.
   Checks the recovery scripts again before writing the receipt.

An HMI failure before the rename leaves the previous image, if any, untouched. An install that
passed the loader probe but could not publish the HMI reports `FAILED` with `HMI only` and the
specific error: 8 for a missing stock file, 9 for fragment refusal, 10 for image build or read-back,
12 for publication. A later failure reports the step that actually failed; `DONE` is not written.

A fresh image enters the mount list at the next boot. On upgrade, if the old image path was
already mounted, replay mounts the replacement at that path. Reboot to reload the HMI and library.
Another image sorting earlier in the boot `overlay*.img` list can shadow the YAFC files.

## The receipts

- `yafc-install/install.log` - what happened, line by line.
- `yafc-install/DONE` - the mode finished and the checks passed.
- `yafc-install/FAILED` - it stopped; the log says why and what was left in place.

## After the install

Reboot once (Power + Seek-Right). Check the camera with the vehicle stationary. If the picture is
wrong, use `/fs/rwdata/yafc/DISABLE` and restart as described in [RECOVERY.md](RECOVERY.md).

## The on-screen edits

`install` applies the fragments to copies of the unit's own four stock files and publishes the
image. `rehearse` builds the image without publishing. To undo only the HMI, arm
`RUN-YAFC-REMOVE-HMI`; `RUN-YAFC-REMOVE` removes both the library and the HMI. The public
installer and its USB image path are **UNPROVEN on a radio**. See [HMI-PATCH.md](HMI-PATCH.md)
and [RECOVERY.md](RECOVERY.md).
