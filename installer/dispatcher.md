# Dispatcher

`yafc-dispatch.sh` is installed as `<USB>/SyncMyMod/autoinstall.sh`, the file the jailbreak's USB
hook runs on every insertion. With no marker it does nothing at all, so the stick cannot change
the unit by accident.

## What it does

1. Derives the stick root from its own path: it must be `<USB>/SyncMyMod/autoinstall.sh`.
2. Searches the stick root and `SyncMyMod/` for the five markers:
   `RUN-YAFC-INSTALL`, `RUN-YAFC-REHEARSE`, `RUN-YAFC-REMOVE`, `RUN-YAFC-REMOVE-HMI`,
   `RUN-YAFC-DISABLE`.
3. **Refuses if more than one is present**, and records the refusal in
   `yafc-install/seen.log`.
4. With none, records `stick seen ...; no marker, nothing done` in `yafc-install/seen.log` and
   exits 0.
5. Renames the marker to `<marker>.running` so a reset cannot repeat the request, syncs, and
   execs the worker:

```
sh <USB>/yafc-install.sh <USB> <mode> <USB>/<marker>.running
```

One marker, one mode:

| Marker | Mode | What the worker does |
|---|---|---|
| `RUN-YAFC-REHEARSE` | `rehearse` | write the current slot bytes; build and read back the HMI image without publishing or initializing config |
| `RUN-YAFC-INSTALL` | `install` | initialize missing `camera.conf`, write and probe YAFC's library, then build and atomically publish the HMI image |
| `RUN-YAFC-REMOVE` | `remove` | delete the HMI image, then restore the unit's own library and delete the preserved copy if present |
| `RUN-YAFC-REMOVE-HMI` | `remove-hmi` | delete the HMI image only; the library is untouched |
| `RUN-YAFC-DISABLE` | `disable` | write the kill switch only; touches nothing under `/fs/mp` |

The HMI step refuses on missing fragments or a missing or duplicate anchor: the library stays
installed and the receipt is `FAILED` with `HMI only` in it. The exit status is the HMI failure
code (8 missing stock file, 9 applier refusal, 10 image build or read-back, 12 publish), not the
generic 4. **UNPROVEN on a radio.**

## Receipts

- `yafc-install/install.log` - what the worker did, line by line.
- `yafc-install/DONE` - the mode finished and the checks passed; the `.running` marker is gone.
- `yafc-install/FAILED` - it stopped; the log says why and what was left in place. For a
  `RUN-YAFC-INSTALL` whose library passed the loader probe but whose image was not published,
  it says `HMI only` and gives the specific error. The dispatcher does not retry a `.running`
  marker.
- `yafc-install/seen.log` - one line per insertion that did not run the worker.

## Arming

`sh tools/make-usb.sh <mount-point>` assembles the stick and leaves it unarmed. Arm one marker by
creating that one empty file at the stick root. Remove the `.running` marker to re-arm a request
that failed.
