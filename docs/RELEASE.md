# Release

How the two ready-made zips are built and published. The build script does not run on a radio, and no zip
is ever committed: `dist/` is ignored, and the zips are attached to a GitHub release.

## What comes out

| File | Stick marker | What the reader gets |
|---|---|---|
| `YAFC-<version>-install.zip` | `RUN-YAFC-INSTALL` | installs the library and HMI overlay |
| `YAFC-<version>-uninstall.zip` | `RUN-YAFC-REMOVE` | removes the HMI overlay and restores the unit's own library if preserved |
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

A leftover rehearsal zip for the same version is removed. Manual rehearsal mode remains
available on a source-built stick; there is no rehearsal download.

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

3. `START-HERE.txt` in each zip opens with the WARNING block and distinguishes design use on
   one 2020 Explorer ST from the packaged installer, which has not been run on a radio. The
   install zip describes early rear video and the later controls without promising exact times.
   `tools/test-make-release.sh` checks this; read one anyway.
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
  --notes "Unofficial hobby project. Design used only on a 2020 Explorer ST; packaged installer not field-tested. Read docs/DISCLAIMER.md."
```

The tag and the version in the file names must match. On a private repository the release is
visible only to people who already have access to it, which is the point: the zips are reviewed
before anyone outside the repository sees them.

**UNPROVEN:** no zip built by this script has been run on a radio. Say so in the release notes.