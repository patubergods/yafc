#!/bin/sh
# Host test for apply-hmi-fragments.sh. Runs on any sh + awk + cksum. It builds
# tiny CRLF fixtures, applies fragment sets and checks the exit status and the
# resulting bytes. It does not need a radio, the HMI files or the real fragments.
#
# usage: sh tools/test-apply-hmi-fragments.sh
# exit 0 all cases pass, 1 a case failed, 2 setup problem.

LC_ALL=C
export LC_ALL

here=$(cd "$(dirname "$0")" && pwd) || exit 2
APPLY=$here/apply-hmi-fragments.sh
[ -f "$APPLY" ] || { echo "setup: $APPLY missing"; exit 2; }
command -v awk >/dev/null || { echo "setup: awk missing"; exit 2; }
command -v cksum >/dev/null || { echo "setup: cksum missing"; exit 2; }
if ! command -v openssl >/dev/null; then
  echo "SKIP: openssl not found; the report sums need it"
  exit 0
fi

T1=themes/ford-10P-MY20/styles/RVCPopupStyle.qml
T2=hmirvc/+10inchP/RVCPopup.qml
T3=hmisettings/driverassistance/+10inchP/RVCSettings.qml
T4=+10inchP/Root.qml

WORK=$(mktemp -d) || { echo "setup: mktemp failed"; exit 2; }
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0
fail=0

ok()   { pass=$((pass + 1)); echo "ok   $1"; }
no()   { fail=$((fail + 1)); echo "FAIL $1"; }

# make_stage DIR: four minimal CRLF HMI files with one stock line each
make_stage() {
  d=$1
  mkdir -p "$d/fordhmi/qml/themes/ford-10P-MY20/styles" \
           "$d/fordhmi/qml/hmirvc/+10inchP" \
           "$d/fordhmi/qml/hmisettings/driverassistance/+10inchP" \
           "$d/fordhmi/qml/+10inchP"
  printf 'Item {\r\n   rvcPopupComponentHeight: 480\r\n}\r\n' > "$d/fordhmi/qml/$T1"
  printf 'Item {\r\n    anchors.fill: parent\r\n    property int aPA: 1\r\n}\r\n' > "$d/fordhmi/qml/$T2"
  printf 'Item {\r\n    objectName: "RVCSettings"\r\n    width: 1\r\n}\r\n' > "$d/fordhmi/qml/$T3"
  printf 'Item {\r\n    property bool fullScreen: false\r\n    visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode\r\n}\r\n' > "$d/fordhmi/qml/$T4"
}

# frag_repl DIR ID TARGET FIND REPLACE
frag_repl() {
  d=$1; id=$2; target=$3; find=$4; repl=$5
  {
    echo "# yafc-fragment v1"
    echo "# id: $id"
    echo "# target: $target"
    echo "# edit: replace"
    echo "# find: $find"
    echo "# replace: $repl"
    echo "# end-header"
  } > "$d/$id.fragment"
}

# frag_append DIR ID TARGET ANCHOR [BODY...]
frag_append() {
  d=$1; id=$2; target=$3; anchor=$4; shift 4
  {
    echo "# yafc-fragment v1"
    echo "# id: $id"
    echo "# target: $target"
    echo "# edit: append-after"
    echo "# anchor: $anchor"
    echo "# end-header"
    for b in "$@"; do echo "$b"; done
  } > "$d/$id.fragment"
}

# good_set DIR: one fragment per target, so all four change
good_set() {
  d=$1; mkdir -p "$d"
  frag_repl "$d" a1 "$T1" "rvcPopupComponentHeight: 480" "rvcPopupComponentHeight: 1208"
  frag_append "$d" b1 "$T2" "property int aPA: 1" \
    "    property bool yafcPanelOpen: false" "    Component.onCompleted: { }"
  frag_append "$d" c1 "$T3" 'objectName: "RVCSettings"' \
    "    property bool yafcEnabled: false"
  frag_repl "$d" d1 "$T4" "visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode" \
    "visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode && !root.yafcCamFull"
}

crlf_only() {   # file: every LF is preceded by CR and there is at least one
  f=$1
  lf=$(tr -dc '\n' < "$f" | wc -c)
  cr=$(tr -dc '\r' < "$f" | wc -c)
  [ "$lf" -gt 0 ] && [ "$lf" -eq "$cr" ]
}

run() { sh "$APPLY" "$1" "$2" > "$WORK/out.txt" 2>&1; echo $?; }

# --- case 1: a good set applies all four and keeps CRLF and indentation ----
S=$WORK/c1/stage; F=$WORK/c1/frag; make_stage "$S"; good_set "$F"
rc=$(run "$S" "$F")
[ "$rc" = 0 ] && ok "good set exits 0" || no "good set exit $rc: $(cat "$WORK/out.txt")"
grep -q 'rvcPopupComponentHeight: 1208' "$S/fordhmi/qml/$T1" 2>/dev/null \
  && ok "replace applied" || no "replace not applied"
grep -q '^   rvcPopupComponentHeight: 1208' "$S/fordhmi/qml/$T1" 2>/dev/null \
  && ok "replace kept original indentation" || no "indentation lost"
grep -q 'yafcPanelOpen' "$S/fordhmi/qml/$T2" && ok "append-after inserted" || no "append missing"
grep -q 'yafcEnabled' "$S/fordhmi/qml/$T3" && ok "settings fragment inserted" || no "settings missing"
grep -q 'yafcCamFull' "$S/fordhmi/qml/$T4" && ok "root replace applied" || no "root replace missing"
crlf_only "$S/fordhmi/qml/$T1" && crlf_only "$S/fordhmi/qml/$T2" && crlf_only "$S/fordhmi/qml/$T3" \
  && crlf_only "$S/fordhmi/qml/$T4" && ok "all four files stay CRLF" || no "line endings changed"

# --- case 2: a second run is a no-op with exit 0 ---------------------------
before=$(cksum "$S/fordhmi/qml/$T2")
rc=$(run "$S" "$F")
[ "$rc" = 0 ] && ok "rerun exits 0" || no "rerun exit $rc"
[ "$before" = "$(cksum "$S/fordhmi/qml/$T2")" ] && ok "rerun changed nothing" || no "rerun altered the file"

# --- case 3: a missing anchor refuses and leaves the file alone ------------
S=$WORK/c3/stage; F=$WORK/c3/frag; make_stage "$S"; good_set "$F"
sed -i 's/^# anchor: property int aPA: 1$/# anchor: property int aPA: 2/' "$F/b1.fragment"
before=$(cksum "$S/fordhmi/qml/$T2")
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && ok "missing anchor exits 1" || no "missing anchor exit $rc"
grep -q 'yafcPanelOpen' "$S/fordhmi/qml/$T2" && no "refused file was edited" || ok "refused file untouched"
[ "$before" = "$(cksum "$S/fordhmi/qml/$T2")" ] && ok "refused file byte-identical" || no "refused file changed"

# --- case 4: a duplicated anchor refuses ----------------------------------
S=$WORK/c4/stage; F=$WORK/c4/frag; make_stage "$S"; good_set "$F"
printf '   property int aPA: 1\r\n' >> "$S/fordhmi/qml/$T2"
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && ok "duplicated anchor exits 1" || no "duplicated anchor exit $rc"

# --- case 5: an existing Component.onCompleted is refused -----------------
S=$WORK/c5/stage; F=$WORK/c5/frag; make_stage "$S"; good_set "$F"
printf '    Component.onCompleted: { }\r\n' >> "$S/fordhmi/qml/$T2"
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && ok "duplicate onCompleted exits 1" || no "duplicate onCompleted exit $rc"

# --- case 6: a target with no fragment fails the run ----------------------
S=$WORK/c6/stage; F=$WORK/c6/frag; make_stage "$S"; good_set "$F"
rm -f "$F/c1.fragment"
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && ok "missing target fragment exits 1" || no "missing target fragment exit $rc"

# --- case 7: usage --------------------------------------------------------
sh "$APPLY" > /dev/null 2>&1
[ $? = 2 ] && ok "usage exits 2" || no "usage exit code"

# --- case 8: a fragment without # end-header is refused -------------------
S=$WORK/c8/stage; F=$WORK/c8/frag; make_stage "$S"; good_set "$F"
grep -v '^# end-header$' "$F/a1.fragment" > "$F/a1.tmp" && mv "$F/a1.tmp" "$F/a1.fragment"
rc=$(run "$S" "$F")
[ "$rc" = 1 ] && ok "header without end-header exits 1" || no "end-header case exit $rc"

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ] || exit 1
exit 0
