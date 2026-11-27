#!/bin/sh
# yafc-dispatch.sh: start a YAFC request from a marker file on the stick.
#
# Install it as <USB>/SyncMyMod/autoinstall.sh, which the jailbreak's USB hook
# runs on every insertion. With no marker it does nothing at all, so the stick
# cannot change the unit by accident.
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
[ -f "$WORK" ] || { echo "missing $WORK" >&2; exit 1; }
REPORT=$USB/yafc-install

seen() {
  mkdir -p "$REPORT" 2>/dev/null || true
  echo "$* $(date -u 2>/dev/null)" >> "$REPORT/seen.log" 2>/dev/null || true
}

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
      [ -f "$f" ] && [ ! -L "$f" ] || { echo "$name must be a plain file" >&2; exit 1; }
      found=$((found + 1))
      mode=$want
      marker=$f
    fi
  done
done

if [ "$found" -gt 1 ]; then
  echo "refused: more than one RUN-YAFC-* marker is present; arm ONE" >&2
  seen "refused: more than one RUN-YAFC-* marker present"
  exit 1
fi

if [ "$found" = 0 ]; then
  seen "stick seen; no marker, nothing done"
  exit 0
fi

if [ -e "$marker.running" ] || [ -L "$marker.running" ]; then
  echo "refused: $marker.running records an earlier request" >&2
  seen "refused: ${marker##*/}.running records an earlier request; preserve it and its receipts"
  exit 1
fi

stamp=$(date -u +%Y%m%dT%H%M%S 2>/dev/null) || stamp=
case "$stamp" in *[!0-9T]*) stamp= ;; esac
request=$stamp-$$
mkdir -p "$REPORT" && mkdir "$REPORT/request-$request" || exit 1
mv "$marker" "$marker.running" && sync || exit 1
printf '%s\n' "$request" > "$marker.running" && sync || exit 1
exec sh "$WORK" "$USB" "$mode" "$marker.running"
