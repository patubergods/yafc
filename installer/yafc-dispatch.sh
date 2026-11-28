#!/bin/sh
# yafc-dispatch.sh: start a YAFC request from a marker file on the stick.
#
# Install it as <USB>/SyncMyMod/autoinstall.sh, which the jailbreak's USB hook
# runs on every insertion. With no marker it does nothing to the unit, so the
# stick cannot change it by accident; it only shows a notice and logs to
# yafc-install/seen.log.
#
#   RUN-YAFC-INSTALL    put YAFC's library in the camera's slot and publish the HMI image
#   RUN-YAFC-REHEARSE   the same path with the unit's own bytes (no picture change)
#   RUN-YAFC-REMOVE     put the unit's own library back and delete the owned HMI image
#   RUN-YAFC-REMOVE-HMI delete the owned HMI image only; the library is untouched
#   RUN-YAFC-RECOVER    restore an interrupted request's journaled previous state
#   RUN-YAFC-DISABLE    write the kill switch only; touches nothing under /fs/mp
#
# A marker may sit at the stick root or in SyncMyMod/. Arm ONE at a time: more
# than one present is refused. Each request gets an ID and its own receipt
# directory, yafc-install/request-<ID>/. The marker is renamed to <marker>.running
# and the ID written into it before anything runs, so a reset cannot repeat the
# request; the worker removes it only on success. A marker whose .running copy
# still exists is refused, so the evidence of an earlier request is never lost.
set -eu

case "$0" in
  */SyncMyMod/autoinstall.sh) USB=${0%/SyncMyMod/autoinstall.sh} ;;
  *) echo "install me as <USB>/SyncMyMod/autoinstall.sh" >&2; exit 1 ;;
esac
# Resolve to absolute: the installer's own path comparisons and the test harness
# match on full paths. The unit itself always calls us with an absolute $0, but
# a rehearsed or automated run may pass a relative one.
case "$USB" in
  /*) ;;
  *) USB=$(cd "$USB" && pwd) || { echo "cannot resolve USB root path" >&2; exit 1; } ;;
esac
PATH=${PATH:+$PATH:}/proc/boot:/bin:/usr/bin:/fs/mp/bin:/fs/mp/usr/bin:/fs/rwdata/dev
export PATH
WORK=$USB/yafc-install.sh
REPORT=$USB/yafc-install

seen() {
  mkdir -p "$REPORT" 2>/dev/null || true
  echo "$* $(date -u 2>/dev/null)" >> "$REPORT/seen.log" 2>/dev/null || true
}

# On-screen notice through utserviceutility popup, the same call the worker
# uses. Best effort and bounded: a missing or stuck utility must never change
# what the dispatcher does, so its status is ignored and it is killed after 5 s.
POPUP_TEXT=${YAFC_POPUP_TEXT:-/fs/tmpfs/yafc-popup.txt}
popup() {  # popup MESSAGE
  printf '%s\n' "$1" > "$POPUP_TEXT" 2>/dev/null || return 0
  utserviceutility popup "$POPUP_TEXT" </dev/null >/dev/null 2>&1 &
  POPUP_PID=$!
  POPUP_I=0
  while [ "$POPUP_I" -lt 5 ] && kill -0 "$POPUP_PID" 2>/dev/null; do
    sleep 1; POPUP_I=$((POPUP_I + 1))
  done
  kill "$POPUP_PID" 2>/dev/null || true
  wait "$POPUP_PID" 2>/dev/null || true
  return 0
}

if [ ! -f "$WORK" ]; then
  echo "missing $WORK" >&2
  seen "refused: missing yafc-install.sh at the stick root"
  popup "YAFC refused: yafc-install.sh is missing from this stick. Nothing was changed. Copy the whole zip to the stick again."
  exit 1
fi

found=0
mode=
marker=
for spec in "RUN-YAFC-INSTALL:install" "RUN-YAFC-REHEARSE:rehearse" \
            "RUN-YAFC-REMOVE:remove" "RUN-YAFC-REMOVE-HMI:remove-hmi" \
            "RUN-YAFC-RECOVER:recover" "RUN-YAFC-DISABLE:disable"; do
  name=${spec%%:*}
  want=${spec#*:}
  for dir in "$USB" "$USB/SyncMyMod"; do
    f=$dir/$name
    if [ -e "$f" ] || [ -L "$f" ]; then
      [ -f "$f" ] && [ ! -L "$f" ] || {
        echo "$name must be a plain file" >&2
        seen "refused: $name must be a plain file"
        popup "YAFC refused: a marker on this stick is not a plain file. Nothing was changed. Details: yafc-install/seen.log on the USB stick."
        exit 1
      }
      found=$((found + 1))
      mode=$want
      marker=$f
    fi
  done
done

if [ "$found" -gt 1 ]; then
  echo "refused: more than one RUN-YAFC-* marker is present; arm ONE" >&2
  seen "refused: more than one RUN-YAFC-* marker present"
  popup "YAFC refused: more than one marker is on this stick. Nothing was changed. Details: yafc-install/seen.log on the USB stick."
  exit 1
fi

if [ "$found" = 0 ]; then
  seen "stick seen; no marker, nothing done"
  popup "YAFC: no install or uninstall marker is armed on this USB stick, so nothing was changed. Details: yafc-install/seen.log on the USB stick."
  exit 0
fi

if [ -e "$marker.running" ] || [ -L "$marker.running" ]; then
  echo "refused: $marker.running records an earlier request" >&2
  seen "refused: ${marker##*/}.running records an earlier request; preserve it and its receipts"
  popup "YAFC refused: an earlier request on this stick did not finish. Nothing was changed. Details: yafc-install/seen.log on the USB stick."
  exit 1
fi

stamp=$(date -u +%Y%m%dT%H%M%S 2>/dev/null) || stamp=
case "$stamp" in *[!0-9T]*) stamp= ;; esac
request=$stamp-$$
mkdir -p "$REPORT" && mkdir "$REPORT/request-$request" || exit 1
mv "$marker" "$marker.running" && sync || exit 1
printf '%s\n' "$request" > "$marker.running" && sync || exit 1
exec sh "$WORK" "$USB" "$mode" "$marker.running"
