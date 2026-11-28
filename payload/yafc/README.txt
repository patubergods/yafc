YAFC payload
============

The installer uses files already on the radio plus this payload. No vendor
binaries are shipped. For the installation steps and prerequisites see:
https://github.com/patubergods/yafc/blob/main/docs/INSTALL.md

The rear camera is safety-critical. A missing or incorrect picture can make it
unusable; never rely on this mod for safe maneuvering. Anything not labelled
otherwise in this repository is UNPROVEN on a radio.

What the installer writes
-------------------------

The installer preserves the radio's own library under a second name and puts
libyafc.so at the path the camera expects, as libRCN_DiagnosticsLib.so. It
checks the installed pair with slotprobe. The USB copy of slotprobe is data:
the installer verifies and stages it in RAM before making it executable.

Install is all-or-nothing. The slot library is written only after the journal
is persisted. A failure before the slot write (exit 8/9/10) leaves the slot
untouched. A failure after the slot write rolls back to the journaled previous
library bytes, or retains the journal for RUN-YAFC-RECOVER. There is no
"library installed but HMI not published" state.

On the developer's 2020 Explorer ST, fullscreen rear video appeared before
SYNC finished starting. The 360 view, parking sensors and view buttons
appeared later. On that one radio the packaged installer was run: install,
uninstall and reinstall all completed, and the owner saw the views, the view
selector, Zoomed View, the Hero icon and the "Please wait" cover work. Every
other vehicle and firmware is UNPROVEN.
https://github.com/patubergods/yafc/blob/main/docs/ARCHITECTURE.md
https://github.com/patubergods/yafc/blob/main/docs/CAMERA-PIPELINE.md

On-screen notices
-----------------

Both the dispatcher and the worker show a message on the radio through the
utserviceutility popup, best effort and bounded to 5 seconds. It never changes
the outcome. Expect a success, failure or no-marker message within about two
minutes of plugging the drive in. The text file is /fs/tmpfs/yafc-popup.txt.
Whether the text appears on every radio is UNPROVEN beyond the one radio.

Logs and reporting a problem
----------------------------

Everything is in the folder yafc-install/ at the root of the USB drive: DONE
(success receipt lines), FAILED (failure receipt with the reason),
install.log (full timestamped log), request-<ID>/ (one folder per run with its
own install.log, probe.out, probe.err, and DONE or FAILED), and seen.log (one
line per plug-in). "stick seen; no marker, nothing done" means the drive was
noticed but no marker was armed, so nothing changed; the install marker is
used up after a success, so re-arm by copying a fresh install zip.

YAFC does not upload logs or collect telemetry. To report a problem, open an
issue at https://github.com/patubergods/yafc/issues/new/choose and attach the
whole yafc-install folder zipped, plus which zip and version and the
vehicle/radio. Do not post photos that show the VIN or other personal data.
https://github.com/patubergods/yafc/blob/main/docs/TROUBLESHOOTING.md

The installer seeds /fs/rwdata/yafc/camera.conf if absent and preserves existing
settings. The DISABLE file in the same directory tells the library to stand
down on the next camera process start. It cannot repair a missing required
library. Preserve the stick and logs after a failure; do not retry the request.
https://github.com/patubergods/yafc/blob/main/docs/RECOVERY.md

RUN-YAFC-RECOVER
----------------

On a fresh stick, recovers from an interrupted install or remove. It restores
the journaled previous library bytes, preserved copy, HMI image, and ownership
record, then replays the recorded mount order. Refuses when the journal does
not authenticate, a file digest differs, or a layer is busy.

One unowned stock
-----------------

Only the one recorded stock build of libRCN_DiagnosticsLib.so is accepted as
an unowned slot. Other firmware or units are refused until their stock digest
is independently verified. An existing preserved copy is never adopted.

Session and ready
-----------------

The camera library writes /fs/tmpfs/yafc-session (PID.monotonic_sec.nsec) at
start. The HMI popup reads it on entry and prefixes every mailbox record to
/fs/tmpfs/yafc-view with <session><seq>;<compose>;<16 rects>. The library
echoes the accepted record in /fs/tmpfs/yafc-ready after a successful Screen
post with verified geometry. The popup composes only after two advancing ready
replies.

Limits: a ready file proves the post and geometry acceptance by the compositor,
not displayed pixels or a painted late bay. QML timer stalls are not detected
by the native; LEASE_MS only gates the ready file. A published layout holds
until a newer record replaces it, the session changes, DISABLE is set, or the
popup writes compose=0. scale_quality (Screen property 56) is 2 by default,
0 sends nothing, 1 is fastest.

Unproven QNX behaviours
-----------------------

The following are UNPROVEN on a radio: the DL_DEBUG=libs loader trace format,
dladdr paths for GOT symbols, the -o before mount flag ordering, file-image
mount listing (mount output for loopback-backed images), the second read-only
inspection mount, and busy layers after a restart.

Overlay refusal
---------------

Before any write, the installer inspects every other overlay*.img under
/fs/images. Each is mounted read-only. If any provides or obscures a YAFC
target path, the installer refuses. An overlay that shadows YAFC cannot be
installed beside it.

Per-request receipts
--------------------

Each receipt is in a request-specific directory under yafc-install/request-<id>/.
The .running marker carries a unique request ID and is consumed only when DONE
is written. An old receipt never passes for the current request.

hmi/ holds the on-screen edits as fragments: our code plus short anchor strings,
applied to the radio's own HMI files by tools/apply-hmi-fragments.sh. No Ford QML
is redistributed. It also holds YAFC's own Hero icon artwork under hmi/icons/
(ten 50x50 PNGs: day and night, five states); the installer verifies and reads
back both. The installer builds them into /fs/images/overlay_00--yafc.img.
https://github.com/patubergods/yafc/blob/main/docs/HMI-PATCH.md

What used to be here
--------------------

An earlier version of this mod started a replacement camera process from a boot
hook and patched the camera binary's window height in place. Both are gone. The
boot hook replaced the factory process, which stripped it of the session
ownership the factory visibility manager and the vehicle bus registration depend
on: the picture could not be trusted and the camera stopped reacting to the gear.
The byte patch was build-specific and fragile. The library slot replaced both.
There is no boot hook file in this repository any more.
