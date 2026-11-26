YAFC payload
============

Everything the installer puts on the unit comes from files the unit already has,
plus what is in this repository. No vendor binary is shipped and no vendor file is
modified in place: the installer makes the preserved copy of the radio's own
library on the unit itself. See ../docs/INSTALL.md.

The rear camera is safety-critical. A missing or incorrect picture can make it
unusable; never rely on this mod for safe maneuvering. Anything not labelled
otherwise in this repository is UNPROVEN on a radio.

What the installer writes
-------------------------

libyafc.so is placed in the camera's link path under the name the camera expects,
libRCN_DiagnosticsLib.so, inside the writable base partition. The radio's own
library is first copied to a second name in the same directory, so every other
process that uses that slot keeps resolving the original functions. On the
developer's 2020 Explorer ST, fullscreen rear video appeared before SYNC finished
starting; the 360 view, parking sensors and view buttons appeared later. This
packaged installer has not been run on a radio. See docs/ARCHITECTURE.md for
details about the early video path and docs/CAMERA-PIPELINE.md for the geometry.

The installer seeds /fs/rwdata/yafc/camera.conf if absent and preserves existing
settings. The DISABLE file in the same directory makes the library stand down on
the next camera process start, and the popup keeps the stock controls and layout.
Restart the unit after setting it: see ../docs/RECOVERY.md.

hmi/ holds the on-screen edits as fragments: our code plus short anchor strings,
applied to the radio's own HMI files by tools/apply-hmi-fragments.sh. No Ford QML
is redistributed. The installer builds them into /fs/images/overlay_00--yafc.img;
RUN-YAFC-REMOVE-HMI deletes that image alone. See ../docs/HMI-PATCH.md.

What used to be here
--------------------

An earlier version of this mod started a replacement camera process from a boot
hook and patched the camera binary's window height in place. Both are gone. The
boot hook replaced the factory process, which stripped it of the session
ownership the factory visibility manager and the vehicle bus registration depend
on: the picture could not be trusted and the camera stopped reacting to the gear.
The byte patch was build-specific and fragile. The library slot replaced both.
There is no boot hook file in this repository any more.
