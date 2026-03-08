r"""
verify_sd.py -- Read back SD card and check the autonomous AES SD pipeline.
Run as Administrator.

Usage:
    python verify_sd.py
    python verify_sd.py \\\\.\\PhysicalDrive1
    python verify_sd.py \\\\.\\PhysicalDrive1 20
"""
import os
import struct
import sys


def open_raw_device(path, mode):
    if sys.platform == "win32" and path.startswith("\\\\.\\"):
        flags = os.O_BINARY
        if "+" in mode:
            flags |= os.O_RDWR
        elif "w" in mode:
            flags |= os.O_WRONLY
        else:
            flags |= os.O_RDONLY
        fd = os.open(path, flags)
        return os.fdopen(fd, mode, buffering=0)
    return open(path, mode)

DEVICE = sys.argv[1] if len(sys.argv) > 1 else r"\\.\PhysicalDrive1"
DATA_BASE_OVERRIDE = int(sys.argv[2]) if len(sys.argv) > 2 else None
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VECTOR_PATH = os.path.join(SCRIPT_DIR, "aes_vectors.hex")
ENTRY_SIZE = 32


def fmt_bytes(data):
    return " ".join(f"{b:02X}" for b in data)


def le_bytes_to_block_hex(data):
    return "".join(f"{b:02X}" for b in reversed(data))


def load_vector_bytes():
    try:
        with open(VECTOR_PATH, "r", encoding="ascii") as vf:
            rows = [line.strip() for line in vf if line.strip()]
    except OSError:
        return None

    if len(rows) < 3:
        return None

    return {
        "Plaintext": bytes.fromhex(rows[0])[::-1],
        "Key": bytes.fromhex(rows[1])[::-1],
        "Expected CT": bytes.fromhex(rows[2])[::-1],
    }


def parse_boot_sector(boot):
    bytes_per_sector = struct.unpack_from("<H", boot, 11)[0]
    sectors_per_cluster = boot[13]
    reserved_sectors = struct.unpack_from("<H", boot, 14)[0]
    num_fats = boot[16]
    root_entries = struct.unpack_from("<H", boot, 17)[0]
    total_sectors_16 = struct.unpack_from("<H", boot, 19)[0]
    fat_sectors = struct.unpack_from("<H", boot, 22)[0]
    total_sectors_32 = struct.unpack_from("<L", boot, 32)[0]
    root_sectors = ((root_entries * ENTRY_SIZE) + (bytes_per_sector - 1)) // bytes_per_sector
    data_start_sector = reserved_sectors + (num_fats * fat_sectors) + root_sectors
    total_sectors = total_sectors_16 or total_sectors_32

    return {
        "bytes_per_sector": bytes_per_sector,
        "sectors_per_cluster": sectors_per_cluster,
        "reserved_sectors": reserved_sectors,
        "num_fats": num_fats,
        "root_entries": root_entries,
        "fat_sectors": fat_sectors,
        "root_sectors": root_sectors,
        "data_start_sector": data_start_sector,
        "total_sectors": total_sectors,
    }


def find_data_bin_entry(root_dir, root_entries):
    target = b"DATA    BIN"
    for idx in range(root_entries):
        entry = root_dir[idx * ENTRY_SIZE:(idx + 1) * ENTRY_SIZE]
        if len(entry) < ENTRY_SIZE or entry[0] in (0x00, 0xE5):
            continue
        if entry[0:11] == target:
            return idx, entry
    return None, None


try:
    with open_raw_device(DEVICE, "rb") as f:
        # Boot sector
        f.seek(0)
        boot = f.read(512)
        if len(boot) != 512:
            raise OSError("could not read full boot sector")

        bpb = parse_boot_sector(boot)
        sig_ok = boot[510:512] == b"\x55\xAA"
        fs_type = boot[54:62].decode("ascii", errors="replace").strip()
        vol_label = boot[43:54].decode("ascii", errors="replace").strip()
        print("=== Boot Sector ===")
        print(f"  Signature  : {'OK (55 AA)' if sig_ok else 'BAD - FAT not written!'}")
        print(f"  FS type    : {fs_type!r}")
        print(f"  Volume     : {vol_label!r}")
        print(f"  Sector size: {bpb['bytes_per_sector']} bytes")
        print(f"  FAT copies : {bpb['num_fats']}")
        print(f"  FAT size   : {bpb['fat_sectors']} sectors each")
        print(f"  Root dir   : {bpb['root_sectors']} sector(s)")
        print(f"  Data start : sector {bpb['data_start_sector']}")

        # Root directory entry
        root_dir_sector = bpb["reserved_sectors"] + (bpb["num_fats"] * bpb["fat_sectors"])
        root_dir_size = bpb["root_sectors"] * bpb["bytes_per_sector"]
        f.seek(root_dir_sector * bpb["bytes_per_sector"])
        root = f.read(root_dir_size)
        entry_idx, entry = find_data_bin_entry(root, bpb["root_entries"])
        if entry is None:
            raise OSError("DATA.BIN entry not found in root directory")

        name = entry[0:8].decode("ascii", errors="replace").rstrip()
        ext = entry[8:11].decode("ascii", errors="replace").rstrip()
        attr = entry[11]
        cluster = struct.unpack_from("<H", entry, 26)[0]
        file_size = struct.unpack_from("<L", entry, 28)[0]
        derived_base_sector = bpb["data_start_sector"] + ((cluster - 2) * bpb["sectors_per_cluster"])
        data_base = DATA_BASE_OVERRIDE if DATA_BASE_OVERRIDE is not None else derived_base_sector

        print(f"\n=== Root Directory Entry {entry_idx} ===")
        print(f"  Filename   : {name}.{ext}")
        print(f"  Attribute  : 0x{attr:02X}")
        print(f"  1st cluster: {cluster}")
        print(
            f"  File size  : {file_size} bytes  "
            f"({'OK - 1 MB' if file_size == 1048576 else 'WRONG - should be 1048576'})"
        )
        print(f"  DATA.BIN   : starts at physical sector {derived_base_sector}")
        if DATA_BASE_OVERRIDE is not None and DATA_BASE_OVERRIDE != derived_base_sector:
            print(
                f"  WARNING    : CLI base sector {DATA_BASE_OVERRIDE} overrides FAT-derived "
                f"sector {derived_base_sector}"
            )

        sectors = [
            ("Plaintext", data_base + 0, 0),
            ("Key", data_base + 1, 512),
            ("Expected CT", data_base + 2, 1024),
            ("Ciphertext", data_base + 3, 1536),
            ("Decrypted", data_base + 4, 2048),
        ]

        vector_bytes = load_vector_bytes()
        blocks = {}
        print(f"\n=== DATA.BIN AES Pipeline View (base sector {data_base}) ===")
        print("  Valid payload bytes for each AES block are byte offsets 0..15 of the 512-byte sector.")
        print("  Byte offsets 16..511 should be 00.")
        for label, sector, file_offset in sectors:
            f.seek(sector * bpb["bytes_per_sector"])
            raw_sector = f.read(bpb["bytes_per_sector"])
            if len(raw_sector) != bpb["bytes_per_sector"]:
                raise OSError(f"short read at sector {sector}")

            block = raw_sector[:16]
            tail = raw_sector[16:]
            tail_zero = all(b == 0 for b in tail)
            blocks[label] = block
            print(
                f"  {label:<11} sector {sector}  "
                f"(disk byte offset {sector * bpb['bytes_per_sector']}, "
                f"DATA.BIN byte offset {file_offset})"
            )
            print(f"    bytes[0:16]  : {fmt_bytes(block)}")
            print(f"    block value  : {le_bytes_to_block_hex(block)}")
            print(f"    bytes[16:512]: {'all 00' if tail_zero else 'NONZERO DATA PRESENT'}")
            if vector_bytes and label in vector_bytes:
                exp = vector_bytes[label]
                print(f"    expected     : {fmt_bytes(exp)}")
                print(f"    vector check : {'MATCH' if block == exp else 'DIFFER'}")

        ct_ok = blocks["Ciphertext"] == blocks["Expected CT"]
        dec_ok = blocks["Decrypted"] == blocks["Plaintext"]

        print("\n=== Checks ===")
        print("  Ciphertext vs Expected CT : " + ("MATCH" if ct_ok else "DIFFER"))
        print("  Decrypted vs Plaintext    : " + ("MATCH" if dec_ok else "DIFFER"))
        if vector_bytes:
            print(
                "  Plaintext vs aes_vectors  : "
                + ("MATCH" if blocks["Plaintext"] == vector_bytes["Plaintext"] else "DIFFER")
            )
            print(
                "  Key vs aes_vectors        : "
                + ("MATCH" if blocks["Key"] == vector_bytes["Key"] else "DIFFER")
            )
            print(
                "  Expected CT vs vectors    : "
                + ("MATCH" if blocks["Expected CT"] == vector_bytes["Expected CT"] else "DIFFER")
            )
        print("  Overall                   : " + ("PASS" if ct_ok and dec_ok else "FAIL"))

        print("\nDone.")

except PermissionError:
    print("ERROR: Run as Administrator.")
except FileNotFoundError:
    print(f"ERROR: Device {DEVICE!r} not found.")
except OSError as exc:
    print(f"ERROR: Raw device access failed: {exc}")
