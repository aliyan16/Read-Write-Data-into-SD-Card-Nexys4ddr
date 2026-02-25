"""
verify_sd.py  --  Read back SD card and check FAT16 structure + FPGA data.
Run as Administrator.

Usage:
    python verify_sd.py                    (uses \\.\PhysicalDrive1)
    python verify_sd.py \\.\PhysicalDrive1
"""
import struct, sys

DEVICE = sys.argv[1] if len(sys.argv) > 1 else r'\\.\PhysicalDrive1'

try:
    with open(DEVICE, 'rb') as f:

        # ── Boot sector ───────────────────────────────────────────────
        f.seek(0)
        boot = f.read(512)
        sig_ok = boot[510:512] == b'\x55\xAA'
        fs_type = boot[54:62].decode('ascii', errors='replace').strip()
        vol_label = boot[43:54].decode('ascii', errors='replace').strip()
        print("=== Boot Sector ===")
        print(f"  Signature  : {'OK (55 AA)' if sig_ok else 'BAD - FAT not written!'}")
        print(f"  FS type    : {fs_type!r}")
        print(f"  Volume     : {vol_label!r}")

        # ── Root directory entry ──────────────────────────────────────
        f.seek(19 * 512)
        root = f.read(512)
        name      = root[0:8].decode('ascii', errors='replace').rstrip()
        ext       = root[8:11].decode('ascii', errors='replace').rstrip()
        attr      = root[11]
        cluster   = struct.unpack_from('<H', root, 26)[0]
        file_size = struct.unpack_from('<L', root, 28)[0]
        print("\n=== Root Directory Entry 0 ===")
        print(f"  Filename   : {name}.{ext}")
        print(f"  Attribute  : 0x{attr:02X}")
        print(f"  1st cluster: {cluster}")
        print(f"  File size  : {file_size} bytes  "
              f"({'OK - 1 MB' if file_size == 1048576 else 'WRONG - should be 1048576'})")

        # ── DATA.BIN first 3 sectors ──────────────────────────────────
        print("\n=== DATA.BIN content (first 3 blocks) ===")
        for blk in range(3):
            f.seek((20 + blk) * 512)
            data = f.read(16)
            hex_str = ' '.join(f'{b:02X}' for b in data)
            asc_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data)
            print(f"  Block {blk} (SW15_5={blk}): {hex_str}  |{asc_str}|")

        print("\nDone.")

except PermissionError:
    print("ERROR: Run as Administrator.")
except FileNotFoundError:
    print(f"ERROR: Device {DEVICE!r} not found.")
