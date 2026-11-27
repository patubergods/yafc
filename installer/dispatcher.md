# Dispatcher

`yafc-dispatch.sh` is installed as `<USB>/SyncMyMod/autoinstall.sh`, the file the jailbreak's USB
hook runs on every insertion. With no marker it does nothing at all, so the stick cannot change
the unit by accident.

## What it does

1. Derives the stick root from its own path: it must be `<USB>/SyncMyMod/autoinstall.sh`.
2. Searches the stick root and `SyncMyMod/` for the six markers:
   `RUN-YAFC-INSTALL`, `RUN-YAFC-REHEARSE`, `RUN-YAFC-REMOVE`, `RUN-YAFC-REMOVE-HMI`,
   `RUN-YAFC-RECOVER`, `RUN-YAFC-DISABLE`.
3. **Refuses if more than one is present**, or if `<marker>.running` from an earlier request still
   exists, and records the refusal in `yafc-install/seen.log`.
4. With none, records `stick seen; no marker, nothing done` in `yafc-install/seen.log` and
   exits 0.
5. Creates a request ID and its receipt directory `yafc-install/request-<ID>/`, renames the marker
   to `<marker>.running`, writes the ID into it, syncs, and execs the worker:

```
sh <USB>/yafc-install.sh <USB> <mode> <USB>/<marker>.running
```

One marker, one mode:

| Marker | Mode | What the worker does |
|---|---|---|
| `RUN-YAFC-REHEARSE` | `rehearse` | rewrite the current slot bytes under the journal; build and read back the HMI image without publishing, owning or initializing config |
| `RUN-YAFC-INSTALL` | `install` | build and read back the HMI image, initialize missing `camera.conf`, journal the previous state, write the stock copy and YAFC's library, probe the pair with the loader trace, publish the image by rename, record ownership |
| `RUN-YAFC-REMOVE` | `remove` | put the authenticated stock library back, delete the owned preserved copy and the owned HMI image |
| `RUN-YAFC-REMOVE-HMI` | `remove-hmi` | delete the owned HMI image only; the library is untouched |
| `RUN-YAFC-RECOVER` | `recover` | restore an interrupted request's journaled previous state, only if the journal and every file authenticate |
| `RUN-YAFC-DISABLE` | `disable` | write the kill switch only; touches nothing under `/fs/mp` |

The worker refuses, with nothing changed, when the slot is not the recorded stock build and no
YAFC ownership record matches it, when a `libRCN_DiagnosticsOld.so` or `overlay_00--yafc.img`
exists that YAFC did not record as its own, when another boot overlay provides one of the four
QML targets, the slot or the preserved name, when a pending journal exists (except `recover`),
and when the mount stack holds anything but the base device and read-only `/fs/images` overlays.

The install is all or nothing. An HMI refusal (missing fragment, stale or duplicate anchor,
missing stock file, image build or read-back failure) stops before the slot is written. A failure
after the journal is written rolls back to the journaled bytes and mount order, or keeps the
journal and says so. Exit codes: 3 refused, 4 write or probe failure, 5 mount order or retained
journal, 6 recovery script changed, 8 missing stock file, 9 applier refusal, 10 image build or
read-back, 12 image publish or delete. **UNPROVEN on a radio.**

## Receipts

Each line names the request ID, the mode and the stage it was written at.

- `yafc-install/request-<ID>/install.log`, `DONE` or `FAILED`, and `probe.out`/`probe.err` for an
  install: this request only. `yafc-install/install.log`, `DONE` and `FAILED` collect the same
  lines across requests.
- `DONE` - the mode finished and every check passed. The worker removes the `.running` marker
  before writing `DONE`, so a `.running` marker next to a receipt means that request did not
  finish.
- `FAILED` - it stopped; the receipt says whether the previous state was verified after a
  rollback or the journal was retained. The dispatcher never retries a `.running` marker.
- `yafc-install/seen.log` - one line per insertion that did not run the worker.

## Interrupted requests

The journal lives in `/fs/rwdata/yafc/installer-pending/`. While it exists every mode except
`recover` and `disable` is refused. Restart the unit (that clears the RAM lock and remounts the
boot images; it does not undo a file write), keep the stick and its receipts, then arm
`RUN-YAFC-RECOVER`. It restores the journaled slot, preserved copy, image and ownership record and
the recorded mount order only when every current file is either its recorded previous or planned
bytes. Otherwise it changes nothing and keeps the journal for manual recovery.

## Arming

`sh tools/make-usb.sh <mount-point>` assembles the stick and leaves it unarmed. Arm one marker by
creating that one empty file at the stick root. Preserve a `.running` marker and its receipts
before resolving it.
