#!/usr/bin/env python3
"""Mocked-unit rehearsal for installer/yafc-install.sh and its dispatcher.

Runs the REAL scripts against a fake /fs/mp tree, with fake mount, umount, cksum
and the qnx6 image tools on PATH (a layer stack kept in a file). Proves the host
contracts only: ownership refusals, the journal, write order, rollback, recovery,
the mount-stack handling, the HMI call order and the marker dispatch. It cannot
prove qnx6, loader or radio behaviour and it never touches a radio.

The fake image mounts expose the files the installer actually wrote, and other
boot overlays are real tar archives that the installer inspects. The mock refuses
deletion or replacement of mounted images and scratch deletion while an image is
mounted. FAKE_KILL=<op>@<signal> signals the worker when a fake tool sees <op>:
TERM exercises the trap and rollback, KILL a crash that only RUN-YAFC-RECOVER can
resolve. The rig's copy of the installer accepts the invented vendor library as
the recorded stock build; nothing else in the script is changed.

Needs: dash, openssl, tar, Node.js (WSL can use node.exe), python3.
Run: python3 -I tools/test-install.py
"""
import hashlib
import io
import os
import re
import shutil
import signal
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
PREVIOUS = b"YAFC-previous-release"        # an older owned YAFC slot library
IMG = "overlay_00--yafc.img"
OLD_IMAGE = b"OTHER-IMAGE-" + IMG.encode() # an owned image from an earlier install
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

# Shared by every shell fake: log the operation and, once, signal the worker.
HOOK = r'''
fake_op() {
  echo "$*" >> "$FAKE/ops"
  [ -n "${FAKE_KILL-}" ] && [ ! -e "$FAKE/killed" ] || return 0
  case "$*" in *"${FAKE_KILL%@*}"*) ;; *) return 0 ;; esac
  : > "$FAKE/killed"
  i=0
  while [ ! -s "$FAKE/worker.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill -s "${FAKE_KILL##*@}" "$(cat "$FAKE/worker.pid")"
}
'''
FAKE_MOUNT = "#!/bin/sh\nset -eu\n" + HOOK + r'''
S=$FAKE/stack
[ $# -eq 0 ] || fake_op "mount $*"
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
      done < "$S"
      if [ -f "$FAKE/image-mode" ]; then
        if [ -n "${FAKE_BARE_MOUNT-}" ]; then
          echo "$(cat "$FAKE/image-src") on $YAFC_SCRATCH/mnt type qnx6"
        else
          echo "$(cat "$FAKE/image-src") on $YAFC_SCRATCH/mnt type qnx6 ($(cat "$FAKE/image-mode"))"
        fi
      fi ;;
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
        if [ -n "${FAKE_READBACK_CORRUPT-}" ] && [ "$5" = "$(cat "$FAKE/backing" 2>/dev/null)" ]; then
          printf damaged >> "$6/fordhmi/qml/+10inchP/Root.qml"
        fi
        echo "$5" > "$FAKE/image-src"
        echo ro > "$FAKE/image-mode"
      else
        [ "$#" = 8 ] && [ "$2 $3 $4 $5 $6" = "-r -t qnx6 -o before" ] && [ "$8" = "$SLOT_MP" ]
        [ -f "$7" ]
        dev=${7##*/}
        if [ -n "${FAKE_REPLAY_FAIL-}" ] && [ "$dev" = "${FAKE_REPLAY_FAIL%%:*}" ]; then
          echo "$dev" >> "$FAKE/replays"
          from=1
          case "$FAKE_REPLAY_FAIL" in *:*) from=${FAKE_REPLAY_FAIL#*:} ;; esac
          [ "$(grep -cxF "$dev" "$FAKE/replays")" -lt "$from" ] || exit 1
        fi
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
      echo "$3" > "$FAKE/image-src"
      echo rw > "$FAKE/image-mode" ;;
  *) exit 1 ;;
esac
'''
FAKE_DINIT = "#!/bin/sh\n" + HOOK + r'''
fake_op "dinit $*"
[ "$1 $2" = "-hq -S4m" ] || exit 1
printf 'BACKING' > "$3"
'''
FAKE_LOOP = r'''#!/usr/bin/env python3
import os
import signal
import sys
from pathlib import Path
fake = Path(os.environ["FAKE"])
device = Path(os.environ["YAFC_HMI_DEV"])
def stop(*_):
    device.unlink(missing_ok=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
with (fake / "ops").open("a") as out:
    out.write("devb-loopback " + " ".join(sys.argv[1:]) + "\n")
backing = [a for a in sys.argv[1:] if a.startswith("fd=")][0][3:].split(",")[0]
(fake / "backing").write_text(backing)
(fake / "loop.pid").write_text(str(os.getpid()))
device.touch()
signal.pause()
'''
FAKE_MKQNX6 = "#!/bin/sh\n" + HOOK + r'''
fake_op "mkqnx6fs $*"
[ -z "${FAKE_MKFS_FAIL-}" ] && [ -f "$4" ] || exit 1
: > "$FAKE/formatted"
'''
FAKE_CHK = "#!/bin/sh\n" + HOOK + r'''
fake_op "chkqnx6fs $*"
[ -s "$1" ] && tar -tf "$1" >/dev/null && [ ! -e "$YAFC_HMI_DEV" ] &&
  [ ! -e "$FAKE/image-mode" ]
'''
FAKE_UMOUNT = "#!/bin/sh\nset -eu\n" + HOOK + r'''
fake_op "umount $*"
if [ "$1" = "$YAFC_SCRATCH/mnt" ]; then
  [ -f "$FAKE/image-mode" ] || exit 1
  mode=$(cat "$FAKE/image-mode")
  src=$(cat "$FAKE/image-src")
  backing=$(cat "$FAKE/backing" 2>/dev/null || true)
  if [ "${FAKE_BUILD_BUSY-}" = "$mode" ] && { [ "$mode" = rw ] || [ "$src" = "$backing" ]; }; then
    exit 1
  fi
  if [ "$mode" = rw ]; then
    tar -cf "$backing" -C "$1" .
    /bin/rm -rf "$1"
  else
    /bin/rm -rf "$FAKE/imgroot"
    /bin/mv "$1" "$FAKE/imgroot"
    if [ "$src" = "$backing" ] && [ -n "${FAKE_PUBLISH_CORRUPT-}" ]; then
      printf damaged >> "$backing"
    fi
  fi
  mkdir "$1"
  /bin/rm "$FAKE/image-mode" "$FAKE/image-src"
else
  [ "$1" = "$SLOT_MP" ]
  read -r top < "$FAKE/stack"
  [ "$top" != /dev/hd0t178 ]
  if grep -qxF "$top" "$FAKE/busy"; then exit 1; fi
  sed '1d' "$FAKE/stack" > "$FAKE/stack.n"
  /bin/mv "$FAKE/stack.n" "$FAKE/stack"
  if [ "$top" = overlay_00--yafc.img ] && [ -d "$FAKE/stock-qml" ]; then
    /bin/rm -rf "$FAKE/overlay-qml"
    /bin/mv "$SLOT_MP/fordhmi/qml" "$FAKE/overlay-qml"
    /bin/mv "$FAKE/stock-qml" "$SLOT_MP/fordhmi/qml"
  fi
fi
'''
FAKE_CP = "#!/bin/sh\n" + HOOK + r'''
case "$1" in
  "$SLOT_MP"/fordhmi/qml/*)
    [ "$(cat "$FAKE/stack")" = /dev/hd0t178 ] || exit 1 ;;
esac
case "$2" in
  "$YAFC_DATA"/*|"$SLOT_MP"/apps/usr/lib/*) fake_op "copy $1 $2" ;;
esac
exec /bin/cp "$@"
'''
FAKE_MV = "#!/bin/sh\n" + HOOK + r'''
[ "$1" != -f ] || shift
case "$2" in
  "$YAFC_IMGDIR"/overlay_00--yafc.img)
    fake_op "publish $1 $2"
    ! grep -qxF overlay_00--yafc.img "$FAKE/stack" || exit 1
    [ "${1%/*}" = "$YAFC_IMGDIR" ] || exit 1
    case "${1##*/}" in
      .yafc-build.*.img)
        if [ -n "${FAKE_REPLACE_OLD-}" ]; then
          [ -f "$2" ] && [ "$(cat "$2")" = "$FAKE_REPLACE_OLD" ] || exit 1
        fi
        [ -z "${FAKE_PUBLISH_FAIL-}" ] || exit 1 ;;
      .yafc-restore.*.img) ;;
      *) exit 1 ;;
    esac
    /bin/mv -f "$1" "$2"
    [ -z "${FAKE_PUBLISH_CORRUPT_AFTER-}" ] || printf damaged >> "$2"
    exit 0 ;;
  "$YAFC_DATA"/*|"$SLOT_MP"/apps/usr/lib/*) fake_op "rename $1 $2" ;;
esac
case "$1" in
  "$YAFC_IMGDIR"/overlay_00--yafc.img)
    ! grep -qxF overlay_00--yafc.img "$FAKE/stack" || exit 1 ;;
esac
exec /bin/mv "$@"
'''
FAKE_RM = "#!/bin/sh\n" + HOOK + r'''
for path do
  case "$path" in
    "$YAFC_IMGDIR"/overlay_00--yafc.img*)
      fake_op "delete $path"
      ! grep -qxF "${path##*/}" "$FAKE/stack" || exit 1
      [ "${path##*/}" != "${FAKE_DELETE_FAIL-}" ] || exit 1 ;;
    "$SLOT_MP"/apps/usr/lib/libRCN_Diagnostics*)
      fake_op "delete $path" ;;
    "$YAFC_SCRATCH")
      fake_op "clean scratch"
      [ ! -e "$FAKE/image-mode" ] && [ ! -e "$YAFC_HMI_DEV" ] || exit 1 ;;
  esac
done
exec /bin/rm "$@"
'''
# A layer named in FAKE_SCRIPT_LAYER provides its own recovery scripts while mounted.
FAKE_CKSUM = r'''#!/bin/sh
case "${1-}" in
  "$SLOT_MP"/scripts/*)
    if [ -n "${FAKE_SCRIPT_LAYER-}" ] && grep -qxF "$FAKE_SCRIPT_LAYER" "$FAKE/stack"; then
      echo "999 1 $1"
      exit 0
    fi ;;
esac
PATH=${PATH#*:}
exec cksum "$@"
'''


def probe_script(lib, kind):
    """The loader probe stand-in. Its loader trace appears only with DL_DEBUG=libs."""
    lines = ["#!/bin/sh", HOOK, 'fake_op "probe DL_DEBUG=${DL_DEBUG-}"']
    if kind == "fail":
        return "\n".join(lines + ["echo 'the pair did not load' >&2", "exit 1", ""])
    where = "/usr/lib" if kind == "elsewhere" else lib
    if kind != "notrace":
        lines += ['if [ "${DL_DEBUG-}" = libs ]; then',
                  f"  echo 'libs: libRCN_DiagnosticsLib.so loaded from: {where}/libRCN_DiagnosticsLib.so' >&2",
                  f"  echo 'libs: libRCN_DiagnosticsOld.so loaded from: {lib}/libRCN_DiagnosticsOld.so' >&2",
                  "fi"]
    screen = f"{lib}/libRCN_DiagnosticsLib.so" if kind == "screen" else "/usr/lib/libscreen.so.1"
    lines += ["echo 'slotprobe start'", "echo 'needed libRCN_DiagnosticsLib.so'"]
    for name, owner in (("diagnostics_async_base_logs", f"{lib}/libRCN_DiagnosticsOld.so"),
                        ("forensics_logworthy_async", f"{lib}/libRCN_DiagnosticsOld.so"),
                        ("screen_create_window", screen), ("screen_post_window", screen)):
        lines.append(f"echo 'slot {name} got=0x1 val=0x2 fname={owner} sname={name} dlsym=0x2 same=yes'")
    lines += ["echo 'slotprobe done'", ""]
    return "\n".join(lines)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def overlay_tar(files):
    """A boot overlay image as the fake mount sees it: a tar archive."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for rel, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo("./" + rel)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class Rig:
    def __init__(self, root: Path):
        self.root = root
        self.usb, self.mp, self.fake, self.data = (root / n for n in ("usb", "mp", "fake", "rwdata"))
        self.lib = self.mp / "apps/usr/lib"
        self.ydata = self.data / "yafc"

    def reset(self, live=VENDOR, preserved=None, stack=None, busy=(), payload=True, probe="ok",
              hmi=True, stock=None, fragments=True, images=(), owned=False, overlays=None):
        for d in (self.usb, self.mp, self.fake, self.data):
            shutil.rmtree(d, ignore_errors=True)
        (self.usb / "SyncMyMod").mkdir(parents=True)
        script = (SRC / "yafc-install.sh").read_text()
        script, n = re.subn(r"^FACTORY=[0-9a-f]{64}$", "FACTORY=" + digest(VENDOR), script, flags=re.M)
        assert n == 1, "installer must define exactly one FACTORY digest"
        (self.usb / "yafc-install.sh").write_bytes(script.encode())
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
            probe_file = m / "slotprobe"
            probe_file.write_bytes(probe_script(self.lib.as_posix(), probe).encode())
            (m / "SHA256SUMS").write_text("".join(
                f"{sha(m / n)}  yafc-payload/{n}\n" for n in ("libyafc.so", "slotprobe", "camera.conf")))
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
        self.boot_stack = list(layers)
        overlays = overlays or {}
        for name in dict.fromkeys([*images, *layers]):
            if name.startswith("/"):
                continue
            if name == IMG or not name.endswith(".img"):
                (self.imgdir / name).write_bytes(OLD_IMAGE if name == IMG else b"OTHER-" + name.encode())
            else:
                files = overlays.get(name, {f"other/{name}.txt": "another overlay\n"})
                (self.imgdir / name).write_bytes(overlay_tar(files))
        self.initial = {p.name: p.read_bytes() for p in self.imgdir.iterdir()}
        (self.fake / "stack").write_bytes(("\n".join(layers) + "\n").encode())
        (self.fake / "busy").write_bytes(("\n".join(busy) + "\n").encode())
        if IMG in layers and hmi:
            qml = self.mp / "fordhmi/qml"
            shutil.copytree(qml, self.fake / "stock-qml")
            popup = qml / "hmirvc/+10inchP/RVCPopup.qml"
            popup.write_text("previous YAFC overlay; lacks stock anchors\n")
        for n, body in (("mount", FAKE_MOUNT), ("umount", FAKE_UMOUNT), ("dinit", FAKE_DINIT),
                        ("devb-loopback", FAKE_LOOP), ("mkqnx6fs", FAKE_MKQNX6),
                        ("chkqnx6fs", FAKE_CHK), ("cp", FAKE_CP), ("mv", FAKE_MV), ("rm", FAKE_RM),
                        ("cksum", FAKE_CKSUM)):
            p = self.fake / n
            p.write_bytes(body.encode())
            p.chmod(p.stat().st_mode | stat.S_IEXEC)
        (self.fake / "dev-yafchmi-0").unlink(missing_ok=True)
        if owned:
            self.own()

    def own(self):
        """Write the record an earlier verified install would have committed."""
        self.ydata.mkdir(parents=True, exist_ok=True)
        old = self.preserved() or "-"
        image = self.image() or "-"
        (self.ydata / "installer-owner").write_text(
            f"YAFC1 {digest(VENDOR)} {self.live()} {old} {image}\n")

    def reboot(self):
        """What a restart clears: RAM scratch and lock, loopback, base rw, mount order."""
        pid = self.fake / "loop.pid"
        if pid.exists():
            try:
                os.kill(int(pid.read_text()), signal.SIGTERM)
            except (OSError, ValueError):
                pass
            pid.unlink()
        for name in ("scratch", "scratch.lock", "imgroot"):
            shutil.rmtree(self.fake / name, ignore_errors=True)
        for name in ("image-mode", "image-src", "dev-yafchmi-0", "rw", "killed", "formatted", "replays"):
            (self.fake / name).unlink(missing_ok=True)
        (self.fake / "stack").write_bytes(("\n".join(self.boot_stack) + "\n").encode())

    def arm(self, name, in_syncmymod=False):
        d = self.usb / "SyncMyMod" if in_syncmymod else self.usb
        (d / name).write_text("")

    def dispatch(self, **env):
        e = dict(os.environ)
        e.update(env)
        e["YAFC_MP"] = self.mp.as_posix()
        e["YAFC_DATA"] = self.ydata.as_posix()
        e["YAFC_SCRATCH"] = (self.fake / "scratch").as_posix()
        e["YAFC_IMGDIR"] = self.imgdir.as_posix()
        e["YAFC_HMI_DEV"] = (self.fake / "dev-yafchmi-0").as_posix()
        e["FAKE"] = self.fake.as_posix()
        e["SLOT_MP"] = self.mp.as_posix()
        e["PATH"] = f"{self.fake}:{os.environ['PATH']}"
        (self.fake / "worker.pid").unlink(missing_ok=True)
        (self.fake / "killed").unlink(missing_ok=True)
        script = self.usb / "SyncMyMod/autoinstall.sh"
        proc = subprocess.Popen(["dash", "./" + script.relative_to(self.root).as_posix()], env=e,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=self.root)
        # The dispatcher execs the worker, so this PID is the worker's.
        (self.fake / "worker.pid").write_text(str(proc.pid))
        out, err = proc.communicate(timeout=90)
        return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)

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

    def owner(self):
        p = self.ydata / "installer-owner"
        return p.read_text() if p.exists() else None

    def journal(self):
        return (self.ydata / "installer-pending").exists()

    def done(self):
        return (self.usb / "yafc-install/DONE").exists()

    def failed(self):
        return (self.usb / "yafc-install/FAILED").exists()

    def image(self):
        p = self.imgdir / IMG
        return sha(p) if p.is_file() else None

    def images(self):
        return sorted(x.name for x in self.imgdir.iterdir() if x.name not in OVL)

    def state(self):
        return (self.live(), self.preserved(), self.image(), self.owner())

    def failed_text(self):
        p = self.usb / "yafc-install/FAILED"
        return p.read_text() if p.exists() else ""

    def last_request(self):
        dirs = list((self.usb / "yafc-install").glob("request-*"))
        return max(dirs, key=lambda p: p.stat().st_mtime_ns) if dirs else None

    def request_receipt(self, kind):
        d = self.last_request()
        p = d / kind if d else None
        return p.read_text() if p and p.exists() else ""


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
                print("  images:", rig.images(), "image:", rig.image(), "stack:", rig.stack(), file=sys.stderr)
                print("  ops:", rig.ops(), file=sys.stderr)

    vendor_sha = digest(VENDOR)
    yafc_sha = digest(YAFC)
    previous_sha = digest(PREVIOUS)
    old_sha = digest(OLD_IMAGE)
    fresh = (vendor_sha, None, None, None)

    with TemporaryDirectory() as t:
        g = Rig(Path(t))
        config = g.ydata / "camera.conf"

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

        # 2b. an earlier request's .running marker is evidence: never overwritten
        g.reset()
        (g.usb / "RUN-YAFC-INSTALL.running").write_text("20260101T000000-1\n")
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("2b earlier .running kept: new request refused, nothing run",
              r.returncode == 1 and not g.ops() and g.live() == vendor_sha
              and (g.usb / "RUN-YAFC-INSTALL.running").read_text() == "20260101T000000-1\n"
              and "earlier request" in g.seen(), g)

        # 3. install happy path
        g.reset()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        ops = g.ops()
        check("3 install: preserved copy made, new library written, probe passed",
              r.returncode == 0 and g.done() and g.live() == yafc_sha
              and g.preserved() == vendor_sha and "passed the loader probe" in g.log(), g)
        mp_ops = [o for o in ops if o in (f"umount {g.mp}", f"mount -uw {g.mp}")]
        check("3 install: stack reduced before the write, replayed exactly, marker consumed",
              [o for o in ops if o.startswith("mount -b -r -t qnx6 -o before")] ==
                  [f"mount -b -r -t qnx6 -o before {g.imgdir / d} {g.mp}" for d in OVL]
              and not (g.usb / "RUN-YAFC-INSTALL").exists()
              and not (g.usb / "RUN-YAFC-INSTALL.running").exists()
              and mp_ops[:3] == [f"umount {g.mp}"] * 2 + [f"mount -uw {g.mp}"]
              and g.stack() == OVL + [BASE], g)
        check("3 fresh install: initializes the exact staged config",
              config.is_file() and config.read_bytes() ==
              (g.usb / "yafc-payload/camera.conf").read_bytes(), g)
        check("3 install: ownership record names the exact committed state, journal settled",
              g.owner() == f"YAFC1 {vendor_sha} {yafc_sha} {vendor_sha} {g.image()}\n"
              and not g.journal() and not list(g.ydata.glob(".installer-*")), g)
        check("3 install: probe ran from RAM with the loader trace enabled",
              "probe DL_DEBUG=libs" in ops
              and "loaded from" in g.last_request().joinpath("probe.err").read_text(), g)
        check("3b install: image built and read back under /fs/images, never from scratch",
              any(o.startswith(f"dinit -hq -S4m {g.imgdir}/.yafc-build.") for o in ops)
              and any(o.startswith(f"mount -b -r -t qnx6 {g.imgdir}/.yafc-build.") for o in ops)
              and not any(o.startswith("mount -b") and str(g.fake / "scratch") in o.split()[-2]
                          for o in ops), g)
        rid = g.last_request().name.removeprefix("request-")
        check("3 install: DONE receipt names this request, mode and stage",
              f"request={rid} mode=install stage=receipt operation verified" in g.request_receipt("DONE")
              and not g.request_receipt("FAILED"), g)

        # 4. probe failure: the exact previous state comes back
        for kind, reason in (("fail", "did not exit cleanly"), ("notrace", "loader trace"),
                             ("elsewhere", "loader trace"), ("screen", "four imports")):
            g.reset(probe=kind)
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch()
            check(f"4 probe {kind}: rolled back to the exact previous slot, no backup, image or owner",
                  r.returncode == 4 and g.failed() and not g.done() and g.state() == fresh
                  and not g.journal() and "back in the slot" in g.failed_text()
                  and reason in g.failed_text() and "loader probe" in g.failed_text()
                  and g.stack() == OVL + [BASE] and g.images() == [], g)
        rid = g.last_request().name.removeprefix("request-")
        check("4 failed receipt is tied to the request and its stage; marker kept with the ID",
              f"request={rid} mode=install stage=loader-probe" in g.request_receipt("FAILED")
              and not g.request_receipt("DONE")
              and (g.usb / "RUN-YAFC-INSTALL.running").read_text().strip() == rid, g)

        # 5. upgrade: an owned earlier release is replaced, the stock copy kept
        g.reset(live=PREVIOUS, preserved=VENDOR, owned=True)
        g.ydata.mkdir(parents=True, exist_ok=True)
        saved = b"enabled=0\nmode=pass\nfront_view=frontwide\n# keep my settings\n"
        config.write_bytes(saved)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("5 upgrade: preserved copy untouched, slot re-written",
              r.returncode == 0 and g.done() and g.live() == yafc_sha and g.preserved() == vendor_sha, g)
        check("5 upgrade: preserves camera.conf byte for byte", config.read_bytes() == saved, g)

        # 6. rehearse: the unit's own bytes through the real path, picture unchanged
        g.reset()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("6 rehearse: bytes written through the path, content unchanged, nothing owned",
              r.returncode == 0 and g.done() and g.state() == fresh and not g.journal()
              and "rehearsal" in g.log() and not config.exists()
              and any(o.startswith(f"rename {g.lib}/.yafc-slot.") for o in g.ops()), g)

        # 7. remove
        g.reset(live=YAFC, preserved=VENDOR, owned=True)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("7 remove: unit's library restored, preserved copy deleted, ownership says stock",
              r.returncode == 0 and g.done() and g.live() == vendor_sha and g.preserved() is None
              and g.owner() == f"YAFC1 {vendor_sha} {vendor_sha} - -\n" and not g.journal(), g)

        # 8. disable touches nothing under /fs/mp
        g.reset()
        g.arm("RUN-YAFC-DISABLE")
        r = g.dispatch()
        check("8 disable: kill switch written, no mount work, slot untouched",
              r.returncode == 0 and (g.ydata / "DISABLE").is_file() and not g.ops()
              and g.live() == vendor_sha and g.done(), g)

        # 9. a busy layer: nothing written, and no replay that would reverse precedence
        g.reset(busy=[OVL[1]])
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("9 busy layer: aborts, nothing written, the popped layer is not forced under it",
              r.returncode == 5 and g.failed() and g.state() == fresh and not g.journal()
              and g.stack() == [OVL[1], BASE]
              and "cannot restore the exact" in g.failed_text()
              and "busy" in g.failed_text()
              and not any(o.startswith(("mount -uw", "mount -b -r -t qnx6 -o before")) for o in g.ops()), g)

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
        check("12 recovery script changed: fails loudly, keeps the marker and the journal",
              r.returncode == 6 and g.failed() and not g.done() and g.journal()
              and "recovery script changed" in g.log() and "journal retained" in g.failed_text()
              and (g.usb / "RUN-YAFC-INSTALL.running").is_file(), g)

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

        def text(rel):
            p = imgroot / rel
            return p.read_text() if p.exists() else ""
        popup = text("hmirvc/+10inchP/RVCPopup.qml")
        settings = text("hmisettings/driverassistance/+10inchP/RVCSettings.qml")
        root = text("+10inchP/Root.qml")
        style = text("themes/ford-10P-MY20/styles/RVCPopupStyle.qml")
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
        uw = [i for i, op in enumerate(ops) if op.startswith("mount -uw")]
        ur = [i for i, op in enumerate(ops) if op.startswith("mount -ur")]
        check("14 install HMI: slot written, base read-only again, then image published, then replay",
              len(published) == 1 and len(replay) == 2 and len(uw) == 1 and len(ur) == 1
              and uw[0] < ur[0] < published[0] < replay[0]
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

        # 15. HMI refused on a stale anchor: the install is all or nothing
        stale = dict(STOCK)
        stale["themes/ford-10P-MY20/styles/RVCPopupStyle.qml"] = "Item {\r\n    rvcPopupComponentHeight: 999\r\n}\r\n"
        g.reset(stock=stale)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("15 HMI refused: slot never written, no image, no journal",
              r.returncode == 9 and g.failed() and not g.done() and g.state() == fresh
              and "applier refused" in g.log() and not g.journal()
              and not any(o.startswith("mount -uw") for o in g.ops())
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
        check("15b duplicate anchor: refused, slot never written, no image",
              r.returncode == 9 and g.failed() and g.state() == fresh
              and not any(o.startswith("mount -uw") for o in g.ops()), g)

        # 16. rehearse builds and reads back but never publishes
        g.reset()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("16 rehearse HMI: built and read back, no image left in /fs/images",
              r.returncode == 0 and g.done() and g.images() == []
              and "would publish" in g.log() and "read-back matches" in g.log()
              and not any(o.startswith("publish ") for o in g.ops()), g)

        # 17. remove deletes the owned image and restores the library
        g.reset(live=YAFC, preserved=VENDOR, stack=[OVL[0], IMG, OVL[1], BASE], owned=True)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("17 remove: image deleted, library restored, preserved copy gone",
              r.returncode == 0 and g.done() and g.live() == vendor_sha
              and g.preserved() is None and g.images() == [] and g.stack() == OVL + [BASE], g)

        # 18. remove with only the library (no image): clean success
        g.reset(live=YAFC, preserved=VENDOR, owned=True)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("18 remove, no image: clean success",
              r.returncode == 0 and g.done() and g.live() == vendor_sha and g.images() == [], g)

        # 19. an image YAFC did not record is never deleted
        g.reset(images=[IMG])
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("19 remove, unowned image: refused, image and slot untouched",
              r.returncode == 3 and g.failed() and not g.done()
              and (g.imgdir / IMG).read_bytes() == OLD_IMAGE and g.live() == vendor_sha
              and "unowned" in g.failed_text() and not g.ops(), g)

        # 20. remove with nothing owned on the recorded stock slot: verified no-op
        g.reset()
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("20 remove, stock and nothing owned: no-op success",
              r.returncode == 0 and g.done() and g.state() == fresh
              and "nothing owned" in g.log() and not g.ops(), g)

        # 20b. an unknown slot without an ownership record is refused, not "removed"
        g.reset(live=YAFC)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("20b remove, unknown unowned slot: refused, nothing touched",
              r.returncode == 3 and g.failed() and g.live() == yafc_sha and not g.ops(), g)

        # 21. remove-hmi deletes only the image; the library is untouched
        g.reset(live=YAFC, preserved=VENDOR, stack=[OVL[0], IMG, OVL[1], BASE], payload=False, owned=True)
        g.arm("RUN-YAFC-REMOVE-HMI")
        r = g.dispatch()
        check("21 remove-hmi: image gone, library and preserved copy untouched",
              r.returncode == 0 and g.done() and g.images() == []
              and g.live() == yafc_sha and g.preserved() == vendor_sha
              and g.owner() == f"YAFC1 {vendor_sha} {yafc_sha} {vendor_sha} -\n"
              and g.stack() == OVL + [BASE] and not any("-uw" in op for op in g.ops()), g)

        # 22. another overlay image is never touched
        other = "overlay_00--other.img"
        g.reset(live=YAFC, preserved=VENDOR, images=[other, IMG], owned=True)
        g.arm("RUN-YAFC-REMOVE")
        r = g.dispatch()
        check("22 remove: another overlay image is never touched",
              r.returncode == 0 and g.done() and g.images() == [other]
              and (g.imgdir / other).read_bytes() == g.initial[other], g)

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
        check("24 empty HMI set: refused, slot never written, no image",
              r.returncode == 9 and g.failed() and g.state() == fresh
              and "missing required HMI fragment" in g.log(), g)

        # 25. a legacy .old backup is not a boot image and not recorded: left alone
        g.reset(live=YAFC, preserved=VENDOR, images=[IMG, IMG + ".old"], owned=True)
        g.arm("RUN-YAFC-REMOVE-HMI")
        r = g.dispatch()
        check("25 remove-hmi: owned image gone, unrecorded .old untouched, library untouched",
              r.returncode == 0 and g.done() and g.images() == [IMG + ".old"]
              and (g.imgdir / (IMG + ".old")).read_bytes() == g.initial[IMG + ".old"]
              and g.live() == yafc_sha and g.preserved() == vendor_sha, g)

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
        old = OLD_IMAGE.decode()
        g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_REPLACE_OLD=old)
        check("27 upgrade: builds from stock, atomically replaces owned image, replays exact stack",
              r.returncode == 0 and g.done() and g.stack() == mounted
              and (g.imgdir / IMG).read_bytes() != OLD_IMAGE
              and "yafcViews" in (g.mp / "fordhmi/qml/hmirvc/+10inchP/RVCPopup.qml").read_text(), g)

        for fault, code in (("FAKE_PUBLISH_FAIL", 12), ("FAKE_PUBLISH_CORRUPT", 10)):
            g.reset(live=PREVIOUS, preserved=VENDOR, stack=mounted, owned=True)
            before = g.state()
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch(FAKE_REPLACE_OLD=old, **{fault: "1"})
            check(f"28 {fault}: exact previous slot, image and stack, staging cleaned, marker kept",
                  r.returncode == code and g.failed() and not g.done() and g.stack() == mounted
                  and g.state() == before and g.images() == [IMG] and not g.journal()
                  and (g.imgdir / IMG).read_bytes() == OLD_IMAGE
                  and (g.usb / "RUN-YAFC-INSTALL.running").is_file()
                  and (fault != "FAKE_PUBLISH_CORRUPT" or not any(op.startswith("publish ") for op in g.ops()))
                  and (fault != "FAKE_PUBLISH_FAIL" or "rolled back" in g.failed_text()), g)

        # 28b. published bytes that are neither previous nor planned: journal kept, recovery refuses
        g.reset(live=PREVIOUS, preserved=VENDOR, stack=mounted, owned=True)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_PUBLISH_CORRUPT_AFTER="1")
        damaged = g.image()
        check("28b corrupted after rename: fails closed with the journal retained",
              r.returncode == 12 and g.failed() and g.journal()
              and "journal retained" in g.failed_text() and damaged not in (old_sha, None), g)
        g.reboot()
        g.arm("RUN-YAFC-RECOVER")
        n = len(g.ops())
        r = g.dispatch()
        check("28b recover with an unknown image: refused, nothing changed, journal kept",
              r.returncode == 5 and g.journal() and g.image() == damaged
              and g.live() == yafc_sha and g.preserved() == vendor_sha
              and "recovery refused" in g.request_receipt("FAILED")
              and not any(o.startswith(("mount -uw", f"umount {g.mp}", "delete", "publish", "rename"))
                          for o in g.ops()[n:]), g)

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("29 rehearsal over existing install leaves slot, configuration and mounted image intact",
              r.returncode == 0 and g.done() and g.stack() == mounted and g.live() == yafc_sha
              and g.preserved() == vendor_sha and (g.imgdir / IMG).read_bytes() == OLD_IMAGE
              and not config.exists() and not any(op.startswith("publish ") for op in g.ops()), g)

        for mode in ("REMOVE-HMI", "REMOVE"):
            g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
            before = g.state()
            g.arm("RUN-YAFC-" + mode)
            r = g.dispatch(FAKE_DELETE_FAIL=IMG)
            check(f"30 {mode} failure deleting the image: exact stack, image and library rolled back",
                  r.returncode == 12 and g.failed() and not g.done() and g.stack() == mounted
                  and g.state() == before and not g.journal()
                  and "cannot delete" in g.failed_text() and "rolled back" in g.failed_text()
                  and (g.usb / f"RUN-YAFC-{mode}.running").is_file(), g)

        for fault in ("FAKE_MKFS_FAIL", "FAKE_READBACK_CORRUPT"):
            g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch(**{fault: "1"})
            check(f"31 {fault}: build error survives cleanup, exact stack and old image restored",
                  r.returncode == 10 and g.failed() and not g.done() and g.stack() == mounted
                  and (g.imgdir / IMG).read_bytes() == OLD_IMAGE
                  and not (g.fake / "scratch").exists() and not (g.fake / "image-mode").exists()
                  and not (g.fake / "dev-yafchmi-0").exists() and g.images() == [IMG]
                  and "HMI image build or read-back failed" in g.failed_text(), g)

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_READBACK_CORRUPT="1", FAKE_BUILD_BUSY="ro")
        check("32 busy read-back mount: refuses scratch deletion and reports original failure",
              r.returncode == 10 and g.failed() and not g.done() and g.stack() == mounted
              and "HMI image build or read-back failed" in g.failed_text()
              and "scratch retained" in g.failed_text() and "clean scratch" not in g.ops()
              and (g.fake / "scratch/mnt").is_dir(), g)

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
        (g.usb / "yafc-payload/hmi/popup-1-state.fragment").unlink()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("33 incomplete nonempty set: missing state rejected before any image build",
              r.returncode == 9 and g.failed() and not g.done() and g.stack() == mounted
              and "missing required HMI fragment popup-1-state" in g.failed_text()
              and (g.imgdir / IMG).read_bytes() == OLD_IMAGE
              and not any(op.startswith("dinit ") for op in g.ops()), g)

        g.reset()
        (g.usb / "yafc-payload/camera.conf").unlink()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("34 fresh install without defaults: refuses before writing slot or HMI image",
              r.returncode == 4 and g.failed() and not g.done() and g.stack() == OVL + [BASE]
              and g.state() == fresh and not config.exists() and g.images() == []
              and not any(op.startswith("mount -uw") for op in g.ops()), g)

        # 35. remount failure after a removal: rolled back bytes, journal kept, recover finishes
        g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
        before = g.state()
        g.arm("RUN-YAFC-REMOVE-HMI")
        r = g.dispatch(FAKE_REPLAY_FAIL=OVL[0] + ":2")
        check("35 remount failure after removal: reports failure, not DONE, journal retained",
              r.returncode == 5 and g.failed() and not g.done() and g.journal()
              and g.state() == before and g.stack() == [BASE]
              and "cannot restore the exact" in g.failed_text(), g)
        g.reboot()
        (g.usb / "RUN-YAFC-REMOVE-HMI.running").unlink()
        g.arm("RUN-YAFC-RECOVER")
        r = g.dispatch()
        check("35 recover after restart: previous state verified, journal settled",
              r.returncode == 0 and g.done() and not g.journal() and g.state() == before
              and g.stack() == mounted, g)

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

        g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
        before = g.state()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_RO_FAIL="1")
        check("36 failed read-only remount: no image publication or success receipt, journal kept",
              r.returncode == 4 and g.failed() and not g.done() and g.journal()
              and g.stack() == mounted and (g.fake / "rw").exists() and g.state() == before
              and "mount -ur failed" in g.failed_text() and "journal retained" in g.failed_text()
              and not any(op.startswith("publish ") for op in g.ops()), g)
        g.reboot()
        (g.usb / "RUN-YAFC-INSTALL.running").unlink()
        g.arm("RUN-YAFC-RECOVER")
        r = g.dispatch()
        check("36 recover after restart settles the verified journal",
              r.returncode == 0 and g.done() and not g.journal() and g.state() == before, g)

        # 38. ownership: never adopt or overwrite an unrecorded pair
        cases = (
            ("unowned preserved copy", dict(preserved=VENDOR), None),
            ("unowned HMI image", dict(images=[IMG]), None),
            ("unknown stock slot", dict(live=PREVIOUS), None),
            ("record does not match", dict(live=YAFC, preserved=VENDOR, owned=True),
             lambda: (g.imgdir / IMG).write_bytes(OLD_IMAGE)),
            ("symlinked preserved copy", dict(), lambda: (g.lib / "libRCN_DiagnosticsOld.so").symlink_to(
                g.lib / "libRCN_DiagnosticsLib.so")),
            ("preserved name is a directory", dict(), lambda: (g.lib / "libRCN_DiagnosticsOld.so").mkdir()),
        )
        for label, kwargs, after in cases:
            g.reset(**kwargs)
            if after:
                after()
            lib_before = {p.name: (p.read_bytes() if p.is_file() else None) for p in g.lib.iterdir()}
            img_before = {p.name: p.read_bytes() for p in g.imgdir.iterdir()}
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch()
            check(f"38 {label}: install refused, nothing touched",
                  r.returncode == 3 and g.failed() and not g.done() and not g.ops()
                  and {p.name: (p.read_bytes() if p.is_file() else None) for p in g.lib.iterdir()} == lib_before
                  and {p.name: p.read_bytes() for p in g.imgdir.iterdir()} == img_before
                  and not g.journal(), g)

        # 39. another boot overlay providing a target path is refused before any mount work
        for victim, rel in ((OVL[1], "fordhmi/qml/+10inchP/Root.qml"),
                            (OVL[0], "apps/usr/lib/libRCN_DiagnosticsLib.so"),
                            ("overlay_zz.img", "fordhmi/qml/hmirvc/+10inchP/RVCPopup.qml")):
            g.reset(images=[victim], overlays={victim: {rel: "shadow\n"}})
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch()
            check(f"39 {victim} shadows {rel}: refused, nothing written or unmounted",
                  r.returncode == 3 and g.failed() and g.state() == fresh and not g.journal()
                  and "shadows" in g.failed_text() and g.stack() == OVL + [BASE]
                  and not any(o.startswith((f"umount {g.mp}", "mount -uw", "dinit")) for o in g.ops())
                  and not (g.fake / "scratch").exists(), g)

        # 40. TERM at each phase: the trap rolls back to the exact previous state
        points = (
            (f"mount -b -r -t qnx6 {g.imgdir}/{OVL[0]}", "overlay-check"),
            (f"umount {g.mp}", "mount-reduction"),
            ("dinit", "hmi-build"),
            ("/.installer-plan.", "journal"),
            ("mount -uw", "slot-write"),
            ("probe DL_DEBUG", "loader-probe"),
            ("mount -ur", "base-readonly"),
            ("publish ", "image-publish"),
            ("mount -b -r -t qnx6 -o before", "mount-replay"),
            (f"copy {g.ydata}/installer-pending/after ", "commit"),
        )
        for op, phase in points:
            g.reset()
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch(FAKE_KILL=op + "@TERM")
            check(f"40 TERM during {phase}: previous state exact, stack exact, no journal",
                  r.returncode == 5 and g.failed() and not g.done() and g.state() == fresh
                  and not g.journal() and g.stack() == OVL + [BASE] and g.images() == []
                  and f"interrupted at {phase}" in g.failed_text()
                  and (g.usb / "RUN-YAFC-INSTALL.running").is_file()
                  and not (g.fake / "scratch").exists() and not (g.fake / "scratch.lock").exists(), g)

        # 41. KILL (a crash) at each phase after the journal: recover restores the exact state
        kills = (
            ("mount -uw", True),
            (f"copy {g.usb}/yafc-payload/libyafc.so", True),
            ("probe DL_DEBUG", True),
            ("publish ", True),
            ("mount -b -r -t qnx6 -o before", True),
            (f"copy {g.ydata}/installer-pending/after ", True),
            ("dinit", False),
        )
        for op, journaled in kills:
            g.reset()
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch(FAKE_KILL=op + "@KILL")
            check(f"41 KILL at '{op}': no receipt claims an outcome, journal {'kept' if journaled else 'absent'}",
                  r.returncode == -signal.SIGKILL and not g.done() and not g.failed()
                  and g.journal() == journaled
                  and (g.usb / "RUN-YAFC-INSTALL.running").is_file(), g)
            g.reboot()
            if journaled:
                (g.usb / "RUN-YAFC-INSTALL.running").unlink(missing_ok=True)
                g.arm("RUN-YAFC-INSTALL")
                r = g.dispatch()
                check(f"41 KILL at '{op}': a pending journal refuses a new install",
                      r.returncode == 3 and "pending transaction" in g.request_receipt("FAILED")
                      and g.journal(), g)
                (g.usb / "RUN-YAFC-INSTALL.running").unlink(missing_ok=True)
                g.arm("RUN-YAFC-RECOVER")
                r = g.dispatch()
                check(f"41 KILL at '{op}': recover restores the exact previous state",
                      r.returncode == 0 and "operation verified" in g.request_receipt("DONE")
                      and g.state() == fresh and not g.journal() and g.stack() == OVL + [BASE]
                      and not (g.usb / "RUN-YAFC-RECOVER.running").exists(), g)
            (g.usb / "RUN-YAFC-INSTALL.running").unlink(missing_ok=True)
            g.arm("RUN-YAFC-INSTALL")
            r = g.dispatch()
            check(f"41 KILL at '{op}': stale temporary files do not block the retry",
                  r.returncode == 0 and "operation verified" in g.request_receipt("DONE")
                  and g.live() == yafc_sha and g.preserved() == vendor_sha and g.image() is not None, g)

        # 42. recover refuses what it cannot authenticate and keeps the journal
        g.reset()
        g.arm("RUN-YAFC-RECOVER")
        r = g.dispatch()
        check("42 recover without a journal: refused, nothing touched",
              r.returncode == 3 and "no pending" in g.failed_text() and g.state() == fresh
              and not g.ops(), g)
        for label, damage in (
                ("slot bytes unknown", lambda: (g.lib / "libRCN_DiagnosticsLib.so").write_bytes(b"other")),
                ("journal record altered", lambda: (g.ydata / "installer-pending/before").write_text("x\n")),
                ("journal copy altered", lambda: (g.ydata / "installer-pending/slot").write_bytes(b"other"))):
            g.reset()
            g.arm("RUN-YAFC-INSTALL")
            g.dispatch(FAKE_KILL="probe DL_DEBUG@KILL")
            g.reboot()
            damage()
            state = g.state()
            (g.usb / "RUN-YAFC-INSTALL.running").unlink()
            g.arm("RUN-YAFC-RECOVER")
            n = len(g.ops())
            r = g.dispatch()
            check(f"42 recover with {label}: refused, nothing changed, journal kept",
                  r.returncode == 5 and g.journal() and g.state() == state
                  and "recovery refused" in g.request_receipt("FAILED")
                  and not any(o.startswith(("mount -uw", f"umount {g.mp}", "delete", "publish", "rename"))
                              for o in g.ops()[n:])
                  and (g.usb / "RUN-YAFC-RECOVER.running").is_file(), g)

        # 44. recovery scripts are compared on the same layer list before and after
        g.reset()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch(FAKE_SCRIPT_LAYER=OVL[0])
        check("44 install with an overlay that provides recovery scripts: same layering, success",
              r.returncode == 0 and g.done(), g)
        g.reset(live=YAFC, preserved=VENDOR, stack=mounted, owned=True)
        g.arm("RUN-YAFC-REMOVE-HMI")
        r = g.dispatch(FAKE_SCRIPT_LAYER=IMG)
        check("44 remove-hmi of a layer that shadows scripts: baseline is the post-removal layering",
              r.returncode == 0 and g.done() and g.image() is None and g.stack() == OVL + [BASE], g)

        # 45. stale request-specific temporaries from an earlier run never block
        g.reset()
        g.ydata.mkdir(parents=True)
        (g.lib / ".yafc-slot.20250101T000000-7.new").write_bytes(b"partial")
        (g.imgdir / ".yafc-build.20250101T000000-7.img").write_bytes(b"partial")
        (g.ydata / ".installer-plan.20250101T000000-7").mkdir()
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("45 stale temporaries: install succeeds and leaves them untouched",
              r.returncode == 0 and g.done() and g.live() == yafc_sha
              and (g.lib / ".yafc-slot.20250101T000000-7.new").read_bytes() == b"partial"
              and (g.imgdir / ".yafc-build.20250101T000000-7.img").read_bytes() == b"partial", g)

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
        lib.write_bytes(b"\x7fELF\x00stale\x00/fs/tmpfs/yafc-view\x00")
        cmd = ["dash", str(project / "tools/make-usb.sh"), str(stick)]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        check("37 packaging rejects stale binary before touching the stick",
              r.returncode != 0 and "lacks the HMI mailbox" in r.stderr and not stick.exists())
        rebuilt = b"\x7fELF\x00/fs/tmpfs/yafc-view\x00/fs/tmpfs/yafc-session\x00/fs/tmpfs/yafc-ready\x00"
        lib.write_bytes(rebuilt)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        check("37 packaging accepts the mailbox-capable artifact and stages its bytes unarmed",
              r.returncode == 0 and (stick / "yafc-payload/libyafc.so").read_bytes() == rebuilt
              and not list(stick.glob("RUN-YAFC-*")))

    print("\n%s" % ("ALL PASS" if not fails else f"{fails} FAILED"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
