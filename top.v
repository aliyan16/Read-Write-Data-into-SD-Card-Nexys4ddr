// ============================================================
// top.v  --  SD Card Read/Write Test
// Nexys4 DDR  (Artix-7 XC7A100T)
//
// USER INTERFACE:
//   SW[0]     = Mode:  1=WRITE,  0=READ
//   SW[4:1]   = 4-bit digit to write  (0-9, use BCD)
//   SW[15:5]  = 11-bit address into DATA.BIN (blocks 0-2047, each block = 512 bytes)
//   BTNC      = Trigger: perform read or write operation
//   BTND      = Reset
//
//   7-SEG     = Shows digit read from SD card (rightmost display)
//
//   LED[0]    = SD init OK
//   LED[1]    = Write done
//   LED[2]    = Read done
//   LED[3]    = Busy
//   LED[15]   = Error
// ============================================================
module top (
    input  wire        CLK100MHZ,

    // Switches
    input  wire        SW0,      // Mode: 1=write 0=read
    input  wire [3:0]  SW4_1,    // Digit to write (SW4 MSB, SW1 LSB)
    input  wire [10:0] SW15_5,   // SD block address (SW15=MSB, SW5=LSB)

    // Buttons
    input  wire        BTNC,    // Trigger
    input  wire        BTND,    // Reset

    // SD card (J1 microSD slot)
    output wire        SD_RESET,
    output wire        SD_SCK,
    output wire        SD_CMD,   // MOSI
    input  wire        SD_DAT0,  // MISO
    output wire        SD_DAT3,  // CS (active low)
    input  wire        SD_CD,    // Card detect (unused, suppresses port warning)

    // 7-segment display
    output wire [7:0]  AN,
    output wire [6:0]  SEG,      // CA CB CC CD CE CF CG

    // LEDs
    output wire [15:0] LED
);

// ------------------------------------------------------------------
// Wires & Regs
// ------------------------------------------------------------------
wire btn_trig_pulse, btn_trig_level;
wire btn_rst_pulse,  btn_rst_level;

wire rst = btn_rst_level;

// SD controller
wire       sd_cs_w, sd_sclk_w, sd_mosi_w;
wire       init_done, init_err, busy;
wire [7:0] rd_data;
wire       rd_valid, rd_done;
wire       wr_done;
wire [4:0] debug_state;
wire [4:0] debug_last;

reg        rd_start  = 0;
reg        wr_start  = 0;
// FAT16 DATA.BIN starts at sector 20 (after boot+FAT+rootdir).
// SW15_5 selects which 512-byte block inside DATA.BIN to access.
wire [31:0] addr     = 32'd20 + {21'b0, SW15_5};
reg [7:0]  wr_byte   = 8'h00;

// Stored digit (last read from SD)
reg [3:0]  disp_digit   = 4'd0;
reg        show_digit    = 0;
reg        write_led     = 0;
reg        read_led      = 0;

// Suppress unused input warning for SD_CD
wire _unused_cd = SD_CD;

// ------------------------------------------------------------------
// Debounce buttons
// ------------------------------------------------------------------
debounce db_trig (
    .clk(CLK100MHZ), .btn_in(BTNC),
    .btn_out(btn_trig_level), .btn_pulse(btn_trig_pulse)
);

debounce db_rst (
    .clk(CLK100MHZ), .btn_in(BTND),
    .btn_out(btn_rst_level), .btn_pulse(btn_rst_pulse)
);

// ------------------------------------------------------------------
// Control FSM
// ------------------------------------------------------------------
reg [2:0] ctrl_state = 0;
localparam
    CS_IDLE    = 3'd0,
    CS_WAIT_WR = 3'd1,
    CS_WAIT_RD = 3'd2;

// First byte index during read capture
reg [9:0]  read_byte_cnt = 0;
reg [7:0]  first_byte    = 0;

always @(posedge CLK100MHZ) begin
    rd_start <= 0;
    wr_start <= 0;

    if (rst) begin
        ctrl_state    <= CS_IDLE;
        write_led     <= 0;
        read_led      <= 0;
        show_digit    <= 0;
        disp_digit    <= 0;
        read_byte_cnt <= 0;
        first_byte    <= 0;
        wr_byte       <= 0;
    end else begin

        case (ctrl_state)

        CS_IDLE: begin
            if (btn_trig_pulse && init_done && !busy) begin
                if (SW0 == 1'b1) begin
                    wr_byte    <= {4'h3, SW4_1};
                    wr_start   <= 1;
                    write_led  <= 0;
                    ctrl_state <= CS_WAIT_WR;
                end else begin
                    rd_start      <= 1;
                    read_led      <= 0;
                    show_digit    <= 0;
                    read_byte_cnt <= 0;
                    first_byte    <= 0;
                    ctrl_state    <= CS_WAIT_RD;
                end
            end
        end

        CS_WAIT_WR: begin
            if (wr_done) begin
                write_led  <= 1;
                ctrl_state <= CS_IDLE;
            end
        end

        CS_WAIT_RD: begin
            // Capture the very first byte of the 512-byte sector
            if (rd_valid) begin
                if (read_byte_cnt == 0) first_byte <= rd_data;
                read_byte_cnt <= read_byte_cnt + 1;
            end
            if (rd_done) begin
                // Decode: we stored ASCII digit → extract lower nibble
                disp_digit <= first_byte[3:0];
                show_digit <= 1;
                read_led   <= 1;
                ctrl_state <= CS_IDLE;
            end
        end

        default: ctrl_state <= CS_IDLE;

        endcase
    end
end

// ------------------------------------------------------------------
// SD Controller instance
// ------------------------------------------------------------------
sd_spi_controller sd0 (
    .clk       (CLK100MHZ),
    .rst       (rst),
    .sd_cs     (sd_cs_w),
    .sd_sclk   (sd_sclk_w),
    .sd_mosi   (sd_mosi_w),
    .sd_miso   (SD_DAT0),
    .sd_reset  (SD_RESET),
    .init_start(1'b1),
    .init_done (init_done),
    .init_err  (init_err),
    .rd_start  (rd_start),
    .rd_addr   (addr),
    .rd_data   (rd_data),
    .rd_valid  (rd_valid),
    .rd_done   (rd_done),
    .wr_start  (wr_start),
    .wr_addr   (addr),
    .wr_data   (wr_byte),
    .wr_done   (wr_done),
    .busy      (busy),
    .debug_state(debug_state),
    .debug_last (debug_last)
);

assign SD_SCK  = sd_sclk_w;
assign SD_CMD  = sd_mosi_w;
assign SD_DAT3 = sd_cs_w;

// ------------------------------------------------------------------
// 7-Segment Display
// ------------------------------------------------------------------
seven_seg seg_disp (
    .clk       (CLK100MHZ),
    .digit     (disp_digit),
    .show_digit(show_digit),
    .init_ok   (init_done),
    .error_flag(init_err),
    .an        (AN),
    .seg       (SEG)
);

// ------------------------------------------------------------------
// LEDs
// LED[4:0]  = unused
// LED[9:5]  = SD controller FSM state (for debugging)
// ------------------------------------------------------------------
assign LED[0]    = init_done;
assign LED[1]    = write_led;
assign LED[2]    = read_led;
assign LED[3]    = busy;
assign LED[4]    = 1'b0;
assign LED[9:5]  = debug_state;    // current state (24=ST_ERROR when broken)
assign LED[14:10]= debug_last;     // last state BEFORE error - this is the culprit
assign LED[15]   = init_err;

endmodule
