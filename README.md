# SD Reader/Writer + AES Image Pipeline

This repository contains a Nexys4 DDR FPGA design that:

- initializes a microSD card in SPI mode
- preloads image blocks into `DATA.BIN`
- encrypts and decrypts the image block-by-block with AES
- verifies the ciphertext and decrypted image written back to the SD card

## Repository Layout

```text
top.v                  Top-level image pipeline
sd_spi.v               SD SPI controller
sevenSeg.v             7-segment display driver
debounce.v             Button debouncer
image_rom.vh           Generated image ROM contents
image.hex              Generated image blocks
aes_vectors.hex        Legacy 3-block AES test vectors
image_to_hex.py        Image -> hex/.vh generator
format_sd.py           FAT16 formatter for the SD card
verify_sd.py           SD verification / image reconstruction tool
nexys4ddr_minimal.xdc  Current constraints file
Aes-Code/              AES encryption/decryption RTL
docs/                  Supporting notes and documentation
```

## Current SD Layout

The active image pipeline uses these `DATA.BIN` sectors:

- sector `20`: image metadata block
- sector `21`: AES key block
- sectors `22..217`: original image blocks
- sectors `218..413`: encrypted image blocks
- sectors `414..609`: decrypted image blocks

Each 512-byte sector stores one 16-byte AES block in bytes `0..15`.
Bytes `16..511` are zero-filled.

## Buttons

- `BTNC`: start one full encrypt/decrypt run
- `BTND`: reset FPGA and rerun SD init/preload

## LED Status

- `LED[0]`: SD init done
- `LED[1]`: preload done
- `LED[2]`: ciphertext write phase completed
- `LED[3]`: decrypted write phase completed
- `LED[4]`: overall verify pass
- `LED[5]`: all ciphertext checks matched
- `LED[6]`: controller busy
- `LED[14:10]`: SD debug state
- `LED[15]`: error

## 7-Segment Debug

The rightmost 7-seg digit shows:

- live SD init state while the controller is initializing
- failing SD state when an error occurs
- pipeline status digit during normal operation

Common SD init states:

- `0` = `ST_PWRUP`
- `1` = `ST_PWRDLY`
- `2` = `ST_DUMMY`
- `3` = `ST_CMD0`
- `4` = `ST_CMD0_RESP`
- `5` = `ST_CMD8`
- `6` = `ST_CMD8_RESP`
- `7` = `ST_CMD55`
- `8` = `ST_CMD55_RESP`
- `9` = `ST_ACMD41`
- `A` = `ST_ACMD41_RESP`
- `B` = `ST_READY`

## Verification

Run as Administrator:

```powershell
python verify_sd.py \\.\PhysicalDrive1
```

The verifier reads the FAT16 layout, reconstructs the original/encrypted/decrypted
image outputs, and opens the generated files for inspection.
