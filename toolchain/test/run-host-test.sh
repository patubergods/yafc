#!/bin/sh
# Host test of the hook in both builds: the LD_PRELOAD library and the slot
# library (-DYAFC_SLOT, whose constructor patches the camera process's own Screen
# call slots). Neither build needs the radio.
#
# Set SS_RVC_STOCK to a copy of the camera binary to also check the recorded text
# hash against a real file. Without it the hash checks are skipped and said so.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${1:-${TMPDIR:-/tmp}/yafc-host-test}"
mkdir -p "$out" || { echo "cannot create $out" >&2; exit 1; }
src="$here/../yafc-slot.c"
[ -f "$src" ] || { echo "missing $src" >&2; exit 1; }
if [ -n "${SS_RVC_STOCK:-}" ] && [ ! -f "${SS_RVC_STOCK:-}" ]; then
  echo "SS_RVC_STOCK is set but not a file; unsetting" >&2
  unset SS_RVC_STOCK
fi
if [ -n "${SS_RVC_STOCK:-}" ]; then export SS_RVC_STOCK; else unset SS_RVC_STOCK; fi

for mode in preload slot; do
  flags=""
  [ "$mode" = slot ] && flags="-DYAFC_SLOT"
  # LIB_SRC names the source under test.
  cc -O1 -Wall -Wextra -pthread $flags "-DLIB_SRC=\"$src\"" \
     -o "$out/test-yafc-host-$mode" "$here/test-yafc-host.c"
  "$out/test-yafc-host-$mode"
done
