# Easy install

> **WARNING - read this first.** YAFC is an unofficial, free hobby project, given as is with
> **no warranty, express or implied**, and **no support**. It may brick the unit or show a wrong
> or missing camera picture. The people who made it are not responsible for accidents, damage,
> injury or a voided warranty. Use it **off-road, parked or on a closed course only**, and never
> rely on it to decide whether it is safe to move. If you do not agree with this, do not use it.
> The full text is in [DISCLAIMER.md](DISCLAIMER.md) on GitHub.

This page is the short version: download a file, put it on a USB drive, plug it in. You do not
need a build, a terminal or a laptop that can talk to the car.

**Read this before you start.** The YAFC design has been used only on the developer's 2020
Explorer ST. This packaged installer has **not been run on a radio**; its checks were run on a
computer. The rear camera is safety-critical: a failure can obscure or interrupt it. Install
only while parked, and use it at your own risk.

## Before you begin

- A **Ford SYNC 3 radio that already has the FMods jailbreak and installer**
  ([fmods.net](https://www.fmods.net/)). YAFC does not install the jailbreak and does nothing
  without it. The jailbreak's USB hook starts YAFC when you plug in the drive.
- A **USB flash drive** of the kind and format you already use with FMods. YAFC does not require
  its own format. **Formatting erases the drive.** Back up your files and check the drive's
  name and size before formatting.
- The car parked in an open area, brake held, ignition on and SYNC running.
- The install zip and the uninstall zip. Keep the uninstall zip available in case you need it.

## Which file to use

Get the install and uninstall zip for the same version from
[GitHub Releases](https://github.com/patubergods/yafc/releases).

| File | What it does |
|---|---|
| `YAFC-<version>-install.zip` | Installs the camera library and HMI overlay. The camera layout and controls change. |
| `YAFC-<version>-uninstall.zip` | Removes the HMI overlay and restores the car's own camera library if the installer preserved a copy. |

## Install

1. **Put the install files on the drive.** Unzip the install zip and copy **everything inside**
   to the top level of the USB drive, not a folder on it.
   - **Windows:** Right-click the zip, choose **Extract All**, then copy the extracted contents.
   - **Mac:** Double-click the zip, then copy the extracted contents.

   The drive should contain `SyncMyMod`, `yafc-install.sh`, `yafc-payload`, `tools`,
   `START-HERE.txt` and `RUN-YAFC-INSTALL`. Wait for copying to finish before ejecting the drive.
2. Park the car, switch the ignition on and wait for SYNC to finish starting.
3. Plug the drive in and **leave it alone**. The radio does the work. How long this takes is
   **UNKNOWN** - nobody has measured it, so there is no number to wait for. Do not pull the drive
   out while it is working.
4. Confirm `yafc-install/DONE` on the stick. If it says `FAILED`, read the log before trying again.
5. Restart SYNC once: hold **Power + Seek-Right** for about 10 seconds. Check the camera while parked.

## How to tell whether it worked

Look on the USB drive:

- `yafc-install/DONE` - it finished and its own checks passed.
- `yafc-install/FAILED` - it stopped. `yafc-install/install.log` says why and what was left in
  place. `HMI only` means the slot passed its probe but the new overlay was not published.

## If it fails

**Do not re-plug the drive again and again.** A request is one-shot. Before the installer starts,
the marker is renamed to `RUN-YAFC-INSTALL.running`, and it is deleted only when the installer
succeeded. A failed stick keeps the `.running` file, so every later insertion does nothing at all.
That is deliberate: it stops a half-finished install from being repeated on every plug.

So after a failure: read `install.log` and do not re-plug. To try again, delete
`RUN-YAFC-INSTALL.running` from the drive (or unzip a fresh copy of the file) and start over at
step 1. If the radio is not behaving, a soft reset - hold **Power + Seek-Right** for about 10
seconds - restores the boot layering.

## Uninstall

Unzip `YAFC-<version>-uninstall.zip` onto a clean drive, not over the install files, and follow
the same steps. The uninstall request is `RUN-YAFC-REMOVE`. It deletes the HMI overlay, restores
the car's own library if the preserved copy exists, and removes that copy. Restart SYNC to
reload the stock files.

## If the picture is wrong and you want it back now

Use the uninstall file. The kill switch also turns YAFC off without removing it. Arm
`RUN-YAFC-DISABLE` or create `/fs/rwdata/yafc/DISABLE` in the jailbreak's shell, then restart
SYNC. See [RECOVERY.md](RECOVERY.md) for details and HMI-only removal.

## Questions

**What does it change?** It installs one camera library, seeds a configuration if missing, and
builds an HMI overlay from the radio's own files. The overlay changes the camera controls and
adds preferences to Camera Settings.
Use the rear camera's plus button to open **Zoomed View**, and the minus button to return to
Rear Only.

**What appears when SYNC starts?** On the development vehicle, fullscreen rear video appeared
early, before SYNC finished starting. The 360 view, parking sensors and view-selection buttons
appeared later as the interface loaded. That timing has not been established on other vehicles
or with this packaged installer.

**Can I undo it?** Yes. The uninstall file removes the overlay and restores the library when
the saved copy exists. The kill switch stands both changes down after restart.

**Does it touch the rear camera safety path?** It changes the picture placement and what the
camera popup draws around it. Do not rely on it while maneuvering.

**What USB drive and format?** The same type of drive the jailbreak already works with, freshly
formatted. No special format is needed or documented.

**Is it tested?** The design was used on one 2020 Explorer ST. The packaged installer has
not been run on a radio. See [TESTING.md](TESTING.md) for the host checks and what remains unproven.

**Where do I get help?** Send `yafc-install/install.log` and say which file you used. Nobody can
tell you what went wrong from "it did not work".