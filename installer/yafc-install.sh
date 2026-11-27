#!/bin/sh
# YAFC installer: put libyafc.so in the camera's library slot on the unit, with a
# preserved copy of the unit's OWN library beside it so every other process that
# uses that slot keeps working, and publish the HMI edits as a small overlay image.
#
# RUN ON THE UNIT from the marker dispatcher:
#   sh yafc-install.sh <usb-root> <mode> <running-marker>
#
#   install    build and read back the HMI image from the unit's own four files,
#              journal the exact previous slot, preserved copy, image and ownership
#              record, write the stock copy and then YAFC's library, probe the pair
#              with the loader trace on, then publish the image by one rename.
#   rehearse   the same ownership and overlay checks, mount work, image build and
#              journal; the slot is rewritten with its own current bytes and not
#              probed. Nothing is published or owned.
#   remove     put the authenticated stock library back in the slot, then delete
#              the owned preserved copy and the owned HMI image.
#   remove-hmi delete the owned HMI image only; the library is untouched.
#   recover    restore an interrupted transaction's journaled previous state, only
#              when the journal and every file authenticate; else keep the journal.
#   disable    write the runtime kill switch only; nothing under /fs/mp is touched.
#
# Nothing that this installer did not record as its own is adopted, replaced or
# deleted. Every failure after the journal is written either rolls back to the
# recorded bytes or keeps the journal and says so. A restart remounts the boot
# images; it does not undo a file write.
#
# The camera keeps running throughout: no service is stopped and no process is
# replaced. See ../docs/INSTALL.md and ../docs/RECOVERY.md.
set -eu

PATH=${PATH:+$PATH:}/proc/boot:/bin:/usr/bin:/sbin:/usr/sbin:/fs/mp/bin:/fs/mp/usr/bin:/fs/mp/sbin:/fs/mp/usr/sbin:/fs/rwdata/dev
LD_LIBRARY_PATH=/proc/boot:/lib:/lib/dll:/usr/lib:/apps/lib:/fs/mp/lib:/fs/mp/usr/lib:/fs/mp/apps/usr/lib
LC_ALL=C
export PATH LD_LIBRARY_PATH LC_ALL
unalias -a 2>/dev/null || true

USB=${1:?usage: yafc-install.sh USB MODE MARKER}
MODE=${2:?missing mode}
MARKER=${3:?missing marker}
M=$USB/yafc-payload
REPORT=$USB/yafc-install
MP=${YAFC_MP:-/fs/mp}
DATA=${YAFC_DATA:-/fs/rwdata/yafc}
BASEDEV=${YAFC_BASEDEV:-/dev/hd0t178}
SCRATCH=${YAFC_SCRATCH:-/fs/tmpfs/yafc-hmi}
IMGDIR=${YAFC_IMGDIR:-/fs/images}
IMG=$IMGDIR/overlay_00--yafc.img
DEV=${YAFC_HMI_DEV:-/dev/yafchmi0}
CONFIG=$DATA/camera.conf
OWNER=$DATA/installer-owner
JOURNAL=$DATA/installer-pending
LOCK=$SCRATCH.lock
# Recorded stock build of libRCN_DiagnosticsLib.so, one radio. Any other unowned
# slot (other firmware or units) is refused until its digest is independently
# verified and added here. An existing preserved copy is never adopted.
FACTORY=af2278a253732f8f641c06c5279c3bbff48e0acdf439a11c36ddf6e440e62481
LIB=$MP/apps/usr/lib
SLOT=$LIB/libRCN_DiagnosticsLib.so
PRESERVED=$LIB/libRCN_DiagnosticsOld.so
NEW=$M/libyafc.so
PROBE=$M/slotprobe
# Never edit these: they are the unit's own recovery path. Their checksums are
# compared before and after the mount work, on the same layer list.
RECOVERY="startup_gf.sh usb_installer.sh launch/launch_usblauncher.sh"

exists() { [ -e "$1" ] || [ -L "$1" ]; }
plain() { [ -f "$1" ] && [ ! -L "$1" ]; }
directory() { [ -d "$1" ] && [ ! -L "$1" ]; }
appendable() { ! exists "$1" || plain "$1"; }
request_id() { case "$1" in ''|*[!0-9T-]*) return 1 ;; esac; }
sha() {
  plain "$1" || return 1
  digest=$(openssl dgst -sha256 < "$1" 2>/dev/null) || return 1
  digest=${digest##* }
  case "$digest" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#digest}" -eq 64 ] || return 1
  printf '%s\n' "$digest"
}
fingerprint() { if exists "$1"; then sha "$1"; else printf '%s\n' -; fi; }
sync3() { sync && sync && sync; }
sums() { for f in $RECOVERY; do cksum "$MP/scripts/$f" || return 1; done; }

# --- request and receipts ----------------------------------------------------
# The dispatcher writes a request ID into the .running marker and creates the
# per-request report directory. Every receipt line names the request, the mode
# and the stage it was written at, so an old receipt cannot pass for this one.
plain "$MARKER" || { echo "missing plain running marker" >&2; exit 3; }
REQUEST=$(cat "$MARKER") && request_id "$REQUEST" || exit 3
OUT=$REPORT/request-$REQUEST
directory "$REPORT" && directory "$OUT" || exit 3
for file in "$REPORT/install.log" "$REPORT/DONE" "$REPORT/FAILED"; do
  appendable "$file" || exit 3
done
LOG=$OUT/install.log
( umask 077; set -C; : > "$LOG" ) || exit 3
# Request-specific temporary names: a stale one never blocks a later request.
BUILD=$IMGDIR/.yafc-build.$REQUEST.img
RESTORE_IMG=$IMGDIR/.yafc-restore.$REQUEST.img
TMP=$LIB/.yafc-slot.$REQUEST.new
CONFIG_TMP=$DATA/.camera.conf.$REQUEST.new
OWNER_TMP=$DATA/.installer-owner.$REQUEST.new
PHASE=request
say() {
  line="$(date -u 2>/dev/null) request=$REQUEST stage=$PHASE $*"
  printf '%s\n' "$line" >> "$LOG" || return 1
  printf '%s\n' "$line" >> "$REPORT/install.log"
}
receipt() {
  ( umask 077; set -C; printf '%s\n' "request=$REQUEST mode=$MODE stage=$PHASE $2" > "$OUT/$1" ) &&
    sync && cat "$OUT/$1" >> "$REPORT/$1" && sync
}
die() {
  say "FAIL: $1" || true
  receipt FAILED "$1" || true
  exit "${2:-4}"
}
ok() {
  PHASE=receipt
  # Consume the request before DONE: DONE never coexists with this .running marker.
  [ "$(cat "$MARKER")" = "$REQUEST" ] && rm "$MARKER" && sync ||
    die "operation verified; cannot consume this request durably"
  receipt DONE "operation verified" || die "operation verified; DONE receipt not confirmed"
  say "done"
  exit 0
}
case "$MODE" in install|rehearse|remove|remove-hmi|recover|disable) ;; *) die "unknown mode" 3 ;; esac
say "yafc $MODE started"

check_scripts() {  # check_scripts BASELINE, taken on the same layer list
  if ! current_sums=$(sums); then
    SCRIPT_ERROR="cannot verify the recovery scripts"
  elif [ "$current_sums" != "$1" ]; then
    SCRIPT_ERROR="a recovery script changed: before [$1] after [$current_sums]"
  else
    return 0
  fi
  return 1
}

# --- disable: the kill switch only ------------------------------------------
if [ "$MODE" = disable ]; then
  PHASE=disable
  mkdir -p "$DATA" && directory "$DATA" || die "invalid runtime data directory"
  if exists "$DATA/DISABLE"; then
    plain "$DATA/DISABLE" || die "kill switch is not a regular file"
  else
    ( umask 022; set -C; printf '%s\n' "disabled by YAFC request $REQUEST" > "$DATA/DISABLE" ) ||
      die "cannot write the kill switch"
  fi
  sync && plain "$DATA/DISABLE" || die "cannot verify the kill switch"
  say "wrote $DATA/DISABLE"
  ok
fi

payload_digest() {
  plain "$M/SHA256SUMS" || return 1
  expected=$(awk -v name="yafc-payload/${1##*/}" '
    NF == 2 && $2 == name { count++; print $1 }
    END { if (count != 1) exit 1 }
  ' "$M/SHA256SUMS") && [ "$(sha "$1")" = "$expected" ] || return 1
  printf '%s\n' "$expected"
}

# --- mount stack ---------------------------------------------------------------
mounts_at() {  # the lines mounted exactly at $1; fails if anything is mounted below it
  table=$(mount 2>> "$LOG") || return 1
  printf '%s\n' "$table" | awk -v root="$1" '
    $2 == "on" && $3 == root { print }
    $2 == "on" && index($3, root "/") == 1 { nested = 1 }
    END { if (nested) exit 1 }
  '
}
mp_lines() { mounts_at "$MP"; }
# Only the base device, last, and read-only image layers belong in this transaction.
validate_stack() {
  printf '%s\n' "$1" | awk -v mp="$MP" -v base="$BASEDEV" -v images="$IMGDIR/" '
    (NF != 5 && NF != 6) || $2 != "on" || $3 != mp || $4 != "type" || $5 != "qnx6" ||
      (NF == 6 && $6 != "(ro)" && $6 != "(rw)") || seen[$1]++ || found { exit 1 }
    $1 == base { found = 1; next }
    $6 == "(rw)" || index($1, images) != 1 ||
      substr($1, length(images) + 1) !~ /^overlay[A-Za-z0-9_.-]*\.img$/ { exit 1 }
    END { if (!found || NR > 33) exit 1 }
  '
}
names() { printf '%s\n' "$1" | awk '{print $1}'; }
without_own_image() { printf '%s\n' "$1" | awk -v img="$IMG" '$1 != img'; }
base_line() { printf '%s\n' "$1" | tail -n 1; }
base_only() {
  actual=$(mp_lines) && validate_stack "$actual" &&
    [ "$(names "$actual")" = "$BASEDEV" ]
}

reduce_mounts() {  # reduce_mounts EXPECTED: pop layers until only the base remains
  expected=$1
  while :; do
    actual=$(mp_lines) && [ "$actual" = "$expected" ] ||
      { MOUNT_ERROR="mount stack changed during reduction"; return 1; }
    top=${actual%% on *}
    [ "$top" != "$BASEDEV" ] || return 0
    umount "$MP" 2>> "$LOG" ||
      { MOUNT_ERROR="cannot unmount busy or inaccessible layer $top"; return 1; }
    expected=$(printf '%s\n' "$expected" | sed '1d')
    say "unmounted $top" || return 1
  done
}

# The mount interface inserts a layer directly above the base. Only replay when
# the current layers are an exact prefix of the wanted list: inserting a popped
# layer under a busy remaining one would reverse precedence.
prefix_names() {
  printf '%s\n' "$1" | awk -v n="$2" '
    NR <= n { print $1 } { last = $1 } END { print last }'
}
replay_mounts() {
  wanted=$1
  actual=$(mp_lines) && validate_stack "$actual" || return 1
  count=$(printf '%s\n' "$actual" | awk 'END {print NR-1}')
  [ "$(names "$actual")" = "$(prefix_names "$wanted" "$count")" ] || return 1
  while [ "$(names "$actual")" != "$(names "$wanted")" ]; do
    next_layer=$(printf '%s\n' "$wanted" | awk -v n="$count" 'NR==n+1 {print $1}')
    [ -n "$next_layer" ] && [ "$next_layer" != "$BASEDEV" ] &&
      mount -b -r -t qnx6 -o before "$next_layer" "$MP" 2>> "$LOG" || return 1
    count=$((count + 1))
    actual=$(mp_lines) && validate_stack "$actual" &&
      [ "$(names "$actual")" = "$(prefix_names "$wanted" "$count")" ] || return 1
    say "remounted $next_layer" || return 1
  done
}
# Exact order or nothing: a busy layer is reported, never forced around.
restore_stack() {
  current=$(mp_lines) && validate_stack "$current" || return 1
  [ "$current" != "$1" ] || return 0
  replay_mounts "$1" && return 0
  current=$(mp_lines) && reduce_mounts "$current" && replay_mounts "$1"
}

base_write() {
  base_only || return 1
  case "$actual" in *"(rw)") return 0 ;; esac
  # The known radio omits mode flags. Only enable writes on an isolated base.
  base_dirty=1
  mount -uw "$MP" 2>> "$LOG"
}
restore_base() {
  base_only || return 1
  case "$(base_line "$MOUNTS0")" in
    *"(rw)") [ "$actual" = "$(base_line "$MOUNTS0")" ] || mount -uw "$MP" 2>> "$LOG" || return 1 ;;
    *) mount -ur "$MP" 2>> "$LOG" || return 1 ;;
  esac
  base_only && [ "$actual" = "$(base_line "$MOUNTS0")" ] || return 1
  base_dirty=0
}

# --- verified writes -------------------------------------------------------------
put_verified() {  # put_verified SOURCE SHA DEST SAME_FILESYSTEM_TEMP MODE
  [ "$(sha "$1")" = "$2" ] && appendable "$3" || return 1
  ( umask 077; set -C; : > "$4" ) || return 1
  if cp "$1" "$4" && chmod "$5" "$4" && sync3 &&
     [ "$(sha "$4")" = "$2" ] && mv -f "$4" "$3"; then
    sync3 && [ "$(sha "$3")" = "$2" ]
  else
    rm -f "$4" 2>> "$LOG" || true
    return 1
  fi
}

seed_config() {
  if exists "$CONFIG"; then plain "$CONFIG"; return; fi
  defaults=$M/camera.conf
  config_sha=$(payload_digest "$defaults") || return 1
  ( umask 022; set -C; : > "$CONFIG_TMP" ) || return 1
  config_tmp_owned=1
  cp "$defaults" "$CONFIG_TMP" && [ "$(sha "$CONFIG_TMP")" = "$config_sha" ] && sync3 || return 1
  # Do not overwrite settings if they appeared since the first check.
  if ln "$CONFIG_TMP" "$CONFIG" 2>> "$LOG"; then
    sync3 && [ "$(sha "$CONFIG")" = "$config_sha" ] && say "initialized $CONFIG"
  else
    plain "$CONFIG"
  fi
}

# --- loader probe ----------------------------------------------------------------
# The USB copy is data: it runs only from RAM after its digest matches.
stage_probe() {
  cp "$PROBE" "$SCRATCH/slotprobe" && [ "$(sha "$SCRATCH/slotprobe")" = "$probe_sha" ] &&
    chmod 700 "$SCRATCH/slotprobe"
}

# The probe runs with the loader's library trace on. The trace must show the slot
# loaded from the slot path and no other copy of the pair; stdout must show the
# four imports bound, each once, to the preserved library and libscreen.
probe_installed() {
  PROBE_ERROR="the probe did not exit cleanly within 15 s"
  DL_DEBUG=libs "$SCRATCH/slotprobe" > "$OUT/probe.out" 2> "$OUT/probe.err" &
  pid=$!
  ( sleep 15; kill -9 "$pid" 2>/dev/null ) </dev/null > /dev/null 2>&1 &
  timer=$!
  result=0
  wait "$pid" || result=$?
  kill "$timer" 2>/dev/null || true
  [ "$result" = 0 ] || return 1
  PROBE_ERROR="the loader trace does not show the slot loaded from $SLOT"
  awk -v slot="$SLOT" -v old="$PRESERVED" '
    index($0, "loaded from") && $NF ~ /\/libRCN_Diagnostics(Lib|Old)\.so$/ {
      if ($NF == slot) lib++
      else if ($NF != old) exit 1
    }
    END { if (!lib) exit 1 }
  ' "$OUT/probe.err" || return 1
  PROBE_ERROR="the four imports do not resolve once each to $PRESERVED and libscreen.so.1"
  awk -v old="$PRESERVED" '
    $1 == "slot" {
      fname = ""
      for (i = 3; i < NF; i++) if (index($i, "fname=") == 1) {
        if (fname != "") exit 1
        fname = substr($i, 7)
      }
      if ($2 == "diagnostics_async_base_logs" || $2 == "forensics_logworthy_async") {
        if (fname != old) exit 1
      } else if ($2 == "screen_create_window" || $2 == "screen_post_window") {
        if (fname !~ /(^|\/)libscreen\.so\.1$/) exit 1
      } else exit 1
      if ($NF != "same=yes" || seen[$2]++) exit 1
      n++
    }
    $0 == "slotprobe done" { done = 1 }
    END { if (n != 4 || !done) exit 1 }
  ' "$OUT/probe.out"
}

FAILMSG=
RC=0
MOUNT_ERROR=
PROBE_ERROR=
SCRIPT_ERROR=
image_mounted=
image_lines=
scratch_owned=0
build_owned=0
config_tmp_owned=0
loop_starting=0
loop_pid=
journal_owned=0
base_dirty=0
MOUNTS0=
SUMS0=

# --- HMI: build the overlay from the unit's own four files ------------------
# The stock copies are read while the mount stack is the base device only: an
# overlay on top may carry modified copies. The applier edits the staging tree,
# never the unit's files. The image is built and read back under $IMGDIR, outside
# the boot overlay*.img glob, and published only by the final rename.
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

mount_image() {  # mount_image SOURCE MOUNT-ARGUMENTS...
  image_lines=$(mounts_at "$SCRATCH/mnt") && [ -z "$image_lines" ] || return 1
  image_mounted=$1
  shift
  mount "$@" >> "$LOG" 2>&1 || return 1
  image_lines=$(mounts_at "$SCRATCH/mnt") && mount_is_ours
}

mount_is_ours() {
  case "$image_lines" in
    "$image_mounted on $SCRATCH/mnt type qnx6"|"$image_mounted on $SCRATCH/mnt type qnx6 (ro)"|\
    "$image_mounted on $SCRATCH/mnt type qnx6 (rw)") return 0 ;;
  esac
  return 1
}

unmount_image() {
  [ "$scratch_owned" = 1 ] || return 0
  image_lines=$(mounts_at "$SCRATCH/mnt") || return 1
  if [ -n "$image_lines" ]; then
    [ -n "$image_mounted" ] && mount_is_ours &&
      umount "$SCRATCH/mnt" >> "$LOG" 2>&1 || return 1
    image_lines=$(mounts_at "$SCRATCH/mnt") && [ -z "$image_lines" ] || return 1
  fi
  image_mounted=
}

# A different provider is a conflict even when its bytes match, or a symlink
# or non-directory ancestor prevents us from verifying what would resolve.
path_unshadowed() {
  ancestor=$1
  remainder=$2
  while [ "${remainder#*/}" != "$remainder" ]; do
    ancestor=$ancestor/${remainder%%/*}
    remainder=${remainder#*/}
    exists "$ancestor" || return 0
    directory "$ancestor" || return 1
  done
  ! exists "$ancestor/$remainder"
}

# layer_inventory inspect|hashes: sets inventory to "sha path" per other boot
# overlay. inspect also mounts each one read-only and refuses any that provides
# or obscures one of the four QML targets, the slot or the preserved copy.
layer_inventory() {
  inventory=
  for other in "$IMGDIR"/overlay*.img; do
    exists "$other" && [ "$other" != "$IMG" ] || continue
    case "${other##*/}" in *[!a-zA-Z0-9_.-]*) return 1 ;; esac
    other_sha=$(sha "$other") || return 1
    if [ "$1" = inspect ]; then
      # Every boot candidate, including ones not mounted now.
      mount_image "$other" -b -r -t qnx6 "$other" "$SCRATCH/mnt" || return 1
      for rel in $HMI_FILES "${SLOT#"$MP/"}" "${PRESERVED#"$MP/"}"; do
        if ! path_unshadowed "$SCRATCH/mnt" "$rel"; then
          say "overlay conflict: ${other##*/} provides or obscures $rel"
          SHADOWED=${other##*/}
          return 1
        fi
      done
      unmount_image && [ "$(sha "$other")" = "$other_sha" ] || return 1
    fi
    inventory=${inventory:+$inventory
}"$other_sha $other"
  done
}

stop_loopback() {
  [ "$loop_starting" = 0 ] || return 1
  [ -n "$loop_pid" ] || return 0
  kill "$loop_pid" 2>/dev/null || true
  tries=0
  while exists "$DEV" && [ "$tries" -lt 10 ]; do sleep 1; tries=$((tries + 1)); done
  ! exists "$DEV" || return 1
  loop_pid=
}

# Copy the patched files into their same relative paths and build a qnx6 image.
# hmi_build STAGE OUT: 0 built and read back (digest in build_sha), 1 failed.
hmi_build() {
  stage=$1
  out=$2
  ! exists "$DEV" || { say "HMI: loopback device already exists"; return 1; }
  ( umask 022; set -C; : > "$out" ) 2>> "$LOG" || { say "HMI: cannot create $out"; return 1; }
  build_owned=1
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
  mount_image "$DEV" -t qnx6 "$DEV" "$SCRATCH/mnt" ||
    { say "HMI: mount rw failed"; return 1; }
  for rel in $HMI_FILES; do
    mkdir -p "$SCRATCH/mnt/$(dirname "$rel")" 2>> "$LOG" || { say "HMI: mkdir in the image failed"; return 1; }
    cp "$stage/$rel" "$SCRATCH/mnt/$rel" 2>> "$LOG" || { say "HMI: copy into the image failed"; return 1; }
  done
  unmount_image || { say "HMI: umount after the copy failed"; return 1; }
  stop_loopback || { say "HMI: the loopback still holds $DEV"; return 1; }
  chkqnx6fs "$out" >> "$LOG" 2>&1 || { say "HMI: chkqnx6fs failed - image not published"; return 1; }
  say "HMI: chkqnx6fs ok"
  build_sha=$(sha "$out") || { say "HMI: cannot hash the built image"; return 1; }
  mount_image "$out" -b -r -t qnx6 "$out" "$SCRATCH/mnt" ||
    { say "HMI: read-back mount from $IMGDIR failed"; return 1; }
  for rel in $HMI_FILES; do
    a=$(sha "$stage/$rel") && b=$(sha "$SCRATCH/mnt/$rel") &&
      [ "$a" = "$b" ] || { say "HMI: read-back differs for $rel"; return 1; }
  done
  unmount_image || { say "HMI: umount after read-back failed"; return 1; }
  [ "$(sha "$out")" = "$build_sha" ] || { say "HMI: image bytes changed during read-back"; return 1; }
  say "HMI: read-back matches (SHA-256) for all four files"
}

do_hmi() {
  RC=9
  for fragment in $FRAGMENTS; do
    plain "$FRAGDIR/$fragment.fragment" && [ -s "$FRAGDIR/$fragment.fragment" ] ||
      { FAILMSG="missing required HMI fragment $fragment"; return 1; }
  done
  set -- $FRAGMENTS
  expected_fragments=$#
  set -- "$FRAGDIR"/*.fragment
  [ "$#" -eq "$expected_fragments" ] ||
    { FAILMSG="unexpected extra HMI fragments"; return 1; }

  RC=10
  mkdir "$SCRATCH/stage" 2>> "$LOG" ||
    { FAILMSG="cannot create the HMI staging tree"; return 1; }
  for rel in $HMI_FILES; do
    src=$MP/$rel
    plain "$src" || { RC=8; FAILMSG="missing or non-regular stock file $src"; return 1; }
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
    say "HMI rehearsed: read-back verified; would publish $IMG; no boot image published"
  fi
}

# --- ownership and the journal -----------------------------------------------------
# An owner record is a constrained tuple of authenticated byte digests, not a
# declaration that an arbitrary pre-existing Old file belongs to us:
#   YAFC1 <stock> <slot> <preserved or -> <image or ->
state_record() {
  plain "$1" && awk -v stock="$FACTORY" '
    function hash(s) { return length(s) == 64 && s ~ /^[0-9a-f]+$/ }
    NR != 1 || NF != 5 || $1 != "YAFC1" || $2 != stock || !hash($3) ||
      $0 != $1 " " $2 " " $3 " " $4 " " $5 { exit 1 }
    $4 == "-" { if ($3 != stock || $5 != "-") exit 1; print; next }
    $4 != stock || $3 == stock || ($5 != "-" && !hash($5)) { exit 1 }
    { print }
    END { if (NR != 1) exit 1 }
  ' "$1"
}

read_pair() {
  directory "$MP/apps" && directory "$MP/apps/usr" && directory "$LIB" &&
    have_slot=$(sha "$SLOT") && have_old=$(fingerprint "$PRESERVED") &&
    have_image=$(fingerprint "$IMG") && have_owner=$(fingerprint "$OWNER")
}

seal() {
  for part in before owner.before mounts layers scripts; do sha "$1/$part" || return 1; done
}

# Persist the exact previous files, mount order, other-layer digests and script
# checksums, then publish the whole set with one rename. Nothing is written to
# the slot, the preserved copy, the image or the owner record before this.
snapshot() {
  prepare=$DATA/.installer-plan.$REQUEST
  ( umask 077; mkdir "$prepare" ) || return 1
  if printf '%s\n' "$before_record" > "$prepare/before" &&
     printf '%s\n' "$before_owner" > "$prepare/owner.before" &&
     printf '%s\n' "$MOUNTS0" > "$prepare/mounts" &&
     printf '%s\n' "$LAYERS" > "$prepare/layers" &&
     printf '%s\n' "$SUMS0" > "$prepare/scripts" &&
     cp "$SLOT" "$prepare/slot" && [ "$(sha "$prepare/slot")" = "$before_slot" ] &&
     { [ "$before_old" = - ] ||
       { cp "$PRESERVED" "$prepare/old" && [ "$(sha "$prepare/old")" = "$before_old" ]; }; } &&
     { [ "$before_image" = - ] ||
       { cp "$IMG" "$prepare/image" && [ "$(sha "$prepare/image")" = "$before_image" ]; }; } &&
     seal "$prepare" > "$prepare/seal" && sync3 && unchanged_pair &&
     verify_layers && base_only && ! exists "$JOURNAL"; then
    mv "$prepare" "$JOURNAL" || return 1
    journal_owned=1
    sync3
  else
    rm -rf "$prepare" 2>> "$LOG" || true
    return 1
  fi
}

load_journal() {
  directory "$JOURNAL" && plain "$JOURNAL/seal" &&
    journal_seal=$(seal "$JOURNAL") && [ "$journal_seal" = "$(cat "$JOURNAL/seal")" ] &&
    before_record=$(state_record "$JOURNAL/before") || return 1
  set -- $before_record
  before_slot=$3 before_old=$4 before_image=$5
  before_owner=$(cat "$JOURNAL/owner.before") &&
    { [ "$before_owner" = - ] || [ "$before_owner" = "$(sha "$JOURNAL/before")" ]; } &&
    [ "$(sha "$JOURNAL/slot")" = "$before_slot" ] &&
    [ "$(fingerprint "$JOURNAL/old")" = "$before_old" ] &&
    [ "$(fingerprint "$JOURNAL/image")" = "$before_image" ] || return 1
  # An absent owner record is only valid for the clean, recorded stock slot.
  [ "$before_owner" != - ] || [ "$before_slot $before_old $before_image" = "$FACTORY - -" ] || return 1
  MOUNTS0=$(cat "$JOURNAL/mounts") && validate_stack "$MOUNTS0" &&
    LAYERS=$(cat "$JOURNAL/layers") && SUMS0=$(cat "$JOURNAL/scripts") && [ -n "$SUMS0" ] || return 1
  next_slot=$before_slot next_old=$before_old next_image=$before_image next_owner=$before_owner
  if exists "$JOURNAL/after"; then
    after_record=$(state_record "$JOURNAL/after") || return 1
    set -- $after_record
    next_slot=$3 next_old=$4 next_image=$5 next_owner=$(sha "$JOURNAL/after") || return 1
  fi
}

prepare_change() {  # prepare_change SLOT OLD IMAGE: record the intended state first
  ( umask 077; set -C; printf 'YAFC1 %s %s %s %s\n' "$FACTORY" "$1" "$2" "$3" > "$JOURNAL/after.new" ) &&
    state_record "$JOURNAL/after.new" >/dev/null && sync3 &&
    mv "$JOURNAL/after.new" "$JOURNAL/after" && sync3 && load_journal
}

unchanged_pair() {
  read_pair &&
    [ "$have_slot $have_old $have_image $have_owner" = "$before_slot $before_old $before_image $before_owner" ]
}

verify_layers() {
  layer_inventory hashes && [ "$inventory" = "$LAYERS" ]
}

either() { [ "$1" = "$2" ] || [ "$1" = "$3" ]; }
known_pair() {
  read_pair &&
    either "$have_slot" "$before_slot" "$next_slot" &&
    either "$have_old" "$before_old" "$next_old" &&
    either "$have_image" "$before_image" "$next_image" &&
    either "$have_owner" "$before_owner" "$next_owner"
}

change_file() {  # change_file DEST BEFORE PLANNED DESIRED SOURCE TEMP MODE
  previous=$(fingerprint "$1") && either "$previous" "$2" "$3" || return 1
  [ "$previous" != "$4" ] || return 0
  if [ "$4" = - ]; then
    rm "$1" && sync3 && ! exists "$1"
  else
    put_verified "$5" "$4" "$1" "$6" "$7"
  fi
}

# Put back the journaled previous state. Every file must be either its recorded
# previous or planned bytes; anything else is unknown and is left alone.
rollback() {
  load_journal && verify_layers && known_pair || return 1
  recovery_stack=$(mp_lines) && validate_stack "$recovery_stack" || return 1
  if [ "$recovery_stack" = "$MOUNTS0" ] && unchanged_pair && [ "$base_dirty" = 0 ]; then
    check_scripts "$SUMS0"
    return
  fi
  reduce_mounts "$recovery_stack" && known_pair || return 1
  if [ "$have_slot $have_old" != "$before_slot $before_old" ]; then
    # The slot never points at YAFC without the stock copy beside it.
    base_write || return 1
    if [ "$before_old" != - ]; then
      change_file "$PRESERVED" "$before_old" "$next_old" "$before_old" "$JOURNAL/old" "$TMP" 755 || return 1
    fi
    change_file "$SLOT" "$before_slot" "$next_slot" "$before_slot" "$JOURNAL/slot" "$TMP" 755 || return 1
    if [ "$before_old" = - ]; then
      change_file "$PRESERVED" "$before_old" "$next_old" - "" "$TMP" 755 || return 1
    fi
  fi
  change_file "$IMG" "$before_image" "$next_image" "$before_image" "$JOURNAL/image" "$RESTORE_IMG" 644 &&
    change_file "$OWNER" "$before_owner" "$next_owner" "$before_owner" "$JOURNAL/before" "$OWNER_TMP" 600 &&
    restore_base && verify_layers && replay_mounts "$MOUNTS0" &&
    unchanged_pair && [ "$(mp_lines)" = "$MOUNTS0" ] && check_scripts "$SUMS0"
}

settle_journal() {
  # A single same-filesystem rename is the commit point. Do not erase the only
  # rollback evidence until that rename has been synced.
  settled=$DATA/.installer-settled.$REQUEST
  ! exists "$settled" && mv "$JOURNAL" "$settled" || return 1
  journal_owned=0
  if ! sync3; then
    FAILMSG="transaction rename completed but commit durability is unknown; inspect $settled"
    return 1
  fi
  for part in before owner.before mounts layers scripts seal slot old image after after.new; do
    if exists "$settled/$part"; then
      plain "$settled/$part" && rm "$settled/$part" ||
        { say "warning: settled journal retained at $settled"; return 0; }
    fi
  done
  rmdir "$settled" 2>> "$LOG" || say "warning: settled journal retained at $settled"
}

abort() { FAILMSG=$1; RC=${2:-4}; exit "$RC"; }
cleanup_failed() {
  FAILMSG="${FAILMSG:+$FAILMSG; }$1"
  [ "$RC" -ne 0 ] || RC=$2
}

finish() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  [ "$status" -eq 0 ] || [ -n "$FAILMSG" ] || cleanup_failed "installer stopped unexpectedly (exit $status)" 4
  failed_phase=$PHASE
  PHASE=cleanup
  if [ "$journal_owned" = 1 ]; then
    if [ "$MODE" != recover ] && rollback; then
      if settle_journal; then
        cleanup_failed "rolled back after stage $failed_phase: the previous library bytes are back in the slot; previous backup, image, ownership and mount order verified" 4
      else
        cleanup_failed "previous state verified but the journal could not be finalized; do not retry" 4
      fi
    else
      # Put the recorded layer order back if that is exact; never force it.
      [ -z "$MOUNTS0" ] || restore_stack "$MOUNTS0" || true
      observed=$(mp_lines) || observed=unreadable
      cleanup_failed "cannot verify restoration after stage $failed_phase; journal retained at $JOURNAL for RUN-YAFC-RECOVER after a restart or manual recovery; expected mounts [$MOUNTS0]; observed mounts [$observed]" 5
    fi
  elif [ -n "$MOUNTS0" ]; then
    if restore_stack "$MOUNTS0"; then
      [ "$RC" -eq 6 ] || [ -z "$SUMS0" ] || check_scripts "$SUMS0" || cleanup_failed "$SCRIPT_ERROR" 6
    else
      observed=$(mp_lines) || observed=unreadable
      cleanup_failed "cannot restore the exact $MP mount order without forcing; no slot, backup or image write was made; a restart remounts the boot images; expected [$MOUNTS0]; observed [$observed]" 5
    fi
  fi
  if unmount_image && stop_loopback; then
    if [ "$scratch_owned" = 1 ]; then
      scratch_mounts=$(mounts_at "$SCRATCH") && [ -z "$scratch_mounts" ] &&
        rm -rf "$SCRATCH" 2>> "$LOG" || cleanup_failed "cannot remove owned scratch safely; scratch retained" 10
    fi
    if [ "$build_owned" = 1 ] && exists "$BUILD"; then
      plain "$BUILD" && rm "$BUILD" || cleanup_failed "cannot remove owned inert image backing $BUILD" 10
    fi
  else
    cleanup_failed "cannot release the HMI mount or loopback; scratch retained and $BUILD kept" 10
  fi
  if [ "$config_tmp_owned" = 1 ]; then
    rm -f "$CONFIG_TMP" 2>> "$LOG" || cleanup_failed "cannot remove owned config temporary file" 4
  fi
  rmdir "$LOCK" 2>> "$LOG" || cleanup_failed "cannot release installer lock" 4
  PHASE=$failed_phase
  [ -z "$FAILMSG" ] || die "$FAILMSG" "$RC"
  ok
}

# --- preflight ---------------------------------------------------------------------
PHASE=preflight
if [ "$MODE" = install ]; then
  new_sha=$(payload_digest "$NEW") && [ "$new_sha" != "$FACTORY" ] ||
    die "missing or invalid slot payload" 3
  probe_sha=$(payload_digest "$PROBE") || die "missing or invalid loader probe" 3
fi
mkdir -p "$DATA" && directory "$DATA" && directory "$IMGDIR" || die "invalid storage directory" 3
( umask 077; mkdir "$LOCK" ) 2>> "$LOG" ||
  die "installer lock exists or is inaccessible; a restart clears a stale lock" 3
trap finish EXIT
trap 'abort "installer interrupted at $PHASE" 5' HUP INT TERM

# --- recover: journaled previous state, authenticated, or nothing -----------------
if [ "$MODE" = recover ]; then
  PHASE=recovery
  exists "$JOURNAL" || abort "no pending installer transaction to recover" 3
  journal_owned=1
  rollback || abort "recovery refused: unauthenticated journal, unknown file state, busy layer or write/read-back failure" 5
  say "previous slot, backup, image, ownership and mount order verified"
  settle_journal || abort "${FAILMSG:-cannot finalize recovery}"
  exit 0
fi

! exists "$JOURNAL" ||
  abort "pending transaction from an interrupted request; preserve the logs and use RUN-YAFC-RECOVER" 3
stack0=$(mp_lines) && validate_stack "$stack0" || abort "unexpected mount stack" 3
MOUNTS0=$stack0
read_pair || abort "active slot, stock backup, image or ownership record is not a plain readable file" 3
before_slot=$have_slot before_old=$have_old before_image=$have_image before_owner=$have_owner
before_record="YAFC1 $FACTORY $before_slot $before_old $before_image"
if [ "$before_owner" = - ]; then
  [ "$before_slot $before_old $before_image" = "$FACTORY - -" ] ||
    abort "unknown stock slot, or unowned preserved library or HMI image; nothing changed" 3
else
  owner_record=$(state_record "$OWNER") && [ "$owner_record" = "$before_record" ] ||
    abort "ownership record does not match the active slot, stock backup and HMI image; nothing changed" 3
fi
if { [ "$MODE" = remove ] && [ "$before_old" = - ]; } ||
   { [ "$MODE" = remove-hmi ] && [ "$before_image" = - ]; }; then
  say "nothing owned to remove; verified current state"
  exit 0
fi
SUMS0=$(sums) || abort "cannot read recovery script checksums on the original stack" 3
( umask 077; mkdir "$SCRATCH" ) || abort "scratch exists or is inaccessible; left unchanged" 10
scratch_owned=1
mkdir "$SCRATCH/mnt" || abort "cannot create image inspection mountpoint" 10

PHASE=overlay-check
SHADOWED=
if ! layer_inventory inspect; then
  [ -z "$SHADOWED" ] || abort "boot overlay $SHADOWED shadows a YAFC target path; nothing changed" 3
  abort "cannot prove boot overlays do not shadow YAFC target paths; nothing changed" 3
fi
LAYERS=$inventory
for mounted in $(names "$MOUNTS0"); do
  [ "$mounted" != "$BASEDEV" ] || continue
  if [ "$mounted" = "$IMG" ]; then
    [ "$before_image" != - ] || abort "mounted YAFC backing image missing" 3
  else
    printf '%s\n' "$LAYERS" | awk -v path="$mounted" '$2 == path { seen=1 } END { exit !seen }' ||
      abort "mounted overlay backing image absent from inspected boot set" 3
  fi
done
if [ "$MODE" = install ]; then
  stage_probe || abort "cannot stage and verify loader probe in RAM" 3
fi

# --- mount reduction and build: still no slot, backup or image write -------------
PHASE=mount-reduction
reduce_mounts "$MOUNTS0" || abort "$MOUNT_ERROR; no files written" 5
unchanged_pair || abort "pair changed when exposing the base; no files written" 3
MOUNTS_FINAL=$MOUNTS0
SUMS_FINAL=$SUMS0
if [ "$MODE" = remove ] || [ "$MODE" = remove-hmi ]; then
  MOUNTS_FINAL=$(without_own_image "$MOUNTS0")
  if [ "$MOUNTS_FINAL" != "$MOUNTS0" ]; then
    # Compare before and after against exactly the same post-removal layering.
    replay_mounts "$MOUNTS_FINAL" && [ "$(mp_lines)" = "$MOUNTS_FINAL" ] && SUMS_FINAL=$(sums) ||
      abort "cannot baseline recovery scripts on the post-removal mount stack; no files written" 5
    reduce_mounts "$MOUNTS_FINAL" || abort "$MOUNT_ERROR; no files written" 5
  fi
fi
if [ "$MODE" = install ] || [ "$MODE" = rehearse ]; then
  PHASE=hmi-build
  do_hmi || exit "$RC"
fi
if [ "$MODE" = install ]; then
  PHASE=config
  seed_config || abort "cannot initialize camera.conf; no slot or image writes"
fi

# --- transaction ---------------------------------------------------------------------
PHASE=journal
snapshot || abort "cannot persist exact previous files and mount order; no slot or image writes"
load_journal || abort "cannot verify the saved previous files"
case "$MODE" in
  install)
    prepare_change "$new_sha" "$FACTORY" "$build_sha" ||
      abort "cannot persist the intended slot and image digests"
    PHASE=slot-write
    base_write || abort "mount -uw failed"
    old_source=$JOURNAL/old
    [ "$before_old" != - ] || old_source=$JOURNAL/slot
    change_file "$PRESERVED" "$before_old" "$next_old" "$next_old" "$old_source" "$TMP" 755 &&
      change_file "$SLOT" "$before_slot" "$next_slot" "$next_slot" "$NEW" "$TMP" 755 ||
      abort "cannot write or verify the new slot and preserved stock library"
    PHASE=loader-probe
    probe_installed || abort "the installed pair failed the loader probe: $PROBE_ERROR"
    say "the installed pair passed the loader probe"
    PHASE=base-readonly
    restore_base || abort "cannot restore original base access (mount -ur failed)"
    PHASE=image-publish
    [ "$(fingerprint "$IMG")" = "$before_image" ] && [ "$(sha "$BUILD")" = "$next_image" ] &&
      sync3 && mv -f "$BUILD" "$IMG" && sync3 && [ "$(sha "$IMG")" = "$next_image" ] ||
      abort "cannot publish or read back the HMI image" 12
    say "HMI: published $IMG"
    ;;
  rehearse)
    PHASE=slot-rehearse
    base_write && put_verified "$JOURNAL/slot" "$before_slot" "$SLOT" "$TMP" 755 ||
      abort "rehearsal slot write failed"
    say "rehearsal: wrote the exact current slot bytes"
    PHASE=base-readonly
    restore_base || abort "cannot restore original base access (mount -ur failed)"
    ;;
  remove)
    prepare_change "$FACTORY" - - || abort "cannot persist the intended stock state"
    PHASE=slot-remove
    base_write && change_file "$SLOT" "$before_slot" "$next_slot" "$next_slot" "$JOURNAL/old" "$TMP" 755 &&
      change_file "$PRESERVED" "$before_old" "$next_old" - "" "$TMP" 755 ||
      abort "cannot restore the authenticated stock slot or remove the owned backup"
    say "removed YAFC: the unit's own library is back in the slot"
    PHASE=base-readonly
    restore_base || abort "cannot restore original base access (mount -ur failed)"
    PHASE=image-remove
    change_file "$IMG" "$before_image" "$next_image" - "" "$RESTORE_IMG" 644 ||
      abort "cannot delete the owned HMI image" 12
    ;;
  remove-hmi)
    prepare_change "$before_slot" "$before_old" - || abort "cannot persist the intended HMI-only removal"
    PHASE=image-remove
    change_file "$IMG" "$before_image" "$next_image" - "" "$RESTORE_IMG" 644 ||
      abort "cannot delete the owned HMI image" 12
    ;;
esac
[ "$before_image" = "$next_image" ] || [ "$next_image" != - ] || say "removed $IMG"
PHASE=mount-replay
verify_layers && replay_mounts "$MOUNTS_FINAL" && [ "$(mp_lines)" = "$MOUNTS_FINAL" ] ||
  abort "cannot restore the exact intended mount order" 5
PHASE=recovery-script-check
# Same layer list as the baseline. The only possibly changed layer is the YAFC
# image, built and read back with the four QML files and nothing else.
check_scripts "$SUMS_FINAL" || abort "$SCRIPT_ERROR" 6
PHASE=commit
if [ "$MODE" != rehearse ]; then
  change_file "$OWNER" "$before_owner" "$next_owner" "$next_owner" "$JOURNAL/after" "$OWNER_TMP" 600 ||
    abort "cannot publish verified ownership"
fi
read_pair && [ "$have_slot $have_old $have_image $have_owner" = "$next_slot $next_old $next_image $next_owner" ] ||
  abort "commit read-back does not match the planned state"
settle_journal || abort "${FAILMSG:-cannot finalize installer transaction}"
say "committed and verified"
# The finish checks now compare against the committed layering.
MOUNTS0=$MOUNTS_FINAL
SUMS0=$SUMS_FINAL
