# Roadmap

## What YAFC is today

A library placed in the camera's own link path attaches to the camera process and redirects two of
its Screen calls. It composes the picture itself - the camera window's source region and its
rectangle, an optional second region in a child window - and leaves every stock Screen symbol,
every other process, and every Ford file alone. See [ARCHITECTURE.md](ARCHITECTURE.md).

## Done

- The slot mechanism: identity checks, the kill switch, the strike counter, and the two GOT writes.
- The two hooks, with the real function called first in both.
- `mode=pass`, `mode=diag`, `mode=compose`, with `pass` as the built-in default.
- Per-view rectangles and presets, resolved from one ordered set of sources.
- The configuration file, with the library's keys and the HMI's keys in one file.
- The bay as a child window of the camera window, so it hides with the camera.
- The installer: one worker, four modes, one marker each, receipts, and a rehearsal mode.
- The USB tooling, which refuses an armed stick and writes a hash list.
- The host suite, including the installer rehearsal and the fragment applier.
- The documentation set you are reading.

## Not done

- **No radio run of the public edition.** Every radio claim in this repository is from an earlier
  development build on one unit.
- The loader probe has not been run on a unit from this repository.
- The install has not been exercised on a unit from this repository.
- The 360 and Trailer views have not been observed; only rear, split and the combined rear-360
  states have.
- The strike counter has never been made to fire on purpose.
- The HMI values for the ship-config shape are supplied but unexercised.
- Whether a warm start re-reads the configuration is unknown.

## Next, in order

1. Rehearse on the unit (`RUN-YAFC-REHEARSE`) and read `install.log`.
2. Run the counter drill ([TESTING.md](TESTING.md)) and record the result.
3. Install for real (`RUN-YAFC-INSTALL`), reboot, and observe the camera on a stationary vehicle.
4. Calibrate the picture against the observed HMI values, one variable at a time.
5. Record every result in [STATUS.md](STATUS.md) and update the labels.

## Not planned

- Replacing `/apps/SS_RVC`, or any write to a read-only image.
- Shipping or redistributing any Ford file or any third-party mod.
- Packet capture on Ford's internal bus.
