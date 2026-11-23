#!/bin/sh
# Radio-side loader probe (see ../../docs/TESTING.md). Ask the owner before running it:
# it is a native binary. Pulls nothing; the three files are staged beforehand into
#   /fs/tmpfs/slotprobe/{slotprobe,libslotgot.so,libslotgot_ro.so,libslotexp.so}
# (check them against probe/SHA256SUMS). Read-only except /fs/tmpfs/slotprobe:
# the only writes are t1..t3a dirs, t*.out/t*.err/t*.rc there. Does not stop the camera,
# touch /fs/mp, mount anything, or create a Screen context.
#
#   sh run-probe.sh          run T0-T3 and print a summary
#   sh run-probe.sh clean    rm -rf the probe directory
#
# T0  control: slotprobe with the stock library path (stock slot, no copy of ours)
# T1  chain + exports: libslotexp as slot, stock bytes as Old; who owns the screen_* JUMP_SLOTs?
# T2  chain without Old: expect the exec to fail in the loader
# T3a chain, libslotgot_ro (read-only build): constructor reports relocated=yes/no, writes nothing
# T3  chain, libslotgot: patches the two screen slots in slotprobe's own GOT
# Each run: DL_DEBUG=all, 20 s watchdog (kill -9).
# Test overrides (PC emulation only): SLOT_DIR STD_LIBS STOCK_SLOT RUNNER PROBE_ALLOW_ANY=1.
D=${SLOT_DIR:-/fs/tmpfs/slotprobe}
STD=${STD_LIBS:-/proc/boot:/lib:/lib/dll:/usr/lib:/apps/lib:/fs/mp/lib:/fs/mp/usr/lib:/fs/mp/apps/usr/lib}
STOCK=${STOCK_SLOT:-/fs/mp/apps/usr/lib/libRCN_DiagnosticsLib.so}
RUNNER=${RUNNER:-}
LIMIT=${LIMIT:-20}

case $D in
  /fs/tmpfs/?*) ;;
  *) [ "${PROBE_ALLOW_ANY:-}" = 1 ] || { echo "refuse: SLOT_DIR must be under /fs/tmpfs"; exit 2; } ;;
esac
if [ "${1:-}" = clean ]; then rm -rf "$D"; echo "removed $D"; exit 0; fi
for f in slotprobe libslotgot.so libslotgot_ro.so libslotexp.so; do
  [ -f "$D/$f" ] || { echo "missing $D/$f"; exit 2; }
done
[ -f "$STOCK" ] || { echo "missing stock slot $STOCK"; exit 2; }
echo "stock slot: $(cksum < "$STOCK") $STOCK"
chmod +x "$D/slotprobe" 2>/dev/null

# stage slot dirs (copies inside $D only)
for t in t1 t2 t3 t3a; do rm -rf "$D/$t"; mkdir -p "$D/$t" || exit 2; done
cp "$D/libslotexp.so" "$D/t1/libRCN_DiagnosticsLib.so" && cp "$STOCK" "$D/t1/libRCN_DiagnosticsOld.so" || exit 2
cp "$D/libslotgot.so" "$D/t2/libRCN_DiagnosticsLib.so" || exit 2
cp "$D/libslotgot.so" "$D/t3/libRCN_DiagnosticsLib.so" && cp "$STOCK" "$D/t3/libRCN_DiagnosticsOld.so" || exit 2
cp "$D/libslotgot_ro.so" "$D/t3a/libRCN_DiagnosticsLib.so" && cp "$STOCK" "$D/t3a/libRCN_DiagnosticsOld.so" || exit 2

run() {  # run NAME LIBPATH
  n=$1; lp=$2
  rm -f "$D/$n.out" "$D/$n.err" "$D/$n.rc"
  env LD_LIBRARY_PATH="$lp" DL_DEBUG=all $RUNNER "$D/slotprobe" > "$D/$n.out" 2> "$D/$n.err" &
  pid=$!
  ( sleep "$LIMIT"; kill -9 $pid 2>/dev/null ) &
  wd=$!
  wait $pid
  echo $? > "$D/$n.rc"
  kill $wd 2>/dev/null
}
run t0 "$STD"
run t1 "$D/t1:$STD"
run t2 "$D/t2:$STD"
run t3a "$D/t3a:$STD"
run t3 "$D/t3:$STD"

rc() { cat "$D/$1.rc" 2>/dev/null || echo '?'; }
slots() { grep '^slot ' "$D/$1.out" 2>/dev/null; }
verdict() {  # verdict NAME yes|no|? text
  echo "$1: $3 -> $2"
}
echo
echo "== summary ($D)"
for t in t0 t1 t2 t3a t3; do
  echo "-- $t rc=$(rc $t)"
  grep -E '^(needed|slot |libslotgot:|exe |dlopen)' "$D/$t.out" 2>/dev/null
  [ -s "$D/$t.err" ] && echo "   (stderr $(wc -l < "$D/$t.err") lines, first: $(head -n 1 "$D/$t.err"))"
done
echo
n0=$(slots t0 | wc -l); y0=$(slots t0 | grep -c 'same=yes')
if [ "$(rc t0)" = 0 ] && [ "$n0" = 4 ] && [ "$y0" = 4 ]; then verdict T0 PASS "control: 4 slots, all equal dlsym"; else verdict T0 FAIL "rc=$(rc t0) slots=$n0 same=$y0"; fi
own=$(slots t1 | grep '^slot screen_' | sed 's/.* fname=\([^ ]*\) .*/\1/' | sort -u | tr '\n' ' ')
echo "T1: rc=$(rc t1); screen_* slots owned by: $own"
echo "T1: (owner libRCN_DiagnosticsLib.so = a slot ahead of libscreen wins binding; libscreen.so.1 = strict scope: STOP rule)"
if [ "$(rc t2)" != 0 ] && ! grep -q '^slotprobe done' "$D/t2.out" 2>/dev/null; then verdict T2 PASS "missing Old: exec failed (rc=$(rc t2))"; else verdict T2 FAIL "missing Old did not fail"; fi
if [ "$(rc t3a)" = 0 ] && grep -q 'libslotgot: ctor ran' "$D/t3a.out" && grep -q 'relocated=yes' "$D/t3a.out" && ! grep -q 'patched' "$D/t3a.out"; then
  verdict T3a PASS "constructor ran, relocated=yes, nothing written"; else verdict T3a FAIL "see t3a.out/t3a.err"; fi
sp=$(slots t3 | grep '^slot screen_' | grep -c 'same=no')
if [ "$(rc t3)" = 0 ] && grep -q 'libslotgot: patched 2 slots' "$D/t3.out" && [ "$sp" = 2 ]; then
  verdict T3 PASS "2 screen slots patched, walk sees them"; else verdict T3 FAIL "rc=$(rc t3) screen slots changed=$sp"; fi
echo "details: $D/t*.out t*.err (DL_DEBUG=all output is in .err). Remove with: sh $0 clean"
