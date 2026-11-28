#!/bin/sh
# Build the two ready-to-use release zips: install and uninstall.
#
#   sh tools/make-release.sh [version]
#
# Runs in WSL Ubuntu (docs/BUILD.md). It builds the library and the probe, stages
# a stick with tools/make-usb.sh, arms ONE marker on a fresh copy per variant, and
# writes YAFC-<version>-{install,uninstall}.zip plus SHA256SUMS into dist/.
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
[ -f "$PROBE" ] || { echo "make-release: missing $PROBE" >&2; exit 1; }

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

# start-here VARIANT: the one page a reader sees before anything else.
start_here() {
  case "$1" in
    install)
      MARK=RUN-YAFC-INSTALL
      what="Installs the YAFC camera library and HMI overlay. On the development vehicle,
fullscreen rear video appeared early, before SYNC finished starting. The 360 view,
parking sensors and view-selection buttons appeared later as the interface loaded."
      undo="For a verified install, use YAFC-$VERSION-uninstall.zip on a separate drive."
      ;;
    uninstall)
      MARK=RUN-YAFC-REMOVE
      what="Removes an owned YAFC overlay and restores the verified factory library.
The installer refuses if it cannot verify ownership or the restored source."
      undo="A soft reset reloads the current files; it cannot undo a persistent write."
      ;;
  esac
  cat <<EOF
WARNING: unofficial free hobby project, use at your own risk. No warranty, express or
implied. No support. It may brick the unit or show a wrong or missing camera picture.
We are not responsible for accidents, damage, injury or a voided warranty. Off-road,
parked, closed-course use only; never rely on it to decide whether it is safe to move.
If you do not agree, do not use it. See https://github.com/patubergods/yafc/blob/main/docs/DISCLAIMER.md.
YAFC for SYNC 3. Developed on a 2020 Explorer ST, where install, uninstall and reinstall ran once; other vehicles are unproven.

WHAT THIS STICK DOES
$what

BEFORE YOU START
The FMods jailbreak, USB installer and FMods Tools must already be set up on the radio.
Install only while parked.

STEPS
1. Back up the USB drive. Unzip to the root of a drive that already works with the USB hook.
2. Park with the brake held, turn the ignition on, wait for SYNC, then plug it in. Leave it alone.
3. Within about two minutes the radio should show a message: success, failure, or "no marker armed".
   Do not pull the drive before a message appears or two minutes pass.
4. After a success message, restart SYNC: hold Power + Seek-Right about 10 seconds.

LOGS, on this USB drive in the folder yafc-install/:
  DONE         the success receipt.   FAILED   the failure receipt and the reason.
  install.log  the full log.          request-<ID>/  the detailed receipts of one run.
  seen.log     one line per plug-in, including when nothing was armed.

CHECK: match the DONE or FAILED request ID to this run in install.log.
If $MARK.running remains or the result is unclear, preserve the stick and logs.
Do not retry. Recovery: https://github.com/patubergods/yafc/blob/main/docs/RECOVERY.md.
UNDO: $undo

PROBLEMS: open an issue at https://github.com/patubergods/yafc/issues/new/choose and attach the
whole yafc-install folder as a zip. Do not post photos that show your VIN or other personal data.
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
        mode = 0o755 if arc.endswith(".sh") else 0o644
        info = zipfile.ZipInfo(arc, date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED
        info.create_system = 3
        info.external_attr = mode << 16
        with open(p, 'rb') as fh:
            z.writestr(info, fh.read())
PY
}

for variant in install uninstall; do
  case "$variant" in
    install) marker=RUN-YAFC-INSTALL ;;
    uninstall) marker=RUN-YAFC-REMOVE ;;
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

# Do not leave an obsolete archive from an earlier build of the same version.
rm -f "$OUT/YAFC-$VERSION-rehearse.zip"
( cd "$OUT" && sha256sum "YAFC-$VERSION-install.zip" "YAFC-$VERSION-uninstall.zip" > SHA256SUMS )

rm -rf "$WORK"
echo
echo "Release $VERSION in $OUT:"
( cd "$OUT" && ls -l "YAFC-$VERSION-install.zip" "YAFC-$VERSION-uninstall.zip" && cat SHA256SUMS )
echo
echo "UNPROVEN: no zip built here has been run on a radio. Read docs/EASY-INSTALL.md"
echo "before you attach one to a release."