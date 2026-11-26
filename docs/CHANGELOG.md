# Changelog

Dates are UTC. This project was split out of a larger project that also covers the vehicle's other
mods; anything before the split is not part of this repository.

<<<<<<< HEAD
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
=======
## 2026-11-23 (view-switch flash)

- The slot library now fixes the window geometry BEFORE the real post: when Ford resets it for a view change, our rectangles go back ahead of the first new frame, and a changed config is picked up ahead of the frame. The config re-read gate is 40 ms (was 150 ms). Host-verified (new ordering test); not run on a radio.

## 2026-11-23 (enabled gate)

- `enabled=0` in `camera.conf` now makes the slot library stand down at the next camera start (log `slot refused: enabled=0`). The shipped value is now `enabled=1`; before, the key was HMI-only and shipped as `0`. Existing installs with `enabled=0` go stock after upgrading the library. Host-verified (test S4b); not run on a radio.
>>>>>>> origin/feat/pre-post-geometry

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
- The installer is rebuilt: one worker, four modes (`install`, `rehearse`, `remove`, `disable`),
  one marker each, a preserved copy of the unit's own library, a probe before the marker is
  consumed, recovery-script hashes, and receipts.
- A `rehearse` mode writes the unit's own bytes through the real write path, so the whole
  installer can be exercised without changing the picture.
- The standalone test rigs are replaced by one host suite, and the installer and the fragment
  applier get regression tests (`tools/test-install.py`, `tools/test-apply-hmi-fragments.sh`).
- The loader probe and its three helper libraries get a build script, an emulated test and a
  recorded hash list.
