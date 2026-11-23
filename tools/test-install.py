#!/usr/bin/env python3
"""Mocked-unit rehearsal for installer/yafc-install.sh and its dispatcher.

Runs the REAL scripts against a fake /fs/mp tree, with fake mount, umount and rm
on PATH (a layer stack kept in a file). Proves the host contracts only: the write
order, the rollback, the mount-stack handling and the marker dispatch. It cannot
prove qnx6 behaviour and it never touches a radio.

Cases: no marker; two markers refused; install happy path; install probe failure
rolls the unit's own library back; rehearse changes no bytes; remove; disable;
busy layer aborts with the stack restored; base device missing; base on top is
never unmounted; a recovery script changed under us fails loudly; missing payload
refuses before anything is touched.

Needs: dash, openssl, python3. Run: python3 -I yafc/tools/test-install.py
"""
import hashlib
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "installer"
BASE = "/dev/hd0t178"
OVL = ["/fs/images/overlay_a.img", "/fs/images/overlay_b.img"]   # top first
RECOVERY = ("startup_gf.sh", "usb_installer.sh", "launch/launch_usblauncher.sh")
VENDOR = b"VENDOR-camera-library"          # the unit's own library, invented
YAFC = b"YAFC-slot-library"                # what the repository ships

FAKE_MOUNT = r'''#!/bin/sh
S=$FAKE/stack; [ $# -gt 0 ] && echo "mount $*" >> $FAKE/ops
case "$1" in
  "") while IFS= read -r d; do echo "$d on $SLOT_MP type qnx6 (ro)"; done < $S ;;
  -uw) : > $FAKE/rw ;;
  -ur) rm -f $FAKE/rw
       [ -n "$FAKE_RO_FAIL" ] && exit 1
       [ -n "$FAKE_TAMPER" ] && echo x >> $SLOT_MP/scripts/startup_gf.sh; true ;;
  -b) awk -v dev="$7" -v base="/dev/hd0t178" '$0 == base { print dev } { print }' "$S" > "$S.n"
      mv "$S.n" "$S" ;;
  *) exit 1 ;;
esac
'''
FAKE_UMOUNT = r'''#!/bin/sh
echo "umount $*" >> $FAKE/ops
T=$(head -n1 $FAKE/stack)
grep -qxF "$T" $FAKE/busy 2>/dev/null && exit 1
sed 1d $FAKE/stack > $FAKE/stack.n; mv $FAKE/stack.n $FAKE/stack
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Rig:
    def __init__(self, root: Path):
        self.root = root
        self.usb, self.mp, self.fake, self.data = (root / n for n in ("usb", "mp", "fake", "rwdata"))
        self.lib = self.mp / "apps/usr/lib"

    def reset(self, live=VENDOR, preserved=None, stack=None, busy=(), payload=True, probe_ok=True):
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
            m.mkdir()
            (m / "libyafc.so").write_bytes(YAFC)
            probe = m / "slotprobe"
            if probe_ok:
                probe.write_text(f"""#!/bin/sh
set -e
echo 'needed libRCN_DiagnosticsLib.so'
echo 'slot diagnostics_async_base_logs fname={self.lib}/libRCN_DiagnosticsOld.so same=yes'
echo 'slot forensics_logworthy_async fname={self.lib}/libRCN_DiagnosticsOld.so same=yes'
echo 'slot screen_create_window fname=/usr/lib/libscreen.so.1 same=yes'
echo 'slot screen_post_window fname=/usr/lib/libscreen.so.1 same=yes'
echo 'loaded from: {self.lib}/libRCN_DiagnosticsLib.so' >&2
""")
            else:
                probe.write_text("#!/bin/sh\necho 'the pair did not load' >&2\nexit 1\n")
            probe.chmod(0o755)
        self.fake.mkdir()
        (self.fake / "stack").write_text("\n".join(OVL + [BASE] if stack is None else stack) + "\n")
        (self.fake / "busy").write_text("\n".join(busy) + "\n")
        for n, body in (("mount", FAKE_MOUNT), ("umount", FAKE_UMOUNT)):
            p = self.fake / n
            p.write_text(body)
            p.chmod(p.stat().st_mode | stat.S_IEXEC)

    def arm(self, name, in_syncmymod=False):
        d = self.usb / "SyncMyMod" if in_syncmymod else self.usb
        (d / name).write_text("")

    def dispatch(self, **env):
        e = dict(os.environ, FAKE=str(self.fake), SLOT_MP=str(self.mp), YAFC_MP=str(self.mp),
                 YAFC_DATA=str(self.data / "yafc"),
                 PATH=f"{self.fake}:{os.environ['PATH']}", **env)
        return subprocess.run(["dash", str(self.usb / "SyncMyMod/autoinstall.sh")], env=e,
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
        check("3 install: stack restored, marker consumed",
              g.stack() == OVL + [BASE] and not (g.usb / "RUN-YAFC-INSTALL").exists()
              and order[:2] == ["umount " + str(g.mp)] * 2
              and [o for o in g.ops() if o.startswith("mount -b")] ==
                  [f"mount -b -r -t qnx6 -o before {d} {g.mp}" for d in OVL], g)

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
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("5 upgrade: preserved copy untouched, slot re-written",
              r.returncode == 0 and g.done() and g.live() == yafc_sha and g.preserved() == vendor_sha, g)

        # 6. rehearse: the unit's own bytes through the real path, picture unchanged
        g.reset()
        g.arm("RUN-YAFC-REHEARSE")
        r = g.dispatch()
        check("6 rehearse: bytes written through the path, content unchanged",
              r.returncode == 0 and g.done() and g.live() == vendor_sha
              and "rehearsal" in g.log(), g)

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
              and "order may have changed" in g.log()
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
        e = dict(os.environ, FAKE=str(g.fake), SLOT_MP=str(g.mp), YAFC_MP=str(g.mp),
                 YAFC_DATA=str(g.data / "yafc"),
                 PATH=f"{g.fake}:{os.environ['PATH']}", FAKE_TAMPER="1")
        r = subprocess.run(["dash", str(g.usb / "SyncMyMod/autoinstall.sh")], env=e,
                           capture_output=True, text=True, timeout=60, cwd=g.root)
        check("12 recovery script changed: fails loudly and keeps the marker",
              r.returncode == 6 and g.failed() and not g.done()
              and "recovery script changed" in g.log(), g)

        # 13. no payload staged: refuse before touching anything
        g.reset(payload=False)
        g.arm("RUN-YAFC-INSTALL")
        r = g.dispatch()
        check("13 no payload: refused with nothing written",
              r.returncode == 3 and g.failed() and not g.ops() and g.live() == vendor_sha, g)

    print("\n%s" % ("ALL PASS" if not fails else f"{fails} FAILED"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
