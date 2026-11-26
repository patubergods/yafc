# Installing

The installer runs on the unit, under the jailbreak's USB hook. It never runs from a host against
a radio. Everything it needs is on the stick, and it arrives **unarmed**: the stick does nothing
until you create one marker.

Just want a file to put on a USB drive, with no build? Start at
[EASY-INSTALL.md](EASY-INSTALL.md); this page is the detail behind it.

## Build

```
sh toolchain/build-slot.sh          # toolchain/bin/libyafc.so
sh toolchain/probe/build-probe.sh   # toolchain/probe/bin/slotprobe
sh tools/make-usb.sh <mount-point>  # the stick
```

`build-slot.sh` refuses a build that would not be safe in the slot (see [BUILD.md](BUILD.md)).
`make-usb.sh` writes a hash list (`yafc-payload/SHA256SUMS`) and refuses to overwrite an armed
stick.

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

## The four modes

Create **exactly one** marker at the stick root. The dispatcher refuses if it finds more than one.

| Marker | What it does |
|---|---|
| `RUN-YAFC-REHEARSE` | Runs the whole install path with the unit's own bytes, so the picture cannot change. Do this first. |
| `RUN-YAFC-INSTALL` | Writes the library and the configuration for real. |
| `RUN-YAFC-REMOVE` | Restores the unit's own library and deletes the preserved copy. |
| `RUN-YAFC-DISABLE` | Writes the kill switch. No mount work. |

## What the installer does, in order

1. Renames the marker to `<marker>.running`, so a boot mid-install does not re-run it.
2. Reads the stick layout: the payload at the stick root.
3. Refuses if the base device or the recovery scripts do not check out.
4. Reduces the writable mount to its base device.
5. On the unit, copies the unit's own library to `libRCN_DiagnosticsOld.so` beside it - once, if it
   is not there already.
6. Writes the new library or the configuration.
7. Restores the mount.
8. Runs the loader probe and checks the result. **If it fails, it puts the unit's own library back
   before the marker is consumed.**
9. Re-checks the recovery scripts against their recorded hashes.
10. Writes the receipt.

## The receipts

- `yafc-install/install.log` - what happened, line by line.
- `yafc-install/DONE` - the mode finished and the checks passed.
- `yafc-install/FAILED` - it stopped; the log says why and what was left in place.

## After the install

Reboot once (Power + Seek-Right). Watch the camera from the moment it starts - the composed
picture should be there before the main interface is ready. If it is not, the kill switch is
`/fs/rwdata/yafc/DISABLE` ([RECOVERY.md](RECOVERY.md)).

## The on-screen edits

The install writes the library and the configuration. The HMI fragments are applied separately,
to a copy of the reader's own files, with `tools/apply-hmi-fragments.sh`
([HMI-PATCH.md](HMI-PATCH.md)).
