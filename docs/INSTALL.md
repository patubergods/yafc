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

## The six modes

Create **exactly one** marker at the stick root. The dispatcher refuses if it finds more than one.

| Marker | What it does |
|---|---|
| `RUN-YAFC-REHEARSE` | Writes the current slot bytes through the same path, and builds and verifies the HMI image without publishing it or seeding configuration. Do this first. |
| `RUN-YAFC-INSTALL` | Initializes `camera.conf` if absent, installs and probes the library, then builds and publishes the HMI image. |
| `RUN-YAFC-REMOVE` | Deletes the HMI image, then restores the unit's own library and deletes the preserved copy if present. |
| `RUN-YAFC-REMOVE-HMI` | Deletes the HMI image only. The library is untouched. |
| `RUN-YAFC-RECOVER` | Restores the journaled previous state from an interrupted install or remove. Refuses when the journal does not authenticate, a file is not at its recorded digest, or a layer is busy. The marker must be on a fresh stick (the `.running` file from the failed request is on the old stick, which does nothing). |
| `RUN-YAFC-DISABLE` | Writes the kill switch. No mount work. |

The design has been used on one 2020 Explorer ST with private tooling. **UNPROVEN:** the
packaged installer, including its HMI image path, has not been run on a radio. Host mocks do
not establish that it works on a unit.

**UNPROVEN:** the following QNX behaviours on a radio:
- the `DL_DEBUG=libs` loader trace format used by the probe;
- `dladdr` returning the expected paths for GOT symbols;
- the `-o before` mount flag arranging image layers in the expected order;
- the file-image mount listing (`mount` output for loopback-backed images);
- the second read-only inspection mount of the built image;
- busy layers after a restart, when the installer replays the mount list.

### The unowned-stock digest limit

Only the one recorded stock build of `libRCN_DiagnosticsLib.so` is accepted as an unowned slot
(digest `af2278a253732f8f641c06c5279c3bbff48e0acdf439a11c36ddf6e440e62481`). An existing
preserved copy is never adopted. Other firmware or units are refused until their stock digest is
independently verified and added here. This is one radio's build.

### Shadowing-overlay refusal

Before any write, the installer inspects every other `overlay*.img` file under `/fs/images`.
Each is mounted read-only for the duration of the check. If any provides or obscures
one of the four QML target files, the slot library path, or the preserved-copy path, the
installer refuses. An overlay that shadows a YAFC target cannot be installed beside it.
The inspection mount is read-only and is unmounted before any write begins.

### Request-ID receipts

The dispatcher writes a unique request ID (timestamp format) into the `.running` marker before
starting the installer. Every receipt is per-request: the report directory is
`yafc-install/request-<id>/`, with its own `install.log`, `DONE` and `FAILED`. Every receipt
line includes the request ID, the mode, and the stage it was written at. An old receipt from a
different request never passes for the current one. The marker is consumed (deleted) only after
`DONE` is written; a failed stick keeps its `.running` file and does nothing on reinsertion.

### The session/ready handshake

The camera library writes `/fs/tmpfs/yafc-session` (`PID.monotonic_sec.monotonic_nsec;`) at
start. The HMI popup reads that session on entry and prefixes every mailbox record to
`/fs/tmpfs/yafc-view` with it: `<session><seq>;<compose>;<16 rects>`. The library echoes the
accepted record in `/fs/tmpfs/yafc-ready` after a successful Screen post with verified
geometry. The popup composes its layout only after two advancing ready replies.

A ready file proves that `screen_post_window` returned success and the compositor accepted the
geometry properties. It does **not** prove that the display painted the result, that a late-created
bay ever appeared, or that the HMI render thread is not stalled. A QML timer stall is not
detected by the native. The library's lease expires locally after `LEASE_MS` with no atomic
cross-process liveness proof. `DISABLE` prevents new requests but does not kill an active lease.

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

Install is all-or-nothing. The slot library is written and probed only after the journal is
persisted and before the image is published. A failure before the slot write (exit 8 for a missing
stock file, 9 for fragment refusal, 10 for image build or read-back) leaves the slot untouched.
A failure after the slot write causes a rollback to the journaled previous library bytes, or
retains the journal for `RUN-YAFC-RECOVER` if the rollback cannot be verified. Exit 12 means the
image could not be published after a successful probe; the slot is rolled back. There is no
"library installed but HMI not published" state. `DONE` is never written after a failure.

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
