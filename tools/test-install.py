#!/usr/bin/env python3
"""Mocked-unit rehearsal for installer/yafc-install.sh and its dispatcher.

Runs the REAL scripts against a fake /fs/mp tree, with fake mount, umount and the
qnx6 image tools on PATH (a layer stack kept in a file). Proves the host contracts
only: the write order, the rollback, the mount-stack handling, the HMI call order
and the marker dispatch. It cannot prove qnx6 behaviour and it never touches a radio.

The fake image mounts expose the files the installer actually wrote. The mock
refuses deletion or replacement of mounted images and scratch deletion while the
image is mounted. It cannot prove qnx6 or radio behavior.

Cases: no marker; two markers refused; install happy path; install probe failure
rolls the unit's own library back; rehearse changes no bytes; remove; disable;
busy layer aborts with the stack restored; base device missing; base on top is
never unmounted; a recovery script changed under us fails loudly; missing payload
refuses before anything is touched; install with HMI; HMI refused on a stale or
duplicate anchor; rehearse leaves /fs/images untouched; remove deletes the image
and restores the library; remove with only the library, only the image, and
neither; remove-hmi leaves the library; another overlay image is never touched.

Needs: dash, openssl, tar, Node.js (WSL can use node.exe), python3.
Run: python3 -I tools/test-install.py
"""
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tarfile
from pathlib import Path
from tempfile import TemporaryDirectory

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "installer"
BASE = "/dev/hd0t178"
OVL = ["overlay_a.img", "overlay_b.img"]   # top first
RECOVERY = ("startup_gf.sh", "usb_installer.sh", "launch/launch_usblauncher.sh")
VENDOR = b"VENDOR-camera-library"          # the unit's own library, invented
YAFC = b"YAFC-slot-library"                # what the repository ships
IMG = "overlay_00--yafc.img"
STOCK = {
    "themes/ford-10P-MY20/styles/RVCPopupStyle.qml":
        "Item {\r\n    rvcPopupComponentHeight: 480\r\n}\r\n",
    "hmirvc/+10inchP/RVCPopup.qml":
        "Item {\r\n    property int aPAPopupWidth: UiTheme.styleRoot.applicationWidth\r\n"
        "    onVisibleChanged: {\r\n"
        "        if (visible) { stockOpen(); } else { stockClose(); }\r\n"
        "    }\r\n"
        "    topMargin: UiTheme.styleRoot.statusBarHeight\r\n"
        "    top:container.bottom\r\n"
        "    bottomMargin:  ((apaCsiActive || fapaActive) && isvalidAPACSISystemState()) ? 0 : UiTheme.styleRoot.navigationBarHeight\r\n"
        "    topMargin: UiTheme.styleRoot.generalMarginSmaller + UiTheme.styleRoot.generalMarginBig\r\n"
        "    rootPopupContents: [\r\n"
        "    Item { id: container; height: _rVCPopupStyle.rvcPopupComponentHeight },\r\n"
        "    Item { id: bottomContainer; property string source: stockBackground },\r\n"
        "    Item { id: zoomButton; visible: stockZoom },\r\n"
        "    Item { id: cameraViewButtons; visible: stockViews },\r\n"
        "    Item { id: pdcImage; visible: stockSensors },\r\n"
        "    Item { id: cancelButton; visible: stockCancel },\r\n"
        "    Item { id: textLabel; visible: stockWarning },\r\n"
        "    property bool fullScreenTransparentPopupStacked: false\r\n"
        "    visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode\r\n"
        "    visible: parent.fullScreenViewActive === 0 && ViewController.activeViewMode !== HmiGui.FarewellViewMode\r\n"
        "    isAvailable: !appStausBar.visible && (ViewManager.activeViewItem && ViewManager.activeViewItem.transientsAllowed)\r\n"
        "    visible: enabled && ViewManager.activeDomain !== HmiGui.HomeDomain\r\n"
        "]\r\n}\r\n",
    "hmisettings/driverassistance/+10inchP/RVCSettings.qml":
        "Item {\r\n    objectName: \"RVCSettings\"\r\n"
        "    scrollableAreaContent: [\r\n]\r\n}\r\n",
    "+10inchP/Root.qml":
        "Item {\r\n    property bool fullScreenTransparentPopupStacked: false\r\n"
        "    visible: ViewController.activeViewMode !== HmiGui.FarewellViewMode\r\n"
        "    visible: parent.fullScreenViewActive === 0 && ViewController.activeViewMode !== HmiGui.FarewellViewMode\r\n"
        "    isAvailable: !appStausBar.visible && (ViewManager.activeViewItem && ViewManager.activeViewItem.transientsAllowed)\r\n"
        "    visible: enabled && ViewManager.activeDomain !== HmiGui.HomeDomain\r\n}\r\n",
}

FAKE_MOUNT = r'''#!/bin/sh
set -eu
S=$FAKE/stack
[ $# -eq 0 ] || echo "mount $*" >> "$FAKE/ops"
case "${1-}" in
  "") while IFS= read -r d; do
        flags=ro
        if [ "$d" = /dev/hd0t178 ]; then
          [ ! -f "$FAKE/rw" ] || flags=rw
        else
          case "$d" in /*) ;; *) d=$YAFC_IMGDIR/$d ;; esac
        fi
        if [ -n "${FAKE_BARE_MOUNT-}" ]; then
          echo "$d on $SLOT_MP type qnx6"
        else
          echo "$d on $SLOT_MP type qnx6 ($flags)"
        fi
      done < "$S" ;;
  -uw) [ "$(cat "$S")" = /dev/hd0t178 ]
       : > "$FAKE/rw" ;;
  -ur) [ "$(cat "$S")" = /dev/hd0t178 ]
       [ -z "${FAKE_RO_FAIL-}" ] || exit 1
       /bin/rm -f "$FAKE/rw"
       [ -z "${FAKE_TAMPER-}" ] || echo x >> "$SLOT_MP/scripts/startup_gf.sh" ;;
  -b) if [ "$#" = 6 ] && [ "$6" = "$YAFC_SCRATCH/mnt" ]; then
        [ "$2 $3 $4" = "-r -t qnx6" ] && [ -s "$5" ] || exit 1
        [ ! -e "$FAKE/image-mode" ]
        tar -xf "$5" -C "$6"
        if [ -n "${FAKE_READBACK_CORRUPT-}" ]; then
          printf damaged >> "$6/fordhmi/qml/+10inchP/Root.qml"
        fi
        echo ro > "$FAKE/image-mode"
      else
        [ "$#" = 8 ] && [ "$2 $3 $4 $5 $6" = "-r -t qnx6 -o before" ] && [ "$8" = "$SLOT_MP" ]
        [ -f "$7" ]
        dev=${7##*/}
        [ "$dev" != "${FAKE_REPLAY_FAIL-}" ] || exit 1
        awk -v dev="$dev" '$0 == "/dev/hd0t178" { print dev } { print }' "$S" > "$S.n"
        /bin/mv "$S.n" "$S"
        if [ "$dev" = overlay_00--yafc.img ] && [ -d "$FAKE/overlay-qml" ]; then
          if tar -tf "$7" >/dev/null 2>&1; then
            tar -xf "$7" -C "$SLOT_MP"
          else
            /bin/cp -R "$FAKE/overlay-qml/." "$SLOT_MP/fordhmi/qml/"
          fi
        fi
      fi ;;
  -t) [ "$#" = 4 ] && [ "$2" = qnx6 ] && [ "$3" = "$YAFC_HMI_DEV" ]
      [ -f "$3" ] && [ -f "$FAKE/formatted" ] && [ ! -e "$FAKE/image-mode" ] || exit 1
      echo rw > "$FAKE/image-mode" ;;
  *) exit 1 ;;
esac
'''
FAKE_DINIT = r'''#!/bin/sh
echo "dinit $*" >> "$FAKE/ops"
[ "$1 $2" = "-hq -S4m" ] || exit 1
printf 'BACKING' > "$3"
'''
FAKE_LOOP = r'''#!/usr/bin/env python3
import os
import signal
import sys
from pathlib import Path
device = Path(os.environ["YAFC_HMI_DEV"])
def stop(*_):
    device.unlink(missing_ok=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
with (Path(os.environ["FAKE"]) / "ops").open("a") as out:
    out.write("devb-loopback " + " ".join(sys.argv[1:]) + "\n")
device.touch()
signal.pause()
'''
FAKE_MKQNX6 = r'''#!/bin/sh
echo "mkqnx6fs $*" >> "$FAKE/ops"
[ -z "$FAKE_MKFS_FAIL" ] && [ -f "$4" ] || exit 1
: > "$FAKE/formatted"
'''
FAKE_CHK = r'''#!/bin/sh
echo "chkqnx6fs $*" >> "$FAKE/ops"
[ -s "$1" ] && tar -tf "$1" >/dev/null && [ ! -e "$YAFC_HMI_DEV" ] &&
  [ ! -e "$FAKE/image-mode" ]
'''
FAKE_UMOUNT = r'''#!/bin/sh
set -eu
echo "umount $*" >> "$FAKE/ops"
if [ "$1" = "$YAFC_SCRATCH/mnt" ]; then
  [ -f "$FAKE/image-mode" ] && [ "${FAKE_BUILD_BUSY-}" != "$(cat "$FAKE/image-mode")" ] || exit 1
  if [ "$(cat "$FAKE/image-mode")" = rw ]; then
    tar -cf "$YAFC_SCRATCH/.yafc-build.img" -C "$1" .
    /bin/rm -rf "$1"
  else
    /bin/mv "$1" "$FAKE/imgroot"
  fi
  mkdir "$1"
  /bin/rm "$FAKE/image-mode"
else
  [ "$1" = "$SLOT_MP" ]
  read -r top < "$FAKE/stack"
  [ "$top" != /dev/hd0t178 ]
  if grep -qxF "$top" "$FAKE/busy"; then exit 1; fi
  sed '1d' "$FAKE/stack" > "$FAKE/stack.n"
  /bin/mv "$FAKE/stack.n" "$FAKE/stack"
  if [ "$top" = overlay_00--yafc.img ] && [ -d "$FAKE/stock-qml" ]; then
    /bin/mv "$SLOT_MP/fordhmi/qml" "$FAKE/overlay-qml"
    /bin/mv "$FAKE/stock-qml" "$SLOT_MP/fordhmi/qml"
  fi
fi
'''
FAKE_CP = r'''#!/bin/sh
case "$1" in
  "$SLOT_MP"/fordhmi/qml/*)
    [ "$(cat "$FAKE/stack")" = /dev/hd0t178 ] || exit 1 ;;
esac
case "$2" in
  "$YAFC_IMGDIR"/.yafc-build.*.img)
    echo "stage $1 $2" >> "$FAKE/ops"
    if [ -n "$FAKE_PUBLISH_CORRUPT" ]; then
      printf damaged > "$2"
      exit 0
    fi ;;
esac
exec /bin/cp "$@"
'''
FAKE_MV = r'''#!/bin/sh
[ "$1" != -f ] || shift
case "$2" in
  "$YAFC_IMGDIR"/overlay_00--yafc.img)
    echo "publish $1 $2" >> "$FAKE/ops"
    ! grep -qxF overlay_00--yafc.img "$FAKE/stack" || exit 1
    [ "${1%/*}" = "$YAFC_IMGDIR" ] || exit 1
    case "${1##*/}" in .yafc-build.*.img) ;; *) exit 1 ;; esac
    if [ -n "$FAKE_REPLACE_OLD" ]; then
      [ -f "$2" ] && [ "$(cat "$2")" = "$FAKE_REPLACE_OLD" ] || exit 1
    fi
    [ -z "$FAKE_PUBLISH_FAIL" ] || exit 1 ;;
esac
case "$1" in
  "$YAFC_IMGDIR"/overlay_00--yafc.img)
    ! grep -qxF overlay_00--yafc.img "$FAKE/stack" || exit 1 ;;
esac
exec /bin/mv "$@"
'''
FAKE_RM = r'''#!/bin/sh
for path do
  case "$path" in
    "$YAFC_IMGDIR"/overlay_00--yafc.img*)
      echo "delete $path" >> "$FAKE/ops"
      ! grep -qxF "${path##*/}" "$FAKE/stack" || exit 1
      [ "${path##*/}" != "$FAKE_DELETE_FAIL" ] || exit 1 ;;
    "$YAFC_SCRATCH")
      echo "clean scratch" >> "$FAKE/ops"
      [ ! -e "$FAKE/image-mode" ] && [ ! -e "$YAFC_HMI_DEV" ] || exit 1 ;;
  esac
done
exec /bin/rm "$@"
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Rig:
    def __init__(self, root: Path):
        self.root = root
        self.usb, self.mp, self.fake, self.data = (root / n for n in ("usb", "mp", "fake", "rwdata"))
        self.lib = self.mp / "apps/usr/lib"

    def reset(self, live=VENDOR, preserved=None, stack=None, busy=(), payload=True, probe_ok=True,
              hmi=True, stock=None, fragments=True, images=()):
        for d in (self.usb, self.mp, self.fake, self.data):
            shutil.rmtree(d, ignore_errors=True)
        (self.usb / "SyncMyMod").mkdir(parents=True)
        shutil.copy2(SRC / "yafc-install.sh", self.usb / "yafc-install.sh")
        shutil.copy2(SRC / "yafc-dispatch.sh", self.usb / "SyncMyMod/autoinstall.sh")
        self.lib.mkdir(parents=True)
        (self.mp / "scripts").mkdir()
        for f in RECOVERY:
            p = self.mp / "scripts" / f
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("recovery " + f + "\n")
        (self.lib / "libRCN_DiagnosticsLib.so").write_bytes(live)
        if preserved is not None:
            (self.lib / "libRCN_DiagnosticsOld.so").write_bytes(preserved)
        if payload:
            m = self.usb / "yafc-payload"
            m.mkdir(parents=True)
            (m / "libyafc.so").write_bytes(YAFC)
            shutil.copy2(REPO / "payload/config/camera.conf", m / "camera.conf")
            probe = m / "slotprobe"
            if probe_ok:
                probe.write_bytes(f"""#!/bin/sh
set -e
echo 'needed libRCN_DiagnosticsLib.so'
echo 'slot diagnostics_async_base_logs fname={self.lib.as_posix()}/libRCN_DiagnosticsOld.so same=yes'
echo 'slot forensics_logworthy_async fname={self.lib.as_posix()}/libRCN_DiagnosticsOld.so same=yes'
echo 'slot screen_create_window fname=/usr/lib/libscreen.so.1 same=yes'
echo 'slot screen_post_window fname=/usr/lib/libscreen.so.1 same=yes'
echo 'loaded from: {self.lib.as_posix()}/libRCN_DiagnosticsLib.so' >&2
""".replace("\r\n", "\n").encode())
            else:
                probe.write_bytes(b"#!/bin/sh\necho 'the pair did not load' >&2\nexit 1\n")
            probe.chmod(0o755)
            if hmi:
                shutil.copytree(REPO / "payload/hmi", m / "hmi")
                (self.usb / "tools").mkdir(exist_ok=True)
                shutil.copy2(REPO / "tools/apply-hmi-fragments.sh", self.usb / "tools/apply-hmi-fragments.sh")
        if hmi:
            for rel, text in (stock or STOCK).items():
                p = self.mp / "fordhmi/qml" / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(text.encode())
            if not fragments:
                shutil.rmtree(self.usb / "yafc-payload/hmi", ignore_errors=True)
        self.imgdir = self.fake / "images"
        self.imgdir.mkdir(parents=True)
        layers = OVL + [BASE] if stack is None else stack
        for name in dict.fromkeys([*images, *layers]):
            if not name.startswith("/"):
                (self.imgdir / name).write_bytes(b"OTHER-IMAGE-" + name.encode())
        (self.fake / "stack").write_bytes(("\n".join(layers) + "\n").encode())
        (self.fake / "busy").write_bytes(("\n".join(busy) + "\n").encode())
        if IMG in layers and hmi:
            qml = self.mp / "fordhmi/qml"
            shutil.copytree(qml, self.fake / "stock-qml")
            popup = qml / "hmirvc/+10inchP/RVCPopup.qml"
            popup.write_text("previous YAFC overlay; lacks stock anchors\n")
        for n, body in (("mount", FAKE_MOUNT), ("umount", FAKE_UMOUNT), ("dinit", FAKE_DINIT),
                        ("devb-loopback", FAKE_LOOP), ("mkqnx6fs", FAKE_MKQNX6),
                        ("chkqnx6fs", FAKE_CHK), ("cp", FAKE_CP), ("mv", FAKE_MV), ("rm", FAKE_RM)):
            p = self.fake / n
            p.write_bytes(body.encode())
            p.chmod(p.stat().st_mode | stat.S_IEXEC)
        (self.fake / "dev-yafchmi-0").unlink(missing_ok=True)

    def arm(self, name, in_syncmymod=False):
        d = self.usb / "SyncMyMod" if in_syncmymod else self.usb
        (d / name).write_text("")

    def dispatch(self, **env):
        e = dict(os.environ, FAKE=str(self.fake), SLOT_MP=str(self.mp), YAFC_MP=str(self.mp),
                 YAFC_DATA=str(self.data / "yafc"), YAFC_SCRATCH=str(self.fake / "scratch"),
                 YAFC_IMGDIR=str(self.imgdir), YAFC_HMI_DEV=str(self.fake / "dev-yafchmi-0"),
                 PATH=f"{self.fake}:{os.environ['PATH']}")
        e.update(env)
        script = self.usb / "SyncMyMod/autoinstall.sh"
        e["YAFC_MP"] = self.mp.as_posix()
        e["YAFC_DATA"] = (self.data / "yafc").as_posix()
        e["YAFC_SCRATCH"] = (self.fake / "scratch").as_posix()
        e["YAFC_IMGDIR"] = self.imgdir.as_posix()
        e["YAFC_HMI_DEV"] = (self.fake / "dev-yafchmi-0").as_posix()
        e["FAKE"] = self.fake.as_posix()
        e["SLOT_MP"] = self.mp.as_posix()
        return subprocess.run(["dash", "./" + script.relative_to(self.root).as_posix()], env=e,
                              capture_output=True, text=True, timeout=60, cwd=self.root)

    def ops(self):
        return (self.fake / "ops").read_text().splitlines() if (self.fake / "ops").exists() else []

    def stack(self):
        return (self.fake / "stack").read_text().split()

    def log(self):
        p = self.usb / "yafc-install/install.log"
        return p.read_text() if p.exists() else ""

    def seen(self):
        p = self.usb / "yafc-install/seen.log"
        return p.read_text() if p.exists() else ""

    def live(self):
        return sha(self.lib / "libRCN_DiagnosticsLib.so")

    def preserved(self):
        p = self.lib / "libRCN_DiagnosticsOld.so"
        return sha(p) if p.exists() else None

    def done(self):
        return (self.usb / "yafc-install/DONE").exists()

    def failed(self):
        return (self.usb / "yafc-install/FAILED").exists()

    def image(self):
        p = self.imgdir / IMG
        return sha(p) if p.is_file() else None

    def images(self):
        return sorted(x.name for x in self.imgdir.iterdir() if x.name not in OVL)

    def failed_text(self):
        p = self.usb / "yafc-install/FAILED"
        return p.read_text() if p.exists() else ""


def main() -> int:
    fails = 0

    def check(name, cond, rig=None):
        nonlocal fails
        if cond:
            print("PASS", name)
        else:
            fails += 1
            print("FAIL", name)
            if rig:
                print("  log:", rig.log().replace("\n", " | "), file=sys.stderr)
                print("  failed:", rig.failed_text().replace("\n", " | "), file=sys.stderr)
                print("  images:", rig.images(), "image:", rig.image(), file=sys.stderr)
                print("  ops:", rig.ops(), file=sys.stderr)

    vendor_sha = hashlib.sha256(VENDOR).hexdigest()
    yafc_sha = hashlib.sha256(YAFC).hexdigest()

    with TemporaryDirectory() as t:
        g = Rig(Path(t))

        # 1. no marker: nothing at all happens
        g.reset()
        r = g.dispatch()
        check("1 no marker: nothing done, and the stick says so",
              r.returncode == 0 and not g.ops() and g.live() == vendor_sha
              and "no marker" in g.seen(), g)

        # 2. two markers: refused
        g.reset()
        g.arm("RUN-YAFC-INSTALL")
        g.arm("RUN-YAFC-DISABLE", in_syncmymod=True)
        r = g.dispatch()
        check("2 two markers: refused, nothing run",
              r.returncode == 1 and not g.ops() and g.live() == vendor_sha
              and (g.usb / "RUN-YAFC-INSTALL").exists(), g)

        # 3. install happy path
        g.reset()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        order = [o.split()[0] + " " + o.split()[1] for o in g.ops() if o.startswith(("mount", "umount"))]
        check("3 install: preserved copy made, new library written, probe passed",
              r.returncode == 0 and g.done() and g.live() == yafc_sha
              and g.preserved() == vendor_sha and "passed the loader probe" in g.log(), g)
        check("3 install: stack restored by replay, marker consumed",
              [o for o in g.ops() if o.startswith("mount -b -r -t qnx6 -o before")] ==
                  [f"mount -b -r -t qnx6 -o before {g.imgdir / d} {g.mp}" for d in OVL]
              and not (g.usb / "RUN-YAFC-INSTALL").exists()
              and order[:2] == ["umount " + str(g.mp)] * 2, g)
        config = g.data / "yafc/camera.conf"
        check("3 fresh install: initializes the exact staged config",
              config.is_file() and config.read_bytes() ==
              (g.usb / "yafc-payload/camera.conf").read_bytes(), g)

        # 4. install probe failure: the unit's own library goes back
        g.reset(probe_ok=False)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("4 probe failure: the unit's own library is back in the slot",
              r.returncode == 4 and g.failed() and not g.done() and g.live() == vendor_sha
              and g.preserved() == vendor_sha and "back in the slot" in g.log(), g)
        check("4 probe failure: the mount stack is still restored", g.stack() == OVL + [BASE], g)

        # 5. upgrade: an existing preserved copy is kept, not overwritten
        g.reset(live=YAFC, preserved=VENDOR)
        config.parent.mkdir(parents=True)
        saved = b"enabled=0\nmode=pass\nfront_view=frontwide\n# keep my settings\n"
        config.write_bytes(saved)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("5 upgrade: preserved copy untouched, slot re-written",
              r.returncode == 0 and g.done() and g.live() == yafc_sha and g.preserved() == vendor_sha, g)
        check("5 upgrade: preserves camera.conf byte for byte",
              config.read_bytes() == saved, g)

        # 6. rehearse: the unit's own bytes through the real path, picture unchanged
        g.reset()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("6 rehearse: bytes written through the path, content unchanged",
              r.returncode == 0 and g.done() and g.live() == vendor_sha
              and "rehearsal" in g.log() and not config.exists(), g)

        # 7. remove
        g.reset(live=YAFC, preserved=VENDOR)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("7 remove: unit's library restored and the preserved copy deleted",
              r.returncode == 0 and g.done() and g.live() == vendor_sha and g.preserved() is None, g)

        # 8. disable touches nothing under /fs/mp
        g.reset()
        g.arm("RUN-YAFC-DISABLE")
        r = g.dispatch()
        check("8 disable: kill switch written, no mount work, slot untouched",
              r.returncode == 0 and (g.data / "yafc/DISABLE").is_file() and not g.ops()
              and g.live() == vendor_sha and g.done(), g)

        # 9. a busy layer aborts; the mount work may leave the image order reversed,
        #    which the worker says in its log rather than claiming success.
        g.reset(busy=[OVL[1]])
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("9 busy layer: aborts, nothing written, order may be reversed",
              r.returncode == 5 and g.failed() and g.live() == vendor_sha
              and g.stack() == OVL[::-1] + [BASE]
              and "cannot restore the exact" in g.failed_text()
              and not any(o.startswith("mount -uw") for o in g.ops()), g)

        # 10. base device missing
        g.reset(stack=["/fs/images/overlay_a.img"])
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("10 base device missing: aborts before any write",
              r.returncode == 3 and not g.ops() and g.live() == vendor_sha, g)

        # 11. base on top is never unmounted
        g.reset(stack=[BASE] + OVL)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("11 base on top: refused, nothing unmounted", r.returncode == 3 and not g.ops(), g)

        # 12. a recovery script changed during the run
        g.reset()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_TAMPER="1")
        check("12 recovery script changed: fails loudly and keeps the marker",
              r.returncode == 6 and g.failed() and not g.done()
              and "recovery script changed" in g.log(), g)

        # 13. no payload staged: refuse before touching anything
        g.reset(payload=False)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("13 no payload: refused with nothing written",
              r.returncode == 3 and g.failed() and not g.ops() and g.live() == vendor_sha, g)

        # 14. install with HMI: image built at the expected name only, hashes verified
        g.reset()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        ops = g.ops()
        check("14 install HMI: image built, read back and published",
              r.returncode == 0 and g.done() and g.image() is not None
              and g.images() == [IMG]
              and "read-back matches" in g.log() and "published" in g.log(), g)
        check("14 install HMI: the recipe ran in order",
              [o.split()[0] for o in ops if o.startswith(("dinit", "devb-loopback", "mkqnx6fs", "chkqnx6fs"))] ==
              ["dinit", "devb-loopback", "mkqnx6fs", "chkqnx6fs"], g)
        imgroot = g.fake / "imgroot/fordhmi/qml"
        popup = (imgroot / "hmirvc/+10inchP/RVCPopup.qml").read_text() if (imgroot / "hmirvc/+10inchP/RVCPopup.qml").exists() else ""
        settings = (imgroot / "hmisettings/driverassistance/+10inchP/RVCSettings.qml").read_text() if (imgroot / "hmisettings/driverassistance/+10inchP/RVCSettings.qml").exists() else ""
        root = (imgroot / "+10inchP/Root.qml").read_text() if (imgroot / "+10inchP/Root.qml").exists() else ""
        style = (imgroot / "themes/ford-10P-MY20/styles/RVCPopupStyle.qml").read_text() if (imgroot / "themes/ford-10P-MY20/styles/RVCPopupStyle.qml").exists() else ""
        try:
            with tarfile.open(g.imgdir / IMG) as image:
                files = sorted(member.name.removeprefix("./") for member in image if member.isfile())
        except (OSError, tarfile.TarError):
            files = []
        check("14 install HMI: only the four patched files are in the published image",
              files == sorted("fordhmi/qml/" + rel for rel in STOCK)
              and not list(g.imgdir.glob(".yafc-build.*.img")), g)
        check("14 install HMI: all current fragments changed their targets",
              "rvcPopupComponentHeight: 480" in style and "yafcPopupComponentHeight: 1208" in style
              and "yafcViews" in popup and "yafcPublishView" in popup
              and "yafcCover" in popup and "yafcViewButton" in popup
              and "top: yafcShown ? undefined : container.bottom" in popup
              and "property bool yafcEnabled:" in settings and "yafcCamFull" in root, g)
        replay = [i for i, op in enumerate(ops) if op.startswith("mount -b -r -t qnx6 -o before")]
        published = [i for i, op in enumerate(ops) if op.startswith("publish ")]
        check("14 install HMI: mount stack replayed after publishing",
              len(published) == 1 and len(replay) == 2 and replay[0] > published[0]
              and g.stack() == OVL + [BASE], g)
        node = shutil.which("node")
        js_paths = [str(REPO / "tools/test-hmi-behavior.js"), str(imgroot)]
        if (not node and sys.platform == "linux" and (wslpath := shutil.which("wslpath"))
                and (node := shutil.which("node.exe"))):
            js_paths = [subprocess.check_output([wslpath, "-aw", path], text=True).strip()
                        for path in js_paths]
        if not node:
            sys.exit("HMI behavior test requires Node.js (node or, under WSL, node.exe on PATH)")
        js = subprocess.run([node, *js_paths], capture_output=True, text=True, timeout=10)
        if js.returncode:
            print(js.stderr, file=sys.stderr)
        check("14 HMI behavior: factory fallback, settings and every camera default", js.returncode == 0, g)

        # 15. HMI refused on a stale anchor: library stays, no image, FAILED says HMI only
        stale = dict(STOCK)
        stale["themes/ford-10P-MY20/styles/RVCPopupStyle.qml"] = "Item {\r\n    rvcPopupComponentHeight: 999\r\n}\r\n"
        g.reset(stock=stale)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("15 HMI refused: library stays, no image, FAILED says HMI only",
              r.returncode == 9 and g.failed() and not g.done() and g.live() == yafc_sha
              and g.preserved() == vendor_sha and g.image() is None
              and "HMI only" in g.failed_text() and "applier refused" in g.log()
              and g.stack() == OVL + [BASE], g)

        # 15b. duplicate anchor refuses the same way
        dup = dict(STOCK)
        dup["+10inchP/Root.qml"] = STOCK["+10inchP/Root.qml"].replace(
            "    property bool fullScreenTransparentPopupStacked: false\r\n",
            "    property bool fullScreenTransparentPopupStacked: false\r\n"
            "    property bool fullScreenTransparentPopupStacked: false\r\n")
        g.reset(stock=dup)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("15b duplicate anchor: refused, library stays, no image",
              r.returncode == 9 and g.failed() and g.live() == yafc_sha and g.image() is None
              and "HMI only" in g.failed_text(), g)

        # 16. rehearse builds and reads back but never writes /fs/images
        g.reset()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("16 rehearse HMI: built and read back, /fs/images untouched",
              r.returncode == 0 and g.done() and g.images() == []
              and "would publish" in g.log() and "read-back matches" in g.log(), g)

        # 17. remove deletes the image and restores the library
        g.reset(live=YAFC, preserved=VENDOR, stack=[OVL[0], IMG, OVL[1], BASE])
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("17 remove: image deleted, library restored, preserved copy gone",
              r.returncode == 0 and g.done() and g.live() == vendor_sha
              and g.preserved() is None and g.images() == [] and g.stack() == OVL + [BASE], g)

        # 18. remove with only the library (no image): clean success
        g.reset(live=YAFC, preserved=VENDOR)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("18 remove, no image: clean success",
              r.returncode == 0 and g.done() and g.live() == vendor_sha and g.images() == [], g)

        # 19. remove with only the image (no preserved copy): image goes, success
        g.reset(live=YAFC, images=[IMG])
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("19 remove, only image: image deleted, nothing to restore",
              r.returncode == 0 and g.done() and g.images() == [] and g.live() == yafc_sha
              and "no preserved copy" in g.log(), g)

        # 20. remove with neither: clean no-op success
        g.reset(live=YAFC)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("20 remove, neither: no-op success",
              r.returncode == 0 and g.done() and g.images() == [] and g.live() == yafc_sha, g)

        # 21. remove-hmi deletes only the image; the library is untouched
        g.reset(live=YAFC, preserved=VENDOR, stack=[OVL[0], IMG, OVL[1], BASE], payload=False)
        g.arm("RUN-YAFC-REMOVE-HMI")
        r = g.dispatch()
        check("21 remove-hmi: image gone, library and preserved copy untouched",
              r.returncode == 0 and g.done() and g.images() == []
              and g.live() == yafc_sha and g.preserved() == vendor_sha
              and g.stack() == OVL + [BASE] and not any("-uw" in op for op in g.ops()), g)

        # 22. another overlay image is never touched
        other = "overlay_00--other.img"
        g.reset(live=YAFC, preserved=VENDOR, images=[other, IMG])
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("22 remove: another overlay image is never touched",
              r.returncode == 0 and g.done() and g.images() == [other]
              and (g.imgdir / other).read_bytes() == b"OTHER-IMAGE-" + other.encode(), g)

        # 23. recovery scripts unchanged after an HMI install
        g.reset()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("23 HMI install: recovery scripts unchanged",
              r.returncode == 0 and g.done()
              and all((g.mp / "scripts" / f).read_text() == "recovery " + f + "\n" for f in RECOVERY), g)

        # 24. an empty HMI directory cannot publish a stock-only image
        g.reset()
        shutil.rmtree(g.usb / "yafc-payload/hmi")
        (g.usb / "yafc-payload/hmi").mkdir()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("24 empty HMI set: refused, library stays, no image",
              r.returncode == 9 and g.failed() and g.live() == yafc_sha and g.image() is None
              and "missing required HMI fragment" in g.log(), g)

        # 25. remove-hmi also removes the previous-image backup
        g.reset(live=YAFC, preserved=VENDOR, images=[IMG, IMG + ".old"])
        g.arm("RUN-YAFC-REMOVE-HMI")
        r = g.dispatch()
        check("25 remove-hmi: image and backup gone, library untouched",
              r.returncode == 0 and g.done() and g.images() == [] and g.live() == yafc_sha
              and g.preserved() == vendor_sha, g)

        # 26. the current view mailbox fragment set is what the installer stages
        g.reset()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        staged = g.usb / "yafc-payload/hmi"
        check("26 current HMI set: popup fragments staged, legacy panel set absent",
              r.returncode == 0 and (staged / "popup-1-state.fragment").is_file()
              and (staged / "popup-8-text-margin.fragment").is_file()
              and not list(staged.glob("panel-*.fragment"))
              and "yafc-view" in (staged / "popup-1-state.fragment").read_text(), g)

        mounted = [OVL[0], IMG, OVL[1], BASE]
        old = "OTHER-IMAGE-" + IMG
        g.reset(live=YAFC, preserved=VENDOR, stack=mounted)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_REPLACE_OLD=old)
        check("27 upgrade: builds from stock, atomically replaces mounted image, replays exact stack",
              r.returncode == 0 and g.done() and g.stack() == mounted
              and (g.imgdir / IMG).read_bytes() != old.encode()
              and "yafcViews" in (g.mp / "fordhmi/qml/hmirvc/+10inchP/RVCPopup.qml").read_text(), g)

        for fault in ("FAKE_PUBLISH_FAIL", "FAKE_PUBLISH_CORRUPT"):
            g.reset(live=YAFC, preserved=VENDOR, stack=mounted)
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch(FAKE_REPLACE_OLD=old, **{fault: "1"})
            check(f"28 {fault}: retains old image and exact stack, cleans staging, keeps marker",
                  r.returncode == 12 and g.failed() and not g.done() and g.stack() == mounted
                  and g.images() == [IMG] and (g.imgdir / IMG).read_bytes() == old.encode()
                  and (g.usb / "RUN-YAFC-INSTALL.running").is_file()
                  and "HMI only" in g.failed_text()
                  and (fault != "FAKE_PUBLISH_CORRUPT" or not any(op.startswith("publish ") for op in g.ops())), g)

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted)
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("29 rehearsal over existing install leaves slot, configuration and mounted image intact",
              r.returncode == 0 and g.done() and g.stack() == mounted and g.live() == yafc_sha
              and g.preserved() == vendor_sha and (g.imgdir / IMG).read_bytes() == old.encode()
              and not config.exists() and not any(op.startswith(("stage ", "publish ")) for op in g.ops()), g)

        for mode, victim in (("REMOVE-HMI", IMG), ("REMOVE-HMI", IMG + ".old"), ("REMOVE", IMG)):
            g.reset(live=YAFC, preserved=VENDOR, stack=mounted, images=[IMG + ".old"])
            g.arm("RUN-YAFC-" + mode)
            r = g.dispatch(FAKE_DELETE_FAIL=victim)
            check(f"30 {mode} failure deleting {victim}: exact stack, active image and library preserved",
                  r.returncode == 12 and g.failed() and not g.done() and g.stack() == mounted
                  and (g.imgdir / IMG).read_bytes() == old.encode()
                  and g.live() == yafc_sha and g.preserved() == vendor_sha
                  and "cannot delete" in g.failed_text()
                  and (g.usb / f"RUN-YAFC-{mode}.running").is_file(), g)

        for fault in ("FAKE_MKFS_FAIL", "FAKE_READBACK_CORRUPT"):
            g.reset(live=YAFC, preserved=VENDOR, stack=mounted)
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch(**{fault: "1"})
            check(f"31 {fault}: build error survives cleanup, exact stack and old image restored",
                  r.returncode == 10 and g.failed() and not g.done() and g.stack() == mounted
                  and (g.imgdir / IMG).read_bytes() == old.encode()
                  and not (g.fake / "scratch").exists() and not (g.fake / "image-mode").exists()
                  and not (g.fake / "dev-yafchmi-0").exists()
                  and "HMI image build or read-back failed" in g.failed_text(), g)

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_READBACK_CORRUPT="1", FAKE_BUILD_BUSY="ro")
        check("32 busy read-back mount: refuses scratch deletion and reports original failure",
              r.returncode == 10 and g.failed() and not g.done() and g.stack() == mounted
              and "HMI image build or read-back failed" in g.failed_text()
              and "scratch retained" in g.failed_text() and "clean scratch" not in g.ops()
              and (g.fake / "scratch/mnt").is_dir(), g)

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted)
        (g.usb / "yafc-payload/hmi/popup-1-state.fragment").unlink()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("33 incomplete nonempty set: missing state rejected before any image build",
              r.returncode == 9 and g.failed() and not g.done() and g.stack() == mounted
              and "missing required HMI fragment popup-1-state" in g.failed_text()
              and (g.imgdir / IMG).read_bytes() == old.encode()
              and not any(op.startswith("dinit ") for op in g.ops()), g)

        g.reset(stack=mounted)
        (g.usb / "yafc-payload/camera.conf").unlink()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("34 fresh install without defaults: refuses before writing slot or HMI image",
              r.returncode == 4 and g.failed() and not g.done() and g.stack() == mounted
              and g.live() == vendor_sha and g.preserved() is None and not config.exists()
              and (g.imgdir / IMG).read_bytes() == old.encode(), g)

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted)
        g.arm("RUN-YAFC-REMOVE-HMI")
        r = g.dispatch(FAKE_REPLAY_FAIL=OVL[0])
        check("35 remount failure after successful removal: reports failure, not DONE",
              r.returncode == 5 and g.failed() and not g.done() and g.image() is None
              and g.stack() == [OVL[1], BASE] and g.live() == yafc_sha
              and "cannot restore the exact" in g.failed_text(), g)

        g.reset()
        (g.fake / "rw").touch()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("36 original writable base remains writable and exact layers replay",
              r.returncode == 0 and g.done() and (g.fake / "rw").exists() and g.stack() == OVL + [BASE]
              and not any(op.startswith(("mount -uw ", "mount -ur ")) for op in g.ops()), g)

        g.reset()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch(FAKE_BARE_MOUNT="1")
        check("36 captured bare mount format: base is made writable then restored read-only",
              r.returncode == 0 and g.done() and not (g.fake / "rw").exists()
              and f"mount -uw {g.mp}" in g.ops() and f"mount -ur {g.mp}" in g.ops()
              and g.stack() == OVL + [BASE], g)

        g.reset(stack=mounted)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_RO_FAIL="1")
        check("36 failed read-only remount: no image publication or success receipt",
              r.returncode == 4 and g.failed() and not g.done()
              and g.stack() == mounted and (g.fake / "rw").exists()
              and (g.imgdir / IMG).read_bytes() == old.encode()
              and "mount -ur failed" in g.failed_text()
              and not any(op.startswith("dinit ") for op in g.ops()), g)

        project = g.root / "package-source"
        for dst in ("tools", "installer", "payload"):
            shutil.copytree(REPO / dst, project / dst)
        bin_dir = project / "toolchain/bin"
        bin_dir.mkdir(parents=True)
        probe = project / "toolchain/probe/bin/slotprobe"
        probe.parent.mkdir(parents=True)
        shutil.copy2(g.usb / "yafc-payload/slotprobe", probe)
        lib = bin_dir / "libyafc.so"
        stick = g.root / "package-stick"
        lib.write_bytes(b"\x7fELF\x00stale\x00")
        cmd = ["dash", str(project / "tools/make-usb.sh"), str(stick)]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        check("37 packaging rejects stale binary before touching the stick",
              r.returncode != 0 and "lacks the HMI mailbox" in r.stderr and not stick.exists())
        rebuilt = b"\x7fELF\x00/fs/tmpfs/yafc-view\x00"
        lib.write_bytes(rebuilt)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        check("37 packaging accepts the mailbox-capable artifact and stages its bytes unarmed",
              r.returncode == 0 and (stick / "yafc-payload/libyafc.so").read_bytes() == rebuilt
              and not list(stick.glob("RUN-YAFC-*")))

    print("\n%s" % ("ALL PASS" if not fails else f"{fails} FAILED"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
