# Safety

> Use is at your own risk, with no warranty, no support and no liability. See [DISCLAIMER.md](DISCLAIMER.md).

The rear camera is safety-critical. A wrong picture is worse than no picture, because the driver
may trust it. Everything below follows from that.

## The position

- YAFC does not replace the camera program, but it changes the camera's library slot and HMI.
  A failed or interrupted install can leave either component changed or prevent services from
  loading. The recovery path is not guaranteed to be available after a loader failure.
- A failed identity check makes the native hook stand down; it does not by itself prove that the
  HMI returns to stock. A failed install can leave a persistent change. See [RECOVERY.md](RECOVERY.md).
- A change to the picture is a real change to a safety system. It is tried on a stationary vehicle
  with the brake held, in one view at a time, with the undo path already known.

## What the design refuses to do

- Replace `/apps/SS_RVC`, or write to any read-only image.
- Ship or redistribute any Ford binary or Ford QML.
- Leave the module active after a repeated boot failure: the counter writes `DISABLE`.
- Act in any process that is not the camera.

## The hidden risk

A library that stops the loader from working could affect other services as well as the camera.
The installer checks a loader probe, but neither the probe nor host tests prove that a real
vehicle will boot or recover after an interrupted write.

## Before a first trial

1. The undo path is known and written down: [RECOVERY.md](RECOVERY.md).
2. `RUN-YAFC-REHEARSE` has run clean on that unit.
3. The vehicle is stationary. Nothing in the camera path requires Park, but a picture change does
   not belong in motion.
4. Someone can reach the unit and hold a reset if the picture does not come back.

## What this repository does not claim

- That the composed picture is factory-equivalent, or that it survives every camera state.
- That a running process or a visible window proves usable video.
- That host tests establish loader behaviour, live video, or vehicle safety.
