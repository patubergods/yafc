# HMI patch

The mod changes four Ford HMI QML files. This repository does not ship those files. It ships small fragment files in [`payload/hmi/`](../payload/hmi/README.md). A script applies them to your own extracted copy of the HMI. Each fragment is either a one-line text replacement or a block of our own QML appended after one stock line.

**UNPROVEN:** this path is not proven in the public edition. No fragment has been applied to a radio and shown to render here. The anchors were checked on a host against one stock tree. A different firmware version can move every anchor.

The rear camera is safety-critical. These edits change how large the camera popup is and which bars the HMI draws around it. A wrong edit can hide the camera, a warning or a control. Keep an unmodified copy of every file. Test only when the vehicle is stationary.

## Artefacts

The fragments in `payload/hmi/` are the shippable artefacts. The whole Ford files are not. The format and the ordering rule are in the [fragment README](../payload/hmi/README.md). `tools/apply-hmi-fragments.sh` applies them. It is one POSIX `sh` script that drives `awk`, with no Python. The installer runs the same script on the radio. **UNPROVEN:** the script under the radio's own `awk`, and `cksum` on the radio. It was exercised on the host with synthetic fixtures only.

The applier refuses a fragment when its anchor is missing from the target or occurs more than once. A refusal means nothing from that fragment is installed. It is the expected result on a firmware that moved the line. It skips a fragment whose result is already present, so a second run is a success. Fragments apply in `id` order. One further refusal exists because an anchor cannot see it: a fragment that would add a `Component.onCompleted` handler to a file that already contains one is refused, since two handlers in one file break the HMI. That also means a firmware which already does that work is not patched at all, and the affected edit is simply missing.

## Targets

All paths are relative to the HMI QML root of your extracted tree.

| Target | What the edits do |
|---|---|
| `themes/ford-10P-MY20/styles/RVCPopupStyle.qml` | Makes the camera popup component 1208 pixels high. |
| `hmirvc/+10inchP/RVCPopup.qml` | Adds the config helper, the camera panel, the sensor bay, and the full-screen geometry. |
| `hmisettings/driverassistance/+10inchP/RVCSettings.qml` | Adds two rows to the Camera Settings page. |
| `+10inchP/Root.qml` | Hides the status bar, menu bar and message tiles while the camera is up and asks for it. |

## Fragments

| Fragment id | Target | Anchor or find text (one stock line) | Edit |
|---|---|---|---|
| `popup-height` | style | `rvcPopupComponentHeight: 480` | Replaces the value with `1208`. |
| `panel-1-state` | popup | `property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth` | Appends the `yafc` properties and the config read, merge-save and view-select functions. Appends a completion handler that loads the config. |
| `panel-2-visible` | popup | `onVisibleChanged: {` | Adds a branch that reloads the config when the popup shows and closes the panel when it hides. The stock branches stay. |
| `panel-3-top` | popup | `topMargin: UiTheme.styleRoot.statusBarHeight` | Sets the container top margin to 0 when the bars are hidden. |
| `panel-4-bottom` | popup | `top:container.bottom` | Anchors the bottom strip to the screen bottom. The stock anchor would give it a negative height at the taller popup size. |
| `panel-5-margin` | popup | `bottomMargin:  ((apaCsiActive …` (full stock line, two spaces after the colon) | Sets the strip bottom margin to 0 when the bars are hidden. |
| `panel-6-items` | popup | `rootPopupContents: [` | Prepends four items: the sensor bay, a second sensor display inside it, the panel opener and the panel. |
| `settings-1-state` | settings | `objectName: "RVCSettings"` | Appends the `yafc` properties, config read and merge-save functions, and a completion handler. |
| `settings-2-rows` | settings | `scrollableAreaContent: [` | Prepends two switches: Fullscreen camera and Hide bars during camera. |
| `chrome-hide-1-property` | root | `property bool fullScreenTransparentPopupStacked: false` | Appends the `yafcCamFull` property. It is true when the active popup reports `yafcHideChrome`. |
| `chrome-hide-2-statusbar` | root | `visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode` | Adds `&& !root.yafcCamFull`. |
| `chrome-hide-3-menubar` | root | `visible: parent.fullScreenViewActive === 0 && ViewController.activeViewMode !== HmiGui.FarewellViewMode` | Adds `&& !root.yafcCamFull`. |
| `chrome-hide-4-transient` | root | `isAvailable: !appStausBar.visible && (ViewManager.activeViewItem && ViewManager.activeViewItem.transientsAllowed)` | Adds `&& !root.yafcCamFull`, so the transient bar does not return. |
| `chrome-hide-5-tiles` | root | `visible: enabled && ViewManager.activeDomain !== HmiGui.HomeDomain` | Adds `&& !root.yafcCamFull`. |

## Behaviour

- **Popup height.** The height edit applies to every camera view, not only ours. With the bars shown, the taller popup can run past the screen bottom. **UNPROVEN:** the result on any display. The edit pairs with the hide-bars option.
- **Configuration.** The popup and the settings page both read and write `/fs/rwdata/yafc/camera.conf` from QML. Each writes its own keys first and keeps every other line unchanged. If the read fails, it does not write. **UNPROVEN:** that QML file reads and writes work on the radio, that a write survives a restart, and that two writers never collide.
- **Camera panel.** The panel opens from a button at the top right. It shows five view buttons in this order: rear + 360 (the default), trailer zoom, rear only, 360 only, and wide. Each button writes its own geometry (`cam_src`, `cam_dst`, `bay_src`, `bay_dst`) and a sensor-panel switch to the config, then asks Ford for a view id through the stock controller. Only rear + 360 exists as a Ford view id on the observed radio, so the other views are our own geometry on top of it; `wide` deliberately leaves Ford's own three-panel presentation. The library reads the geometry live. **UNPROVEN:** that the vehicle accepts each request, and on another unit. **Verified on one radio** (development build, 2026-11-22): every button switches and persists; the exact pictures still need refinement.
- **Gating.** The opener, panel and sensor bay show only when `enabled=1` in the config. With it off, the popup draws the stock items.
- **Sensor bay.** The bay is an opaque black panel with a second instance of the stock sensor component. It draws below every stock item, shows only while a combined view shows, and only for views whose switch is on (the 360-only and rear-only views show none). It starts exactly where the 360 bay ends. The position and size come from one build. **UNPROVEN:** that they fit another display. The stock sensor display stays visible, so two sensor displays can appear.
- **Chrome.** The root edits hide bars only while the popup reports `yafcHideChrome` as true. That comes from `hide_chrome=1` in the config. **UNPROVEN:** that no required information disappears with the bars.

## Apply and check

1. Extract the HMI QML tree from your own radio. Keep an untouched copy.
2. Run `sh tools/apply-hmi-fragments.sh STAGE_DIR payload/hmi` against the extracted tree. `STAGE_DIR` holds your copies under `fordhmi/qml/`. Read its output, which lists each fragment as applied or skipped with the cksum and SHA-1 of every input and output file. Any refused fragment means the edit set is incomplete. Do not install a partial set unless you know what each missing fragment does.
3. Check each edited file for balanced braces and list commas. Use a QML parser that matches the target imports, if you have one. **UNPROVEN:** that a host parser reproduces the radio runtime.
4. Install the tree with the mod's installer. See [`INSTALL.md`](INSTALL.md).
5. On the radio, with the vehicle stationary, check the camera popup, the safety text, the sensor display, the stock camera buttons, the panel and the settings rows.

## When it is wrong

A QML syntax error or a missing type usually leaves the HMI without the edited view or without the whole HMI. Expect a blank camera area, a missing Camera Settings page, a missing panel, clipped controls, an opaque bay over live video, or missing bars. Remove the mod and restore your copies. See [`RECOVERY.md`](RECOVERY.md). **UNPROVEN:** that recovery is automatic or leaves a clean factory state.

## Not installable

These features of the development HMI have no fragment, so this edition cannot install them:

- A per-camera default view and its settings pages.
- Settings pages for camera controls direction, parking sensors, active park assist, vehicle appearance and background colour.
- Hiding the stock camera view buttons, moving the stock sensor display, and re-placing the stock safety text.

## Ownership

The Ford QML files belong to Ford. This repository does not copy or redistribute them. It names the one-line anchors above only so that the applier can find them in your own copy.
