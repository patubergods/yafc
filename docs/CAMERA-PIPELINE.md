# Camera pipeline

The rear camera is safety-critical. Use a known recovery method before changing this pipeline.
The observations below describe one radio and do not establish support for another build,
vehicle, or display. Composition and recovery are **UNPROVEN** unless identified otherwise.
See [SAFETY.md](SAFETY.md) before making changes.

## Evidence and scope

**Verified on a radio:** A read-only observation recorded the camera window and its properties.
The values below are a sample, not a specification for every boot or camera state.
**Host-verified:** Analysis of a camera executable identified window creation and post calls.
The executable analysis and the window observation need not describe the same binary revision.
A matching geometry does not prove that every runtime branch follows the same route.

## Observed Screen window

**Verified on a radio:** The read-only observation reported these values:

| Property | Observed value |
|---|---|
| Window name | `RVC_app` |
| Window size | 800 × 480 pixels |
| Window position | (0, 71) pixels |
| Source viewport | (0, 0, 720, 480) pixels |
| Buffer size | 720 × 1900 pixels |
| Format | UYVY |
| Z-order | 75 |
| Rotation | 90 degrees |
| Color space | BT.601 |
| Pipeline ID | 1 |

The source viewport selects one area within the buffer.
Rows outside that viewport are not thereby proven free or unused.
The displayed window size is not the writable source-buffer size.

**Host-verified:** The executable initially requests Z-order 50.
A later call can request 75; the observation alone does not prove why 75 was set.
The executable initially requests an invisible window.
**UNPROVEN:** The mechanism that later changes its visibility.

## Window creation and posting

**Host-verified:** The camera process creates a Screen context and a window.
It sets window properties including format, usage, buffer size, source size,
displayed size, position, and Z-order.
It creates one render buffer, retrieves its handle, and retrieves a buffer pointer.
It translates that pointer to a physical address and forwards the result twice
through a capture setup call.
This supports a direct-capture interpretation; it does not establish the hardware route.
An identified pixel-writing loop fills memory; it is not established as a frame copy.

**Host-verified:** Several call sites post one dirty rectangle with flags zero.
Two posts follow independent status tests after an interrupt wait.
Both tests can succeed in one loop iteration.
The rectangle uses geometry dimensions at those sites.
One additional post uses a global pair whose live values are **UNPROVEN**.
A dirty rectangle is not a source and destination rectangle pair.
The viewport and displayed geometry are separate window properties.

## Interposer

**Host-verified:** The library intercepts window creation and window posting.
It retains the Screen context and forwards posts to the real Screen function.
In `pass` it forwards posts without changing geometry.
In `diag` it attempts to log buffer size and stride, then forwards the post.
In `compose` it requests source and displayed geometry for the camera window.
An optional child window can show another region of the same shared buffer.
The compositor performs scaling; this version does not rewrite camera pixels.

**UNPROVEN:** Child-window creation, sharing, placement, and visibility on every target.
**UNPROVEN:** A successful post proves that a fresh or complete frame is visible.
If the real post cannot be resolved, forwarding cannot succeed.
A log entry is not a recovery mechanism.

## Configuration

The following table describes the supplied configuration and the interposer's
built-in initial values. Configuration behavior is **host-verified**, not a
promise of safety on a radio. Values use `x,y,width,height` for rectangles.
Source rectangles use buffer pixels; destination rectangles use screen pixels.

The library reads only the keys in the first table. The second table's keys belong to the HMI
fragments and the installer, and the library ignores them; one file has three consumers.

| Key | Meaning and units | Shipped value |
|---|---|---|
| `mode` | `pass`, `diag` or `compose` | `compose` |
| `view` | the view name the rectangles come from | `rear360` |
| `cam_src` | camera source rectangle, buffer pixels | `0,84,439,316` |
| `cam_dst` | camera destination rectangle, screen pixels | `0,0,800,518` |
| `bay_src` | bay source region, buffer pixels | `447,0,273,480` |
| `bay_dst` | bay rectangle, screen pixels; a zero width or height disables the bay | `0,522,456,718` |
| `bay_id` | set the child window's `ID_STRING` | `0` |
| `sen_dst` | reserved sensor rectangle; parsed but unused | empty |
| `tail_dst` | reserved trailer rectangle; parsed but unused | empty |
| `reread` | posts between configuration re-reads; `0` disables later reads | `1` |
| `stats` | `1` logs a post-rate line about every ten seconds | `0` |

| Key | Read by | Shipped value |
|---|---|---|
| `version` | installer | `1` |
| `enabled` | interposer (once, at camera start) and HMI | `1` |
| `layout` | installer | `stock` |
| `bay_360`, `bay_side`, `background` | HMI | `450`, `left`, `black` |

The interposer reads only its own keys (and `enabled`, once at camera start: `0` means stock); boot and interface settings have distinct consumers.
Its configured view is not proof of the actual incoming camera state.
An unreadable or oversized configuration can retain previous interposer state.
Do not assume that every invalid setting selects factory presentation.

## Views and combinations

**Verified on a radio:** Observed frames included rear-plus-360 and front-plus-360 views.
Other observed frames included a single-camera image across the source width.
The observed combined image placed the camera and bird's-eye regions side by side.
The observed single-camera images did not include a bird's-eye view.
These observations do not exclude other layouts on another vehicle or build.

**Host-verified:** The view policy distinguishes the two combined states
`IPMBRear360` and `IPMBFront360` from single, split, and trailer states.
A configured `rear` or `front` is not a combined-view request.
Split is not treated as a combined state for composition.
Unknown, trailer, zoom, and single-camera states must retain their full field of view.
A state name alone does not prove that its hardware is present.
The exact distinction between the plain and normal front or rear states is **UNPROVEN**.

**Verified on a radio:** One observed split image showed a stitched wide region and a blank region.
That observation does not establish what the blank region can show in other conditions.
**UNPROVEN:** A full-width single-camera image and a 360 image exist together in one frame.
A second window can only show available buffer content; it cannot create missing imagery.

## Safety and open questions

The following remain **UNPROVEN**, even when a pointer or a post is available:

- Buffer ownership and exclusive write access.
- Whether capture and display or other writers access the buffer concurrently.
- Actual stride and its relationship to any hardware register.
- Origin and direction of the observed rotation.
- Whether each post corresponds to one complete, fresh frame.
- Exact dirty-rectangle semantics and safe timing relative to capture completion.
- Which buffer rows capture uses, and whether any unused region exists.
- Cache coherence and safe reuse of shared buffers.
- Per-view crop boundaries, complete field of view, and safe front geometry.
- A coordinated return to factory video geometry and interface framing.

Never hide warnings, sensor indications, controls, or safety-relevant image content.
An apparently successful geometry change does not establish that the view is safe.
