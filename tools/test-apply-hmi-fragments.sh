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
    printf 'ParentStyles.RVCPopupStyle {\r\n   rvcPopupComponentHeight: 480\r\n}\r\n' \
        > "$d/fordhmi/qml/$T1"
    cat > "$d/fordhmi/qml/$T2" <<'EOF'
RVCBasePopup {
    property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth
    onVisibleChanged: {
    }
    rootPopupContents: [
        Item {
            anchors {
                topMargin: UiTheme.styleRoot.statusBarHeight
            }
            height: _rVCPopupStyle.rvcPopupComponentHeight
            IconPushButton { id: zoomButton }
        },
        HmiImage {
            id: bottomContainer
            anchors {
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
    awk 'seen { print } /^# end-header$/ { seen = 1 }' "$1"
}

# --- case 1: the real fragment set applies to all four targets -------------
S=$WORK/c1/stage; make_stage "$S"
rc=$(run "$S" "$FDIR")
[ "$rc" = 0 ] && ok "full set exits 0" || no "full set exit $rc: $(cat "$WORK/out.txt")"
grep -q 'rvcPopupComponentHeight: 1208' "$S/fordhmi/qml/$T1" \
    && ok "style replace applied" || no "style replace missing"
grep -q 'yafcViews' "$S/fordhmi/qml/$T2" && ok "popup state inserted" || no "popup state missing"
grep -q 'yafcCover' "$S/fordhmi/qml/$T2" && ok "cover inserted" || no "cover missing"
grep -q 'yafcSelectView' "$S/fordhmi/qml/$T2" && ok "selector inserted" || no "selector missing"
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
[ "$rc" = 1 ] && ok "missing anchor exits 1" || no "missing anchor exit $rc"
[ "$before" = "$(cksum "$S/fordhmi/qml/$T2")" ] && ok "refused file byte-identical" || no "refused file changed"

# --- case 4: a duplicated anchor refuses --------------------------------
S=$WORK/c4/stage; make_stage "$S"
printf '    property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth\r\n' >> "$S/fordhmi/qml/$T2"
rc=$(run "$S" "$FDIR")
[ "$rc" = 1 ] && ok "duplicate anchor exits 1" || no "duplicate anchor exit $rc"

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

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ] || exit 1
exit 0