# Troubleshooting

Start here when an install or uninstall did not do what you expected. YAFC is an unofficial hobby
project with no warranty and no support promise; this page is a guide, not a service. Read
[DISCLAIMER.md](DISCLAIMER.md) and [SAFETY.md](SAFETY.md) first.

## What you should see after plugging the stick in

The radio shows a short on-screen message within about two minutes of plugging the stick in. On
the one radio this has run on, an install took about 40 seconds to two minutes and an uninstall
about 25 seconds. Do not pull the drive before a message appears or two minutes have passed.

| Message on the radio screen | What it means | What to do |
|---|---|---|
| `YAFC installed. Restart SYNC (hold Power and Seek-Right) to finish.` | The install finished and its own checks passed. | Hold Power + Seek-Right about 10 seconds. Check the camera while parked. |
| `YAFC removed. Restart SYNC (hold Power and Seek-Right) to finish.` | The uninstall finished. The unit's own library is back and the overlay is gone. | Restart SYNC the same way. |
| `YAFC install failed. See yafc-install/install.log on the USB stick.` (or `remove`, `rehearse`, ...) | The request stopped. Most failures leave the unit untouched. | Do not plug the stick in again. Read the logs below, then open an issue. |
| `YAFC: no install or uninstall marker is armed on this USB stick, so nothing was changed.` | The stick was recognised but had nothing to do. The install marker is used up after a success. | Nothing is wrong. To install again, copy a fresh install zip onto the drive. |
| `YAFC refused: more than one marker is on this stick.` | Two `RUN-YAFC-*` files were present. | Delete all but one. Nothing was changed. |
| `YAFC refused: an earlier request on this stick did not finish.` | A `RUN-YAFC-*.running` file from an earlier failed run is still on the stick. It is kept on purpose as evidence. | Keep the logs, then use a fresh copy of the zip on a clean drive. |
| `YAFC refused: yafc-install.sh is missing from this stick.` | The zip was not copied completely. | Copy the whole zip contents to the drive root again. |

The message is a best-effort notice. If it does not appear, the logs on the stick still record
what happened, so check them. Whether the notice appears on every radio and firmware is
**UNPROVEN**; it was seen on one.

## Where the logs are

Everything is on the USB stick, in the folder `yafc-install/` at the stick root. Nothing is
uploaded anywhere, and the project collects no telemetry.

| File or folder | What it holds |
|---|---|
| `yafc-install/DONE` | One line per request that succeeded. Presence means success. |
| `yafc-install/FAILED` | The reason a request failed. Presence means failure. |
| `yafc-install/install.log` | The full timestamped log of every run, with each stage. This is the file to read first. |
| `yafc-install/request-<ID>/` | One folder per run. It holds that run's own `install.log` and, for installs, `probe.out` and `probe.err` (the loader check). |
| `yafc-install/seen.log` | One line each time the stick was plugged in, including when nothing was armed or a request was refused. |
| `RUN-YAFC-*.running` at the stick root | Left after a failure on purpose. It stops a half-finished request from repeating. Keep it. |

To read a run, find the request ID in `DONE` or `FAILED`, then open the matching folder.
The `can't open config file: /etc/openssl/openssl.cnf` warnings in the log are harmless noise from
the radio's hashing tool.

## What to try, and what not to

- **Do not plug the stick in again and again.** A failed request keeps its `.running` marker, so
  later insertions do nothing. See [EASY-INSTALL.md](EASY-INSTALL.md) for the one-shot rule.
- **After a failure,** read `install.log`. If it says the slot library may have been written,
  arm `RUN-YAFC-RECOVER` on a **fresh** stick (see [RECOVERY.md](RECOVERY.md)).
- **If the picture is wrong and you want the factory camera back,** use the uninstall zip, or arm
  `RUN-YAFC-DISABLE`, then restart SYNC.
- **If the unit misbehaves,** a soft reset (hold Power + Seek-Right about 10 seconds) restores
  the boot layering.

## Report a problem

Open an issue at <https://github.com/patubergods/yafc/issues/new/choose> and pick **Bug report**.
Attach the whole `yafc-install` folder from the USB stick, zipped. Say:

- which zip you used (install or uninstall) and its version;
- your vehicle, model year and screen size, and what the radio's software version is if you know it;
- what message, if any, appeared on the screen and about how long after you plugged the stick in;
- what you expected, and what you saw instead.

If the installer refuses an unknown stock slot, include the `observed SHA-256` from `FAILED`
or `install.log`. It identifies the library build; it does not establish compatibility.

Before you attach anything, skim the files. The installer logs hold file names, hashes and mount
lists and no personal data that we know of, but you are the one sharing them. Do **not** post
photos or screenshots that show your VIN, licence plate, phone, or Wi-Fi details.

No email address is published for this project. Use the issue form. If a report must stay
private because it describes a security problem, use GitHub's **Report a vulnerability** option
on the repository's Security tab, described in [../SECURITY.md](../SECURITY.md).
