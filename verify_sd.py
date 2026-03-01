"""
verify_sd.py -- Read back SD card and check FAT16 structure + FPGA data.
Run as Administrator.

Usage:
    python verify_sd.py                               (uses \\\\.\\PhysicalDrive1, base block 0)
    python verify_sd.py \\\\.\\PhysicalDrive1         (base block 0)
    python verify_sd.py \\\\.\\PhysicalDrive1 5       (base block SW15_5=5)
"""
import struct
import sys

DEVICE = sys.argv[1] if len(sys.argv) > 1 else r"\\.\PhysicalDrive1"
BASE_BLOCK = int(sys.argv[2]) if len(sys.argv) > 2 else 0

if BASE_BLOCK < 0 or BASE_BLOCK > 2047:
    raise SystemExit("ERROR: base block must be in range 0..2047 (SW15_5 value).")

try:
    with open(DEVICE, "rb") as f:
        # Boot sector
        f.seek(0)
        boot = f.read(512)
        sig_ok = boot[510:512] == b"\x55\xAA"
        fs_type = boot[54:62].decode("ascii", errors="replace").strip()
        vol_label = boot[43:54].decode("ascii", errors="replace").strip()
        print("=== Boot Sector ===")
        print(f"  Signature  : {'OK (55 AA)' if sig_ok else 'BAD - FAT not written!'}")
        print(f"  FS type    : {fs_type!r}")
        print(f"  Volume     : {vol_label!r}")

        # Root directory entry
        f.seek(19 * 512)
        root = f.read(512)
        name = root[0:8].decode("ascii", errors="replace").rstrip()
        ext = root[8:11].decode("ascii", errors="replace").rstrip()
        attr = root[11]
        cluster = struct.unpack_from("<H", root, 26)[0]
        file_size = struct.unpack_from("<L", root, 28)[0]
        print("\n=== Root Directory Entry 0 ===")
        print(f"  Filename   : {name}.{ext}")
        print(f"  Attribute  : 0x{attr:02X}")
        print(f"  1st cluster: {cluster}")
        print(
            f"  File size  : {file_size} bytes  "
            f"({'OK - 1 MB' if file_size == 1048576 else 'WRONG - should be 1048576'})"
        )

        # Selected block full header view (single-sector flow verification)
        f.seek((20 + BASE_BLOCK) * 512)
        block = f.read(512)
        plain = block[0:16]
        enc = block[16:32]
        dec = block[32:48]

        print(f"\n=== DATA.BIN selected block SW15_5={BASE_BLOCK} ===")
        print("  Plain [0..15] : " + " ".join(f"{b:02X}" for b in plain))
        print("  Enc   [16..31]: " + " ".join(f"{b:02X}" for b in enc))
        print("  Dec   [32..47]: " + " ".join(f"{b:02X}" for b in dec))

        same = plain == dec
        print("\n=== Single-Sector Check ===")
        print(
            "  Plain[0..15] vs Dec[32..47]: "
            + ("MATCH (decrypt OK)" if same else "DIFFER (decrypt not matching yet)")
        )

        # Legacy view for older bitstreams (encrypt/decrypt in next sectors).
        print("\n=== Legacy Cross-Sector View (old flow) ===")
        for blk in (BASE_BLOCK, min(BASE_BLOCK + 1, 2047), min(BASE_BLOCK + 2, 2047)):
            f.seek((20 + blk) * 512)
            data = f.read(16)
            hex_str = " ".join(f"{b:02X}" for b in data)
            print(f"  Block {blk} first 16 bytes: {hex_str}")

        print("\nDone.")

except PermissionError:
    print("ERROR: Run as Administrator.")
except FileNotFoundError:
    print(f"ERROR: Device {DEVICE!r} not found.")
