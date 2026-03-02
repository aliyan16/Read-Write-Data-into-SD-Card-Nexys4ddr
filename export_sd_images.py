#!/usr/bin/env python3
r"""Export and view original/encrypted/decrypted image streams from SD card.

Reads current FPGA single-sector layout per DATA.BIN index:
- bytes  0..15: plain block
- bytes 16..31: encrypted block
- bytes 32..47: decrypted block

It concatenates these 16-byte chunks across indices and writes:
- plain_stream.bin, encrypted_stream.bin, decrypted_stream.bin
- plain.bmp (if BMP header is found in plain stream)
- decrypted.bmp (if BMP header is found in decrypted stream)
- encrypted_visual.ppm (always; noise-style preview)

Examples:
  python export_sd_images.py --device \\.\PhysicalDrive1 --blocks 197
  python export_sd_images.py --device \\.\PhysicalDrive1 --hex-file image_input.hex
  python export_sd_images.py --device \\.\PhysicalDrive1 --blocks 197 --recover-shift
  python export_sd_images.py --device DATA.BIN --file-mode --blocks 197
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
from pathlib import Path
from typing import Optional, Tuple

SECTOR_SIZE = 512
DEFAULT_DATA_START = 20
DEFAULT_BLOCK_SIZE = 16


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Export plain/encrypted/decrypted image data from SD sectors.")
    p.add_argument("--device", default=r"\\.\PhysicalDrive1", help="Raw drive path or file path.")
    p.add_argument("--file-mode", action="store_true", help="Treat --device as a regular file.")
    p.add_argument("--data-start-sector", type=int, default=DEFAULT_DATA_START, help="DATA.BIN start sector. Default 20.")
    p.add_argument("--start-index", type=int, default=0, help="Start DATA.BIN index (SW15_5).")
    p.add_argument("--blocks", type=int, default=None, help="Number of indices to read.")
    p.add_argument("--hex-file", default="image_input.hex", help="Used only to infer block count if --blocks is omitted.")
    p.add_argument("--outdir", default="sd_exports", help="Output directory.")
    p.add_argument(
        "--recover-shift",
        action="store_true",
        help=(
            "Recover known historical +1 byte write-shift bug in sd_spi.v. "
            "Use only for data written with old buggy bitstream."
        ),
    )
    p.add_argument("--open", action="store_true", help="Open generated image files on Windows.")
    return p.parse_args()


def infer_blocks(hex_file: str) -> Optional[int]:
    p = Path(hex_file)
    if not p.exists():
        return None
    cnt = 0
    for ln in p.read_text(encoding="ascii", errors="ignore").splitlines():
        if ln.strip():
            cnt += 1
    return cnt if cnt > 0 else None


def read_sector(fh, sector_index: int) -> bytes:
    if sector_index < 0:
        raise ValueError(f"Negative sector index: {sector_index}")
    fh.seek(sector_index * SECTOR_SIZE)
    data = fh.read(SECTOR_SIZE)
    if len(data) != SECTOR_SIZE:
        raise EOFError(f"Could not read full sector {sector_index}")
    return data


def stream_from_sd(
    fh,
    start_index: int,
    blocks: int,
    data_start_sector: int,
    recover_shift: bool,
) -> Tuple[bytes, bytes, bytes]:
    plain = bytearray()
    enc = bytearray()
    dec = bytearray()

    for idx in range(start_index, start_index + blocks):
        sec = read_sector(fh, data_start_sector + idx)
        p = sec[0:16]
        e = sec[16:32]
        d = sec[32:48]

        if recover_shift:
            # Recover historical bug pattern (sector-wide +1 byte shift)
            p = p[1:16] + e[0:1]
            e = e[1:16] + d[0:1]
            d = d[1:16] + sec[48:49]

        plain.extend(p)
        enc.extend(e)
        dec.extend(d)

    return bytes(plain), bytes(enc), bytes(dec)


def extract_bmp(blob: bytes) -> Optional[Tuple[bytes, int, int, int, int]]:
    """Return (bmp_bytes, start_off, file_size, width, height) if valid BMP found."""
    start = blob.find(b"BM")
    if start < 0:
        return None
    if len(blob) < start + 54:
        return None

    file_size = struct.unpack_from("<I", blob, start + 2)[0]
    pix_off = struct.unpack_from("<I", blob, start + 10)[0]
    dib_size = struct.unpack_from("<I", blob, start + 14)[0]

    if dib_size < 40:
        return None
    if file_size <= 54 or start + file_size > len(blob):
        return None

    width = struct.unpack_from("<i", blob, start + 18)[0]
    height = struct.unpack_from("<i", blob, start + 22)[0]
    bpp = struct.unpack_from("<H", blob, start + 28)[0]
    comp = struct.unpack_from("<I", blob, start + 30)[0]

    if width == 0 or height == 0:
        return None
    if bpp not in (24, 32, 8):
        return None
    if comp != 0:
        return None
    if pix_off >= file_size:
        return None

    return blob[start:start + file_size], start, file_size, abs(width), abs(height)


def nonzero_indices(blob: bytes, block_size: int = DEFAULT_BLOCK_SIZE) -> list[int]:
    idxs: list[int] = []
    for i in range(0, len(blob), block_size):
        if any(blob[i:i + block_size]):
            idxs.append(i // block_size)
    return idxs


def write_encrypted_visual_ppm(enc_blob: bytes, out_path: Path, width: int, height: int) -> None:
    pix_n = width * height * 3
    raw = enc_blob[:pix_n]
    if len(raw) < pix_n:
        raw = raw + (b"\x00" * (pix_n - len(raw)))
    header = f"P6\n{width} {height}\n255\n".encode("ascii")
    out_path.write_bytes(header + raw)


def reverse_each_block(blob: bytes, block_size: int = DEFAULT_BLOCK_SIZE) -> bytes:
    if block_size <= 0:
        return blob
    out = bytearray()
    for i in range(0, len(blob), block_size):
        out.extend(blob[i:i + block_size][::-1])
    return bytes(out)


def try_open(paths) -> None:
    if os.name != "nt":
        return
    for p in paths:
        try:
            os.startfile(str(p))  # type: ignore[attr-defined]
        except Exception:
            pass


def main() -> int:
    args = parse_args()

    blocks = args.blocks
    if blocks is None:
        blocks = infer_blocks(args.hex_file)
    if blocks is None:
        print("ERROR: Provide --blocks, or ensure --hex-file exists and has lines.")
        return 2

    if blocks <= 0:
        print("ERROR: --blocks must be > 0")
        return 2
    if args.start_index < 0:
        print("ERROR: --start-index must be >= 0")
        return 2

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    print("=== SD Image Export ===")
    print(f"Source               : {args.device}")
    print(f"Mode                 : {'file' if args.file_mode else 'raw-device'}")
    print(f"DATA.BIN start sector: {args.data_start_sector}")
    print(f"Index range          : {args.start_index}..{args.start_index + blocks - 1} (count={blocks})")
    print(f"Recover shift bug    : {'ON' if args.recover_shift else 'OFF'}")
    print(f"Output dir           : {outdir}")

    try:
        with open(args.device, "rb") as fh:
            plain_blob, enc_blob, dec_blob = stream_from_sd(
                fh=fh,
                start_index=args.start_index,
                blocks=blocks,
                data_start_sector=args.data_start_sector,
                recover_shift=args.recover_shift,
            )
    except PermissionError:
        print("ERROR: Permission denied. Run as Administrator for raw physical drive access.")
        return 3
    except FileNotFoundError:
        print(f"ERROR: Source not found: {args.device}")
        return 3
    except (EOFError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}")
        return 3

    plain_bin = outdir / "plain_stream.bin"
    enc_bin = outdir / "encrypted_stream.bin"
    dec_bin = outdir / "decrypted_stream.bin"
    plain_bin.write_bytes(plain_blob)
    enc_bin.write_bytes(enc_blob)
    dec_bin.write_bytes(dec_blob)

    print(f"Wrote: {plain_bin}")
    print(f"Wrote: {enc_bin}")
    print(f"Wrote: {dec_bin}")

    p_nz = nonzero_indices(plain_blob)
    e_nz = nonzero_indices(enc_blob)
    d_nz = nonzero_indices(dec_blob)
    print(
        "Non-zero 16B blocks   : "
        f"plain={len(p_nz)}, enc={len(e_nz)}, dec={len(d_nz)} out of {blocks}"
    )
    if len(p_nz) < blocks or len(d_nz) < blocks:
        def head(xs: list[int]) -> str:
            if not xs:
                return "none"
            return ", ".join(str(x) for x in xs[:12]) + (" ..." if len(xs) > 12 else "")
        print("Warning: stream is sparse/incomplete. This usually means only a few SW15_5 indices were written on FPGA.")
        print(f"  Plain non-zero idx   : {head(p_nz)}")
        print(f"  Decrypt non-zero idx : {head(d_nz)}")

    opened = []

    plain_for_bmp = plain_blob
    plain_bmp_info = extract_bmp(plain_for_bmp)
    plain_transform = "raw"
    if not plain_bmp_info:
        plain_for_bmp = reverse_each_block(plain_blob)
        plain_bmp_info = extract_bmp(plain_for_bmp)
        if plain_bmp_info:
            plain_transform = "reverse-each-16B"

    if plain_bmp_info:
        plain_bmp_bytes, off, fsz, w, h = plain_bmp_info
        plain_bmp = outdir / "plain.bmp"
        plain_bmp.write_bytes(plain_bmp_bytes)
        print(
            f"Wrote: {plain_bmp}  "
            f"(transform={plain_transform}, BMP offset={off}, size={fsz}, {w}x{h})"
        )
        opened.append(plain_bmp)
    else:
        w = 32
        h = 32
        print("Plain BMP header not found in exported stream.")
        print("Hint: ensure indices 0..196 were all written (BTNC/BTNU/BTNR per index), then export again.")

    dec_for_bmp = dec_blob
    dec_bmp_info = extract_bmp(dec_for_bmp)
    dec_transform = "raw"
    if not dec_bmp_info:
        dec_for_bmp = reverse_each_block(dec_blob)
        dec_bmp_info = extract_bmp(dec_for_bmp)
        if dec_bmp_info:
            dec_transform = "reverse-each-16B"

    if dec_bmp_info:
        dec_bmp_bytes, off, fsz, dw, dh = dec_bmp_info
        dec_bmp = outdir / "decrypted.bmp"
        dec_bmp.write_bytes(dec_bmp_bytes)
        print(
            f"Wrote: {dec_bmp}  "
            f"(transform={dec_transform}, BMP offset={off}, size={fsz}, {dw}x{dh})"
        )
        opened.append(dec_bmp)
    else:
        print("Decrypted BMP header not found in exported stream.")
        print("Hint: decrypted BMP appears only when decrypted blocks are complete and contiguous.")

    enc_ppm = outdir / "encrypted_visual.ppm"
    write_encrypted_visual_ppm(enc_blob, enc_ppm, w, h)
    print(f"Wrote: {enc_ppm}  (visualized from encrypted bytes)")
    opened.append(enc_ppm)

    if args.open:
        try_open(opened)

    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
