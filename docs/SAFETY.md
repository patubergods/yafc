# Safety

> Use is at your own risk, with no warranty, no support and no liability. See [DISCLAIMER.md](DISCLAIMER.md).

The rear camera is safety-critical. A wrong picture is worse than no picture, because the driver
may trust it. Everything below follows from that.

## The position

- YAFC does not replace the camera program. The worst ordinary failure is that the factory picture
  appears unchanged, or does not appear until the next boot.
- Every failed identity check means the library does nothing. Every failed write check means the
  installer stops and leaves the unit's own library in place.
- A change to the picture is a real change to a safety system. It is tried on a stationary vehicle
  with the brake held, in one view at a time, with the undo path already known.

## What the design refuses to do

- Replace `/apps/SS_RVC`, or write to any read-only image.
- Ship or redistribute any Ford binary or Ford QML.
- Leave the module active after a repeated boot failure: the counter writes `DISABLE`.
- Act in any process that is not the camera.

## The hidden risk

A library that stops the loader from working would take several services with it - about twenty
processes load the library, and the camera is one. That is why the identity checks run before
anything else, why the library exports no Screen symbol of its own, and why the install writes a
probe result before it reboots anything. If the probe fails, the unit's own library goes back
immediately.

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
