# HMI fragments

These files hold the HMI edits that YAFC applies to your own copy of four Ford QML files. They contain our code and short anchor strings only. They contain no Ford file. The directory also holds YAFC's own Hero icon artwork under `icons/`, described below. The full description is in [../../docs/HMI-PATCH.md](../../docs/HMI-PATCH.md).

`tools/apply-hmi-fragments.sh` (POSIX sh and awk) reads the `*.fragment` files. The installer requires the complete set and applies it only to copies of the unit's stock HMI. The applier refuses a missing or duplicate anchor and leaves that target unedited. Host tests use synthetic stock-like files; the public fragments have not been applied to an actual radio.

## Format

A fragment starts with `# `-prefixed header lines and ends the header with `# end-header`. Everything after it is the body.

```
# yafc-fragment v1
# id: <name>
# target: <path under the HMI root>
# edit: replace | append-after
# find: <text>          (replace)
# replace: <text>       (replace)
# anchor: <text>        (append-after)
# end-header
<body>
```

The file name must be `<id>.fragment`, and `append-after` needs a nonblank body.

- `replace` swaps exactly one matching line. It does nothing when the identical replacement line is already present.
- `append-after` inserts the body after the line that holds `anchor`. It does nothing when the body is already present.
- Fragments for one target apply in `id` order.
- `find` and `anchor` match whole lines, ignoring surrounding spaces and tabs and a trailing carriage return.

## Files

| Fragment | Target (under the HMI root) | Edit |
|---|---|---|
| `popup-height` | `themes/ford-10P-MY20/styles/RVCPopupStyle.qml` | add a 1208-pixel YAFC height without replacing the stock height |
| `popup-1-state` | `hmirvc/+10inchP/RVCPopup.qml` | YAFC state, per-view table, RAM-mailbox publish, select/commit/reconcile, cover and zoom-sync functions |
| `popup-2-visible` | `hmirvc/+10inchP/RVCPopup.qml` | route the stock visibility handler through `yafcVisibleChanged()` |
| `popup-3-top` | `hmirvc/+10inchP/RVCPopup.qml` | drop the status-bar gap when bars are hidden |
| `popup-4-margin` | `hmirvc/+10inchP/RVCPopup.qml` | drop the navigation-bar gap when bars are hidden |
| `popup-5-root` | `hmirvc/+10inchP/RVCPopup.qml` | timers, black fill, `Please wait...` cover, sensor bay, second sensor image, bottom safety text |
| `popup-6-items` | `hmirvc/+10inchP/RVCPopup.qml` | view opener, stock-icon selector row, Zoomed View plus and minus |
| `popup-7-text-anchor` | `hmirvc/+10inchP/RVCPopup.qml` | release the bottom strip's top anchor only in YAFC mode |
| `popup-8-text-margin` | `hmirvc/+10inchP/RVCPopup.qml` | adjust the stock safety string's margin only in YAFC mode |
| `settings-1-state` | `hmisettings/driverassistance/+10inchP/RVCSettings.qml` | state, config read and merge-save |
| `settings-2-rows` | `hmisettings/driverassistance/+10inchP/RVCSettings.qml` | enable, hide-bars, default rear view and default front view rows |
| `chrome-hide-1-property` | `+10inchP/Root.qml` | `yafcCamFull` property |
| `chrome-hide-2-statusbar` | `+10inchP/Root.qml` | hide the status bar |
| `chrome-hide-3-menubar` | `+10inchP/Root.qml` | hide the navigation bar |
| `chrome-hide-4-transient` | `+10inchP/Root.qml` | stop transients from restoring a bar |
| `chrome-hide-5-tiles` | `+10inchP/Root.qml` | hide message tiles |

The popup uses `file:///fs/rwdata/yafc/camera.conf`, `file:///fs/rwdata/yafc/DISABLE`, the session file `file:///fs/tmpfs/yafc-session`, and the RAM mailbox `file:///fs/tmpfs/yafc-view`. While shown it renews the mailbox record every 100 ms, and it keeps renewing Zoomed View while Ford's report differs. The native holds a published layout until a newer record replaces it, the session changes, `DISABLE` is set, or the popup writes a `compose=0` record; on hide it writes that record. Restart after changing the kill switch so the native library and the HMI both start in stock mode.

## Hero view icon

The Hero selector artwork is YAFC's own, not a Ford file and not a derivative of
one: a camera body inside a 360 orbit, 50x50 RGBA, day and night, five states
each. The files live under `icons/<theme>/50x50/parkingfeatures/` in this
directory.

| iconId | Files |
|---|---|
| `parkingfeatures/icon_hero_view` | `icon_hero_view_active.png`, `_activepressed`, `_inactive`, `_selected`, `_selectedpressed` |

`IconPushButton` appends the state suffix itself and resolves the id under
`themes/ford-10P-MY20/icons/<theme>/50x50/` on the unit. The installer requires
all ten files, verifies each against `yafc-payload/SHA256SUMS`, stages them into
the HMI image and reads them back. Another overlay that provides or obscures one
of these paths is refused.

The selector fragments now name `parkingfeatures/icon_hero_view` for Hero, so the
artwork is in use. On the one 2020 Explorer ST the owner saw the Hero icon after the
2026-11-27 install; other firmware is UNPROVEN.

## Rules for new fragments

- Write only our own QML. Prefix every identifier with `yafc`.
- Copy `find` and `anchor` text from the stock file. It must occur exactly once.
- Never put a Ford line in a body, and never ship a whole Ford file.
- Make a `replace` idempotent: the replacement line must differ from the exact line it replaces.
