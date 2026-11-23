#!/bin/sh
# Check a built binary only uses ELF features seen in Ford's own SYNC 3 stock
# binaries (QNX 6.5 ldqnx.so.2). Structural check only - it cannot prove the
# binary runs. Usage: sh lint-elf.sh FILE ["NEEDED list"]
# The optional list is the exact ordered NEEDED set (probe binaries only); the default is libc.so.3 alone.
f=$1; want="${2:-libc.so.3}"; bad=0
fail(){ echo "LINT FAIL $(basename "$f"): $*"; bad=1; }
h=$(readelf -hW "$f"); l=$(readelf -lW "$f"); d=$(readelf -dW "$f"); r=$(readelf -rW "$f")

echo "$h" | grep -q 'Type: *EXEC' || fail "not ET_EXEC"
echo "$h" | grep -q 'Machine: *ARM' || fail "not ARM"
echo "$h" | grep -q 'Version5 EABI' || fail "not EABI5"
echo "$h" | grep -q 'hard-float' && fail "hard-float ABI"
echo "$l" | grep -q 'interpreter: /usr/lib/ldqnx.so.2\]' || fail "wrong interpreter"
echo "$l" | awk '$1=="LOAD"{print $3}' | head -1 | grep -q '^0x00100000$' || fail "first LOAD not at 0x100000"
[ "$(echo "$l" | awk '$1=="LOAD"' | wc -l)" = 2 ] || fail "expected 2 LOAD segments"
for t in GNU_RELRO GNU_STACK GNU_EH_FRAME TLS GNU_PROPERTY; do
  echo "$l" | awk '{print $1}' | grep -qx "$t" && fail "has PT_$t"
done
echo "$d" | grep -q '(HASH)' || fail "no DT_HASH"
echo "$d" | grep -q 'GNU_HASH' && fail "has DT_GNU_HASH"
echo "$d" | grep -q '(BIND_NOW)' || fail "no DT_BIND_NOW"
echo "$d" | grep -q '(FLAGS) ' && fail "has DT_FLAGS (stock uses DT_BIND_NOW)"
echo "$d" | grep -Eq 'VERNEED|VERSYM|RELA\b|RELR|TEXTREL|RUNPATH' && fail "unsupported dynamic tag"
needed=$(echo "$d" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')
[ "$needed" = "$want " ] || fail "NEEDED is '$needed', want '$want'"
types=$(echo "$r" | awk '$3 ~ /^R_ARM/{print $3}' | sort -u | tr '\n' ' ')
for t in $types; do
  case $t in R_ARM_JUMP_SLOT|R_ARM_GLOB_DAT|R_ARM_ABS32|R_ARM_RELATIVE|R_ARM_COPY) ;;
    *) fail "relocation $t not seen in stock binaries" ;; esac
done
readelf -AW "$f" | grep -q 'Tag_ABI_VFP_args' && fail "VFP argument passing"
readelf -AW "$f" | grep -Eq 'Tag_FP_arch|Tag_Advanced_SIMD' && fail "uses FPU instructions"
readelf -AW "$f" | grep -q 'Tag_DIV_use: Allowed in v7-A' && fail "hardware divide"
und=$(readelf --dyn-syms -W "$f" | awk '$7=="UND" && $8!=""{print $8}' | sort | tr '\n' ' ')
echo "ok-so-far $(basename "$f"): $(stat -c %s "$f") bytes; relocs: $types; imports: $und"
[ $bad = 0 ] && echo "LINT PASS $(basename "$f")"
exit $bad
