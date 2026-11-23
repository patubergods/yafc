# Recovery

Three undo paths, from fastest to most complete. You do not need the first one to be finished
before you use the second.

## 1. The kill switch - the picture only

Create an empty file on the unit:

```
touch /fs/rwdata/yafc/DISABLE
```

or arm `RUN-YAFC-DISABLE` on the stick. The library stops acting on the next camera start and the
factory picture returns. The slot file stays where it is - the library is still loaded, it just
does nothing. To re-arm it:

```
rm /fs/rwdata/yafc/DISABLE
```

This path needs no reboot and no mount work. It is the one to use when the picture is wrong and
you want it back now.

## 2. Removal - the file

Arm `RUN-YAFC-REMOVE` on the stick and insert it. The installer restores the unit's own library
from the preserved copy and deletes that copy. The slot goes back to what the unit shipped with.
It refuses if the recovery scripts do not match their recorded hashes.

## 3. A soft reset - the layering

Hold **Power + Seek-Right** for about ten seconds. The unit restarts and the boot layering is
restored. Use this when a mount step was interrupted, when an install aborted part-way, or when
the unit is not behaving. Nothing about YAFC survives a soft reset that you did not write to disk.

## What each path leaves behind

| Path | Library in the slot | Preserved copy | Config | Needs a reboot |
|---|---|---|---|---|
| DISABLE | still there, inactive | still there | still there | no (next camera start) |
| REMOVE | the unit's own | deleted | still there | no |
| Soft reset | unchanged | unchanged | unchanged | yes |

## If a mount step was interrupted

The installer reduces the writable mount to its base device, writes, and restores the mount. If it
aborts during the reduction, the layer order can be left reversed. The installer says so in its
log rather than claiming success, and a soft reset restores the boot order.

## If the unit will not boot

The unit's own library is preserved in the slot directory as `libRCN_DiagnosticsOld.so`. It can be
copied back over `libRCN_DiagnosticsLib.so` from a shell, or the kill switch can be written
directly. A soft reset is the last resort and works without any of this.

## The one rule

Never leave the module active without a written undo. Every persistent write in this repository
has one, and it is one of these three paths.
