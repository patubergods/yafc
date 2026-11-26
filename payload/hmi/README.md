# HMI fragments

These files hold the HMI edits that YAFC applies to your own copy of four Ford QML files. They contain our code and short anchor strings only. They contain no Ford file. The full description is in [../../docs/HMI-PATCH.md](../../docs/HMI-PATCH.md).

`tools/apply-hmi-fragments.sh` (POSIX sh and awk) reads every `*.fragment` file in this folder. The installer runs it on the radio against copies of the radio's own HMI files. **Host-verified:** every `find` and `anchor` string below occurs exactly once in one stock-like copy of the four files, and the full set applies to a synthetic stock-like tree with balanced output. **UNPROVEN:** the same text occurs in any other firmware, and the public fragments have never been applied to a radio. The patcher refuses when an anchor is missing or occurs twice, and it leaves that file unedited.

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

- `replace` swaps the one occurrence of `find`. It does nothing when `replace` is already present. No `replace` text contains its `find` text, so a second run changes nothing.
- `append-after` inserts the body after the line that holds `anchor`. It does nothing when the body is already present.
- Fragments for one target apply in `id` order.
- Matching is a substring match on file text. Indentation is not part of a `find` or `anchor`.

## Files

| Fragment | Target (under the HMI root) | Edit |
|---|---|---|
| `popup-height` | `themes/ford-10P-MY20/styles/RVCPopupStyle.qml` | popup height `480` to `1208` |
| `popup-1-state` | `hmirvc/+10inchP/RVCPopup.qml` | YAFC state, per-view table, RAM-mailbox publish, select/commit/reconcile, cover and zoom-sync functions |
| `popup-2-visible` | `hmirvc/+10inchP/RVCPopup.qml` | route the stock visibility handler through `yafcVisibleChanged()` |
| `popup-3-top` | `hmirvc/+10inchP/RVCPopup.qml` | drop the status-bar gap when bars are hidden |
| `popup-4-margin` | `hmirvc/+10inchP/RVCPopup.qml` | drop the navigation-bar gap when bars are hidden |
| `popup-5-root` | `hmirvc/+10inchP/RVCPopup.qml` | timers, black fill, `Please wait...` cover, sensor bay, second sensor image, bottom safety text |
| `popup-6-items` | `hmirvc/+10inchP/RVCPopup.qml` | view opener, stock-icon selector row, Trailer plus and minus |
| `popup-7-text-anchor` | `hmirvc/+10inchP/RVCPopup.qml` | anchor the stock safety string to the bottom |
| `popup-8-text-margin` | `hmirvc/+10inchP/RVCPopup.qml` | give that string a bottom margin |
| `settings-1-state` | `hmisettings/driverassistance/+10inchP/RVCSettings.qml` | state, config read and merge-save |
| `settings-2-rows` | `hmisettings/driverassistance/+10inchP/RVCSettings.qml` | enable, hide-bars, default rear view and default front view rows |
| `chrome-hide-1-property` | `+10inchP/Root.qml` | `yafcCamFull` property |
| `chrome-hide-2-statusbar` | `+10inchP/Root.qml` | hide the status bar |
| `chrome-hide-3-menubar` | `+10inchP/Root.qml` | hide the navigation bar |
| `chrome-hide-4-transient` | `+10inchP/Root.qml` | stop transients from restoring a bar |
| `chrome-hide-5-tiles` | `+10inchP/Root.qml` | hide message tiles |

Runtime paths used by the QML: `file:///fs/rwdata/yafc/camera.conf` and the RAM mailbox `file:///fs/tmpfs/yafc-view`.

No icon files are shipped. The selector uses stock Ford icon ids; Hero uses `parkingfeatures/icon_360_view`. The owner's private build used a generated composite Hero icon, which is not included.

## Rules for new fragments

- Write only our own QML. Prefix every identifier with `yafc`.
- Copy `find` and `anchor` text from the stock file. It must occur exactly once.
- Never put a Ford line in a body, and never ship a whole Ford file.
- Make a `replace` idempotent: the new text must not contain the old text.
