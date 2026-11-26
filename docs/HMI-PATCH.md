# HMI patch

The mod changes four Ford HMI QML files. This repository does not ship those files. It ships small fragment files in [`payload/hmi/`](../payload/hmi/README.md). A script applies them to your own extracted copy of the HMI. Each fragment is either a one-line text replacement or a block of our own QML appended after one stock line.

**Evidence labels used here.** *Verified on one radio* means the owner confirmed it in the car on 2026-11-24/25 with the private development build. *Host-verified* means a test in this repository ran on a host. *UNPROVEN* means no available evidence establishes it. The public fragments are **host-verified only**: they have never been applied to a radio. A different firmware version can move every anchor.

The rear camera is safety-critical. These edits change how large the camera popup is, which bars the HMI draws around it, and which view is composed. A wrong edit can hide the camera, a warning or a control. Keep an unmodified copy of every file. Test only when the vehicle is stationary.

## Artefacts

The fragments in `payload/hmi/` are the shippable artefacts. The whole Ford files are not. The format and the ordering rule are in the [fragment README](../payload/hmi/README.md). `tools/apply-hmi-fragments.sh` applies them. It is one POSIX `sh` script that drives `awk`, with no Python. The installer runs the same script on the radio. **Host-verified:** the full set applies to synthetic stock-like fixtures, a second run changes nothing, a missing or duplicated anchor refuses without editing the file, and every patched file has balanced braces and brackets. **UNPROVEN:** the script under the radio's own `awk`, `cksum` on the radio, and the anchors against real firmware.

The applier refuses a fragment when its anchor is missing from the target or occurs more than once. A refusal means nothing from that fragment is installed. It is the expected result on a firmware that moved the line. It skips a fragment whose result is already present, so a second run is a success. Fragments apply in `id` order. One further refusal exists because an anchor cannot see it: a fragment that would add a `Component.onCompleted` handler to a file that already contains one is refused, since two handlers in one file break the HMI. That also means a firmware which already does that work is not patched at all, and the affected edit is simply missing.

## Targets

All paths are relative to the HMI QML root of your extracted tree.

| Target | What the edits do |
|---|---|
| `themes/ford-10P-MY20/styles/RVCPopupStyle.qml` | Makes the camera popup component 1208 pixels high. |
| `hmirvc/+10inchP/RVCPopup.qml` | Adds the YAFC view table, RAM-mailbox publish, cover, selector row, Trailer plus/minus, sensor bay and full-screen geometry. |
| `hmisettings/driverassistance/+10inchP/RVCSettings.qml` | Adds the enable, hide-bars, default rear view and default front view rows. |
| `+10inchP/Root.qml` | Hides the status bar, menu bar and message tiles while the camera popup asks for it. |

## Fragments

| Fragment id | Target | Anchor or find text (one stock line) | Edit |
|---|---|---|---|
| `popup-height` | style | `rvcPopupComponentHeight: 480` | Replaces the value with `1208`. |
| `popup-1-state` | popup | `property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth` | Appends the YAFC properties, the per-view table, config read, RAM publish, select/commit/reconcile, cover and zoom-sync functions, and one completion handler. |
| `popup-2-visible` | popup | `onVisibleChanged: {` | Calls `yafcVisibleChanged(visible)` first; the stock branches stay. |
| `popup-3-top` | popup | `topMargin: UiTheme.styleRoot.statusBarHeight` | Sets the container top margin to 0 when the bars are hidden. |
| `popup-4-margin` | popup | `bottomMargin:  ((apaCsiActive …` (full stock line, two spaces after the colon) | Sets the strip bottom margin to 0 when the bars are hidden. |
| `popup-5-root` | popup | `rootPopupContents: [` | Prepends the timers, black fill, `Please wait...` cover, sensor bay, second sensor image and bottom safety text. |
| `popup-6-items` | popup | `height: _rVCPopupStyle.rvcPopupComponentHeight` | Appends the view opener, the stock-icon selector row and the Trailer plus/minus inside the popup container. |
| `popup-7-text-anchor` | popup | `top : cameraViewButtons.bottom` | Anchors the stock safety string to the bottom. |
| `popup-8-text-margin` | popup | `topMargin: UiTheme.styleRoot.generalMarginSmaller + UiTheme.styleRoot.generalMarginBig` | Gives that string a bottom margin. |
| `settings-1-state` | settings | `objectName: "RVCSettings"` | Appends the YAFC properties, config read and merge-save functions, and one completion handler. |
| `settings-2-rows` | settings | `scrollableAreaContent: [` | Prepends the enable, hide-bars, default rear view and default front view rows. |
| `chrome-hide-1-property` | root | `property bool fullScreenTransparentPopupStacked: false` | Appends the `yafcCamFull` property. It is true when the active popup reports `yafcHideChrome`. |
| `chrome-hide-2-statusbar` | root | `visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode` | Adds `&& !root.yafcCamFull`. |
| `chrome-hide-3-menubar` | root | `visible: parent.fullScreenViewActive === 0 && ViewController.activeViewMode !== HmiGui.FarewellViewMode` | Adds `&& !root.yafcCamFull`. |
| `chrome-hide-4-transient` | root | `isAvailable: !appStausBar.visible && (ViewManager.activeViewItem && ViewManager.activeViewItem.transientsAllowed)` | Adds `&& !root.yafcCamFull`, so the transient bar does not return. |
| `chrome-hide-5-tiles` | root | `visible: enabled && ViewManager.activeDomain !== HmiGui.HomeDomain` | Adds `&& !root.yafcCamFull`. |

Every `find` and `anchor` above occurs exactly once in the stock copies used for the host test. **UNPROVEN:** that the same line occurs once in any other firmware.

## Behaviour

Every `find` and `anchor` above occurs exactly once in the stock-like copies used for the host test. **UNPROVEN:** that the same line occurs once in any other firmware.
- **Configuration.** The popup and the settings page read and write `/fs/rwdata/yafc/camera.conf` from QML. Each writes its own keys first and keeps every other line unchanged. If the read fails, it does not write. The popup does not write the config on a view pick; only the Settings page persists preferences. **Verified on one radio** for the private build. **UNPROVEN:** that QML file reads and writes work in the public edition, that a write survives a restart, and that two writers never collide.
- **RAM mailbox.** On every view pick the popup writes one line to `/fs/tmpfs/yafc-view`: `compose;cam_src,cam_dst,bay_src,bay_dst`. The library re-reads it live per post. **Verified on one radio** for the private build. **UNPROVEN:** the mailbox path in any build other than the private one.
- **Compose mode.** A single-camera view (Rear Only, Wide, Trailer, Front Only, Front Wide) is composed centered in an 800x480 band at y=400 with small sensors below and black elsewhere. Hero (rear+360 or front+360) and 360 Only keep the two-window layout. **Verified on one radio** for the private build. Front Only, Front Wide and the front 360-only crop were checked by eye in the car only. **UNPROVEN:** the public fragments on a radio.
- **Cover.** A black rectangle at x0 y0 800x1240 with white centered `Please wait...` text at y 240 shows on every cross-stream switch and on Trailer entry/exit. The dwell is `cover_ms` from the config (default 700, 0 disables, max 3000), starting when Ford reports the new view, plus 300 ms when leaving Trailer. Taps are ignored while it is up. A 2 s timeout reconciles to whatever Ford shows, so the cover cannot stay up. **Verified on one radio** for the private build. **UNPROVEN:** that the public cover never covers a warning on another build.
- **Rear selector.** The opener is top-left; the row closes on a tap. The row is Hero, Rear Only, Wide, 360 Only. Trailer has no row button: a plus at the top right of the band opens it from Hero (top margin 14) and Rear Only (top margin 414); the minus in the same place returns to Rear Only. **Verified on one radio** for the private build.
- **Trailer.** Trailer is the plain rear stream (`IPMBRearNormal`) with Ford zoom at `ZoomLevelMax`, laid out exactly like Rear Only. `yafcSyncZoom()` forces Ford's zoom level to match the layout, rechecks on every `rvcZoomLevel` change and after a 1.2 s timer, with at most three tries per layout. Zoom on the Hero stream is the wrong, skewed picture. **Verified on one radio** for the private build.
- **Front selector.** When the front camera is showing, the row is Hero (`IPMBFront360`), Front Only (`IPMBFrontNormal`, centered band), Front Wide (`IPMBFrontSplit`, centered band) and 360 Only (full-screen surround from `IPMBFront360`). There is no Trailer plus on the front. **Verified on one radio** for the private build, by eye for the front crops. **UNPROVEN:** the front crops on another unit.
- **Per-view table.** `yafcViews` is the single source of truth: Ford view id, config value, source and destination rectangles, compose flag, holes, sensor rectangle, sensor scale, black fill, sensor switch and zoom flag. A black fill tiles everything the holes and sensor panel do not cover, so another app cannot show through. **Host-verified:** the table is balanced and the fragments apply.
- **Gating.** The opener, row, sensor bay and cover are present only while the popup is showing. The stock zoom, camera row and centered sensor image are hidden when the popup shows. **Host-verified:** the assignments are in the applied output. **UNPROVEN:** the visual result on a radio.
- **Sensor bay.** The bay is an opaque black panel with a second instance of the stock sensor component. It draws below the stock items, shows only while a combined view shows, and only for views whose switch is on. **Verified on one radio** for the private build. **UNPROVEN:** that the coordinates fit another display.
- **Chrome.** The root edits hide bars only while the popup reports `yafcHideChrome` as true. That comes from `hide_chrome=1` in the config. **Verified on one radio** for the private build. **UNPROVEN:** that no required information disappears with the bars.
- **Settings rows.** The page adds enable, hide-bars, default rear view and default front view. `cover_ms` is config-only; the page has no row for it. **Host-verified:** the rows apply and the file is balanced. **UNPROVEN:** that the page renders on a radio.

## Apply and check

1. Extract the HMI QML tree from your own radio. Keep an untouched copy.
2. Run `sh tools/apply-hmi-fragments.sh STAGE_DIR payload/hmi` against the extracted tree. `STAGE_DIR` holds your copies under `fordhmi/qml/`. Read its output, which lists each fragment as applied or skipped with the cksum and SHA-1 of every input and output file. Any refused fragment means the edit set is incomplete. Do not install a partial set unless you know what each missing fragment does.
3. Run `sh tools/test-apply-hmi-fragments.sh`. It applies the real fragment set to synthetic stock-like fixtures and checks idempotence, refusal, balance and the forbidden-token rule. **Host-verified.**
4. Check each edited file for balanced braces and brackets. Use a QML parser that matches the target imports, if you have one. **UNPROVEN:** that a host parser reproduces the radio runtime.
5. Install the tree with the mod's installer. See [`INSTALL.md`](INSTALL.md).
6. On the radio, with the vehicle stationary, check the camera popup, the safety text, the sensor display, the stock camera buttons, the selector row, the Trailer plus/minus, the cover and the settings rows.

## When it is wrong

A QML syntax error or a missing type usually leaves the HMI without the edited view or without the whole HMI. Expect a blank camera area, a missing Camera Settings page, a missing selector row, clipped controls, an opaque bay over live video, or missing bars. Remove the mod and restore your copies. See [`RECOVERY.md`](RECOVERY.md). **UNPROVEN:** that recovery is automatic or leaves a clean factory state.

## Not installable

These features of the private development HMI have no fragment, so this edition cannot install them:

- The generated composite Hero icon. The selector uses stock `parkingfeatures/icon_360_view` for Hero instead; no PNG is shipped.
- A user-selectable background colour.
- Settings pages for camera controls direction, parking sensors, active park assist, vehicle appearance and background colour.
- Hiding the stock camera view buttons, moving the stock sensor display, and re-placing the stock safety text beyond the bottom anchor above.
- The private boot hook and any native binary. This edition is source-only.

## Ownership

The Ford QML files belong to Ford. This repository does not copy or redistribute them. It names the one-line anchors above only so the applier can find them in your own copy.