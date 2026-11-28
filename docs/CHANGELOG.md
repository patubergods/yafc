# Changelog

Dates are UTC. This project was split out of a larger project that also covers the vehicle's other
mods; anything before the split is not part of this repository.

## Unreleased

- Log the observed SHA-256 when refusing an unknown unowned stock library.
  The accepted stock fingerprint and preflight checks are unchanged.

## 2026-11-27 (radio run, layout hold, on-screen notices, beta.3)

- The packaged installer was run on one 2020 Explorer ST (10-inch portrait): install, uninstall
  and reinstall all completed, with receipts on the stick. **verified on one radio.** Every other
  vehicle and firmware stays **UNPROVEN**.
- The native no longer drops a layout 500 ms after the last renewal from the popup. A published
  layout now holds until a newer record replaces it, the session changes, `DISABLE` is set, or the
  popup writes `compose=0`. `LEASE_MS` only gates the ready file.
- The popup keeps renewing Zoomed View while Ford's report differs, takes its look (divider,
  sensor panel, Zoom button position, backdrop) from Ford's report without waiting for the
  mailbox write, and retries the write from its 100 ms poll with a catch-up of the sequence
  number.
- Zoomed View root cause fixed: Ford's zoom changes the reported stream, so the popup stopped
  renewing and the native fell back to the `camera.conf` Hero rectangles.
- Added `scale_quality` (Screen property 56). Default 2 (nicest) when the key is absent, 0 sends
  nothing, 1 is fastest. Applied to the camera window and the second view; the camera window gets
  Ford's default back when composition ends or `DISABLE` is set. Seeded `camera.conf` documents
  it.
- The original Hero icon artwork is now in use: the selector points Hero at
  `parkingfeatures/icon_hero_view`.
- The installer shows an on-screen notice from both the dispatcher and the worker through the
  `utserviceutility` popup, best effort and bounded to 5 seconds. Success, failure, removed,
  rehearsal, recover and disabled variants, plus no-marker, more-than-one-marker, earlier
  `.running`, non-plain-file marker and missing `yafc-install.sh` refusals from the dispatcher.
- `START-HERE.txt` now describes the two-minute message and lists the logs in `yafc-install/`.
- Added the issue templates and `docs/TROUBLESHOOTING.md`.
- Released `v0.1.0-beta.3` as a GitHub prerelease with the install and uninstall zips and
  `SHA256SUMS`.

## 2026-11-26 (popup selection ported to the proven event-driven flow)

The public popup now follows the behaviour proven by the private build, on top of the existing
session mailbox:

- A view pick closes the row, raises the cover and stores a pending key. The layout is published
  and applied when Ford reports that view (`onYafcFordViewChanged`), not on the next poll tick. A
  pick whose Ford view already matches (Rear Only to Zoomed View) applies at once.
- The 2 s timeout reconciles to whatever Ford reports and drops the cover when no layout matches,
  so the camera cannot stay black. Taps are ignored while the cover is up.
- The 100 ms poll only renews the native's 500 ms lease; it no longer restarts the cover or the
  default timer. If Ford changes the stream, the popup re-takes a layout matching the report so
  the lease stays alive. (Superseded on 2026-11-27: the lease no longer expires a published
  layout; see the 2026-11-27 entry.)
- Zoomed View asks for `IPMBRearNormal`, not `IPMBRearZoom`; Ford's zoom level is the state.
- Hide, DISABLE and a session change write a valid `compose=0` record. The old `;off` sentinel
  failed the native parser and never released the window.
- A session that appears after entry publishes the layout already taken from `camera.conf`, and
  the tick after a session mismatch adopts the restarted native and re-takes the layout.
- `tools/test-hmi-behavior.js` is updated for the pending/commit, timeout, release,
  late-session, hide-latch and lease-renewal paths; it has not been run since this change, and
  the fragments have not been applied to a radio.

## 2026-11-26 (original Hero view icon artwork)

- Added YAFC's own `parkingfeatures/icon_hero_view` artwork: a camera body inside
  a 360 orbit with two rotation arrowheads, 50x50 RGBA, day and night, five states
  each. It is drawn deterministically by `tools/make-hero-icon.js`; no Ford icon
  is copied, sampled or derived.
- Install and rehearsal now require all ten PNGs, verify each against
  `yafc-payload/SHA256SUMS`, stage them into the HMI image, read them back with
  the four QML files, and refuse a boot overlay that shadows any icon path.
- `tools/make-usb.sh` refreshes the icon tree and writes the icon digests into the
  payload manifest. Release packaging and tests cover the icon bytes and hashes.
- The selector fragments still name stock `parkingfeatures/icon_360_view` for
  Hero. Integration is one fragment edit to `parkingfeatures/icon_hero_view`.
  **UNPROVEN:** the new icon has not been rendered on a radio.

## 2026-11-26 (installer mount-line fixes found by the first radio run)

The packaged installer was run on a radio for the first time. It stopped at the overlay check and
wrote nothing. Two defects were reachable only on a radio:

- `mount_is_ours` compared a whole `mount` line against a constructed string. The radio prints a
  trailing space where the mode flag would be when there is none, so the comparison never matched
  and every run aborted at the overlay check. It now compares fields.
- The read-only shadow inspection ran before the mount stack was reduced, so a boot overlay that
  was already mounted could not be mounted a second time (`Resource busy`). The inspection now
  runs after the reduction, when every candidate is unmounted.

The host `mount` mock now reproduces the radio's trailing-space format and refuses a second mount
of an image already on the slot, so the existing suite covers both defects. `EASY-INSTALL.md` now
states that the drive's partition table must be MBR: SYNC refuses a GPT drive with "USB not
supported" before the installer runs. The fixed installer has not been run on a radio.

## 2026-11-26 (all-or-nothing install, RECOVER, handshake, unproven QNX)

- Install is now all-or-nothing. Exit 8 (missing stock file), 9 (fragment refusal), or 10 (image
  build/read-back) leave the slot untouched. There is no "library installed but HMI not published"
  state. A failure after the slot write rolls back to the journaled previous library bytes, or
  retains the journal for recovery.
- Added `RUN-YAFC-RECOVER`. On a fresh stick, restores the journaled previous state from an
  interrupted install or remove. Refuses when the journal does not authenticate, a file digest
  differs, or a layer is busy.
- Added the unowned-stock digest limit: only the one recorded stock build of
  `libRCN_DiagnosticsLib.so` is accepted as unowned. Other firmware refused until its digest is
  independently verified.
- Added shadowing-overlay refusal. Before any write, every other `overlay*.img` is mounted
  read-only and checked. An overlay that provides or obscures a YAFC target path is refused.
- Added per-request receipts. Each receipt is in a request-specific directory under
  `yafc-install/request-<id>/`. The `.running` marker carries a unique request ID and is consumed
  only when `DONE` is written.
- Added the session/ready handshake. The native writes `/fs/tmpfs/yafc-session` at start. The
  popup prefixes every mailbox record with the session and an advancing sequence number. The
  native echoes the accepted record in `/fs/tmpfs/yafc-ready` after a successful post. The popup
  composes only after two advancing ready replies. A ready file proves Screen post and geometry
  acceptance, not displayed pixels or a painted late bay. QML timer stalls are not detected by
  the native. `LEASE_MS` expiry is local-only: no atomic cross-process liveness proof.
- **UNPROVEN** QNX items documented: `DL_DEBUG=libs` trace format, `dladdr` paths, `-o before`
  mount flag ordering, file-image mount listing, second read-only inspection mount, busy layers
  after restart.
- Updated all docs to remove "HMI only" failure semantics and add the new contracts. STATUS
  labels remain honest (host-verified vs UNPROVEN).

## 2026-11-25 (USB HMI install and removal)

- The USB installer stages the radio's four stock HMI files, applies the complete
  fragment set, and builds and verifies an overlay image without shipping Ford QML.
- Rehearsal checks an image without publishing it or seeding configuration. Install
  seeds missing configuration and publishes with a verified same-directory rename.
- Full removal deletes the HMI overlay before restoring the slot. HMI-only removal
  leaves the library untouched. Both check the surviving mount stack.
- Popup changes are gated on configuration, the kill switch, and verified mailbox
  publication. Both sets of default views are honored and stock bindings are preserved.
- Added host regressions for mount handling, failure cleanup, configuration, live
  mailbox posts, popup behavior and packaged payloads. The public paths remain unproven on a radio.
- Release packaging now produces only install and uninstall zips. Source-built
  sticks still support rehearsal. User instructions call the rear zoom mode Zoomed View
  and distinguish the startup timing observed on one 2020 Explorer ST from untested hardware.

## 2026-11-25

- Ported the camera views verified in the development build into the public edition. **Host-verified**
  here; the underlying behaviour was **verified on one radio** in the private build.
- Library: a RAM mailbox, `/fs/tmpfs/yafc-view`, carries the geometry of the view the HMI just
  picked. The library re-reads it before every real post and falls back to the last good geometry on
  any missing, short, garbled or out-of-range record. A compose flag places a single-camera view in a
  centered 800x480 band. Also in this change: the geometry-before-post step and the `enabled=0` gate
  that pull requests 2 and 3 carry, and a 100 ms re-read.
- HMI fragments: the earlier `panel-*` set is replaced by `popup-*`. It adds the rear selector (Hero,
  Rear Only, Wide, 360 Only), the Trailer plus and minus, the front selector (Hero, Front Only, Front
  Wide, 360 Only), a black "Please wait..." cover on cross-stream switches and Trailer entry or exit
  (`cover_ms`, default 700), and the zoom sync that keeps Ford's zoom level matching the layout.
- The Hero button uses a stock icon, not the composite icon of the development build.
- Tests: mailbox parser cases in the host suite; the fragment test now applies the whole set, checks
  idempotence and refusal, balance, and rejects private tokens.

## 2026-11-23 (view-switch flash)

- The slot library began fixing window geometry before the real post, so a Ford view switch
  arrives with the corrected rectangles. This change used a 40 ms config re-read gate, down
  from 150 ms. Host-verified (ordering test); not run on a radio.

## 2026-11-23 (enabled gate)

- `enabled=0` in `camera.conf` now makes the slot library stand down at the next camera start (log `slot refused: enabled=0`). The shipped value is now `enabled=1`; before, the key was HMI-only and shipped as `0`. Existing installs with `enabled=0` go stock after upgrading the library. Host-verified (test S4b); not run on a radio.

## 2026-11-23 (process)

- Changes now land through pull requests with full notes and documentation. Added
  `.github/pull_request_template.md` and a "How changes land" section in `CONTRIBUTING.md`.

## 2026-11-23

- The HMI fragments carry the per-view geometry from the development build: five views in a fixed
  order, each writing its own rectangles and sensor-panel switch, with a 150 ms live re-read. The
  older Front/Rear/F360/R360/Split buttons and the layout row are gone. Host-verified
  (fragment applier, brace balance); not run on a radio from this repository.

## 2026-11-22

- The mod is split out of the parent project into `yafc/`, so it can be developed and shared on
  its own.
- The boot hook is gone. It replaced the factory camera process, which stripped it of the session
  ownership the factory visibility manager and the vehicle bus registration depend on. The
  library slot replaces it, and it starts earlier.
- The library now takes the slot directly: `-DYAFC_SLOT` builds `libyafc.so` with a constructor
  that patches the camera's own two Screen call slots, instead of exporting the Screen names.
- The camera's configuration file now carries the view rules and layout as well as the mode, so
  the picture's geometry is one file with one set of defaults.
- Window placement now follows the child-window geometry rule (a child's rectangle is in its
  parent's source coordinates), which is what the HMI aperture assumes.
- The bay (360 panel) is created as a child window of the camera window and joined to a window
  group, so it inherits the camera's visibility and cannot be left on screen.
- The installer was rebuilt: one worker, four modes at that time (`install`, `rehearse`, `remove`,
  `disable`), one marker each, a preserved copy of the unit's own library, a probe before the marker
  is consumed, recovery-script hashes, and receipts.
- A `rehearse` mode writes the unit's own bytes through the real write path, so the whole
  installer can be exercised without changing the picture.
- The standalone test rigs are replaced by one host suite, and the installer and the fragment
  applier get regression tests (`tools/test-install.py`, `tools/test-apply-hmi-fragments.sh`).
- The loader probe and its three helper libraries get a build script, an emulated test and a
  recorded hash list.
