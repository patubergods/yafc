# Architecture

YAFC adds a fullscreen camera presentation by attaching a library to the **factory camera
process** and redirecting two of that process's own Screen calls. It never replaces the camera
program, never replaces a Ford file, and does nothing in any other process.

## Evidence labels

- **verified on one radio** - observed on one unit. Not a support claim for another build,
  display or vehicle.
- **host-verified** - checked on a host, not on a radio.
- **UNPROVEN** - no adequate evidence yet.

## The slot

**verified on one radio:** the camera binary is `/apps/SS_RVC` (`/apps` is read-only) and the
launcher runs it with
`LD_LIBRARY_PATH=/proc/boot:/lib:/lib/dll:/usr/lib:/apps/lib:/fs/mp/lib:/fs/mp/usr/lib:/fs/mp/apps/usr/lib`.
`/fs/mp/apps/usr/lib` is writable and last on that path.

**verified on one radio:** the camera executable requires exactly one library from that
directory, `libRCN_DiagnosticsLib.so`. Nothing else needs it except the camera.

So the slot is one file: `libRCN_DiagnosticsLib.so` in `/fs/mp/apps/usr/lib`. Every process that
loads the slot keeps resolving the original functions, because the installer first copies the
unit's own library to a second name in the same directory, on the unit.

## The library

`libyafc.so` is built as the slot library itself (`sh toolchain/build-slot.sh`, `-DYAFC_SLOT`).
It is freestanding: it declares its own prototypes and includes no system header. It defines
**no Screen symbol at all**.

### Start-up, in order

An `__attribute__((constructor))` function runs before `main` and decides, in four checks,
whether to act. Every refusal writes one line to `/fs/rwdata/yafc/post.log`, and every step is
read-only:

1. **Identity.** `dl_iterate_phdr` confirms the main executable's program headers are the stock
   layout (text load at `0x100000`, `filesz 0x43800`, a read/write load at `0x144800`), then an
   FNV-1a-64 hash over that text is compared with the recorded value. The observed build is
   294,564 bytes with text hash `0xf3442ba773f7b837`. A different build refuses here.
2. **The kill switch.** `/fs/rwdata/yafc/DISABLE` means stand down.
3. **The strike counter.** If `/fs/rwdata/yafc/slot-inflight` is still present, the previous run
   never proved itself: it adds a strike. At three strikes it writes `DISABLE` and stands down.
4. **The call slots.** It resolves the real functions from `libscreen.so.1` with
   `dlopen`/`dlsym`, then checks that the camera's own GOT slots (`0x144d80` for
   `screen_post_window`, `0x144dd4` for `screen_create_window`) still hold libscreen's addresses.
   That check proves relocation is finished and that nothing else has written there.

Only then does it write its two static wrappers into those two GOT slots and log
`slot active pid <pid> <boot>`. This is a two-word change to the camera's own data, made once,
before the camera creates any window.

### Why the GOT, and not a symbol

The camera imports `screen_post_window` and `screen_create_window` from `libscreen.so.1`, which
sits earlier on the search path. Defining those names in the slot library would not bind them.
Writing the camera's own GOT slots does, and the equality check above makes the write safe: if
any of the four conditions is not what we recorded, the write does not happen.

**UNPROVEN:** this on any build but the observed one. The offsets and the hash are build-specific
and the repository says so next to them.

### The two wrappers

- `hook_create_window` - calls the real function, records the returned window and the current
  Screen context, returns the real result. Nothing else.
- `hook_post_window` - calls the real post **first**, then, only in a non-pass mode and only for
  the camera's own frame window, adjusts the window (below), and returns the real result.

In the LD_PRELOAD build the same code exports those two names instead of patching the GOT. That
build is for host tests and diagnostics; the slot build is the supported one.

## The picture

**verified on one radio:** the camera owns one Screen window, `RVC_app`, whose buffer is
`720 x 1900` UYVY; the live picture is the first 480 rows. The window's `ID_STRING` reads
`RVC_app`.

**host-verified:** the library finds the camera window by reading that `ID_STRING` on a post,
once. Placement uses Screen's own properties: `SOURCE_POSITION`/`SOURCE_SIZE` select the region
of the buffer to show, and `POSITION`/`SIZE` say where and how large to show it. There is **no
destination property** - the "destination rectangle" a property dump prints is derived from
`POSITION + SIZE`, and the compositor does all the scaling.

### Modes

- `mode=pass` (0, default) - call the real post unchanged. Safest.
- `mode=diag` (1) - log the real buffer properties once, then pass through.
- `mode=compose` (2) - apply the geometry and compose the layout.
- Any other value means pass. The pixel-writing and probe modes were removed on 2026-11-20.

### The bay (the 360 panel)

The bay shows a second region of the same buffer, using `screen_share_window_buffers`. It is a
**child window** of the camera window, joined to a window group parented by it, so it inherits the
camera's visibility and disappears with it. If parenting fails it is destroyed rather than left
visible. A child's `POSITION` is relative to its parent's. The bay is off unless `bay_id=1` and a
`bay_dst` is set.

**verified on one radio:** an earlier version made the bay a second top-level window, shown once
and never hidden; because the factory visibility manager, not the camera, shows and hides
`RVC_app`, nothing hid the bay when the camera closed, and it stayed on screen until a reboot.
That is why the bay is a child window now.

### No pixel writes

A previous version composed the layout by writing into buffer rows 480..959. The capture engine
writes into that buffer too (measured: source rows 0..3 land at buffer rows 483..486). Those rows
are not ours. Nothing in the library writes into a buffer any more, and CAMERA-PIPELINE.md says so.

## The configuration

`/fs/rwdata/yafc/camera.conf` is a flat `key=value` file, at most 4095 bytes, read from the start
and re-read on a post every `reread` posts (`reread=60` by default, `0` means never). Keys:

| Key | Meaning |
|---|---|
| `mode` | `pass`, `diag` or `compose` |
| `view` | the view name the rectangles come from |
| `reread` | posts between configuration re-reads; `0` never |
| `stats` | `1` logs a rate line about every ten seconds |
| `cam_src`, `cam_dst` | the camera's source region and destination rectangle |
| `sen_dst` | the sensor area |
| `tail_dst` | the trailer view rectangle |
| `bay_id`, `bay_src`, `bay_dst` | the bay: on/off, its source region, its rectangle |

Values are validated against a small set and the built-in defaults cover anything missing or out
of range, so a damaged file falls back safely. The shipped default is
`payload/config/camera.conf`.

**UNPROVEN:** whether a warm start (a re-read without a restart) is needed at all, and the values
for the 360, Trailer and ship-config shapes - a config fragment ships, but no radio run has
exercised it.

## The failure counter

A library that never loads cannot count anything, so the counter lives in the start-up path and
does not depend on any Screen call:

- Each run writes `/fs/rwdata/yafc/slot-inflight` before it acts and deletes it once it has
  proved itself with 60 good posts (`SLOT_VERIFY_POSTS`).
- The next start that finds `slot-inflight` still there counts a strike
  (`/fs/rwdata/yafc/slot-strikes`).
- Three strikes in a row write `/fs/rwdata/yafc/DISABLE`; the library then stands down and the
  factory picture is what you get. `rm DISABLE` re-arms it.

**UNPROVEN:** the counter has never been made to fire on a unit. Doing that deliberately, with a
known restore, is the next evidence step ([TESTING.md](TESTING.md)).

## The installer

`installer/yafc-install.sh` runs on the unit under the jailbreak's USB hook, one worker with four
modes armed by exactly one marker at the stick root: `RUN-YAFC-REHEARSE`, `RUN-YAFC-INSTALL`,
`RUN-YAFC-REMOVE`, `RUN-YAFC-DISABLE`. Every write mode makes the preserved copy of the unit's
own library once, reduces the writable mount, writes, restores the mount, runs the loader probe
and puts the unit's own library back if the probe fails, then re-checks the recovery scripts and
writes a receipt.

**host-verified:** every mode, every refusal, and a rehearsal that writes the unit's own bytes
through the real path (`python3 -I tools/test-install.py`, all assertions pass).
**UNPROVEN:** any run on a unit from this repository.

## See also

[SAFETY.md](SAFETY.md) - the safety position. [RECOVERY.md](RECOVERY.md) - the undo paths.
[CAMERA-PIPELINE.md](CAMERA-PIPELINE.md) - the frame path and timings. [INSTALL.md](INSTALL.md) -
the write order.
