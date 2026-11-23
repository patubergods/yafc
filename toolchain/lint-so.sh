#!/bin/sh
# Check a shared object (libyafc.so) against the ELF features seen in the
# radio's own libraries (libscreen.so.1, libc.so.3, libcpp.so.4).
# Structural check only - it cannot prove the QNX loader accepts it.
# Usage: sh lint-elf-so.sh FILE
f=$1; allow="${2:-}"; bad=0
fail(){ echo "LINT FAIL $(basename "$f"): $*"; bad=1; }
h=$(readelf -hW "$f"); l=$(readelf -lW "$f"); d=$(readelf -dW "$f")

echo "$h" | grep -q 'Type: *DYN' || fail "not ET_DYN"
echo "$h" | grep -q 'Machine: *ARM' || fail "not ARM"
echo "$h" | grep -q 'Version5 EABI' || fail "not EABI5"
echo "$h" | grep -q 'hard-float' && fail "hard-float ABI"
echo "$l" | grep -q 'interpreter' && fail "has PT_INTERP (a library must not)"
[ "$(echo "$l" | awk '$1=="LOAD"' | wc -l)" -le 3 ] || fail "more than 3 LOAD segments"
for t in GNU_RELRO GNU_STACK GNU_EH_FRAME TLS GNU_PROPERTY; do
  echo "$l" | awk '{print $1}' | grep -qx "$t" && fail "has PT_$t"
done
echo "$d" | grep -q '(HASH)' || fail "no DT_HASH"
echo "$d" | grep -q 'GNU_HASH' && fail "has DT_GNU_HASH"
echo "$d" | grep -q '(SONAME)' || fail "no DT_SONAME"
echo "$d" | grep -Eq 'VERNEED|VERSYM|RELA\b|RELR|TEXTREL|RUNPATH' && fail "unsupported dynamic tag"
needed=$(echo "$d" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')
if [ -z "$allow" ]; then
  [ "$needed" = "libc.so.3 " ] || fail "NEEDED is '$needed', want only libc.so.3"
else
  # Slot build: libc plus an explicit allow-list (the preserved stock copy).
  echo "$needed" | grep -qw libc.so.3 || fail "missing NEEDED libc.so.3"
  for n in $needed; do
    [ "$n" = "libc.so.3" ] && continue
    case " $allow " in *" $n "*) ;; *) fail "unexpected NEEDED '$n' (allowed: $allow)";; esac
  done
  for n in $allow; do
    echo "$needed" | grep -qw "$n" || fail "missing NEEDED '$n'"
  done
fi
readelf -AW "$f" | grep -q 'Tag_ABI_VFP_args' && fail "VFP argument passing"
readelf -AW "$f" | grep -Eq 'Tag_FP_arch|Tag_Advanced_SIMD' && fail "uses FPU instructions"
readelf -AW "$f" | grep -q 'Tag_DIV_use: Allowed in v7-A' && fail "hardware divide"
# Exact export set. The LD_PRELOAD build exports exactly the two Screen calls it
# interposes. The slot build exports NOTHING of its own (the loader may add
# _init/_fini): any screen_* or other symbol would put our code in the global
# scope of every process that links the slot.
exports=$(readelf --dyn-syms -W "$f" | awk '$1 ~ /^[0-9]+:$/ && $7!="UND" && $8!=""{print $8}' | sort | tr '\n' ' ')
if [ -z "$allow" ]; then
  [ "$exports" = "screen_create_window screen_post_window " ] \
    || fail "exports '$exports', want exactly screen_create_window screen_post_window"
else
  for s in $exports; do
    case "$s" in _init|_fini) ;; *) fail "slot exports '$s' (only _init/_fini allowed)";; esac
  done
  echo "$d" | grep -Eq 'INIT_ARRAY|\(INIT\)' || fail "slot has no constructor (INIT_ARRAY/INIT)"
fi
# Imports: only libc calls this source makes (raise comes from libgcc's divide).
for s in $(readelf --dyn-syms -W "$f" | awk '$1 ~ /^[0-9]+:$/ && $7=="UND" && $8!=""{print $8}'); do
  case "$s" in
    abort|raise|getpid|dlopen|dlsym|clock_gettime|open|read|write|close|unlink|dl_iterate_phdr) ;;
    *) fail "unexpected import '$s'";;
  esac
done
echo "ok-so-far $(basename "$f"): $(stat -c %s "$f") bytes; NEEDED: $needed"
[ $bad = 0 ] && echo "LINT PASS $(basename "$f")"
exit $bad