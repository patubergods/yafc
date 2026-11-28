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
- The installer: one worker, six modes, one marker each, per-request receipts, a rehearsal mode,
  a recover mode, the USB HMI image path (source-level only), all-or-nothing install semantics.
- The unowned-stock digest limit: only one recorded stock build accepted.
- Shadowing-overlay refusal: every other `overlay*.img` inspected read-only before any write.
- The session/ready handshake: popup and native coordinate over tmpfs files.
- The USB tooling, which refuses an armed stick and writes a hash list.
- The host suite, including the installer rehearsal and the fragment applier.
- The documentation set you are reading.

## Not done

- **No radio run on any unit but the one 2020 Explorer ST.** Install, uninstall and reinstall ran
  there once each on 2026-11-27; every other vehicle and firmware is unproven.
- The loader probe has not been run on a unit from this repository.
- `RUN-YAFC-RECOVER` and the DISABLE kill switch live have not been exercised on a radio.
- Rehearsal has not been run on a radio.
- The 360 and Zoomed View layouts in the public build were seen working on the one radio; other
  firmware is unproven.
- The strike counter has never been made to fire on purpose.
- The HMI values for the ship-config shape are supplied but unexercised.
- Whether a warm start re-reads the configuration is unknown.
- All QNX-specific behaviours (`DL_DEBUG=libs` trace, `dladdr` paths, `-o before` mount order,
  file-image mount listing, second read-only inspection mount, busy layers after restart) are
  **UNPROVEN** on a radio.
- The session/ready handshake on any firmware but the one observed, and the ready-file `LEASE_MS`
  expiry and stalled-thread detection, are **UNPROVEN** on a radio.

## Next, in order

1. Rehearse on another unit (`RUN-YAFC-REHEARSE`) and read `install.log`.
2. Run the probe on a unit to confirm the `DL_DEBUG=libs` trace format and `dladdr` paths.
3. Run the counter drill ([TESTING.md](TESTING.md)) and record the result.
4. Exercise `RUN-YAFC-RECOVER` and the DISABLE kill switch live on a radio.
5. Repeat the install on other firmware and record whether the on-screen notice text appears.
6. Calibrate the picture against the observed HMI values, one variable at a time.
7. Record every result in [STATUS.md](STATUS.md) and update the labels.

## Not planned

- Replacing `/apps/SS_RVC`, or any write to a read-only image.
- Shipping or redistributing any Ford file or any third-party mod.
- Packet capture on Ford's internal bus.
