#!/bin/sh
# Cross-build the loader probe (see ../../docs/TESTING.md, "the loader probe"):
#   slotprobe   ET_EXEC at 0x100000, NEEDED libRCN_DiagnosticsLib.so, libscreen.so.1, libc.so.3
#   libslotgot.so  export-free slot prototype (SONAME libRCN_DiagnosticsLib.so), GOT patcher
#   libslotgot_ro.so  same source, -DSLOTGOT_RO: verifies and reports, never writes
#   libslotexp.so  T1 control: same chain but exports screen_create_window/screen_post_window
# Run inside WSL Ubuntu:   sh toolchain/probe/build-probe.sh
# Intermediate files go to $OUT (default ~/sync3-build/probe); results to toolchain/probe/bin/.
# Same compiler/linker flags as toolchain/build.sh and build-slot.sh; stub libraries only carry
# symbol names (the radio's real libraries bind at run time). Not part of the car payload.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tc=$(cd "$here/.." && pwd)
out="${OUT:-$HOME/sync3-build/probe}"
mkdir -p "$out/stub"
cd "$here"

TARGET=armv7a-unknown-linux-gnueabi
CFLAGS="--target=$TARGET -march=armv7-a -marm -mfloat-abi=soft -Os
 -ffreestanding -nostdinc -fno-builtin -fno-stack-protector
 -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-exceptions
 -ffunction-sections -fdata-sections -Wall -Wextra -Werror -I."
LIBGCC=$(arm-linux-gnueabi-gcc -print-libgcc-file-name)
S="$out/stub"

# --- stub shared objects (names only) ---------------------------------------
stub() {  # stub NAME SONAME sym...
  n=$1; so=$2; shift 2
  : > "$S/$n.c"
  for s in "$@"; do echo "void $s(void){}" >> "$S/$n.c"; done
  clang --target=$TARGET -march=armv7-a -marm -mfloat-abi=soft -ffreestanding -nostdinc \
    -fno-builtin -fPIC -Wno-incompatible-library-redeclaration -Wno-invalid-noreturn \
    -c "$S/$n.c" -o "$S/$n.o"
  ld.lld -shared -soname "$so" --hash-style=sysv -o "$S/$so" "$S/$n.o"
}
stub libc libc.so.3 _init_libc _preinit_array _init_array _fini_array atexit exit \
  write dlopen dlsym dladdr dlerror
stub scr libscreen.so.1 screen_create_window screen_post_window
stub diag libRCN_DiagnosticsLib.so diagnostics_async_base_logs forensics_logworthy_async
stub old libRCN_DiagnosticsOld.so oldstub_unused

# --- slotprobe: ET_EXEC, layout as build.sh ---------------------------------
clang $CFLAGS -fno-pic -c "$tc/crt1.c" -o "$out/crt1.o"
clang $CFLAGS -fno-pic -c slotprobe.c -o "$out/slotprobe.o"
ld.lld -m armelf_linux_eabi --image-base=0x100000 -z max-page-size=0x1000 \
  -dynamic-linker /usr/lib/ldqnx.so.2 --hash-style=sysv --no-rosegment \
  -z norelro -z nognustack --no-eh-frame-hdr --gc-sections --build-id=md5 \
  -z now -e _start --no-undefined -o "$out/slotprobe" \
  "$out/crt1.o" "$out/slotprobe.o" "$LIBGCC" -L"$S" \
  -l:libRCN_DiagnosticsLib.so -l:libscreen.so.1 -l:libc.so.3
llvm-strip --strip-unneeded "$out/slotprobe"
python3 "$tc/fix-bindnow.py" "$out/slotprobe"
sh "$tc/lint-elf.sh" "$out/slotprobe" "libRCN_DiagnosticsLib.so libscreen.so.1 libc.so.3"
# The four plan-named imports must all be JUMP_SLOTs (libc imports are slots too).
js=$(readelf -rW "$out/slotprobe" | awk '$3=="R_ARM_JUMP_SLOT"{print $5}' | sort | tr '\n' ' ')
for s in diagnostics_async_base_logs forensics_logworthy_async screen_create_window screen_post_window; do
  case " $js" in *" $s "*) ;; *) echo "slotprobe: $s is not a JUMP_SLOT ($js)"; exit 1 ;; esac
done

# --- libraries: layout as build-slot.sh ------------------------------------
solink() {  # solink OUT SRC FLAGS (SONAME libRCN_DiagnosticsLib.so; NEEDED libc.so.3, libRCN_DiagnosticsOld.so)
  clang $CFLAGS -fPIC $3 -c "$2.c" -o "$out/$1.o"
  ld.lld -m armelf_linux_eabi -shared -soname libRCN_DiagnosticsLib.so \
    -z max-page-size=0x1000 --hash-style=sysv --no-rosegment \
    -z norelro -z nognustack --no-eh-frame-hdr --gc-sections \
    -z now -o "$out/$1.so" "$out/$1.o" "$LIBGCC" -L"$S" -l:libc.so.3 -l:libRCN_DiagnosticsOld.so
  llvm-strip --strip-unneeded "$out/$1.so"
  python3 "$tc/fix-bindnow.py" "$out/$1.so"
}
solink libslotgot libslotgot -fvisibility=hidden
solink libslotgot_ro libslotgot "-fvisibility=hidden -DSLOTGOT_RO"
solink libslotexp libslotexp ""

solint() {  # solint FILE "exports"
  f=$1; want=$2; bad=0
  fail() { echo "LINT FAIL $(basename "$f"): $*"; bad=1; }
  h=$(readelf -hW "$f"); l=$(readelf -lW "$f"); d=$(readelf -dW "$f")
  echo "$h" | grep -q 'Type: *DYN' || fail "not ET_DYN"
  echo "$h" | grep -q 'Machine: *ARM' || fail "not ARM"
  echo "$h" | grep -q 'hard-float' && fail "hard-float ABI"
  echo "$l" | grep -q 'interpreter' && fail "has PT_INTERP"
  for t in GNU_RELRO GNU_STACK GNU_EH_FRAME TLS GNU_PROPERTY; do
    echo "$l" | awk '{print $1}' | grep -qx "$t" && fail "has PT_$t"
  done
  echo "$d" | grep -q '(HASH)' || fail "no DT_HASH"
  echo "$d" | grep -q 'GNU_HASH' && fail "has DT_GNU_HASH"
  echo "$d" | grep -Eq 'VERNEED|VERSYM|RELA\b|RELR|TEXTREL|RUNPATH' && fail "unsupported dynamic tag"
  [ "$(echo "$d" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')" = libRCN_DiagnosticsLib.so ] || fail "SONAME"
  [ "$(echo "$d" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')" = "libc.so.3 libRCN_DiagnosticsOld.so " ] || fail "NEEDED order"
  readelf -AW "$f" | grep -Eq 'Tag_FP_arch|Tag_Advanced_SIMD|Tag_ABI_VFP_args' && fail "FPU/VFP"
  ex=$(readelf --dyn-syms -W "$f" | awk '$1 ~ /^[0-9]+:$/ && $7!="UND" && $8!=""{print $8}' | sort | tr '\n' ' ')
  [ "$ex" = "$want" ] || fail "exports '$ex', want '$want'"
  [ $bad = 0 ] && echo "LINT PASS $(basename "$f") ($(stat -c %s "$f") bytes; exports: '$ex')"
  return $bad
}
solint "$out/libslotgot.so" ""
solint "$out/libslotgot_ro.so" ""
solint "$out/libslotexp.so" "screen_create_window screen_post_window "

mkdir -p "$here/bin"
install -m 755 "$out/slotprobe" "$here/bin/slotprobe"
cp "$out/libslotgot.so" "$out/libslotgot_ro.so" "$out/libslotexp.so" "$here/bin/"
( cd "$here" && sha256sum bin/slotprobe bin/libslotgot.so bin/libslotgot_ro.so bin/libslotexp.so run-probe.sh > SHA256SUMS && cat SHA256SUMS )
