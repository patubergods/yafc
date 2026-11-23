#!/bin/sh
# YAFC installer: put libyafc.so in the camera's library slot on the unit, with a
# preserved copy of the unit's OWN library beside it so every other process that
# uses that slot keeps working.
#
# RUN ON THE UNIT (the dispatcher calls it), or by hand over a shell:
#   sh yafc-install.sh <usb-root> <mode> <marker-file>
#
#   install   copy the unit's own library to the preserved name if it is not there
#             yet, then write YAFC's library over the slot, then probe the pair and
#             put the preserved copy back if the probe fails.
#   rehearse  the whole path with the unit's own bytes as the "new" library: proves
#             the mount work, the write and the probe without changing the picture.
#   remove    put the preserved copy back over the slot, then delete it.
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
case "$MODE" in install|rehearse|remove|disable) ;; *) say "refused: mode '$MODE'"; exit 3 ;; esac
say "yafc $MODE started (marker $MARKER)"

sha() { digest=$(openssl dgst -sha256 < "$1" 2>/dev/null) || return 1; printf '%s\n' "${digest##* }"; }
sums() { for f in $RECOVERY; do cksum "$MP/scripts/$f" || return 1; done; }
mp_lines() { mount 2>/dev/null | grep -F " on $MP "; }
sync3() { sync; sync; sync; }

ok() {
  echo "yafc $MODE complete $(date -u 2>/dev/null)" > "$OUT/DONE" 2>/dev/null || true
  rm -f "$MARKER" 2>/dev/null && sync || say "warning: marker not removed"
  say "done"
  exit 0
}
die() {
  say "FAIL: $1"
  echo "yafc $MODE FAILED $(date -u 2>/dev/null): $1; marker kept; see install.log" > "$OUT/FAILED" 2>/dev/null || true
  exit "${2:-4}"
}

SUMS0=$(sums) || die "cannot read the recovery script checksums" 3
check_scripts() {
  current=$(sums) || die "cannot verify the recovery scripts afterwards" 6
  [ "$current" = "$SUMS0" ] || die "a recovery script changed: before [$SUMS0] after [$current]" 6
}

# --- disable: the kill switch only ------------------------------------------
if [ "$MODE" = disable ]; then
  mkdir -p "$DATA" || die "cannot create $DATA"
  echo "disabled by $USB $(date -u 2>/dev/null)" > "$DATA/DISABLE" || die "cannot write the kill switch"
  sync
  [ -f "$DATA/DISABLE" ] || die "kill switch missing after write"
  check_scripts
  say "wrote $DATA/DISABLE"
  ok
fi

# --- everything else needs the payload --------------------------------------
[ -f "$NEW" ] || die "missing $NEW (is the payload staged on the stick?)" 3
[ -x "$PROBE" ] || die "missing or non-executable $PROBE (the loader probe)" 3

# --- remove -----------------------------------------------------------------
if [ "$MODE" = remove ]; then
  [ -f "$PRESERVED" ] || { say "nothing to remove: no preserved copy at $PRESERVED"; check_scripts; ok; }
fi

# --- mount stack: reduce to the base device, with checks --------------------
MOUNTS0=$(mp_lines)
say "mounts before: $(echo "$MOUNTS0" | tr '\n' '|')"
echo "$MOUNTS0" | grep -F -q "$BASEDEV on $MP " || die "$BASEDEV is not mounted on $MP" 3
[ "$(printf '%s\n' "$MOUNTS0" | tail -n 1 | awk '{print $1}')" = "$BASEDEV" ] ||
  die "$BASEDEV is not the bottom mount on $MP" 3
# Only the base device and image layers belong in this transaction.
printf '%s\n' "$MOUNTS0" | awk -v mp="$MP" -v base="$BASEDEV" '
  $2 != "on" || $3 != mp || $4 != "type" || $5 != "qnx6" { exit 1 }
  $1 == base { n++; next }
  $1 !~ /^\/fs\/images\/overlay[^/]*\.img$/ { exit 1 }
  END { if (n != 1) exit 1 }
' || die "unexpected layer in the $MP mount stack" 3

# Remount what we popped. The radio lists the image layers in mount-call order, so
# replay the recorded order rather than reversing it. A failed remount must not
# hide behind a clean exit.
remount_all() {
  printf '%s\n' "$MOUNTS0" | while IFS= read -r line; do
    dev=${line%% on *}
    [ "$dev" = "$BASEDEV" ] && continue
    mp_lines | grep -F -q "$dev on $MP " && continue
    if mount -b -r -t qnx6 -o before "$dev" "$MP" 2>> "$LOG"; then say "remounted $dev"
    else say "warning: could not remount $dev"; fi
  done
  [ "$(mp_lines | awk '{print $1, $2, $3}')" = "$(echo "$MOUNTS0" | awk '{print $1, $2, $3}')" ]
}

n=0
expected=$MOUNTS0
while :; do
  L=$(mp_lines) || { remount_all || true; die "cannot read the current mount stack" 5; }
  [ "$L" = "$expected" ] ||
    { remount_all || true; die "the $MP mount stack changed under us; nothing written" 5; }
  top=$(printf '%s\n' "$L" | awk 'NR==1 {print $1}')
  if [ "$top" = "$BASEDEV" ]; then
    [ "$(printf '%s\n' "$L" | awk 'END {print NR}')" = 1 ] ||
      die "unexpected layers behind $BASEDEV; nothing written" 5
    break
  fi
  n=$((n+1))
  if [ "$n" -gt 32 ] || ! umount "$MP" 2>> "$LOG"; then
    remount_all || true
    die "cannot reduce $MP to $BASEDEV only (attempt $n); nothing was written, but the layer order may have changed - a reset restores the boot order" 5
  fi
  say "popped a layer (attempt $n)"
  expected=$(printf '%s\n' "$expected" | sed '1d')
done

# --- write, with a temporary name and verification --------------------------
FAILMSG=""
put_verified() {  # put_verified SRC SHA DEST
  [ ! -e "$TMP" ] && [ ! -L "$TMP" ] || return 1
  ( umask 077; set -C; : > "$TMP" ) || return 1
  cp "$1" "$TMP" && chmod 755 "$TMP" && sync3 && [ "$(sha "$TMP")" = "$2" ] &&
    mv "$TMP" "$3" || return 1
  sync3 && [ "$(sha "$3")" = "$2" ]
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
  mount -uw "$MP" 2>> "$LOG" || { FAILMSG="mount -uw failed"; return 1; }
  : > "$LIB/.yafc-rw-probe" 2>/dev/null && rm -f "$LIB/.yafc-rw-probe" ||
    { FAILMSG="/fs/mp is not writable"; return 1; }

  # 1. the preserved copy of the unit's OWN library, once. `rehearse` needs it for
  #    the same reason `install` does: it writes those bytes through the same path.
  if [ ! -f "$PRESERVED" ]; then
    OWN=$(sha "$SLOT") || { FAILMSG="cannot read the live slot"; return 1; }
    [ -n "$OWN" ] || { FAILMSG="live slot unreadable ($SLOT)"; return 1; }
    put_verified "$SLOT" "$OWN" "$PRESERVED" || { FAILMSG="cannot write the preserved copy"; return 1; }
    say "preserved the unit's own library as $PRESERVED"
  fi
  [ -f "$PRESERVED" ] || { FAILMSG="no preserved copy at $PRESERVED"; return 1; }
  PRES=$(sha "$PRESERVED") || { FAILMSG="preserved copy unreadable"; return 1; }

  if [ "$MODE" = remove ]; then
    [ "$(sha "$SLOT")" = "$PRES" ] || put_verified "$PRESERVED" "$PRES" "$SLOT" ||
      { FAILMSG="cannot restore the preserved copy over the slot"; return 1; }
    rm -f "$PRESERVED" || { FAILMSG="cannot delete $PRESERVED"; return 1; }
    sync3 && [ ! -e "$PRESERVED" ] || { FAILMSG="preserved copy still present"; return 1; }
    say "removed YAFC: the unit's own library is back in the slot"
    return 0
  fi

  # 2. the new library. `rehearse` writes the unit's own bytes instead, so the
  #    whole path is exercised without changing the picture.
  if [ "$MODE" = rehearse ]; then
    put_verified "$PRESERVED" "$PRES" "$SLOT" || { FAILMSG="rehearsal write failed"; return 1; }
    say "rehearsal: the unit's own bytes written through the real path"
    return 0
  fi
  WANT=$(sha "$NEW") || { FAILMSG="cannot read $NEW"; return 1; }
  put_verified "$NEW" "$WANT" "$SLOT" || { FAILMSG="writing the new library failed"; return 1; }

  # 3. prove the pair loads, before anything is rebooted.
  if probe_installed &&
     [ "$(grep -c 'same=yes' "$OUT/probe.out" 2>/dev/null || true)" -ge 4 ] &&
     grep -Fq "libRCN_DiagnosticsOld.so" "$OUT/probe.out" &&
     grep -Fq "$SLOT" "$OUT/probe.err"; then
    say "the installed pair passed the loader probe"
    return 0
  fi

  # 4. it did not: put the unit's own library back, so a failed install cannot
  #    cost the camera.
  FAILMSG="the installed pair failed the loader probe"
  if put_verified "$PRESERVED" "$PRES" "$SLOT"; then
    say "install failed: the unit's own library is back in the slot"
  else
    FAILMSG="$FAILMSG; and restoring the unit's own library failed"
  fi
  return 1
}

write_pair || say "write failed: $FAILMSG"
rm -f "$TMP" 2>/dev/null || true
mount -ur "$MP" 2>> "$LOG" || FAILMSG="${FAILMSG:+$FAILMSG; }mount -ur failed"
remount_all || FAILMSG="${FAILMSG:+$FAILMSG; }the mount list differs after remount"
say "mounts after: $(mp_lines | tr '\n' '|')"
[ -z "$FAILMSG" ] || die "$FAILMSG" 4
check_scripts
ok
