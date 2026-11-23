#!/bin/sh
# yafc-dispatch.sh: start a YAFC request from a marker file on the stick.
#
# Install it as <USB>/SyncMyMod/autoinstall.sh, which the jailbreak's USB hook
# runs on every insertion. With no marker it does nothing at all, so the stick
# cannot change the unit by accident.
#
#   RUN-YAFC-INSTALL    put YAFC's library in the camera's slot
#   RUN-YAFC-REHEARSE   the same path with the unit's own bytes (no picture change)
#   RUN-YAFC-REMOVE     put the unit's own library back and forget YAFC
#   RUN-YAFC-DISABLE    write the kill switch only; touches nothing under /fs/mp
#
# A marker may sit at the stick root or in SyncMyMod/. Arm ONE at a time: more
# than one present is refused. The marker is renamed to <marker>.running before
# anything runs, so a reset cannot repeat the request, and the worker removes it
# only on success; on failure the .running marker and the receipts stay for you.
set -eu

case "$0" in
  */SyncMyMod/autoinstall.sh) USB=${0%/SyncMyMod/autoinstall.sh} ;;
  *) echo "install me as <USB>/SyncMyMod/autoinstall.sh" >&2; exit 1 ;;
esac
PATH=${PATH:+$PATH:}/proc/boot:/bin:/usr/bin:/fs/mp/bin:/fs/mp/usr/bin:/fs/rwdata/dev
export PATH
WORK=$USB/yafc-install.sh
[ -f "$WORK" ] || { echo "missing $WORK" >&2; exit 1; }

found=0
mode=
marker=
for spec in "RUN-YAFC-INSTALL:install" "RUN-YAFC-REHEARSE:rehearse" \
            "RUN-YAFC-REMOVE:remove" "RUN-YAFC-DISABLE:disable"; do
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
  mkdir -p "$USB/yafc-install" 2>/dev/null || true
  echo "refused: more than one RUN-YAFC-* marker present $(date -u 2>/dev/null)" \
    >> "$USB/yafc-install/seen.log" 2>/dev/null || true
  exit 1
fi

if [ "$found" = 0 ]; then
  mkdir -p "$USB/yafc-install" 2>/dev/null || true
  echo "stick seen $(date -u 2>/dev/null); no marker, nothing done" \
    >> "$USB/yafc-install/seen.log" 2>/dev/null || true
  exit 0
fi

mv "$marker" "$marker.running" && sync || exit 1
exec sh "$WORK" "$USB" "$mode" "$marker.running"
