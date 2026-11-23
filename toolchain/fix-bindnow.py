"""lld marks eager binding with DT_FLAGS(BIND_NOW); Ford's GCC 4.4 binaries use
the older DT_BIND_NOW tag, which is what a QNX 6.5 loader certainly knows.
Rewrite the DT_FLAGS entry in place to DT_BIND_NOW so nothing depends on lazy
PLT binding. Usage: python3 fix-bindnow.py ELF"""
import struct, sys

p = sys.argv[1]
b = bytearray(open(p, 'rb').read())
assert b[:6] == b'\x7fELF\x01\x01', 'want ELF32 little-endian'
phoff, = struct.unpack_from('<I', b, 28)
phentsize, phnum = struct.unpack_from('<HH', b, 42)
done = False
for i in range(phnum):
    ptype, off, _va, _pa, filesz = struct.unpack_from('<IIIII', b, phoff + i * phentsize)
    if ptype != 2:  # PT_DYNAMIC
        continue
    for o in range(off, off + filesz, 8):
        tag, val = struct.unpack_from('<II', b, o)
        if tag == 0:
            break
        if tag == 0x18:
            done = True
        if tag == 0x1e:  # DT_FLAGS
            assert val == 0x8, 'DT_FLAGS has flags other than BIND_NOW: %#x' % val
            struct.pack_into('<II', b, o, 0x18, 0)
            done = True
assert done, 'no DT_FLAGS/DT_BIND_NOW found'
open(p, 'wb').write(b)
