#!/bin/sh
# PC-only emulation of the R1 probe: runs toolchain/probe/run-probe.sh itself under qemu-arm with
# glibc's ld.so as ldqnx.so.2 and fake libc/libscreen/slot libraries. Proves only that the probe
# code and script behave as designed against glibc's loader; says nothing about the QNX loader.
# Run in WSL Ubuntu after build-probe.sh:   sh toolchain/probe/test-emulated.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$HOME/sync3-build/probe}"
w="$out/emu"
root="$w/root"
rm -rf "$w"; mkdir -p "$root/usr/lib" "$root/lib" "$w/std" "$w/p"
G=/usr/arm-linux-gnueabi/lib
cp $G/ld-linux.so.3 "$root/usr/lib/ldqnx.so.2"
cp $G/ld-linux.so.3 $G/libc.so.6 "$root/lib/"
T=armv7a-unknown-linux-gnueabi
CF="--target=$T -march=armv7-a -marm -mfloat-abi=soft -Os -ffreestanding -nostdinc -fno-builtin -fno-stack-protector -fPIC"
clang $CF -Wall -Wextra -c "$here/emu-libc.c" -o "$w/emu-libc.o"
ld.lld -shared -soname libc.so.3 --hash-style=sysv -z now -o "$w/std/libc.so.3" \
  "$w/emu-libc.o" "$(arm-linux-gnueabi-gcc -print-libgcc-file-name)" $G/libc.so.6
# fake libscreen and fake stock slot (no SONAME, as stock; the file name identifies it)
echo 'int screen_create_window(void){return 0x5c;} int screen_post_window(void){return 0x5d;}' > "$w/scr.c"
echo 'int diagnostics_async_base_logs(void){return 1;} int forensics_logworthy_async(void){return 2;}' > "$w/stock.c"
clang $CF -c "$w/scr.c" -o "$w/scr.o"; clang $CF -c "$w/stock.c" -o "$w/stock.o"
ld.lld -shared -soname libscreen.so.1 --hash-style=sysv -o "$w/std/libscreen.so.1" "$w/scr.o"
ld.lld -shared --hash-style=sysv -o "$w/std/libRCN_DiagnosticsLib.so" "$w/stock.o"
B="$here/bin"
cp "$B/slotprobe" "$B/libslotgot.so" "$B/libslotgot_ro.so" "$B/libslotexp.so" "$w/p/"
rc=0
SLOT_DIR="$w/p" PROBE_ALLOW_ANY=1 STD_LIBS="$w/std" STOCK_SLOT="$w/std/libRCN_DiagnosticsLib.so" \
  RUNNER="qemu-arm -L $root" LIMIT=30 sh "$here/run-probe.sh" > "$w/summary.txt" || rc=$?
cat "$w/summary.txt"
echo "run-probe rc=$rc"
[ $rc = 0 ]
# T1: expected PASS contract of the emulated loader: libslotexp owns screen_*
grep -q '^T0: .*PASS' "$w/summary.txt"
grep -q '^T2: .*PASS' "$w/summary.txt"
grep -q '^T3a: .*PASS' "$w/summary.txt"
grep -q '^T3: .*PASS' "$w/summary.txt"
grep -q '^T1: rc=0; screen_\* slots owned by: .*libRCN_DiagnosticsLib.so' "$w/summary.txt"
# the stock-path control must show libscreen as owner and exact NEEDED order
grep -q '^needed libRCN_DiagnosticsLib.so$' "$w/p/t0.out"
[ "$(grep '^needed' "$w/p/t0.out" | tr '\n' ' ')" = "needed libRCN_DiagnosticsLib.so needed libscreen.so.1 needed libc.so.3 " ]
grep '^slot screen_post_window' "$w/p/t0.out" | grep -q 'fname=.*libscreen.so.1'
# clean option
SLOT_DIR="$w/p" PROBE_ALLOW_ANY=1 sh "$here/run-probe.sh" clean
[ ! -e "$w/p" ]
# refuses a directory outside /fs/tmpfs without the override
if SLOT_DIR="$w/p" sh "$here/run-probe.sh" >/dev/null 2>&1; then echo "FAIL: no refusal"; exit 1; fi
echo "EMULATED PROBE PASS"
