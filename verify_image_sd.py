#!/usr/bin/env python3
"""Verify SD-card image flow: original/plain/encrypted/decrypted blocks.

Current FPGA layout per DATA.BIN sector (index = SW15_5):
- bytes  0..15 : plain block
- bytes 16..31 : encrypted block
- bytes 32..47 : decrypted block

Absolute SD sector = data_start_sector + index (default data_start_sector=20).
"""

from __future__ import annotations

import argparse
import binascii
import sys
from dataclasses import dataclass
from typing import List, Optional

SECTOR_SIZE = 512
DATA_REGION_START_SECTOR = 20
DEFAULT_KEY_HEX = "00112233445566778899AABBCCDDEEFF"


@dataclass
class BlockResult:
    index: int
    abs_sector: int
    expected_plain: bytes
    sd_plain: bytes
    sd_enc: bytes
    sd_dec: bytes
    expected_enc: Optional[bytes]
    plain_ok: bool
    dec_matches_plain: bool
    dec_matches_expected: bool
    enc_check_run: bool
    enc_ok: bool
    shift_bug_like: bool
    recovered_plain: bytes
    recovered_plain_ok: bool
    sector_first64: bytes


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Verify original/encrypted/decrypted image blocks from SD card.")
    p.add_argument(
        "--device",
        default=r"\\.\PhysicalDrive1",
        help=(
            "Raw device path (e.g. \\\\.\\PhysicalDrive1) or binary image file path. "
            "Default: \\\\.\\PhysicalDrive1"
        ),
    )
    p.add_argument(
        "--hex-file",
        default="image_input.hex",
        help="Path to image_input.hex with one 128-bit block per line.",
    )
    p.add_argument(
        "--index",
        type=int,
        help="Verify one block index only (same as SW15_5).",
    )
    p.add_argument(
        "--start",
        type=int,
        default=0,
        help="Start block index (inclusive) when verifying a range.",
    )
    p.add_argument(
        "--count",
        type=int,
        default=None,
        help="Number of blocks to verify from --start (default: all blocks in hex file).",
    )
    p.add_argument(
        "--data-start-sector",
        type=int,
        default=DATA_REGION_START_SECTOR,
        help="Absolute SD sector where DATA.BIN starts. Default: 20",
    )
    p.add_argument(
        "--file-mode",
        action="store_true",
        help=(
            "Treat --device as a regular binary image file. "
            "Without this flag, script opens the path as a raw device."
        ),
    )
    p.add_argument(
        "--check-encrypted",
        action="store_true",
        help="Also verify encrypted bytes against AES-128-ECB(expected_plain, key).",
    )
    p.add_argument(
        "--key-hex",
        default=DEFAULT_KEY_HEX,
        help=f"AES-128 key (32 hex chars). Default: {DEFAULT_KEY_HEX}",
    )
    p.add_argument(
        "--show-passing",
        action="store_true",
        help="Print per-block details even when a block passes all checks.",
    )
    p.add_argument(
        "--dump-sector64",
        action="store_true",
        help="Print first 64 bytes of the sector for inspected blocks.",
    )
    p.add_argument(
        "--scan-neighbors",
        action="store_true",
        help="For single --index, print bytes 0..47 of nearby sectors (index-2..index+2).",
    )
    return p.parse_args()


def load_expected_blocks(hex_path: str) -> List[bytes]:
    blocks: List[bytes] = []
    with open(hex_path, "r", encoding="ascii", errors="strict") as f:
        for lineno, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line:
                continue
            if len(line) != 32:
                raise ValueError(
                    f"{hex_path}:{lineno}: expected 32 hex chars (16 bytes), got {len(line)}"
                )
            try:
                msb_first = binascii.unhexlify(line)
            except binascii.Error as exc:
                raise ValueError(f"{hex_path}:{lineno}: invalid hex: {exc}") from exc

            # top.v writes blk[7:0], blk[15:8], ... blk[127:120].
            # For $readmemh-loaded 128-bit words, effective byte order is reversed.
            blocks.append(msb_first[::-1])

    if not blocks:
        raise ValueError(f"No blocks found in {hex_path}")
    return blocks


def build_index_list(total: int, index: Optional[int], start: int, count: Optional[int]) -> List[int]:
    if index is not None:
        if index < 0 or index >= total:
            raise ValueError(f"--index {index} out of range 0..{total - 1}")
        return [index]

    if start < 0 or start >= total:
        raise ValueError(f"--start {start} out of range 0..{total - 1}")

    if count is None:
        end = total
    else:
        if count <= 0:
            raise ValueError("--count must be > 0")
        end = min(total, start + count)

    return list(range(start, end))


def make_encryptor(check_encrypted: bool, key_hex: str):
    if not check_encrypted:
        return None

    key_hex = key_hex.strip()
    if len(key_hex) != 32:
        raise ValueError("--key-hex must be exactly 32 hex chars (16 bytes)")
    try:
        key = binascii.unhexlify(key_hex)
    except binascii.Error as exc:
        raise ValueError(f"Invalid --key-hex: {exc}") from exc

    try:
        from Crypto.Cipher import AES  # type: ignore
    except Exception as exc:
        raise RuntimeError(
            "--check-encrypted requires pycryptodome. Install: pip install pycryptodome"
        ) from exc

    cipher = AES.new(key, AES.MODE_ECB)
    return cipher.encrypt


def read_sector(fh, sector_index: int) -> bytes:
    if sector_index < 0:
        raise ValueError(f"Negative sector index: {sector_index}")
    fh.seek(sector_index * SECTOR_SIZE)
    data = fh.read(SECTOR_SIZE)
    if len(data) != SECTOR_SIZE:
        raise EOFError(f"Could not read full sector {sector_index}")
    return data


def first_mismatch(a: bytes, b: bytes) -> Optional[int]:
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return None


def fmt_bytes(b: bytes) -> str:
    return " ".join(f"{x:02X}" for x in b)


def format_16wide(data: bytes, base_offset: int = 0) -> str:
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        lines.append(f"    +0x{base_offset + i:03X}: {fmt_bytes(chunk)}")
    return "\n".join(lines)


def verify_one(
    fh,
    block_index: int,
    data_start_sector: int,
    expected_plain: bytes,
    encrypt_block,
) -> BlockResult:
    abs_sector = data_start_sector + block_index
    sec = read_sector(fh, abs_sector)

    sd_plain = sec[0:16]
    sd_enc = sec[16:32]
    sd_dec = sec[32:48]

    plain_ok = sd_plain == expected_plain
    dec_matches_plain = sd_dec == sd_plain
    dec_matches_expected = sd_dec == expected_plain

    if encrypt_block is None:
        expected_enc = None
        enc_check_run = False
        enc_ok = True
    else:
        expected_enc = encrypt_block(expected_plain)
        enc_check_run = True
        enc_ok = (sd_enc == expected_enc)

    # Detect the known sector-wide +1-byte shift symptom:
    #   sd_plain[1..15] == expected_plain[0..14]
    #   sd_enc[0]       == expected_plain[15]
    #   sd_dec[1..15]   ~= expected_plain[0..14]  (if dec should mirror plain)
    shift_bug_like = (
        sd_plain[1:] == expected_plain[:15]
        and sd_enc[0:1] == expected_plain[15:16]
        and (sd_dec[1:] == expected_plain[:15] or sd_dec[1:] == sd_plain[:15])
    )

    recovered_plain = sd_plain[1:16] + sd_enc[0:1]
    recovered_plain_ok = recovered_plain == expected_plain

    return BlockResult(
        index=block_index,
        abs_sector=abs_sector,
        expected_plain=expected_plain,
        sd_plain=sd_plain,
        sd_enc=sd_enc,
        sd_dec=sd_dec,
        expected_enc=expected_enc,
        plain_ok=plain_ok,
        dec_matches_plain=dec_matches_plain,
        dec_matches_expected=dec_matches_expected,
        enc_check_run=enc_check_run,
        enc_ok=enc_ok,
        shift_bug_like=shift_bug_like,
        recovered_plain=recovered_plain,
        recovered_plain_ok=recovered_plain_ok,
        sector_first64=sec[:64],
    )


def print_block_result(r: BlockResult, show_all: bool, dump_sector64: bool) -> bool:
    ok = r.plain_ok and r.dec_matches_plain and r.dec_matches_expected and r.enc_ok
    if ok and not show_all:
        return True

    sector_base = r.abs_sector * SECTOR_SIZE

    print(f"\n[Block {r.index}] {'PASS' if ok else 'FAIL'}")
    print(f"  DATA.BIN index         : {r.index}")
    print(f"  Absolute SD sector     : {r.abs_sector}")
    print(f"  Sector byte range      : {sector_base} .. {sector_base + 511}")
    print(f"  Plain location         : sector+0x000 .. +0x00F")
    print(f"  Encrypted location     : sector+0x010 .. +0x01F")
    print(f"  Decrypted location     : sector+0x020 .. +0x02F")

    print(f"  Expected Plain         : {fmt_bytes(r.expected_plain)}")
    print(f"  SD Plain               : {fmt_bytes(r.sd_plain)}")
    print(f"  SD Encrypted           : {fmt_bytes(r.sd_enc)}")
    print(f"  SD Decrypted           : {fmt_bytes(r.sd_dec)}")

    if r.enc_check_run and r.expected_enc is not None:
        print(f"  Expected Enc           : {fmt_bytes(r.expected_enc)}")

    if not r.plain_ok:
        mm = first_mismatch(r.sd_plain, r.expected_plain)
        print(f"  plain_vs_original      : FAIL (first mismatch byte {mm})")
    else:
        print("  plain_vs_original      : PASS")

    if not r.dec_matches_plain:
        mm = first_mismatch(r.sd_dec, r.sd_plain)
        print(f"  dec_vs_plain           : FAIL (first mismatch byte {mm})")
    else:
        print("  dec_vs_plain           : PASS")

    if not r.dec_matches_expected:
        mm = first_mismatch(r.sd_dec, r.expected_plain)
        print(f"  dec_vs_original        : FAIL (first mismatch byte {mm})")
    else:
        print("  dec_vs_original        : PASS")

    if r.enc_check_run:
        if r.enc_ok:
            print("  enc_vs_aes(key)        : PASS")
        else:
            mm = first_mismatch(r.sd_enc, r.expected_enc or b"")
            print(f"  enc_vs_aes(key)        : FAIL (first mismatch byte {mm})")
    else:
        print("  enc_vs_aes(key)        : SKIPPED (--check-encrypted not set)")

    if r.shift_bug_like:
        print("  shift_pattern_detected : YES (sector looks right-shifted by 1 byte)")
        print(f"  recovered_plain        : {fmt_bytes(r.recovered_plain)}")
        print(
            "  recovered_plain_check  : "
            + ("PASS" if r.recovered_plain_ok else "FAIL")
        )
    else:
        print("  shift_pattern_detected : NO")

    if dump_sector64:
        print("  Sector first 64 bytes:")
        print(format_16wide(r.sector_first64, base_offset=0))

    return ok


def print_neighbor_sectors(fh, center_index: int, data_start_sector: int) -> None:
    print("\n=== Neighbor Sector Scan (bytes 0..47) ===")
    for idx in range(center_index - 2, center_index + 3):
        if idx < 0:
            continue
        abs_sector = data_start_sector + idx
        sec = read_sector(fh, abs_sector)
        print(
            f"Index {idx:4d} -> AbsSector {abs_sector:6d}: "
            f"{fmt_bytes(sec[0:48])}"
        )


def main() -> int:
    args = parse_args()

    try:
        expected_blocks = load_expected_blocks(args.hex_file)
        indices = build_index_list(len(expected_blocks), args.index, args.start, args.count)
        encrypt_block = make_encryptor(args.check_encrypted, args.key_hex)
    except (ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}")
        return 2

    open_path = args.device

    print("=== SD Image Flow Verifier ===")
    print(f"Device/File             : {open_path}")
    print(f"Hex file                : {args.hex_file}")
    print(f"Data start sector       : {args.data_start_sector}")
    print(f"Blocks in hex           : {len(expected_blocks)}")
    print(f"Checking indices        : {indices[0]}..{indices[-1]} (count={len(indices)})")
    print(f"Encrypted check         : {'ON' if args.check_encrypted else 'OFF'}")

    pass_count = 0
    fail_count = 0

    try:
        with open(open_path, "rb") as fh:
            for idx in indices:
                r = verify_one(
                    fh=fh,
                    block_index=idx,
                    data_start_sector=args.data_start_sector,
                    expected_plain=expected_blocks[idx],
                    encrypt_block=encrypt_block,
                )
                ok = print_block_result(r, show_all=args.show_passing, dump_sector64=args.dump_sector64)
                if ok:
                    pass_count += 1
                else:
                    fail_count += 1

            if args.scan_neighbors:
                if len(indices) != 1:
                    print("\nNOTE: --scan-neighbors works with a single index. Use --index N.")
                else:
                    print_neighbor_sectors(fh, indices[0], args.data_start_sector)

    except PermissionError:
        print("ERROR: Permission denied. Run terminal as Administrator for raw physical drive access.")
        return 3
    except FileNotFoundError:
        print(f"ERROR: Device/file not found: {open_path}")
        return 3
    except EOFError as exc:
        print(f"ERROR: {exc}")
        return 3
    except OSError as exc:
        print(f"ERROR: Could not read '{open_path}': {exc}")
        return 3

    print("\n=== Summary ===")
    print(f"Pass: {pass_count}")
    print(f"Fail: {fail_count}")
    print(f"Total checked: {len(indices)}")

    if fail_count == 0:
        print("Result: ALL CHECKS PASSED")
        return 0

    print("Result: MISMATCH FOUND")
    return 1


if __name__ == "__main__":
    sys.exit(main())
