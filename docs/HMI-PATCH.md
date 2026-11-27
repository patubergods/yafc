# HMI patch

The mod changes four Ford HMI QML files. This repository does not ship those files. It ships small fragment files in [`payload/hmi/`](../payload/hmi/README.md). A script applies them to your own extracted copy of the HMI. Each fragment is either a one-line text replacement or a block of our own QML appended after one stock line.

**Evidence labels used here.** *Verified on one radio* means the owner confirmed it on a 2020 Explorer ST on 2026-11-24/25 with the private development build. *Host-verified* means a test ran on a host. *UNPROVEN* means no available evidence establishes it. The public fragments have never been applied to a radio. A different firmware version can move every anchor.

The rear camera is safety-critical. These edits change how large the camera popup is, which bars the HMI draws around it, and which view is composed. A wrong edit can hide the camera, a warning or a control. Keep an unmodified copy of every file. Test only when the vehicle is stationary.

## Artefacts

The fragments in `payload/hmi/` are the shippable artefacts. The whole Ford files are not. The format and order are in the [fragment README](../payload/hmi/README.md). The installer requires the complete set and runs `tools/apply-hmi-fragments.sh` (POSIX `sh` and `awk`) on copies of the unit's stock files. Host tests use synthetic stock-like fixtures to check application, idempotence and refusal. **UNPROVEN:** the radio's `awk` and `cksum`, the real firmware anchors, and the rendered HMI.

The applier matches one whole stock line, ignoring surrounding spaces and tabs and a trailing carriage return. It refuses a missing or duplicate anchor, skips an identical result and applies fragments in `id` order. It also refuses to add a duplicate `Component.onCompleted` handler. If any fragment is refused, the USB installer does not publish the staged HMI.

## Targets

All paths are relative to the HMI QML root of your extracted tree.

| Target | What the edits do |
|---|---|
| `themes/ford-10P-MY20/styles/RVCPopupStyle.qml` | Adds the 1208-pixel YAFC height alongside the factory value of 480 pixels. |
| `hmirvc/+10inchP/RVCPopup.qml` | Adds the YAFC view table, RAM-mailbox publish, cover, selector row, Zoomed View plus/minus, sensor bay and full-screen geometry. |
| `hmisettings/driverassistance/+10inchP/RVCSettings.qml` | Adds the enable, hide-bars, default rear view and default front view rows. |
| `+10inchP/Root.qml` | Hides the status bar, menu bar and message tiles while the camera popup asks for it. |

## Fragments

| Fragment id | Target | Anchor or find text (one stock line) | Edit |
|---|---|---|---|
| `popup-height` | style | `rvcPopupComponentHeight: 480` | Appends the separate YAFC height; preserves the stock height. |
| `popup-1-state` | popup | `property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth` | Adds popup state, guarded stock bindings, default mapping, RAM publication, view selection, cover and zoom synchronization. |
| `popup-2-visible` | popup | `onVisibleChanged: {` | Calls `yafcVisibleChanged(visible)` first; the stock branches stay. |
| `popup-3-top` | popup | `topMargin: UiTheme.styleRoot.statusBarHeight` | Sets the container top margin to 0 when the bars are hidden. |
| `popup-4-margin` | popup | `bottomMargin:  ((apaCsiActive …` (full stock line, two spaces after the colon) | Sets the strip bottom margin to 0 when the bars are hidden. |
| `popup-5-root` | popup | `rootPopupContents: [` | Prepends the timers, black fill, `Please wait...` cover, sensor bay, second sensor image and bottom safety text. |
| `popup-6-items` | popup | `rootPopupContents: [` | Adds the view opener, selector row and Zoomed View plus/minus. |
| `popup-7-text-anchor` | popup | `top:container.bottom` | Releases the bottom strip's top anchor only in YAFC mode. |
| `popup-8-text-margin` | popup | `topMargin: UiTheme.styleRoot.generalMarginSmaller + UiTheme.styleRoot.generalMarginBig` | Adjusts the stock text's top margin only in YAFC mode. |
| `settings-1-state` | settings | `objectName: "RVCSettings"` | Appends the YAFC properties, config read and merge-save functions, and one completion handler. |
| `settings-2-rows` | settings | `scrollableAreaContent: [` | Prepends the enable, hide-bars, default rear view and default front view rows. |
| `chrome-hide-1-property` | root | `property bool fullScreenTransparentPopupStacked: false` | Appends the `yafcCamFull` property. It is true when the active popup reports `yafcHideChrome`. |
| `chrome-hide-2-statusbar` | root | `visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode` | Adds `&& !root.yafcCamFull`. |
| `chrome-hide-3-menubar` | root | `visible: parent.fullScreenViewActive === 0 && ViewController.activeViewMode !== HmiGui.FarewellViewMode` | Adds `&& !root.yafcCamFull`. |
| `chrome-hide-4-transient` | root | `isAvailable: !appStausBar.visible && (ViewManager.activeViewItem && ViewManager.activeViewItem.transientsAllowed)` | Adds `&& !root.yafcCamFull`, so the transient bar does not return. |
| `chrome-hide-5-tiles` | root | `visible: enabled && ViewManager.activeDomain !== HmiGui.HomeDomain` | Adds `&& !root.yafcCamFull`. |

Host tests exercise these anchors on synthetic stock-like files. **UNPROVEN:** that the same lines occur once on firmware in a public installation.

## Behaviour

- **Configuration.** The installer seeds `/fs/rwdata/yafc/camera.conf` only if it does not exist. Settings changes only the keys it owns; the popup reads preferences and writes transient selections to RAM. Settings refuses to save if it cannot read the existing file and checks the result before logging success. Local QML reads and writes in this edition are **UNPROVEN** on a radio.
- **RAM mailbox and session.** The popup reads the native's session identity from `/fs/tmpfs/yafc-session` on entry and prefixes every mailbox record to `/fs/tmpfs/yafc-view` with `<session><seq>;<compose>;<16 rects>`. The native echoes the accepted record in `/fs/tmpfs/yafc-ready` after a successful Screen post with verified geometry. The popup composes only after two advancing ready replies; a missing, stale, or mismatched session returns the popup to stock. A ready file proves `screen_post_window` returned success and the compositor accepted the geometry. It does **not** prove that the display painted the result, or that a late-created bay ever appeared. QML timers stall with the render thread; a stalled HMI poll is not detected by the native. The popup's 100 ms poll read of `/fs/tmpfs/yafc-ready` and `/fs/tmpfs/yafc-session` uses synchronous XHR; **UNPROVEN** on a radio.
- **Compose mode.** A single-camera view (Rear Only, Wide, Zoomed View, Front Only, Front Wide) is composed centered in an 800x480 band at y=400 with small sensors below and black elsewhere. Hero (rear+360 or front+360) and 360 Only keep the two-window layout. **Verified on one radio** for the private build. Front Only, Front Wide and the front 360-only crop were checked by eye in the car only. **UNPROVEN:** the public fragments on a radio.
- **Cover.** A black rectangle at x0 y0 800x1240 with white centered `Please wait...` text at y 240 shows on every cross-stream switch and on entry to or exit from Zoomed View. The dwell is `cover_ms` from the config (default 700, 0 disables, max 3000), starting when Ford reports the new view, plus 300 ms when leaving Zoomed View. Taps are ignored while it is up. A 2 s timeout reconciles to whatever Ford shows, so the cover cannot stay up. **Verified on one radio** for the private build. **UNPROVEN:** that the public cover never covers a warning on another build.
- **Rear selector.** The opener is top-left; the row closes on a tap. The row is Hero, Rear Only, Wide, 360 Only. Zoomed View has no row button: a plus at the top right of the band opens it from Hero (top margin 14) and Rear Only (top margin 414); the minus in the same place returns to Rear Only. **Verified on one radio** for the private build.
- **Zoomed View.** Uses the plain rear stream (`IPMBRearNormal`) with Ford zoom at `ZoomLevelMax`, laid out exactly like Rear Only. `yafcSyncZoom()` forces Ford's zoom level to match the layout, rechecks on every `rvcZoomLevel` change and after a 1.2 s timer, with at most three tries per layout. Zoom on the Hero stream is the wrong, skewed picture. **Verified on one radio** for the private build.
- **Front selector.** When the front camera is showing, the row is Hero (`IPMBFront360`), Front Only (`IPMBFrontNormal`, centered band), Front Wide (`IPMBFrontSplit`, centered band) and 360 Only (full-screen surround from `IPMBFront360`). Zoomed View is rear-only. **Verified on one radio** for the private build, by eye for the front crops. **UNPROVEN:** the front crops on another unit.
- **Per-view table.** `yafcViews` is the single source of truth: Ford view id, config value, source and destination rectangles, compose flag, holes, sensor rectangle, sensor scale, black fill, sensor switch and zoom flag. A black fill tiles everything the holes and sensor panel do not cover, so another app cannot show through. **Host-verified:** the table is balanced and the fragments apply.
- **Gating.** The popup keeps the stock layout and controls when `DISABLE` is present, composition is off, the native session is absent, or the initial mailbox publication fails verification (no two advancing ready replies). Stock bindings resume when YAFC deactivates. Restart after changing `DISABLE` or `enabled` so the library and HMI start in the same state. The public fallback is **UNPROVEN** on a radio.
- **Sensor bay.** The bay is an opaque black panel with a second instance of the stock sensor component. It draws below the stock items, shows only while a combined view shows, and only for views whose switch is on. **Verified on one radio** for the private build. **UNPROVEN:** that the coordinates fit another display.
- **Chrome.** The root edits hide bars only while the popup reports `yafcHideChrome` as true. That comes from `hide_chrome=1` in the config. **Verified on one radio** for the private build. **UNPROVEN:** that no required information disappears with the bars.
- **Settings rows.** The page adds enable, hide-bars, default rear view and default front view. Each offered view maps to a popup layout. `cover_ms` is config-only. The page remains **UNPROVEN** on a radio.

## Apply and check

1. Extract the HMI QML tree from your own radio. Keep an untouched copy.
2. Run `sh tools/apply-hmi-fragments.sh STAGE_DIR payload/hmi` on your own copies under `fordhmi/qml/`. The output lists each fragment and target checksums. Do not install a partial set.
3. Run `sh tools/test-apply-hmi-fragments.sh` and `python3 -I tools/test-install.py`. The latter checks image paths and exercises patched JavaScript with fake QML services. Neither test renders Ford QML.
4. Check each edited file for balanced braces and brackets. Use a QML parser that matches the target imports, if you have one. **UNPROVEN:** that a host parser reproduces the radio runtime.
5. Use the USB installer's rehearsal mode to build and check an image on the unit without publishing, then install only if its checks pass. See [`INSTALL.md`](INSTALL.md).
6. On the radio, with the vehicle stationary, check the camera popup, the safety text, the sensor display, the stock camera buttons, the selector row, the Zoomed View plus/minus, the cover and the settings rows.

## When it is wrong

A QML syntax error or a missing type usually leaves the HMI without the edited view or without the whole HMI. Expect a blank camera area, a missing Camera Settings page, a missing selector row, clipped controls, an opaque bay over live video, or missing bars. Remove the mod and restore your copies. See [`RECOVERY.md`](RECOVERY.md). **UNPROVEN:** that recovery is automatic or leaves a clean factory state.

## Not installable

These features of the private development HMI have no fragment, so this edition cannot install them:

- The generated composite Hero icon. The selector uses stock `parkingfeatures/icon_360_view` for Hero instead; no PNG is shipped.
- A user-selectable background colour.
- Settings pages for camera controls direction, parking sensors, active park assist, vehicle appearance and background colour.
- The private boot hook and any native binary. This edition is source-only.

## Ownership

The Ford QML files belong to Ford. This repository does not copy or redistribute them. It names the one-line anchors above only so the applier can find them in your own copy.