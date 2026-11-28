# Building

Everything is cross-built for the radio, on a host, inside WSL Ubuntu. Nothing is built on the
unit and no vendor binary is built or shipped.

## What you need

- `clang`, `lld` (or LLVM `ld.lld`), `llvm-strip`
- an ARM cross GCC and binutils (`arm-linux-gnueabi-gcc` is used only to print the libgcc path)
- `python3`

## The library

```
sh toolchain/build-slot.sh
```

It writes `libyafc.so` to `$OUT` (default `~/yafc-build`), copies it to `toolchain/bin/`, and
writes `toolchain/bin/SHA1SUMS.yafc`. `OUT` must be set to use `--log-only`:

```
OUT=~/yafc-log sh toolchain/build-slot.sh --log-only
```

The log-only build (`-DYAFC_SLOT_LOG_ONLY`) does the identity checks and logs the result but never
patches the GOT. It is the safe build to put in the slot when you only want to know whether the
library is loaded and recognised.

### What the build does, and why

- `-DYAFC_SLOT` selects the slot build: static wrappers and a GOT patch, not exported symbols.
- `--target=armv7a-unknown-linux-gnueabi -march=armv7-a -marm -mfloat-abi=soft`, `-Os`,
  `-ffreestanding -nostdinc`: the radio's ARMv7, soft-float, and no system header - every
  prototype and constant the source needs is declared in it or in `toolchain/screen.h`.
- Stub shared objects carry **only the symbol names** libc and the preserved copy must provide;
  the radio's real libraries bind at run time. The stubs are rebuilt every time, so a stale stub
  from another build cannot change this library's dynamic symbols.
- The artefact is linked with `-soname libRCN_DiagnosticsLib.so` (the name the camera expects) and
  `-z now`, then `toolchain/fix-bindnow.py` fixes the dynamic tag to the form SYNC 3's loader wants.
- `toolchain/lint-so.sh` then checks the result and **must** print `LINT PASS`: no interpreter, no
  RELRO/STACK/EH_FRAME/TLS/GNU_PROPERTY segments, no GNU_HASH, no VERSYM/RUNPATH/TEXTREL, SONAME
  as above, and NEEDED exactly `libc.so.3 libRCN_DiagnosticsOld.so`. A build that fails the lint
  is not copied.

## The loader probe

```
sh toolchain/probe/build-probe.sh
```

Builds four artefacts into `toolchain/probe/bin/` and writes `SHA256SUMS`:

| Artefact | What it is |
|---|---|
| `slotprobe` | the probe itself: an `ET_EXEC` at `0x100000` that needs `libRCN_DiagnosticsLib.so`, `libscreen.so.1` and `libc.so.3` |
| `libslotgot.so` | a slot library that patches the probe's GOT - the happy path |
| `libslotgot_ro.so` | the same, `-DSLOTGOT_RO`: verifies and reports, never writes |
| `libslotexp.so` | a control that exports the Screen names |

The probe binary is checked by `toolchain/lint-elf.sh` against the same ELF features Ford's own
binaries use, and its four imports must all be `JUMP_SLOT`s.

## The USB tooling

```
sh tools/make-usb.sh <mount-point>
```

It copies the built artefacts into the stick layout, writes `yafc-payload/SHA256SUMS`
(library, probe, configuration, fragments and Hero icons), and refuses to touch a
directory it does not own or a stick that still has a `RUN-YAFC-*` marker.

## See also

[TESTING.md](TESTING.md) - what to run and what each level can prove.
