#!/bin/sh
# Build the three ready-to-use release zips: install, uninstall, rehearse.
#
#   sh tools/make-release.sh [version]
#
# Runs in WSL Ubuntu (docs/BUILD.md). It builds the library and the probe, stages
# a stick with tools/make-usb.sh, arms ONE marker on a fresh copy per variant, and
# writes YAFC-<version>-{install,uninstall,rehearse}.zip plus SHA256SUMS into dist/.
# The zip root is the stick root, so unzipping onto a USB drive root is the whole
# job. Nothing is committed: zips are attached to a GitHub release (docs/RELEASE.md).
#
# YAFC_SKIP_BUILD=1 skips both builds and takes the payload from YAFC_LIB and
# YAFC_PROBE. The host test uses that; a release build must not.
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${YAFC_OUT:-$REPO/dist}

VERSION=${1:-}
if [ -z "$VERSION" ]; then
  VERSION=$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null) || VERSION=
  [ -n "$VERSION" ] || VERSION=$(date -u +%Y.%m.%d)
fi
VERSION=$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '-')
[ -n "$VERSION" ] || { echo "make-release: empty version" >&2; exit 1; }

if [ "${YAFC_SKIP_BUILD:-0}" = 1 ]; then
  LIB=${YAFC_LIB:-$REPO/toolchain/bin/libyafc.so}
  PROBE=${YAFC_PROBE:-$REPO/toolchain/probe/bin/slotprobe}
else
  ( cd "$REPO" && sh toolchain/build-slot.sh )
  ( cd "$REPO" && sh toolchain/probe/build-probe.sh )
  LIB=$REPO/toolchain/bin/libyafc.so
  PROBE=$REPO/toolchain/probe/bin/slotprobe
fi
[ -f "$LIB" ] || { echo "make-release: missing $LIB" >&2; exit 1; }
[ -x "$PROBE" ] || { echo "make-release: missing $PROBE" >&2; exit 1; }

WORK=$OUT/work
rm -rf "$WORK"
mkdir -p "$WORK/repo/toolchain/bin" "$WORK/repo/toolchain/probe/bin" "$WORK/repo/tools"

# make-usb.sh reads the repository around itself, so it runs from a stage that
# holds exactly the files it copies. The payload is the one just built (or given).
cp -R "$REPO/installer" "$WORK/repo/installer"
cp -R "$REPO/payload" "$WORK/repo/payload"
cp -f "$REPO/tools/make-usb.sh" "$REPO/tools/apply-hmi-fragments.sh" "$WORK/repo/tools/"
cp -f "$LIB" "$WORK/repo/toolchain/bin/libyafc.so"
cp -f "$PROBE" "$WORK/repo/toolchain/probe/bin/slotprobe"
chmod 755 "$WORK/repo/toolchain/probe/bin/slotprobe"

# start-here VARIANT: the one page a reader sees before anything else.
start_here() {
  variant=$1
  case "$variant" in
    install) MARK=RUN-YAFC-INSTALL ;;
    uninstall) MARK=RUN-YAFC-REMOVE ;;
    rehearse) MARK=RUN-YAFC-REHEARSE ;;
  esac
  case "$variant" in
    install) what="Installs the YAFC camera library. The picture changes. The rear camera safety
path is UNPROVEN on a real unit." ;;
    uninstall) what="Puts the unit's own camera library back and forgets YAFC. The picture
returns to how the car shipped." ;;
    rehearse) what="Changes no picture. Runs the whole install with the unit's own bytes,
to prove the path works on this radio." ;;
  esac
  case "$variant" in
    install) undo="Use YAFC-$VERSION-uninstall.zip the same way." ;;
    uninstall) undo="Nothing to undo. Install YAFC again with YAFC-$VERSION-install.zip." ;;
    rehearse) undo="Nothing to undo; the picture never changed. Install with YAFC-$VERSION-install.zip." ;;
  esac
  cat <<EOF
WARNING: unofficial free hobby project, use at your own risk. No warranty, express or
implied. No support. It may brick the unit or show a wrong or missing camera picture.
We are not responsible for accidents, damage, injury or a voided warranty. Off-road,
parked, closed-course use only; never rely on it to decide whether it is safe to move.
If you do not agree, do not use it. Full text: docs/DISCLAIMER.md on GitHub.
YAFC fullscreen camera for SYNC 3. The public edition has NEVER been tested on a car.

WHAT THIS STICK DOES
$what

BEFORE YOU START
The FMods jailbreak must already be on the radio; YAFC does not install it.
Install only while parked.

STEPS
1. Unzip onto the root of a USB drive you have just formatted.
2. Park, ignition on, SYNC running.
3. Plug it in and wait. How long this takes is UNKNOWN (not measured).
4. Restart SYNC once: hold Power + Seek-Right about 10 seconds.

DID IT WORK? yafc-install/DONE = worked, yafc-install/FAILED = stopped. If it failed
send yafc-install/install.log. Do not re-plug repeatedly: a failed request is kept
as $MARK.running and will not run again.
UNDO: $undo
EOF
}

# zip STICK ZIP: the stick root becomes the zip root, in a fixed order with fixed
# timestamps, so two runs of the same version give the same bytes.
zip_stick() {
  python3 - "$1" "$2" <<'PY'
import os, sys, zipfile

src, out = sys.argv[1], sys.argv[2]
entries = []
for root, dirs, files in os.walk(src):
    dirs.sort()
    for name in files:
        p = os.path.join(root, name)
        entries.append((os.path.relpath(p, src).replace(os.sep, '/'), p))
entries.sort()
with zipfile.ZipFile(out, 'w', zipfile.ZIP_STORED) as z:
    for arc, p in entries:
        mode = 0o755 if os.stat(p).st_mode & 0o111 else 0o644
        info = zipfile.ZipInfo(arc, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED
        info.create_system = 3
        info.external_attr = mode << 16
        with open(p, 'rb') as fh:
            z.writestr(info, fh.read())
PY
}

for variant in install uninstall rehearse; do
  case "$variant" in
    install) marker=RUN-YAFC-INSTALL ;;
    uninstall) marker=RUN-YAFC-REMOVE ;;
    rehearse) marker=RUN-YAFC-REHEARSE ;;
  esac
  dest=$WORK/stick-$variant
  sh "$WORK/repo/tools/make-usb.sh" "$dest" >/dev/null
  start_here "$variant" > "$dest/START-HERE.txt"
  # The full disclaimer lives in the repository; the stick gets a copy when there is one.
  if [ -f "$REPO/docs/DISCLAIMER.md" ]; then
    cp -f "$REPO/docs/DISCLAIMER.md" "$dest/DISCLAIMER.txt"
  fi
  : > "$dest/$marker"
  zip_stick "$dest" "$OUT/YAFC-$VERSION-$variant.zip"
  echo "made YAFC-$VERSION-$variant.zip ($marker armed)"
done

( cd "$OUT" && sha256sum "YAFC-$VERSION-install.zip" "YAFC-$VERSION-uninstall.zip" \
    "YAFC-$VERSION-rehearse.zip" > SHA256SUMS )

rm -rf "$WORK"
echo
echo "Release $VERSION in $OUT:"
( cd "$OUT" && ls -l "YAFC-$VERSION"-*.zip && cat SHA256SUMS )
echo
echo "UNPROVEN: no zip built here has been run on a radio. Read docs/EASY-INSTALL.md"
echo "before you attach one to a release."