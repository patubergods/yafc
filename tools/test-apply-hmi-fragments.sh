#!/bin/sh
# Host test for apply-hmi-fragments.sh. It applies the real fragment set to
# synthetic stock-like CRLF fixtures, then checks idempotence, refusal,
# balanced braces/brackets and the forbidden-token rule.
#
# usage: sh tools/test-apply-hmi-fragments.sh
# exit 0 all cases pass, 1 a case failed, 2 setup problem.

LC_ALL=C
export LC_ALL

here=$(cd "$(dirname "$0")" && pwd) || exit 2
APPLY=$here/apply-hmi-fragments.sh
FDIR=$here/../payload/hmi
[ -f "$APPLY" ] || { echo "setup: $APPLY missing"; exit 2; }
[ -d "$FDIR" ] || { echo "setup: $FDIR missing"; exit 2; }
command -v awk >/dev/null || { echo "setup: awk missing"; exit 2; }
command -v cksum >/dev/null || { echo "setup: cksum missing"; exit 2; }

T1=themes/ford-10P-MY20/styles/RVCPopupStyle.qml
T2=hmirvc/+10inchP/RVCPopup.qml
T3=hmisettings/driverassistance/+10inchP/RVCSettings.qml
T4=+10inchP/Root.qml

WORK=$(mktemp -d) || { echo "setup: mktemp failed"; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
no() { fail=$((fail + 1)); echo "FAIL $1"; }

# make_stage DIR: four minimal CRLF files that contain every anchor once.
make_stage() {
    d=$1
    mkdir -p "$d/fordhmi/qml/hmirvc/+10inchP" \
             "$d/fordhmi/qml/hmisettings/driverassistance/+10inchP" \
             "$d/fordhmi/qml/themes/ford-10P-MY20/styles" \
             "$d/fordhmi/qml/+10inchP"
    printf 'ParentStyles.RVCPopupStyle {\n   rvcPopupComponentHeight: 480\n}\n' \
        > "$d/fordhmi/qml/$T1"
    cat > "$d/fordhmi/qml/$T2" <<'EOF'
RVCBasePopup {
    property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth
    onVisibleChanged: {
    }
    rootPopupContents: [
        Item {
            id: container
            anchors {
                topMargin: UiTheme.styleRoot.statusBarHeight
            }
            height: _rVCPopupStyle.rvcPopupComponentHeight
            IconPushButton { id: zoomButton }
            Item { id: cameraViewButtons }
            Item { id: pdcImage }
            IconPushButton { id: cancelButton }
        },
        HmiImage {
            id: bottomContainer
            anchors {
                top:container.bottom
                bottomMargin:  ((apaCsiActive || fapaActive) && isvalidAPACSISystemState()) ? 0 : UiTheme.styleRoot.navigationBarHeight
            }
            RVCTextLabel {
                id: textLabel
                anchors {
                    top : cameraViewButtons.bottom
                    topMargin: UiTheme.styleRoot.generalMarginSmaller + UiTheme.styleRoot.generalMarginBig
                }
            }
        }
    ]
}
EOF
    cat > "$d/fordhmi/qml/$T3" <<'EOF'
PictureBookView {
    objectName: "RVCSettings"
    scrollableAreaContent: [
    ]
}
EOF
    cat > "$d/fordhmi/qml/$T4" <<'EOF'
Item {
    id: root
    property bool fullScreenTransparentPopupStacked: false
    StatusBar {
        visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode
    }
    MessageTileContainer {
        visible: enabled && ViewManager.activeDomain !== HmiGui.HomeDomain
    }
    FullscreenStatusBar {
        isAvailable: !appStausBar.visible && (ViewManager.activeViewItem && ViewManager.activeViewItem.transientsAllowed)
    }
    MenuBar {
        visible: parent.fullScreenViewActive === 0 && ViewController.activeViewMode !== HmiGui.FarewellViewMode
    }
}
EOF
    for f in "$d/fordhmi/qml/$T1" "$d/fordhmi/qml/$T2" \
             "$d/fordhmi/qml/$T3" "$d/fordhmi/qml/$T4"; do
        sed -i 's/$/\r/' "$f"
    done
}

run() { sh "$APPLY" "$1" "$2" > "$WORK/out.txt" 2>&1; echo $?; }

# balanced FILE: braces and brackets match outside strings and comments.
balanced() {
    awk '
    {
        line = $0
        out = ""
        in_str = 0; in_comment = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (in_comment) break
            if (in_str) {
                if (c == "\\") { i++; continue }
                if (c == "\"") in_str = 0
                continue
            }
            if (c == "\"") { in_str = 1; continue }
            if (c == "/" && substr(line, i + 1, 1) == "/") break
            out = out c
        }
        n = split(out, a, "")
        for (i = 1; i <= n; i++) {
            if (a[i] == "{") ob++
            else if (a[i] == "}") cb++
            else if (a[i] == "[") os++
            else if (a[i] == "]") cs++
        }
    }
    END { exit (ob == cb && os == cs) ? 0 : 1 }
    ' "$1"
}

# body_of FILE: everything after the end-header line.
body_of() {
    awk '{ sub(/\r+$/, "") } seen { print } /^# end-header$/ { seen = 1 }' "$1"
}

# --- case 1: the real fragment set applies to all four targets -------------
S=$WORK/c1/stage; make_stage "$S"
rc=$(run "$S" "$FDIR")
[ "$rc" = 0 ] && ok "full set exits 0" || no "full set exit $rc: $(cat "$WORK/out.txt")"
grep -Fq 'rvcPopupComponentHeight: 480' "$S/fordhmi/qml/$T1" \
    && grep -Fq 'property int yafcPopupComponentHeight: 1208' "$S/fordhmi/qml/$T1" \
    && ok "YAFC height added without replacing stock height" || no "incorrect style height"
grep -q 'yafcViews' "$S/fordhmi/qml/$T2" && ok "popup state inserted" || no "popup state missing"
grep -q 'yafcCover' "$S/fordhmi/qml/$T2" && ok "cover inserted" || no "cover missing"
grep -q 'yafcSelectView' "$S/fordhmi/qml/$T2" && ok "selector inserted" || no "selector missing"
grep -Fq 'top: yafcShown ? undefined : container.bottom' "$S/fordhmi/qml/$T2" \
    && ok "bottom strip anchor guarded" || no "bottom strip anchor not guarded"
grep -Fq 'topMargin: yafcShown ? UiTheme.styleRoot.generalMarginBig : UiTheme.styleRoot.generalMarginSmaller + UiTheme.styleRoot.generalMarginBig' "$S/fordhmi/qml/$T2" \
    && ok "stock text margin guarded" || no "stock text margin not guarded"
grep -q 'yafcRearRadio' "$S/fordhmi/qml/$T3" && ok "settings rows inserted" || no "settings rows missing"
grep -q 'yafcCamFull' "$S/fordhmi/qml/$T4" && ok "root property inserted" || no "root property missing"
balanced "$S/fordhmi/qml/$T1" && balanced "$S/fordhmi/qml/$T2" \
    && balanced "$S/fordhmi/qml/$T3" && balanced "$S/fordhmi/qml/$T4" \
    && ok "all four files balanced" || no "unbalanced output"

# --- case 2: a second run changes nothing --------------------------------
before=$(cksum "$S/fordhmi/qml/$T2")
rc=$(run "$S" "$FDIR")
[ "$rc" = 0 ] && ok "rerun exits 0" || no "rerun exit $rc"
[ "$before" = "$(cksum "$S/fordhmi/qml/$T2")" ] && ok "rerun byte-identical" || no "rerun altered file"

# --- case 3: a missing anchor refuses and leaves the file alone ------------
S=$WORK/c3/stage; F=$WORK/c3/frag; make_stage "$S"; cp -R "$FDIR" "$F"
sed -i 's/^# anchor: property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth$/# anchor: property int aPAPopupWidth: 0/' "$F/popup-1-state.fragment"
before=$(cksum "$S/fordhmi/qml/$T2")
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && grep -Fq 'popup-1-state: anchor occurs 0 times' "$WORK/out.txt" \
    && ok "missing anchor refused" || no "missing anchor exit $rc: $(cat "$WORK/out.txt")"
[ "$before" = "$(cksum "$S/fordhmi/qml/$T2")" ] && ok "refused file byte-identical" || no "refused file changed"

# --- case 4: a duplicated anchor refuses --------------------------------
S=$WORK/c4/stage; make_stage "$S"
printf '    property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth\r\n' >> "$S/fordhmi/qml/$T2"
rc=$(run "$S" "$FDIR")
[ "$rc" = 1 ] && grep -Fq 'popup-1-state: anchor occurs 2 times' "$WORK/out.txt" \
    && ok "duplicate anchor refused" || no "duplicate anchor exit $rc: $(cat "$WORK/out.txt")"

# --- case 5: no fragment body may contain a forbidden token --------------
# The legacy prefix is assembled at run time so this file does not carry it.
badp=p"at"
bad=0
for f in "$FDIR"/*.fragment; do
    body_of "$f" > "$WORK/body.txt"
    if grep -Eqi "(^|[^A-Za-z0-9_])${badp}[A-Za-z0-9_]*|${badp}-rvc|${badp}cam|/fs/tmpfs/${badp}|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|[A-Za-z]:\\\\Users|/home/" "$WORK/body.txt"; then
        echo "forbidden token in $f"; bad=1
    fi
done
[ "$bad" = 0 ] && ok "no forbidden token in fragment bodies" || no "forbidden token found"

# --- case 9: named fragment cannot be replaced with another fragment --------
S=$WORK/c9/stage; F=$WORK/c9/frag; make_stage "$S"; cp -R "$FDIR" "$F"
cp "$F/popup-1-state.fragment" "$F/popup-2-visible.fragment"
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && grep -q 'id must match the filename' "$WORK/out.txt" \
    && ok "misnamed fragment refused" || no "misnamed fragment exit $rc: $(cat "$WORK/out.txt")"

# --- case 10: an append header alone cannot stand in for the real body ------
S=$WORK/c10/stage; F=$WORK/c10/frag; make_stage "$S"; cp -R "$FDIR" "$F"
sed -i '/^# end-header\r*$/q' "$F/popup-1-state.fragment"
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && grep -q 'empty append body' "$WORK/out.txt" \
    && ok "blank append refused" || no "blank append exit $rc: $(cat "$WORK/out.txt")"

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ] || exit 1
exit 0