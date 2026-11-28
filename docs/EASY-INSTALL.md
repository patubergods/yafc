# Easy install

> **WARNING - read this first.** YAFC is an unofficial, free hobby project, given as is with
> **no warranty, express or implied**, and **no support**. It may brick the unit or show a wrong
> or missing camera picture. The people who made it are not responsible for accidents, damage,
> injury or a voided warranty. Use it **off-road, parked or on a closed course only**, and never
> rely on it to decide whether it is safe to move. If you do not agree with this, do not use it.
> The full text is in [DISCLAIMER.md](DISCLAIMER.md) on GitHub.

This page is the short version: download a file, put it on a USB drive, plug it in. You do not
need a build, a terminal or a laptop that can talk to the car.

**Read this before you start.** YAFC is an unfinished community project. The design was developed
and tested on the developer's **2020 Ford Explorer ST** with the 10-inch portrait screen. On that
one radio the packaged installer was run: install, uninstall and reinstall all completed, and the
owner saw every front and rear view, the view selector, Zoomed View, the Hero icon and the
"Please wait" cover behave correctly. That is **verified on one radio**. It is still one vehicle,
one radio and one firmware: every other vehicle is **UNPROVEN**. The rear camera is
safety-critical: a failure can obscure or interrupt it. Install only while parked and at your own
risk. Keep the uninstall zip handy.

## Before you begin

Check every line. If one is missing, stop.

- **A Ford SYNC 3 radio with the FMods jailbreak, USB installer and FMods Tools already set up**
  ([fmods.net](https://www.fmods.net/)). YAFC does not install any of them. The FMods USB hook
  starts YAFC when you plug in the drive. No fullscreen CarPlay or Android Auto mod is required.
- **A USB flash drive with an MBR partition table, formatted exFAT or FAT32.** SYNC refuses a
  drive whose partition table is GPT, with its own "USB not supported" message, before YAFC runs.
  On Windows, `Get-Disk` shows the style: it must read `MBR`. A `GPT` drive has to be
  repartitioned as MBR, which erases it. Use the kind of drive and format you already use with
  FMods if that works for you. **Formatting or repartitioning erases the drive.** Back up your
  files and check the drive's name and size first.
- **The car parked in an open area, brake held, ignition on and SYNC running.**
- **The install and uninstall zips.** Keep the uninstall zip available in case you need it.

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
   `START-HERE.txt` and `RUN-YAFC-INSTALL`. Wait for copying to finish, then safely eject the
   drive before unplugging it.
2. Park the car, switch the ignition on and wait for SYNC to finish starting.
3. Plug the drive in and **leave it alone**. The radio does the work. Within about two minutes the
   radio should show a message: success, failure, or that no marker is armed. Do not pull the
   drive out before a message appears or two minutes pass.
4. Then confirm `yafc-install/DONE` or `yafc-install/FAILED` on the stick. If it says `FAILED`,
   read the log before trying again.
5. Restart SYNC once: hold **Power + Seek-Right** for about 10 seconds. Check the camera while parked.

## How to tell whether it worked

First, the radio screen. Within about two minutes of plugging the drive in you should see one
message: a success line, a failure line, or a line saying that no install or uninstall marker is
armed on this stick. If no message appears at all, the logs on the stick still say what happened.

Then look on the USB drive:

- `yafc-install/DONE` - it finished and its own checks passed.
- `yafc-install/FAILED` - it stopped. `yafc-install/install.log` says why and what was left in
  place. The slot library is never written without the HMI overlay being published: install
  is all-or-nothing. A failure before the slot write leaves the slot untouched; a failure
  after the slot write rolls back to the journaled previous library bytes.

### Where the logs are

Everything is in the folder `yafc-install/` at the root of the USB drive:

- `DONE` - success receipt lines, one per successful request.
- `FAILED` - the failure receipt with the reason.
- `install.log` - the full timestamped log of every run.
- `request-<ID>/` - one folder per run, with its own `install.log`, `probe.out`, `probe.err`,
  and `DONE` or `FAILED`.
- `seen.log` - one line per plug-in, including when nothing was armed or a request was refused.

`stick seen; no marker, nothing done` in `seen.log` means the drive was noticed but no marker was
armed, so nothing changed. The install marker is used up after a success, so plugging the same
drive in again does nothing until you arm a marker again: copy a fresh install zip to the drive.

## If it fails

**Do not re-plug the drive again and again.** A request is one-shot. Before the installer starts,
the marker is renamed to `RUN-YAFC-INSTALL.running`, and it is deleted only when the installer
succeeded. A failed stick keeps the `.running` file, so every later insertion does nothing at all.
That is deliberate: it stops a half-finished install from being repeated on every plug.

So after a failure: read `install.log` and do not re-plug. Most failures leave the slot
untouched, but if the failure happened after the slot was written and before the journal was
settled, the previous library bytes may be the journaled ones. To check, arm
`RUN-YAFC-RECOVER` on a fresh stick. The recover mode restores the journaled previous state only
when every file and record authenticates; it refuses otherwise.

To try again from the start, delete `RUN-YAFC-INSTALL.running` from the drive (or unzip a fresh
copy) and start over at step 1. If the radio is not behaving, a soft reset — hold **Power +
Seek-Right** for about 10 seconds — restores the boot layering.

## Uninstall

Repeat the install steps with `YAFC-<version>-uninstall.zip` on a clean drive, not over the
install files. Look for `RUN-YAFC-REMOVE` instead of `RUN-YAFC-INSTALL`. The uninstall deletes
the HMI overlay and, if the preserved copy of the car's own library exists, restores the
library and removes that copy. Confirm `yafc-install/DONE`, then restart SYNC to reload the
stock files. To remove only the overlay and keep the library, use `RUN-YAFC-REMOVE-HMI`. If a
remove was interrupted, use `RUN-YAFC-RECOVER` on a fresh stick to restore the journaled state.

## If the picture is wrong and you want it back now

Use the uninstall file. The kill switch also turns YAFC off without removing it. Arm
`RUN-YAFC-DISABLE` or create `/fs/rwdata/yafc/DISABLE` in the jailbreak's shell, then restart
SYNC. See [RECOVERY.md](RECOVERY.md) for details and overlay-only removal.

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

**What USB drive and format?** Use the same type of drive and format that already work with
FMods (see "Before you begin"). YAFC has no format of its own.

**Is it tested?** The packaged installer was run on one 2020 Explorer ST: install, uninstall and
reinstall all completed, and the owner saw the views, the view selector, Zoomed View, the Hero icon
and the "Please wait" cover work. That is **verified on one radio**. Every other vehicle and
firmware is **UNPROVEN**. See [TESTING.md](TESTING.md) for the host checks and what remains
unproven.

**Where do the logs go?** Into the folder `yafc-install/` on the USB drive: `DONE`, `FAILED`,
`install.log`, `request-<ID>/` and `seen.log`. YAFC does not upload logs or collect telemetry. If
you ask for help, share that folder yourself and say which zip you used.

## Getting help

Open an issue at <https://github.com/patubergods/yafc/issues/new/choose> and attach the whole
`yafc-install` folder zipped, plus which zip and version you used and the vehicle and radio. Skim
the logs before attaching: they hold hashes, file names and mount lists, and no known personal
data, but check that no photo or note of yours shows a VIN or other personal detail. For what is
still unproven and how to read the receipts, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).