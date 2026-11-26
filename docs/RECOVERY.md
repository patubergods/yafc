# Recovery

Three undo paths, from fastest to most complete. You do not need the first one to be finished
before you use the second.

Use is at your own risk, with no warranty, no support and no liability. See [SAFETY.md](SAFETY.md).

## 1. The kill switch - the picture only

Create an empty file on the unit:

```
touch /fs/rwdata/yafc/DISABLE
```

Or arm `RUN-YAFC-DISABLE` on the stick. Restart the unit so the native library evaluates the marker
and the HMI starts with its stock layout and controls. The slot file and the HMI image remain
installed. To re-arm the mod, remove the marker and restart again:

```
rm /fs/rwdata/yafc/DISABLE
```

Writing the marker needs no mount work. The library checks it when the camera process starts,
not on every frame. Do not count on closing and reopening the popup to restart that process.

## 2. Removal - the file

Arm `RUN-YAFC-REMOVE` on the stick and insert it. The installer deletes the HMI image
`/fs/images/overlay_00--yafc.img`, then restores the unit's own library from the preserved copy and
deletes that copy. If the image cannot be removed, the library and preserved copy are left alone.
If no preserved copy exists, the installer cannot restore the library and leaves the slot alone.

To undo only the on-screen edits, arm `RUN-YAFC-REMOVE-HMI`. It deletes the HMI image and its
legacy `.old` backup, then leaves the library alone. It replays the surviving mount layers only.
If deletion fails and the live image remains, the installer includes it when replaying the stack.

The manual fallback is a shell: delete `/fs/images/overlay_00--yafc.img` and its `.old` backup, then
soft reset. An image that is in use may report `Resource busy`; the stick path is intended to remove
it while the mount stack is popped. **UNPROVEN:** both paths on a unit.

## 3. A soft reset - the layering

Hold **Power + Seek-Right** for about ten seconds. The unit restarts and the boot layering is
restored. Use this when a mount step was interrupted, when an install aborted part-way, or when
the unit is not behaving. Nothing about YAFC survives a soft reset that you did not write to disk.

## What each path leaves behind

| Path | Library in the slot | Preserved copy | HMI image | Config | Needs a reboot |
|---|---|---|---|---|---|
| DISABLE | still there; inactive after restart | still there | still there | still there | yes |
| REMOVE | the unit's own, if preserved | deleted | deleted | still there | yes, to reload the stock files |
| REMOVE-HMI | unchanged | unchanged | deleted | still there | yes, to reload the stock HMI |
| Soft reset | unchanged | unchanged | unchanged | unchanged | yes |

## If a mount step was interrupted

The installer checks the exact mount list on exit. If a layer refuses to unmount after earlier
layers were popped, the system may not let the installer restore their original order without
forcing the busy layer off. It reports `FAILED` instead of forcing an unmount or claiming success.
Use a soft reset to restore the boot order.

## If the unit will not boot

The unit's own library is preserved in the slot directory as `libRCN_DiagnosticsOld.so`. It can be
copied back over `libRCN_DiagnosticsLib.so` from a shell, or the kill switch can be written
directly. A soft reset is the last resort and works without any of this.

## The one rule

Never leave the module active without a written undo. Every persistent write in this repository
has one, and it is one of these three paths.
