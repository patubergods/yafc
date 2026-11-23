#!/bin/sh
# Cross-build the library-slot hook, libyafc.so.
# Run inside WSL Ubuntu:   sh build-slot.sh
#
# This is the same interposer source as the composed-view library, compiled with
# -DYAFC_SLOT. The result defines NO Screen symbols of its own: its constructor
# runs inside the camera process only (identity, kill switch and GOT checks; see
# ../docs/ARCHITECTURE.md) and overwrites two of that process's own Screen call
# slots. It is linked under the SONAME the camera expects and carries a NEEDED
# entry on the preserved copy of the radio's own library, so every other process
# that loads the slot keeps resolving the original functions.
#
# The preserved copy is NOT built here and no vendor binary is part of this
# repository: the installer makes that copy from the radio's own file. See
# ../docs/INSTALL.md.
#
# Needs: clang, lld, LLVM tools (llvm-strip), Python 3, the ARM cross GCC and
# binutils. Output goes to $OUT (default $HOME/yafc-build); the shared object and
# its SHA-1 list are copied to bin/.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="${OUT:-$HOME/yafc-build}"
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$here"

TARGET=armv7a-unknown-linux-gnueabi
CFLAGS="--target=$TARGET -march=armv7-a -marm -mfloat-abi=soft -Os
 -ffreestanding -nostdinc -fno-builtin -fno-stack-protector -fPIC
 -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-exceptions
 -ffunction-sections -fdata-sections -Wall -Wextra -Werror -DYAFC_SLOT"
case "${1:-}" in
  "") ;;
  --log-only) [ -n "${OUT:-}" ] || { echo 'set OUT for the logging-only build' >&2; exit 2; }
              CFLAGS="$CFLAGS -DYAFC_SLOT_LOG_ONLY" ;;
  *) echo "unknown build mode: $1" >&2; exit 2 ;;
esac
LIBGCC=$(arm-linux-gnueabi-gcc -print-libgcc-file-name)

# --- stub shared objects the linker records as NEEDED ----------------------
LIBC_SYMS="_init_libc _preinit_array _init_array _fini_array atexit exit abort
 write getpid dlopen dlsym dlerror dlclose clock_gettime sleep
 open close read lseek unlink dl_iterate_phdr"
# A private directory, rebuilt every time: a stub libc left by another build
# script (with another symbol list) would change this library's dynamic symbols.
st="$out/slot-stub"
rm -rf "$st"; mkdir -p "$st"
: > "$st/stub.c"
for s in $LIBC_SYMS; do echo "void $s(void){}" >> "$st/stub.c"; done
clang --target=$TARGET -march=armv7-a -marm -mfloat-abi=soft -ffreestanding \
  -nostdinc -fno-builtin -fPIC -Wno-incompatible-library-redeclaration -Wno-invalid-noreturn \
  -c "$st/stub.c" -o "$st/stub.o"
ld.lld -shared -soname libc.so.3 --hash-style=sysv -o "$st/libc.so.3" "$st/stub.o"
: > "$st/depstub.c"
clang --target=$TARGET -march=armv7-a -marm -mfloat-abi=soft -ffreestanding \
  -nostdinc -fno-builtin -fPIC -c "$st/depstub.c" -o "$st/depstub.o"
# The SONAME of the preserved copy. The installer writes the radio's own library
# under exactly this name beside this one.
ld.lld -shared -soname libRCN_DiagnosticsOld.so --hash-style=sysv \
  -o "$st/depstub.so" "$st/depstub.o"

# --- build the slot library -------------------------------------------------
clang $CFLAGS -c yafc-slot.c -o "$out/yafc-slot.o"
ld.lld -m armelf_linux_eabi -shared -soname libRCN_DiagnosticsLib.so \
  -z max-page-size=0x1000 --hash-style=sysv --no-rosegment \
  -z norelro -z nognustack --no-eh-frame-hdr --gc-sections \
  -z now -o "$out/libyafc.so" \
  "$out/yafc-slot.o" "$LIBGCC" -L"$st" -l:libc.so.3 -l:depstub.so
llvm-strip --strip-unneeded "$out/libyafc.so"
python3 "$here/fix-bindnow.py" "$out/libyafc.so"
sh "$here/lint-so.sh" "$out/libyafc.so" "libRCN_DiagnosticsOld.so"
if [ "${1:-}" = --log-only ]; then
  ( cd "$out" && sha1sum libyafc.so > SHA1SUMS.yafc )
  echo "log-only build: $out/libyafc.so"
  exit 0
fi
mkdir -p "$here/bin"
cp "$out/libyafc.so" "$here/bin/"
( cd "$here/bin" && { sha1sum libyafc.so | tee SHA1SUMS.yafc; } )
