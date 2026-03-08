#!/usr/bin/env python3
"""
Convert an image file into the FPGA image pipeline format.

Outputs:
    image.hex        - 128-bit blocks, one per line
                       block 0 = metadata (file size in first 4 bytes, big-endian)
                       block 1..N = image file bytes, padded to 16-byte boundary
    image_rom.vh     - Verilog include generated from image.hex
    image_meta.txt   - file size, image block count, total ROM block count
    original_image.* - reference copy of the source image (or generated pattern)

Usage:
    python image_to_hex.py
    python image_to_hex.py --width 32 --height 32
    python image_to_hex.py my_image.bmp
"""

import math
import os
import shutil
import sys


def generate_test_pattern(width, height):
    pixels = bytearray(width * height)

    cx, cy = width // 2, height // 2
    radius = min(width, height) // 4

    for y in range(height):
        for x in range(width):
            check = ((x // 8) + (y // 8)) % 2
            val = 200 if check else 55

            if y >= height - height // 8:
                val = int(255 * x / (width - 1))

            if abs(x - y) <= 1 or abs(x - (width - 1 - y)) <= 1:
                val = 128

            dx = x - cx
            dy = y - cy
            dist = math.sqrt(dx * dx + dy * dy)
            if abs(dist - radius) < 2.0:
                val = 0

            if x == 0 or y == 0 or x == width - 1 or y == height - 1:
                val = 255

            pixels[y * width + x] = val

    return bytes(pixels)


def build_pgm_bytes(width, height, pixels):
    header = f"P5\n{width} {height}\n255\n".encode("ascii")
    return header + pixels


def parse_args(argv):
    width = 32
    height = 32
    image_file = None

    args = argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--width" and i + 1 < len(args):
            width = int(args[i + 1])
            i += 2
        elif args[i] == "--height" and i + 1 < len(args):
            height = int(args[i + 1])
            i += 2
        elif args[i] in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        elif not args[i].startswith("-"):
            image_file = args[i]
            i += 1
        else:
            raise SystemExit(f"Unknown argument: {args[i]}")

    return width, height, image_file


def make_metadata_block(file_size):
    return file_size.to_bytes(4, "big") + (b"\x00" * 12)


def write_image_hex(path, metadata_block, file_bytes):
    padded = file_bytes + (b"\x00" * ((16 - (len(file_bytes) % 16)) % 16))
    blob = metadata_block + padded

    with open(path, "w", encoding="ascii") as fh:
        for idx in range(0, len(blob), 16):
            fh.write(blob[idx:idx + 16].hex().upper() + "\n")


def write_image_rom_vh(image_hex_path, output_path):
    with open(image_hex_path, "r", encoding="ascii") as fh:
        lines = [line.strip().upper() for line in fh if line.strip()]

    with open(output_path, "w", encoding="ascii") as fh:
        fh.write("// Auto-generated from image.hex\n")
        fh.write("// Included inside top.v initial begin ... end\n")
        fh.write("// Each 128-bit constant is byte-reversed so block_byte(idx=0) emits the\n")
        fh.write("// original left-to-right bytes from image.hex onto the SD card.\n")
        for idx, line in enumerate(lines):
            rev = "".join(reversed([line[i:i + 2] for i in range(0, len(line), 2)]))
            fh.write(f"    image_rom[{idx}] = 128'h{rev};\n")


def main():
    width, height, image_file = parse_args(sys.argv)

    if image_file:
        with open(image_file, "rb") as fh:
            file_bytes = fh.read()
        source_ext = os.path.splitext(image_file)[1] or ".bin"
        ref_name = "original_image" + source_ext
        shutil.copyfile(image_file, ref_name)
        print(f"Loaded source image: {image_file} ({len(file_bytes)} bytes)", file=sys.stderr)
    else:
        pixels = generate_test_pattern(width, height)
        file_bytes = build_pgm_bytes(width, height, pixels)
        ref_name = "original_image.pgm"
        with open(ref_name, "wb") as fh:
            fh.write(file_bytes)
        print(f"Generated test pattern: {width}x{height} grayscale PGM", file=sys.stderr)

    file_size = len(file_bytes)
    file_blocks = (file_size + 15) // 16
    total_rom_blocks = file_blocks + 1

    metadata_block = make_metadata_block(file_size)
    write_image_hex("image.hex", metadata_block, file_bytes)
    write_image_rom_vh("image.hex", "image_rom.vh")

    with open("image_meta.txt", "w", encoding="ascii") as fh:
        fh.write(f"{file_size}\n")
        fh.write(f"{file_blocks}\n")
        fh.write(f"{total_rom_blocks}\n")

    print(f"Reference image : {ref_name}", file=sys.stderr)
    print(f"File size       : {file_size} bytes", file=sys.stderr)
    print(f"Image blocks    : {file_blocks}", file=sys.stderr)
    print(f"Total ROM blocks: {total_rom_blocks}", file=sys.stderr)
    print("Files: image.hex, image_rom.vh, image_meta.txt", file=sys.stderr)


if __name__ == "__main__":
    main()
