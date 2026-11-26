# Easy install

> **WARNING - read this first.** YAFC is an unofficial, free hobby project, given as is with
> **no warranty, express or implied**, and **no support**. It may brick the unit or show a wrong
> or missing camera picture. The people who made it are not responsible for accidents, damage,
> injury or a voided warranty. Use it **off-road, parked or on a closed course only**, and never
> rely on it to decide whether it is safe to move. If you do not agree with this, do not use it.
> The full text is in [DISCLAIMER.md](DISCLAIMER.md) on GitHub.

This page is the short version: download a file, put it on a USB drive, plug it in. You do not
need a build, a terminal or a laptop that can talk to the car.

**Read this before you start.** YAFC is an unfinished community project. The design has been
used on the developer's own vehicle, but this packaged installer has **not yet been run on a
unit** - its checks were run on a normal computer. The rear camera is safety-critical: a failure can obscure or interrupt it. Install only
while parked, and use it at your own risk. There is an undo, and it is on this page.

## Before you begin

Check every line. If one is missing, stop.

- **A Ford SYNC 3 radio that already has the FMods jailbreak and installer** ([fmods.net](https://www.fmods.net/)).
  YAFC does not install the jailbreak and does nothing without it. The jailbreak's USB hook is
  what starts YAFC when you plug the drive in.
- **A USB flash drive.** Use the kind of drive and the format you already use with the jailbreak.
  Other SYNC 3 mod pages call for **exFAT**, and Ford's own SYNC update guide describes formatting
  a drive the same way; YAFC has no format of its own, so follow what works for FMods today.
  The YAFC files are small (about 75 KB). **Formatting erases the drive.** Back up what you want
  to keep and check the drive's name and size before you format it.
- **The car parked in an open area, the brake held, ignition on, SYNC running.**
- **The files from this page:** the install zip, and keep the uninstall zip handy.

## Which file to use

| File | What it does |
|---|---|
| `YAFC-<version>-install.zip` | Installs YAFC for real. The picture changes. |
| `YAFC-<version>-uninstall.zip` | Puts the car's own camera part back and forgets YAFC. |

## Install

1. **Put the files on the drive.** Unzip the file, then copy **everything inside it** to the
   top level of the USB drive - the drive itself, not a folder on it.
   - *Windows:* right-click the zip, **Extract All**, open the result, copy its contents to the drive.
   - *Mac:* double-click the zip, open the result, copy its contents to the drive.
   Wait until copying finishes, then **eject the drive safely** before you unplug it. You should
   end up with `SyncMyMod`, `yafc-install.sh`, `yafc-payload`, `tools`,
   `START-HERE.txt` and one file called `RUN-YAFC-INSTALL` on the drive.
2. Park the car, switch the ignition on and wait for SYNC to finish starting.
3. Plug the drive in and **leave it alone**. The radio does the work. How long this takes is
   **UNKNOWN** - nobody has measured it, so there is no number to wait for. Do not pull the drive
   out while it is working.
4. Restart SYNC once: hold **Power + Seek-Right** for about 10 seconds.
5. Look at the camera.

## How to tell whether it worked

Look on the USB drive:

- `yafc-install/DONE` - it finished and its own checks passed.
- `yafc-install/FAILED` - it stopped. `yafc-install/install.log` says why and what was left in
  place. Send that log to whoever gave you the file.

## If it fails

**Do not re-plug the drive again and again.** A request is one-shot. Before the installer starts,
the marker is renamed to `RUN-YAFC-INSTALL.running`, and it is deleted only when the installer
succeeded. A failed stick keeps the `.running` file, so every later insertion does nothing at all.
That is deliberate: it stops a half-finished install from being repeated on every plug.

So after a failure: read `install.log`, send it, and do not re-plug. To try again, delete
`RUN-YAFC-INSTALL.running` from the drive (or unzip a fresh copy of the file) and start over at
step 1. If the radio is not behaving, a soft reset - hold **Power + Seek-Right** for about 10
seconds - restores the boot layering.

## Uninstall

Unzip `YAFC-<version>-uninstall.zip` onto the drive and follow the same four steps. The car's own
camera library is put back and the copy YAFC kept is deleted. The picture returns to how the car
shipped.

## If the picture is wrong and you want it back now

Use the uninstall file. There is also a kill switch that turns YAFC off without removing it, but
it is written on the radio itself (`/fs/rwdata/yafc/DISABLE`) and needs the jailbreak's shell. If
you cannot do that, the uninstall file is the way.

## Questions

**What does it change?** One library in the camera's part of the radio, plus a small
configuration file. It does not change the menus or the on-screen buttons.

**Can I undo it?** Yes. The uninstall file restores the car's own library. The kill switch turns
the picture change off without removing anything.

**Does it touch the rear camera safety path?** It changes **how the camera picture is placed** on
the screen. The factory library is kept beside YAFC's and is put back by the uninstall, and the
kill switch exists for the picture alone. **UNPROVEN on a real unit:** the design has been used on
the developer's own vehicle, but this packaged installer has not yet been run on another unit, so
do not rely on the camera while maneuvering.

**What USB drive and format?** The same drive and format the jailbreak already works with for you
(see "Before you begin"). No special format of our own.

**Is it tested?** The design has been used on the developer's own vehicle. This packaged installer has
not yet been run on a unit; what is checked is listed in [TESTING.md](TESTING.md) and is
**host-verified** - a computer, not a radio.

**Where do I get help?** Send `yafc-install/install.log` and say which file you used. Nobody can
tell you what went wrong from "it did not work".