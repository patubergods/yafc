# Release

How the two ready-made zips are built and published. Nothing here runs on a radio, and no zip
is ever committed: `dist/` is ignored, and the zips are attached to a GitHub release.

## What comes out

| File | Stick marker | What the reader gets |
|---|---|---|
| `YAFC-<version>-install.zip` | `RUN-YAFC-INSTALL` | the real install |
| `YAFC-<version>-uninstall.zip` | `RUN-YAFC-REMOVE` | the unit's own library back |
| `SHA256SUMS` | - | the two hashes |

The zip root **is** the stick root: `SyncMyMod/`, `yafc-install.sh`, `yafc-payload/`, `tools/`,
`START-HERE.txt`, one marker, and `DISCLAIMER.txt` when `docs/DISCLAIMER.md` exists. Unzipping
onto the USB drive root is the whole job, so there is no wrapper directory to remove.

## Build

```
sh tools/make-release.sh              # version from git describe, else the date
sh tools/make-release.sh 0.3.0        # or name it
```

Needs WSL Ubuntu with the cross toolchain ([BUILD.md](BUILD.md)) and `python3`. It runs
`toolchain/build-slot.sh` (which lints) and `toolchain/probe/build-probe.sh`, stages a stick with
`tools/make-usb.sh` into a fresh scratch directory per variant - `make-usb.sh` refuses an armed
stick, so the marker is created only after assembly - and writes the zips plus `SHA256SUMS` into
`dist/`. The scratch directory is removed.

The zips are byte-for-byte reproducible for one version: entries are sorted, timestamps are
fixed, entries are stored rather than compressed, and modes are normalised. Two runs give the
same `SHA256SUMS`. `YAFC_SKIP_BUILD=1` with `YAFC_LIB` and `YAFC_PROBE` replaces the payload with
stub files and exists for the host test only; never publish a build made that way.

## Checklist before attaching anything

1. Every host suite is green, from the repository root in WSL:

   ```
   sh toolchain/test/run-host-test.sh /tmp/ht
   sh tools/test-apply-hmi-fragments.sh
   sh toolchain/probe/test-emulated.sh
   python3 -I tools/test-install.py
   sh tools/test-make-release.sh
   ```

2. The forbidden-token scan finds nothing (private names, user paths, addresses):

   ```
   grep -rInE '\bpat\b|PAT_|pat-rvc|patcam|/home/|/Users/|/mnt/c/' . \
     --exclude-dir=.git --exclude=test-make-release.sh --exclude=RELEASE.md

   ```

   The two excluded files are the scan itself: they have to spell the pattern out.

3. `START-HERE.txt` in each zip opens with the WARNING block, says the design has been used on the
   developer's vehicle but this installer is not yet field-tested, and gives no timing it cannot back. `tools/test-make-release.sh` checks
   this; read one anyway.
4. The hashes are reviewed, not just generated: `cat dist/SHA256SUMS`, then build again and
   compare the file.
5. `git status` shows source changes only. No zip, no `dist/`, no built binary.

## Publish

Attach the zips to a release. Do not commit them.

```
gh release create v0.3.0 \
  dist/YAFC-0.3.0-install.zip \
  dist/YAFC-0.3.0-uninstall.zip \
  dist/SHA256SUMS \
  --title "YAFC 0.3.0" \
  --notes "Unofficial hobby project. Used on the developer's vehicle; this installer is not yet field-tested. Read docs/DISCLAIMER.md."
```

The tag and the version in the file names must match. On a private repository the release is
visible only to people who already have access to it, which is the point: the zips are reviewed
before anyone outside the repository sees them.

**UNPROVEN:** no zip built by this script has been run on a radio. Say so in the release notes.