# Dispatcher

`yafc-dispatch.sh` is installed as `<USB>/SyncMyMod/autoinstall.sh`, the file the jailbreak's USB
hook runs on every insertion. With no marker it does nothing at all, so the stick cannot change
the unit by accident.

## What it does

1. Derives the stick root from its own path: it must be `<USB>/SyncMyMod/autoinstall.sh`.
2. Searches the stick root and `SyncMyMod/` for the four markers:
   `RUN-YAFC-INSTALL`, `RUN-YAFC-REHEARSE`, `RUN-YAFC-REMOVE`, `RUN-YAFC-DISABLE`.
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
| `RUN-YAFC-REHEARSE` | `rehearse` | the whole install path with the unit's own bytes; no picture change |
| `RUN-YAFC-INSTALL` | `install` | write YAFC's library and configuration into the slot |
| `RUN-YAFC-REMOVE` | `remove` | restore the unit's own library, delete the preserved copy |
| `RUN-YAFC-DISABLE` | `disable` | write the kill switch only; touches nothing under `/fs/mp` |

## Receipts

- `yafc-install/install.log` - what the worker did, line by line.
- `yafc-install/DONE` - the mode finished and the checks passed; the `.running` marker is gone.
- `yafc-install/FAILED` - it stopped; the log says why, and the `.running` marker is kept so the
  request is not retried on the next insertion.
- `yafc-install/seen.log` - one line per insertion that did not run the worker.

## Arming

`sh tools/make-usb.sh <mount-point>` assembles the stick and leaves it unarmed. Arm one marker by
creating that one empty file at the stick root. Remove the `.running` marker to re-arm a request
that failed.
