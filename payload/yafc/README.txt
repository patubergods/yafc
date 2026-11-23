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
process that uses that slot keeps resolving the original functions. See
../docs/ARCHITECTURE.md for why that is what makes the picture appear early, and
../docs/CAMERA-PIPELINE.md for the geometry.

camera.conf is the configuration. The library re-reads it live. A copy
belongs at /fs/rwdata/yafc/camera.conf on the unit. The kill-switch file
/fs/rwdata/yafc/DISABLE makes the library refuse to act, which is the fast way
back to the factory picture: see ../docs/RECOVERY.md.

hmi/ holds the on-screen edits as fragments: our code plus short anchor strings,
applied to the radio's own HMI files by tools/apply-hmi-fragments.sh. No Ford QML
is redistributed. See ../docs/HMI-PATCH.md.

What used to be here
--------------------

An earlier version of this mod started a replacement camera process from a boot
hook and patched the camera binary's window height in place. Both are gone. The
boot hook replaced the factory process, which stripped it of the session
ownership the factory visibility manager and the vehicle bus registration depend
on: the picture could not be trusted and the camera stopped reacting to the gear.
The byte patch was build-specific and fragile. The library slot replaced both.
There is no boot hook file in this repository any more.
