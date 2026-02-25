"""
format_sd.py  --  Write a minimal FAT16 filesystem to an SD card.

Creates one file: DATA.BIN (1 MB = 2048 x 512-byte blocks).
After running this script, insert the SD card into the Nexys4 DDR.
The FPGA reads/writes DATA.BIN blocks using SW[15:5] as the address.
On your PC, DATA.BIN appears as a normal 1 MB file you can open/read.

FAT16 layout written to the SD card:
  Sector  0        : Boot Sector (BPB)
  Sectors 1-9      : FAT table  (copy 1)
  Sectors 10-18    : FAT table  (copy 2)
  Sector  19       : Root directory  (DATA.BIN entry)
  Sectors 20-2067  : DATA.BIN data area  <-- FPGA reads/writes here

Usage:
  Windows (run as Administrator):
      python format_sd.py \\.\PhysicalDrive2
      python format_sd.py \\.\PhysicalDrive2 --force

  Linux (run as root):
      sudo python format_sd.py /dev/sdb
      sudo python format_sd.py /dev/sdb --force

  To only SHOW the drive number without writing, run without arguments:
      python format_sd.py

WARNING: Specify the SD card's PHYSICAL DISK, not a partition.
         All existing data on the device will be overwritten.
"""

import struct
import sys
import os

# ── FAT16 parameters ──────────────────────────────────────────────────────────
SECTOR_SIZE        = 512
SECTORS_PER_CLUST  = 1
RESERVED_SECTORS   = 1          # just the boot sector
NUM_FATS           = 2
ROOT_ENTRIES       = 16         # 16 x 32 bytes = 512 bytes = 1 sector
FAT_SECTORS        = 9          # ceil((2050 entries * 2 bytes) / 512)
ROOT_SECTORS       = 1
DATA_CLUSTERS      = 2048       # matches SW[15:5] range  (2048 x 512 B = 1 MB)

DATA_START_SECTOR  = RESERVED_SECTORS + NUM_FATS * FAT_SECTORS + ROOT_SECTORS
# = 1 + 18 + 1 = 20

TOTAL_SECTORS      = DATA_START_SECTOR + DATA_CLUSTERS   # 2068


# ── Build boot sector ─────────────────────────────────────────────────────────
def make_boot_sector():
    b = bytearray(SECTOR_SIZE)
    b[0:3]   = b'\xEB\x5A\x90'        # jmp short + nop
    b[3:11]  = b'MSDOS5.0'            # OEM name
    struct.pack_into('<H', b, 11, SECTOR_SIZE)          # bytes per sector
    b[13]    = SECTORS_PER_CLUST                        # sectors per cluster
    struct.pack_into('<H', b, 14, RESERVED_SECTORS)     # reserved sectors
    b[16]    = NUM_FATS                                  # number of FATs
    struct.pack_into('<H', b, 17, ROOT_ENTRIES)          # root dir entries
    struct.pack_into('<H', b, 19, TOTAL_SECTORS)         # total sectors (16-bit)
    b[21]    = 0xF8                                      # media type: fixed disk
    struct.pack_into('<H', b, 22, FAT_SECTORS)           # sectors per FAT
    struct.pack_into('<H', b, 24, 63)                    # sectors per track
    struct.pack_into('<H', b, 26, 255)                   # number of heads
    struct.pack_into('<L', b, 28, 0)                     # hidden sectors
    struct.pack_into('<L', b, 32, 0)                     # total sectors (32-bit, 0 = use 16-bit)
    b[36]    = 0x80                                      # drive number
    b[38]    = 0x29                                      # extended boot signature
    struct.pack_into('<L', b, 39, 0xDEADBEEF)            # volume serial number
    b[43:54] = b'FPGA DATA  '                            # volume label (11 bytes)
    b[54:62] = b'FAT16   '                               # FS type string (8 bytes)
    b[510]   = 0x55
    b[511]   = 0xAA
    return bytes(b)


# ── Build FAT16 table ─────────────────────────────────────────────────────────
def make_fat():
    fat = bytearray(FAT_SECTORS * SECTOR_SIZE)

    # Entries 0 & 1: reserved
    struct.pack_into('<H', fat, 0, 0xFFF8)   # media byte
    struct.pack_into('<H', fat, 2, 0xFFFF)   # end-of-chain marker

    # Entries 2 .. (2 + DATA_CLUSTERS - 2): each points to the next cluster
    for c in range(2, DATA_CLUSTERS + 2 - 1):
        struct.pack_into('<H', fat, c * 2, c + 1)

    # Last cluster of DATA.BIN: end-of-chain
    last = DATA_CLUSTERS + 2 - 1           # = 2049
    struct.pack_into('<H', fat, last * 2, 0xFFFF)

    return bytes(fat)


# ── Build root directory ──────────────────────────────────────────────────────
def make_root_dir():
    root = bytearray(ROOT_SECTORS * SECTOR_SIZE)

    # 8.3 directory entry for DATA.BIN (32 bytes starting at offset 0)
    root[0:8]  = b'DATA    '            # filename  (8 bytes, space-padded)
    root[8:11] = b'BIN'                 # extension (3 bytes)
    root[11]   = 0x20                   # attribute: archive
    # bytes 12-21: reserved / timestamps (zero = fine for FAT16)
    struct.pack_into('<H', root, 26, 2)                              # first cluster (low)
    struct.pack_into('<L', root, 28, DATA_CLUSTERS * SECTOR_SIZE)   # file size in bytes

    return bytes(root)


# ── Write to device ───────────────────────────────────────────────────────────
def write_fat16(device_path):
    boot  = make_boot_sector()
    fat   = make_fat()
    root  = make_root_dir()

    print(f"\nTarget device : {device_path}")
    print(f"Boot sector   : sector 0")
    print(f"FAT (copy 1)  : sectors 1-{1 + FAT_SECTORS - 1}")
    print(f"FAT (copy 2)  : sectors {1 + FAT_SECTORS}-{1 + 2*FAT_SECTORS - 1}")
    print(f"Root dir      : sector {DATA_START_SECTOR - 1}")
    print(f"DATA.BIN data : sectors {DATA_START_SECTOR}-{DATA_START_SECTOR + DATA_CLUSTERS - 1}")
    print(f"DATA.BIN size : {DATA_CLUSTERS * SECTOR_SIZE // 1024} KB  ({DATA_CLUSTERS} blocks x 512 bytes)")
    print(f"\nFPGA address mapping:")
    print(f"  SW[15:5] = 0    -> sector {DATA_START_SECTOR}  = DATA.BIN byte offset 0")
    print(f"  SW[15:5] = 1    -> sector {DATA_START_SECTOR+1}  = DATA.BIN byte offset 512")
    print(f"  SW[15:5] = 2047 -> sector {DATA_START_SECTOR+2047} = DATA.BIN byte offset {2047*512}")

    try:
        with open(device_path, 'r+b') as f:
            # Boot sector
            f.seek(0 * SECTOR_SIZE)
            f.write(boot)

            # FAT copy 1
            f.seek(RESERVED_SECTORS * SECTOR_SIZE)
            f.write(fat)

            # FAT copy 2
            f.seek((RESERVED_SECTORS + FAT_SECTORS) * SECTOR_SIZE)
            f.write(fat)

            # Root directory
            f.seek((RESERVED_SECTORS + NUM_FATS * FAT_SECTORS) * SECTOR_SIZE)
            f.write(root)

            f.flush()
            os.fsync(f.fileno())

        print("\nDone! FAT16 structure written successfully.")
        print("Safely eject and reinsert the SD card.")
        print("DATA.BIN should appear as a 1 MB file on your PC.")

    except PermissionError:
        print("\nERROR: Permission denied.")
        if sys.platform == 'win32':
            print("  Run this script as Administrator.")
            print("  Also make sure no Explorer window has the SD card open.")
        else:
            print("  Run with: sudo python format_sd.py <device>")
        sys.exit(1)
    except FileNotFoundError:
        print(f"\nERROR: Device '{device_path}' not found.")
        print("  Windows example: \\\\.\\PhysicalDrive2")
        print("  Linux example:   /dev/sdb")
        sys.exit(1)


# ── List physical drives (Windows helper) ────────────────────────────────────
def list_drives_windows():
    import subprocess
    print("Physical drives detected on this system:")
    try:
        result = subprocess.run(
            ['wmic', 'diskdrive', 'get', 'DeviceID,Model,Size'],
            capture_output=True, text=True, timeout=10
        )
        print(result.stdout)
        print("Use the DeviceID of your SD card reader, e.g.:")
        print("  python format_sd.py \\\\.\\PhysicalDrive1")
    except Exception as e:
        print(f"  (Could not list drives: {e})")
        print("  Open Disk Management (diskmgmt.msc) to find the SD card disk number.")


# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        if sys.platform == 'win32':
            list_drives_windows()
        else:
            print("Block devices on this system:")
            os.system("lsblk -d -o NAME,SIZE,MODEL 2>/dev/null || ls /dev/sd*")
        sys.exit(0)

    device = sys.argv[1]
    force  = '--force' in sys.argv

    print("=" * 60)
    print("  FAT16 SD Card Formatter for FPGA SD Reader")
    print("=" * 60)
    print(f"\nAbout to write FAT16 structure to: {device}")
    print("This will OVERWRITE the first 20 sectors (boot+FAT+rootdir).")
    print("Existing DATA.BIN content (sectors 20+) is NOT erased.")

    if not force:
        answer = input("\nType YES to continue: ")
        if answer.strip().upper() != 'YES':
            print("Aborted.")
            sys.exit(0)

    write_fat16(device)
