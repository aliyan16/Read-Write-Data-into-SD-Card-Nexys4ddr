# FPGA SD Card Reader/Writer — Project Summary

---

## What format_sd.py Did

The Python script wrote a **FAT16 filesystem structure** to the first 20 sectors
of your SD card (PhysicalDrive1). It did NOT erase your data — it only wrote
the filesystem "header" information so Windows/Linux can recognize the card.

### Sectors written to SD card:

```
Sector 0        → Boot Sector (tells OS: "this is FAT16, file DATA.BIN is here")
Sectors 1–9     → FAT Table copy 1 (File Allocation Table: maps clusters to file)
Sectors 10–18   → FAT Table copy 2 (backup copy, required by FAT spec)
Sector 19       → Root Directory   (one entry: "DATA.BIN", size=1MB, starts at cluster 2)
Sectors 20–2067 → DATA.BIN data area (1 MB = 2048 blocks × 512 bytes each)
                  ↑ FPGA reads and writes HERE
```

After running the script:
- Eject SD card → insert into PC → Windows shows **DATA.BIN (1 MB)**
- That file is the area the FPGA reads/writes using your switches

---

## How the Full System Works

### Hardware (FPGA — Nexys4 DDR)

```
SD Card ←——SPI bus——→ sd_spi_controller ←——→ top.v ←——→ Switches / Buttons / LEDs
```

#### Switch roles:

| Switch    | Purpose                                         |
|-----------|-------------------------------------------------|
| SW0       | Mode: 1 = WRITE,  0 = READ                      |
| SW[4:1]   | The digit to write (0–9 in BCD)                 |
| SW[15:5]  | Address: which 512-byte block of DATA.BIN       |

#### Button roles:

| Button | Purpose                        |
|--------|--------------------------------|
| BTNC   | Trigger: start read or write   |
| BTND   | Reset the FPGA                 |

#### LED indicators:

| LED    | Meaning               |
|--------|-----------------------|
| LED[0] | SD card initialized OK |
| LED[1] | Last write completed  |
| LED[2] | Last read completed   |
| LED[3] | Busy (operation in progress) |
| LED[15]| Error                 |

---

### Communication Protocol: SPI Mode

The FPGA talks to the SD card using **SPI** (Serial Peripheral Interface),
not the native SD protocol. SPI uses 4 wires:

```
FPGA pin SD_CMD  (MOSI) → sends data TO the SD card
FPGA pin SD_DAT0 (MISO) ← receives data FROM the SD card
FPGA pin SD_SCK         → clock signal (250 kHz)
FPGA pin SD_DAT3 (CS)   → chip select (active LOW)
```

---

### SD Card Initialization Sequence (automatic on power-up)

```
1. Power-up delay (250 ms)
2. Send 80 dummy clock pulses
3. CMD0  → reset card to idle state
4. CMD8  → check voltage compatibility
5. CMD55 + ACMD41 → initialize card (repeated until card reports ready)
6. LED[0] lights up = initialization complete
```

---

### Write Operation (SW0 = 1, press BTNC)

```
1. top.v captures: digit = SW[4:1],  address = 20 + SW[15:5]
2. Sends wr_start signal to sd_spi_controller
3. sd_spi_controller sends CMD24 (WRITE SINGLE BLOCK) with the address
4. Sends data token 0xFE to SD card
5. Sends 512 bytes — all equal to the digit byte (e.g. digit 5 = 0x35)
6. Sends 2 dummy CRC bytes
7. Waits for SD card to finish internal write
8. Sets wr_done → LED[1] lights up
```

What gets stored in DATA.BIN at offset (SW[15:5] × 512):
```
35 35 35 35 35 35 35 35 35 35 ... (512 bytes, all = 0x35 for digit 5)
```

---

### Read Operation (SW0 = 0, press BTNC)

```
1. top.v sets address = 20 + SW[15:5]
2. Sends rd_start signal to sd_spi_controller
3. sd_spi_controller sends CMD17 (READ SINGLE BLOCK) with the address
4. Waits for data token 0xFE from SD card
5. Reads all 512 bytes — captures only the FIRST byte
6. Extracts lower nibble of first byte → this is the digit
7. Sends digit to 7-segment display
8. Sets rd_done → LED[2] lights up
```

---

### Address Mapping (the key formula)

```
Physical SD block = 20 + SW[15:5]

SW[15:5] = 0    → SD sector 20  → DATA.BIN byte offset 0
SW[15:5] = 1    → SD sector 21  → DATA.BIN byte offset 512
SW[15:5] = 100  → SD sector 120 → DATA.BIN byte offset 51200
SW[15:5] = 2047 → SD sector 2067→ DATA.BIN byte offset 1,048,064
```

The number 20 is the FAT16 overhead (boot + FAT tables + root directory).
This offset makes the FPGA write into DATA.BIN instead of corrupting
the filesystem metadata.

---

### Reading DATA.BIN on Your PC

After the FPGA writes some data:
1. Power off FPGA, remove SD card
2. Insert SD card into PC
3. Open SD card in File Explorer → you see **DATA.BIN (1 MB)**
4. Open DATA.BIN with a hex editor (e.g. **HxD**, free download)
5. Navigate to offset `SW[15:5] × 512` to see your written bytes

Example — if you wrote digit 7 at address SW[15:5]=5:
- Open DATA.BIN in HxD
- Go to offset 5 × 512 = **2560 (0xA00)**
- You will see: `37 37 37 37 37 37 ...` (0x37 = ASCII '7')

---

## File List

| File              | Purpose                                              |
|-------------------|------------------------------------------------------|
| top.v             | Main FPGA logic: switches, buttons, LEDs, FSM        |
| sd_spi.v          | SD card SPI controller: CMD17 read, CMD24 write      |
| debounce.v        | Button debouncer                                     |
| sevenSeg.v        | 7-segment display driver                             |
| nexys4ddr.xdc     | Pin constraints (maps Verilog ports to FPGA pins)    |
| format_sd.py      | One-time PC script: writes FAT16 structure to SD card|
| SUMMARY.md        | This file                                            |
