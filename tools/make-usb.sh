#!/bin/sh
# Assemble a YAFC stick: everything the installer needs, in the layout it expects.
#
#   sh tools/make-usb.sh /media/<you>/<STICK>
#
# Build the library first: sh toolchain/build-slot.sh, and the loader probe:
# sh toolchain/probe/build-probe.sh. No vendor binary is copied and no marker is
# created: arming the stick is a separate, deliberate act.
set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <dest>" >&2
  exit 1
fi

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$REPO/toolchain/bin/libyafc.so" ] ||
  { echo "Missing toolchain/bin/libyafc.so; run 'sh toolchain/build-slot.sh' first." >&2; exit 1; }
LC_ALL=C grep -aFq '/fs/tmpfs/yafc-view' "$REPO/toolchain/bin/libyafc.so" ||
  { echo "Slot library lacks the HMI mailbox; rebuild with 'sh toolchain/build-slot.sh'." >&2; exit 1; }
[ -x "$REPO/toolchain/probe/bin/slotprobe" ] ||
  { echo "Missing toolchain/probe/bin/slotprobe; run 'sh toolchain/probe/build-probe.sh' first." >&2; exit 1; }

DEST=$1
STICK=$DEST/SyncMyMod
if [ -e "$STICK" ] || [ -L "$STICK" ]; then
  if [ ! -d "$STICK" ] || [ -L "$STICK" ] || [ ! -f "$STICK/.yafc-usb" ] || [ -L "$STICK/.yafc-usb" ]; then
    echo "Refusing to use an unowned SyncMyMod directory: $STICK" >&2
    exit 1
  fi
else
  mkdir -p "$STICK"
  : > "$STICK/.yafc-usb"
fi

# An armed stick is a request in flight: do not overwrite it.
for m in RUN-YAFC-INSTALL RUN-YAFC-REHEARSE RUN-YAFC-REMOVE RUN-YAFC-REMOVE-HMI RUN-YAFC-DISABLE; do
  for f in "$DEST/$m" "$STICK/$m" "$DEST/$m.running" "$STICK/$m.running"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      echo "Refusing: $f exists. Finish or remove that request first." >&2
      exit 1
    fi
  done
done

# Refresh, do not skip: the stamp proves this directory is ours, so the stick must
# match the repository. A skipped copy leaves a stale script or a stale fragment
# behind, and a stale fragment makes the applier refuse.
mkdir -p "$STICK" "$DEST/yafc-payload/hmi" "$DEST/tools"
cp -f "$REPO/installer/yafc-dispatch.sh" "$STICK/autoinstall.sh"
cp -f "$REPO/installer/yafc-install.sh" "$DEST/yafc-install.sh"
cp -f "$REPO/tools/apply-hmi-fragments.sh" "$DEST/tools/"
cp -f "$REPO/payload/yafc/README.txt" "$DEST/yafc-payload/"
cp -f "$REPO/payload/config/camera.conf" "$DEST/yafc-payload/camera.conf"
cp -f "$REPO/toolchain/bin/libyafc.so" "$DEST/yafc-payload/libyafc.so"
cp -f "$REPO/toolchain/probe/bin/slotprobe" "$DEST/yafc-payload/slotprobe"
rm -f "$DEST"/yafc-payload/hmi/*.fragment
cp -f "$REPO"/payload/hmi/*.fragment "$DEST/yafc-payload/hmi/"
chmod 755 "$STICK/autoinstall.sh" "$DEST/yafc-install.sh" "$DEST/tools/apply-hmi-fragments.sh" \
          "$DEST/yafc-payload/slotprobe"

# Say what was written, with hashes, so the copy can be checked afterwards.
( cd "$DEST" && sha256sum SyncMyMod/autoinstall.sh yafc-install.sh \
    yafc-payload/libyafc.so yafc-payload/slotprobe yafc-payload/camera.conf \
    yafc-payload/hmi/*.fragment tools/apply-hmi-fragments.sh > yafc-payload/SHA256SUMS &&
    cat yafc-payload/SHA256SUMS )
echo
echo "Stick ready and UNARMED. To request something, create ONE marker at the stick"
echo "root: RUN-YAFC-REHEARSE, RUN-YAFC-INSTALL, RUN-YAFC-REMOVE, RUN-YAFC-REMOVE-HMI or"
echo "RUN-YAFC-DISABLE."
