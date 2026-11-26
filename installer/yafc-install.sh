#!/bin/sh
# YAFC installer: put libyafc.so in the camera's library slot on the unit, with a
# preserved copy of the unit's OWN library beside it so every other process that
# uses that slot keeps working, and publish the HMI edits as a small overlay image.
#
# RUN ON THE UNIT (the dispatcher calls it), or by hand over a shell:
#   sh yafc-install.sh <usb-root> <mode> <marker-file>
#
#   install   copy the unit's own library to the preserved name if it is not there
#             yet, then write YAFC's library over the slot, probe the pair, and put
#             the preserved copy back if the probe fails. Then build the HMI overlay
#             from the unit's own four stock files and publish it.
#   rehearse  the write and image-build paths with the current slot bytes and
#             without publishing the image or seeding config.
#   remove    put the preserved copy back over the slot, delete it, and delete the
#             HMI image.
#   remove-hmi delete the HMI image only; the library is not touched.
#   disable   write the kill-switch file only. Nothing under /fs/mp is touched.
#
# The camera keeps running throughout: no service is stopped and no process is
# replaced. See ../docs/INSTALL.md and ../docs/RECOVERY.md.
set -eu

PATH=${PATH:+$PATH:}/proc/boot:/bin:/usr/bin:/sbin:/usr/sbin:/fs/mp/bin:/fs/mp/usr/bin:/fs/mp/sbin:/fs/mp/usr/sbin:/fs/rwdata/dev
LD_LIBRARY_PATH=/proc/boot:/lib:/lib/dll:/usr/lib:/apps/lib:/fs/mp/lib:/fs/mp/usr/lib:/fs/mp/apps/usr/lib
export PATH LD_LIBRARY_PATH
unalias -a 2>/dev/null || true

USB=${1:?usage: yafc-install.sh USB MODE MARKER}
MODE=${2:?missing mode}
MARKER=${3:?missing marker}
M=$USB/yafc-payload
OUT=$USB/yafc-install
MP=${YAFC_MP:-/fs/mp}
DATA=${YAFC_DATA:-/fs/rwdata/yafc}
BASEDEV=${YAFC_BASEDEV:-/dev/hd0t178}
SCRATCH=${YAFC_SCRATCH:-/fs/tmpfs/yafc-hmi}
IMGDIR=${YAFC_IMGDIR:-/fs/images}
IMG=$IMGDIR/overlay_00--yafc.img
DEV=${YAFC_HMI_DEV:-/dev/yafchmi0}
BUILD=$SCRATCH/.yafc-build.img
PUBLISH=$IMGDIR/.yafc-build.$$.img
CONFIG=$DATA/camera.conf
CONFIG_TMP=$DATA/.camera.conf.$$.new
LIB=$MP/apps/usr/lib
SLOT=$LIB/libRCN_DiagnosticsLib.so
PRESERVED=$LIB/libRCN_DiagnosticsOld.so
TMP=$LIB/.libRCN_DiagnosticsLib.so.new
NEW=$M/libyafc.so
PROBE=$M/slotprobe
LOG=$OUT/install.log
# Never edit these: they are the unit's own recovery path. Their checksums are
# compared before and after the mount work.
RECOVERY="startup_gf.sh usb_installer.sh launch/launch_usblauncher.sh"

say() { echo "$(date -u 2>/dev/null) $*" >> "$LOG"; }
mkdir -p "$OUT" || exit 1
: > "$LOG"
rm -f "$OUT/DONE" "$OUT/FAILED" 2>/dev/null || true
[ -f "$MARKER" ] && [ ! -L "$MARKER" ] || { say "refused: no request marker ($MARKER)"; exit 3; }
case "$MODE" in install|rehearse|remove|remove-hmi|disable) ;; *) say "refused: mode '$MODE'"; exit 3 ;; esac
say "yafc $MODE started (marker $MARKER)"

sha() { digest=$(openssl dgst -sha256 < "$1" 2>/dev/null) || return 1; printf '%s\n' "${digest##* }"; }
sums() { for f in $RECOVERY; do cksum "$MP/scripts/$f" || return 1; done; }
mp_lines() { mount 2>/dev/null | grep -F " on $MP "; }
sync3() { sync && sync && sync; }

ok() {
  echo "yafc $MODE complete $(date -u 2>/dev/null)" > "$OUT/DONE" 2>/dev/null ||
    die "cannot write the DONE receipt"
  if ! rm -f "$MARKER" 2>/dev/null || ! sync; then
    rm -f "$OUT/DONE" 2>/dev/null || true
    die "cannot consume the request marker durably"
  fi
  say "done"
  exit 0
}
die() {
  say "FAIL: $1"
  echo "yafc $MODE FAILED $(date -u 2>/dev/null): $1; see install.log" > "$OUT/FAILED" 2>/dev/null || true
  exit "${2:-4}"
}

SUMS0=$(sums) || die "cannot read the recovery script checksums" 3
check_scripts() {
  if ! current=$(sums); then
    SCRIPT_ERROR="cannot verify the recovery scripts"
  elif [ "$current" != "$SUMS0" ]; then
    SCRIPT_ERROR="a recovery script changed: before [$SUMS0] after [$current]"
  else
    return 0
  fi
  return 1
}

# --- disable: the kill switch only ------------------------------------------
if [ "$MODE" = disable ]; then
  mkdir -p "$DATA" || die "cannot create $DATA"
  echo "disabled by $USB $(date -u 2>/dev/null)" > "$DATA/DISABLE" || die "cannot write the kill switch"
  sync || die "cannot sync the kill switch"
  [ -f "$DATA/DISABLE" ] || die "kill switch missing after write"
  check_scripts || die "$SCRIPT_ERROR" 6
  say "wrote $DATA/DISABLE"
  ok
fi

if [ "$MODE" = install ]; then
  [ -f "$NEW" ] || die "missing $NEW (is the payload staged on the stick?)" 3
  [ -x "$PROBE" ] || die "missing or non-executable $PROBE (the loader probe)" 3
fi

if [ "$MODE" = remove ] && [ ! -f "$PRESERVED" ]; then
  say "no preserved copy at $PRESERVED; the slot will be left unchanged"
fi
if [ "$MODE" = remove-hmi ] || { [ "$MODE" = remove ] && [ ! -f "$PRESERVED" ]; }; then
  if [ ! -e "$IMG" ] && [ ! -L "$IMG" ] && [ ! -e "$IMG.old" ] && [ ! -L "$IMG.old" ]; then
    say "no HMI image to remove"
    check_scripts || die "$SCRIPT_ERROR" 6
    ok
  fi
fi

# --- mount stack: reduce to the base device, with checks --------------------
MOUNTS0=$(mp_lines) || die "cannot read the $MP mount stack" 3
say "mounts before: $(echo "$MOUNTS0" | tr '\n' '|')"
echo "$MOUNTS0" | grep -F -q "$BASEDEV on $MP " || die "$BASEDEV is not mounted on $MP" 3
[ "$(printf '%s\n' "$MOUNTS0" | tail -n 1 | awk '{print $1}')" = "$BASEDEV" ] ||
  die "$BASEDEV is not the bottom mount on $MP" 3
# Only the base device and image layers belong in this transaction.
printf '%s\n' "$MOUNTS0" | awk -v mp="$MP" -v base="$BASEDEV" -v images="$IMGDIR/" '
  $2 != "on" || $3 != mp || $4 != "type" || $5 != "qnx6" || seen[$1]++ { exit 1 }
  $1 == base { n++; next }
  index($1, images) != 1 || substr($1, length(images) + 1) !~ /^overlay[^/]*\.img$/ { exit 1 }
  END { if (n != 1 || NR > 33) exit 1 }
' || die "unexpected layer in the $MP mount stack" 3

# The radio lists image layers in mount-call order. Keep that order, and omit
# the YAFC layer only when a requested deletion actually removed its image.
replay_mounts() {
  wanted=$MOUNTS0
  if [ "$remove_image" = 1 ] && [ ! -e "$IMG" ] && [ ! -L "$IMG" ]; then
    wanted=$(printf '%s\n' "$MOUNTS0" | awk -v img="$IMG" '$1 != img')
  fi
  printf '%s\n' "$wanted" | while IFS= read -r line; do
    dev=${line%% on *}
    [ "$dev" = "$BASEDEV" ] && continue
    mp_lines | grep -F -q "$dev on $MP " && continue
    if mount -b -r -t qnx6 -o before "$dev" "$MP" 2>> "$LOG"; then say "remounted $dev"
    else say "warning: could not remount $dev"; fi
  done
  actual=$(mp_lines)
  say "mounts after: $(printf '%s\n' "$actual" | tr '\n' '|')"
  [ "$actual" = "$wanted" ]
}

reduce_mounts() {
  expected=$MOUNTS0
  while :; do
    current=$(mp_lines) && [ "$current" = "$expected" ] ||
      { FAILMSG="the $MP mount stack changed during reduction; no files written"; return 1; }
    top=${current%% on *}
    [ "$top" != "$BASEDEV" ] || return 0
    umount "$MP" 2>> "$LOG" ||
      { FAILMSG="cannot unmount $top from $MP; no files written"; return 1; }
    expected=$(printf '%s\n' "$expected" | sed '1d')
    say "unmounted $top"
  done
}

# --- write, with a temporary name and verification --------------------------
FAILMSG=
RC=0
remove_image=0
base_restore_ro=0
image_mounted=0
scratch_owned=0
publish_owned=0
config_tmp_owned=0
loop_starting=0
loop_pid=
put_verified() {  # put_verified SRC SHA DEST
  [ ! -e "$TMP" ] && [ ! -L "$TMP" ] || return 1
  ( umask 077; set -C; : > "$TMP" ) || return 1
  if cp "$1" "$TMP" && chmod 755 "$TMP" && sync3 &&
     [ "$(sha "$TMP")" = "$2" ] && mv "$TMP" "$3"; then
    sync3 && [ "$(sha "$3")" = "$2" ]
  else
    rm -f "$TMP" 2>> "$LOG" || true
    return 1
  fi
}

seed_config() {
  [ ! -L "$CONFIG" ] || return 1
  [ ! -e "$CONFIG" ] || { [ -f "$CONFIG" ]; return; }
  defaults=$M/camera.conf
  [ -s "$defaults" ] && mkdir -p "$DATA" || return 1
  ( umask 022; set -C; : > "$CONFIG_TMP" ) || return 1
  config_tmp_owned=1
  digest=$(sha "$defaults") && cp "$defaults" "$CONFIG_TMP" &&
    [ "$(sha "$CONFIG_TMP")" = "$digest" ] && sync3 || return 1
  # Publish without overwriting settings if they appeared after the first check.
  if ln "$CONFIG_TMP" "$CONFIG" 2>> "$LOG"; then
    sync3 && [ "$(sha "$CONFIG")" = "$digest" ] || return 1
    say "initialized $CONFIG"
  else
    [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || return 1
  fi
}

# The probe runs the freshly written pair through the loader and prints where each
# of its own Screen and diagnostics calls resolved. Bounded: it must never hang.
probe_installed() {
  "$PROBE" > "$OUT/probe.out" 2> "$OUT/probe.err" &
  pid=$!
  ( sleep 15; kill -9 "$pid" 2>/dev/null ) </dev/null > /dev/null 2>&1 &
  timer=$!
  result=0
  wait "$pid" || result=$?
  kill "$timer" 2>/dev/null || true
  [ "$result" = 0 ]
}

write_pair() {
  # The captured radio omits mode flags from mount output. Use its normal
  # read-only boot baseline unless the listing explicitly reports writable.
  case "$base_mount" in
    *"(rw)"*) ;;
    *) base_restore_ro=1
       mount -uw "$MP" 2>> "$LOG" || { FAILMSG="mount -uw failed"; return 1; };;
  esac

  if [ "$MODE" = rehearse ]; then
    OWN=$(sha "$SLOT") && put_verified "$SLOT" "$OWN" "$SLOT" ||
      { FAILMSG="rehearsal write failed"; return 1; }
    say "rehearsal: the current slot bytes written through the real path"
    return 0
  fi

  # Preserve the unit's own library once. Removal never invents a backup.
  if [ ! -f "$PRESERVED" ]; then
    OWN=$(sha "$SLOT") && put_verified "$SLOT" "$OWN" "$PRESERVED" ||
      { FAILMSG="cannot preserve the unit's own library"; return 1; }
    say "preserved the unit's own library as $PRESERVED"
  fi
  [ -f "$PRESERVED" ] || { FAILMSG="no preserved copy at $PRESERVED"; return 1; }
  PRES=$(sha "$PRESERVED") || { FAILMSG="preserved copy unreadable"; return 1; }

  if [ "$MODE" = remove ]; then
    [ "$(sha "$SLOT")" = "$PRES" ] || put_verified "$PRESERVED" "$PRES" "$SLOT" ||
      { FAILMSG="cannot restore the preserved copy over the slot"; return 1; }
    rm -f "$PRESERVED" && sync3 && [ ! -e "$PRESERVED" ] ||
      { FAILMSG="cannot remove the preserved copy"; return 1; }
    say "removed YAFC: the unit's own library is back in the slot"
    return 0
  fi

  # Verify the loader after the atomic slot write; restore stock on failure.
  WANT=$(sha "$NEW") || { FAILMSG="cannot read $NEW"; return 1; }
  if ! put_verified "$NEW" "$WANT" "$SLOT"; then
    FAILMSG="writing the new library failed"
    [ "$(sha "$SLOT")" != "$PRES" ] || return 1
  elif probe_installed &&
       [ "$(grep -c 'same=yes' "$OUT/probe.out" 2>/dev/null || true)" -ge 4 ] &&
       grep -Fq "libRCN_DiagnosticsOld.so" "$OUT/probe.out" &&
       grep -Fq "$SLOT" "$OUT/probe.err"; then
    say "the installed pair passed the loader probe"
    return 0
  else
    FAILMSG="the installed pair failed the loader probe"
  fi

  # Restore the unit's own library before returning a failed install receipt.
  if put_verified "$PRESERVED" "$PRES" "$SLOT"; then
    say "install failed: the unit's own library is back in the slot"
  else
    FAILMSG="$FAILMSG; and restoring the unit's own library failed"
  fi
  return 1
}


# --- HMI: build the overlay from the unit's own four files ------------------
# The stock copies are read while the mount stack is still the base device only:
# an overlay on top may already carry modified copies. The applier edits the
# staging tree, never the unit's files. The image is published, if at all, inside
# this same popped window, because a mounted image cannot be replaced.
FRAGDIR=$M/hmi
HMI_FILES="fordhmi/qml/themes/ford-10P-MY20/styles/RVCPopupStyle.qml
fordhmi/qml/hmirvc/+10inchP/RVCPopup.qml
fordhmi/qml/hmisettings/driverassistance/+10inchP/RVCSettings.qml
fordhmi/qml/+10inchP/Root.qml"
FRAGMENTS="popup-height popup-1-state popup-2-visible popup-3-top
popup-4-margin popup-5-root popup-6-items popup-7-text-anchor popup-8-text-margin
settings-1-state settings-2-rows chrome-hide-1-property chrome-hide-2-statusbar
chrome-hide-3-menubar chrome-hide-4-transient chrome-hide-5-tiles"

hmi_balanced() {  # hmi_balanced FILE: braces and brackets must balance
  awk '{
    n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (c == "{") b++; else if (c == "}") b--
      else if (c == "[") k++; else if (c == "]") k--
      if (b < 0 || k < 0) exit 1
    }
  } END { if (b != 0 || k != 0) exit 1 }' "$1" 2>> "$LOG"
}

hmi_cksum() { set -- $(cksum "$1" 2>/dev/null); [ "$#" -ge 2 ] || return 1; printf '%s %s\n' "$1" "$2"; }

unmount_image() {
  [ "$image_mounted" = 1 ] || return 0
  umount "$SCRATCH/mnt" >> "$LOG" 2>&1 || return 1
  image_mounted=0
}

stop_loopback() {
  [ "$loop_starting" = 0 ] || return 1
  [ -n "$loop_pid" ] || return 0
  kill "$loop_pid" 2>/dev/null || true
  tries=0
  while [ -e "$DEV" ] && [ "$tries" -lt 10 ]; do sleep 1; tries=$((tries + 1)); done
  [ ! -e "$DEV" ] || return 1
  loop_pid=
}

# Copy the patched files into their same relative paths and build a qnx6 image.
# hmi_build STAGE OUT: 0 built, 1 the recipe failed.
hmi_build() {
  stage=$1
  out=$2
  [ ! -e "$DEV" ] || { say "HMI: loopback device already exists"; return 1; }
  touch "$out" 2>> "$LOG" || return 1
  dinit -hq -S4m "$out" >> "$LOG" 2>&1 || { say "HMI: dinit failed"; return 1; }
  say "HMI: dinit ok"
  [ -s "$out" ] || { say "HMI: the backing file is empty"; return 1; }
  loop_starting=1
  devb-loopback blk cache=512k,auto=none loopback fd="$out",prefix=yafchmi >> "$LOG" 2>&1 &
  loop_pid=$!
  loop_starting=0
  i=0
  while [ ! -e "$DEV" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
  [ -e "$DEV" ] || { say "HMI: the loopback device never appeared"; return 1; }
  say "HMI: loopback device ready"
  mkqnx6fs -q -b 4096 "$DEV" >> "$LOG" 2>&1 || { say "HMI: mkqnx6fs failed"; return 1; }
  say "HMI: mkqnx6fs ok"
  image_mounted=1
  mount -t qnx6 "$DEV" "$SCRATCH/mnt" >> "$LOG" 2>&1 ||
    { image_mounted=0; say "HMI: mount rw failed"; return 1; }
  for rel in $HMI_FILES; do
    mkdir -p "$SCRATCH/mnt/$(dirname "$rel")" 2>> "$LOG" || { say "HMI: mkdir in the image failed"; return 1; }
    cp "$stage/$rel" "$SCRATCH/mnt/$rel" 2>> "$LOG" || { say "HMI: copy into the image failed"; return 1; }
  done
  unmount_image || { say "HMI: umount after the copy failed"; return 1; }
  stop_loopback || { say "HMI: the loopback still holds $DEV"; return 1; }
  chkqnx6fs "$out" >> "$LOG" 2>&1 || { say "HMI: chkqnx6fs failed - image not published"; return 1; }
  say "HMI: chkqnx6fs ok"
  image_mounted=1
  mount -b -r -t qnx6 "$out" "$SCRATCH/mnt" >> "$LOG" 2>&1 ||
    { image_mounted=0; say "HMI: verify mount failed"; return 1; }
  for rel in $HMI_FILES; do
    [ -f "$SCRATCH/mnt/$rel" ] || { say "HMI: read-back missing $rel"; return 1; }
    a=$(hmi_cksum "$stage/$rel") && b=$(hmi_cksum "$SCRATCH/mnt/$rel") &&
      [ "$a" = "$b" ] || { say "HMI: read-back differs for $rel"; return 1; }
  done
  unmount_image || { say "HMI: umount after read-back failed"; return 1; }
  say "HMI: read-back matches (cksum) for all four files"
  return 0
}

do_hmi() {
  RC=9
  for fragment in $FRAGMENTS; do
    [ -s "$FRAGDIR/$fragment.fragment" ] ||
      { FAILMSG="missing required HMI fragment $fragment"; return 1; }
  done
  set -- $FRAGMENTS
  expected_fragments=$#
  set -- "$FRAGDIR"/*.fragment
  [ "$#" -eq "$expected_fragments" ] ||
    { FAILMSG="unexpected extra HMI fragments"; return 1; }

  RC=10
  mkdir "$SCRATCH" 2>> "$LOG" ||
    { FAILMSG="cannot create clean scratch directory $SCRATCH"; return 1; }
  scratch_owned=1
  mkdir "$SCRATCH/stage" "$SCRATCH/mnt" 2>> "$LOG" ||
    { FAILMSG="cannot create the HMI staging tree"; return 1; }
  for rel in $HMI_FILES; do
    src=$MP/$rel
    [ -f "$src" ] || { RC=8; FAILMSG="missing stock file $src"; return 1; }
    mkdir -p "$SCRATCH/stage/$(dirname "$rel")" 2>> "$LOG" &&
      cp "$src" "$SCRATCH/stage/$rel" 2>> "$LOG" ||
      { FAILMSG="cannot stage stock file $src"; return 1; }
    say "HMI: staged $rel"
  done

  RC=9
  sh "$USB/tools/apply-hmi-fragments.sh" "$SCRATCH/stage" "$FRAGDIR" >> "$LOG" 2>&1 ||
    { FAILMSG="the HMI applier refused the fragment set"; return 1; }
  for rel in $HMI_FILES; do
    hmi_balanced "$SCRATCH/stage/$rel" ||
      { FAILMSG="unbalanced braces or brackets in $rel"; return 1; }
  done

  RC=10
  hmi_build "$SCRATCH/stage" "$BUILD" ||
    { FAILMSG="the HMI image build or read-back failed"; return 1; }
  RC=0
  if [ "$MODE" = rehearse ]; then
    say "HMI rehearsed: would publish $IMG; $IMGDIR untouched"
    for rel in $HMI_FILES; do
      say "HMI would publish $rel $(hmi_cksum "$SCRATCH/stage/$rel")"
    done
    say "HMI would publish image $(hmi_cksum "$BUILD")"
  fi
}

publish_image() {
  [ ! -L "$IMG" ] && { [ ! -e "$IMG" ] || [ -f "$IMG" ]; } || return 1
  ( umask 022; set -C; : > "$PUBLISH" ) || return 1
  publish_owned=1
  digest=$(sha "$BUILD") && cp "$BUILD" "$PUBLISH" &&
    [ "$(sha "$PUBLISH")" = "$digest" ] && sync3 || return 1
  # Same directory, outside the boot glob until the atomic rename.
  mv -f "$PUBLISH" "$IMG" 2>> "$LOG" || return 1
  publish_owned=0
  say "HMI: published $IMG"
  if ! sync3; then
    FAILMSG="HMI image was renamed but final sync failed"
    return 1
  fi
  rm -f "$IMG.old" 2>> "$LOG" || say "HMI: warning: legacy $IMG.old remains"
}

delete_images() {
  # Delete the inert legacy backup first: if it fails, the active image remains.
  for image in "$IMG.old" "$IMG"; do
    [ -e "$image" ] || [ -L "$image" ] || continue
    [ "$image" != "$IMG" ] || remove_image=1
    rm -f "$image" 2>> "$LOG" && [ ! -e "$image" ] && [ ! -L "$image" ] ||
      { FAILMSG="cannot delete $image"; return 1; }
    say "removed $image"
  done
  sync3 || { FAILMSG="could not sync HMI image deletion"; return 1; }
}

cleanup_failed() {
  FAILMSG="${FAILMSG:+$FAILMSG; }$1"
  [ "$RC" -ne 0 ] || RC=$2
}

restore_base() {
  [ "$base_restore_ro" = 1 ] || return 0
  mount -ur "$MP" 2>> "$LOG" || return 1
  base_restore_ro=0
}

finish() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$status" -ne 0 ] && [ -z "$FAILMSG" ]; then
    FAILMSG="installer stopped unexpectedly (exit $status)"
    RC=4
  fi
  if unmount_image && stop_loopback; then
    if [ "$scratch_owned" = 1 ]; then
      rm -rf "$SCRATCH" 2>> "$LOG" || cleanup_failed "cannot remove $SCRATCH" 10
    fi
  else
    cleanup_failed "cannot release the HMI build mount or loopback; scratch retained" 10
  fi
  if [ "$publish_owned" = 1 ]; then
    rm -f "$PUBLISH" 2>> "$LOG" || cleanup_failed "cannot remove $PUBLISH" 12
  fi
  if [ "$config_tmp_owned" = 1 ]; then
    rm -f "$CONFIG_TMP" 2>> "$LOG" || cleanup_failed "cannot remove $CONFIG_TMP" 4
  fi
  restore_base || cleanup_failed "mount -ur failed" 4
  replay_mounts || cleanup_failed "cannot restore the exact $MP mount stack; reset to restore boot order" 5
  [ "$RC" -eq 6 ] || check_scripts || cleanup_failed "$SCRIPT_ERROR" 6
  [ -z "$FAILMSG" ] || die "$FAILMSG" "$RC"
  ok
}

base_mount=$(printf '%s\n' "$MOUNTS0" | tail -n 1)
trap finish EXIT
trap 'FAILMSG="installer interrupted"; RC=5; exit "$RC"' HUP INT TERM
if ! reduce_mounts; then RC=5; exit "$RC"; fi

case "$MODE" in
  remove|remove-hmi)
    if ! delete_images; then RC=12; exit "$RC"; fi
    if [ "$MODE" = remove ] && [ -f "$PRESERVED" ]; then
      if ! write_pair; then RC=4; exit "$RC"; fi
    fi
    ;;
  install|rehearse)
    if [ "$MODE" = install ] && ! seed_config; then
      FAILMSG="cannot initialize $CONFIG; slot and HMI image unchanged"
      RC=4
      exit "$RC"
    fi
    if ! write_pair; then RC=4; exit "$RC"; fi
    if ! restore_base; then FAILMSG="mount -ur failed"; RC=4; exit "$RC"; fi
    if ! check_scripts; then FAILMSG=$SCRIPT_ERROR; RC=6; exit "$RC"; fi
    if ! do_hmi; then
      if [ "$MODE" = install ]; then FAILMSG="HMI only: $FAILMSG; slot passed the loader probe"; fi
      exit "$RC"
    fi
    if [ "$MODE" = install ] && ! publish_image; then
      FAILMSG="${FAILMSG:-HMI only: cannot stage or publish $IMG; slot passed the loader probe}"
      RC=12
      exit "$RC"
    fi
    ;;
esac
