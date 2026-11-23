# Changelog

Dates are UTC. This project was split out of a larger project that also covers the vehicle's other
mods; anything before the split is not part of this repository.

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
