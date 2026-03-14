// ============================================================
// top.v -- Autonomous SD -> AES -> SD pipeline
//
// FLOW:
//   1. After SD init, preload plaintext/key/expected-ct vectors
//      from aes_vectors.hex into fixed DATA.BIN sectors.
//   2. BTNC starts one full operation:
//        read plaintext from SD
//        read key from SD
//        AES encrypt
//        write ciphertext to SD
//        read ciphertext back from SD
//        AES decrypt
//        write decrypted text to SD
//   3. LEDs show init/preload/write/verify progress.
//
// SD LAYOUT (DATA.BIN sectors 20+):
//   sector 20 : plaintext     bytes 0..15 valid
//   sector 21 : AES key       bytes 0..15 valid
//   sector 22 : expected ct   bytes 0..15 valid
//   sector 23 : ciphertext    bytes 0..15 valid
//   sector 24 : decrypted     bytes 0..15 valid
//
// Byte order:
//   block_byte(idx=0) writes blk[7:0] first, so SD bytes are the
//   little-endian byte view of the 128-bit register value.
//   Read capture uses the same mapping, so the AES cores see the
//   original 128-bit word values from aes_vectors.hex.
// ============================================================
module top (
    input  wire        CLK100MHZ,

    // Buttons
    input  wire        BTNC,      // start operation
    input  wire        BTND,      // reset

    // SD card (J1 microSD slot)
    output wire        SD_RESET,
    output wire        SD_SCK,
    output wire        SD_CMD,
    input  wire        SD_DAT0,
    output wire        SD_DAT3,

    // 7-segment display
    output wire [7:0]  AN,
    output wire [6:0]  SEG,

    // LEDs
    output wire [15:0] LED
);

// ------------------------------------------------------------------
// Debounced buttons
// ------------------------------------------------------------------
wire btn_start_pulse, btn_start_level;
wire btn_rst_pulse, btn_rst_level;
wire rst = btn_rst_level;

debounce db_start (.clk(CLK100MHZ), .btn_in(BTNC), .btn_out(btn_start_level), .btn_pulse(btn_start_pulse));
debounce db_rst   (.clk(CLK100MHZ), .btn_in(BTND), .btn_out(btn_rst_level),   .btn_pulse(btn_rst_pulse));

// ------------------------------------------------------------------
// SD controller I/O
// ------------------------------------------------------------------
wire       sd_cs_w, sd_sclk_w, sd_mosi_w;
wire       init_done, init_err, busy;
wire [7:0] rd_data;
wire       rd_valid, rd_done;
wire       wr_done;
wire [8:0] wr_byte_idx;
wire [4:0] debug_state;
wire [4:0] debug_last;

reg        rd_start = 1'b0;
reg        wr_start = 1'b0;
reg [31:0] sd_addr  = 32'd20;

assign SD_SCK  = sd_sclk_w;
assign SD_CMD  = sd_mosi_w;
assign SD_DAT3 = sd_cs_w;

// ------------------------------------------------------------------
// Fixed sector map
// ------------------------------------------------------------------
localparam [31:0] DATA_BASE_ADDR = 32'd20;
localparam [31:0] PT_SECTOR      = DATA_BASE_ADDR + 32'd0;
localparam [31:0] KEY_SECTOR     = DATA_BASE_ADDR + 32'd1;
localparam [31:0] EXP_SECTOR     = DATA_BASE_ADDR + 32'd2;
localparam [31:0] CT_SECTOR      = DATA_BASE_ADDR + 32'd3;
localparam [31:0] DEC_SECTOR     = DATA_BASE_ADDR + 32'd4;

// ------------------------------------------------------------------
// AES vectors preloaded into SD after init.
// Keep them as HDL constants instead of relying on $readmemh so the
// synthesized bitstream always contains the expected test data.
// ------------------------------------------------------------------
localparam [127:0] ROM_PLAIN_BLOCK = 128'h00112233445566778899AABBCCDDEEFF;
localparam [127:0] ROM_KEY_BLOCK   = 128'h000102030405060708090A0B0C0D0E0F;
localparam [127:0] ROM_EXP_BLOCK   = 128'h69C4E0D86A7B0430D8CDB78070B4C55A;

// ------------------------------------------------------------------
// AES engine and working registers
// ------------------------------------------------------------------
reg  [127:0] pt_block      = 128'd0;
reg  [127:0] key_block     = 128'd0;
reg  [127:0] ct_block      = 128'd0;
reg  [127:0] ct_read_block = 128'd0;
reg  [127:0] dec_block     = 128'd0;

reg  aes_enc_start = 1'b0;
wire aes_enc_done;
wire [127:0] aes_enc_out;

reg  aes_dec_start = 1'b0;
wire aes_dec_done;
wire [127:0] aes_dec_out;

ASMD_Encryption aes_enc_u (
    .done         (aes_enc_done),
    .Dout         (aes_enc_out),
    .plain_text_in(pt_block),
    .key_in       (key_block),
    .encrypt      (aes_enc_start),
    .clock        (CLK100MHZ),
    .reset        (rst)
);

ASMD_Decryption aes_dec_u (
    .done             (aes_dec_done),
    .Dout             (aes_dec_out),
    .encrypted_text_in(ct_read_block),
    .key_in           (key_block),
    .decrypt          (aes_dec_start),
    .clock            (CLK100MHZ),
    .reset            (rst)
);

function [7:0] block_byte;
    input [127:0] blk;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  block_byte = blk[7:0];
            4'd1:  block_byte = blk[15:8];
            4'd2:  block_byte = blk[23:16];
            4'd3:  block_byte = blk[31:24];
            4'd4:  block_byte = blk[39:32];
            4'd5:  block_byte = blk[47:40];
            4'd6:  block_byte = blk[55:48];
            4'd7:  block_byte = blk[63:56];
            4'd8:  block_byte = blk[71:64];
            4'd9:  block_byte = blk[79:72];
            4'd10: block_byte = blk[87:80];
            4'd11: block_byte = blk[95:88];
            4'd12: block_byte = blk[103:96];
            4'd13: block_byte = blk[111:104];
            4'd14: block_byte = blk[119:112];
            4'd15: block_byte = blk[127:120];
            default: block_byte = 8'h00;
        endcase
    end
endfunction

localparam [2:0]
    WS_ROM_PT  = 3'd0,
    WS_ROM_KEY = 3'd1,
    WS_ROM_EXP = 3'd2,
    WS_CT      = 3'd3,
    WS_DEC     = 3'd4;

reg [2:0] wr_source = WS_ROM_PT;

wire [127:0] wr_block =
    (wr_source == WS_ROM_PT)  ? ROM_PLAIN_BLOCK :
    (wr_source == WS_ROM_KEY) ? ROM_KEY_BLOCK   :
    (wr_source == WS_ROM_EXP) ? ROM_EXP_BLOCK   :
                                (wr_source == WS_CT)      ? ct_block        :
                                                            dec_block;

wire [7:0] wr_byte =
    (wr_byte_idx < 9'd16) ? block_byte(wr_block, wr_byte_idx[3:0]) :
                            8'h00;

// ------------------------------------------------------------------
// Read capture helpers
// ------------------------------------------------------------------
localparam [1:0]
    RT_NONE = 2'd0,
    RT_PT   = 2'd1,
    RT_KEY  = 2'd2,
    RT_CT   = 2'd3;

reg [1:0] rd_target = RT_NONE;
reg [4:0] rd_capture_idx = 5'd0;

// ------------------------------------------------------------------
// UI / status / control
// ------------------------------------------------------------------
reg [3:0] disp_digit = 4'd0;
reg       show_digit = 1'b0;

localparam [3:0]
    DISP_IDLE     = 4'h0,
    DISP_PRELOAD  = 4'h1,
    DISP_READ_PT  = 4'h2,
    DISP_READ_KEY = 4'h3,
    DISP_ENC      = 4'h4,
    DISP_WRITE_CT = 4'h5,
    DISP_READ_CT  = 4'h6,
    DISP_DEC      = 4'h7,
    DISP_WRITE_DC = 4'h8,
    DISP_PASS     = 4'h9,
    DISP_FAIL     = 4'hA,
    DISP_ERROR    = 4'hE;

reg preload_done = 1'b0;
reg ct_write_done = 1'b0;
reg dec_write_done = 1'b0;
reg verify_pass = 1'b0;
reg op_done = 1'b0;
reg op_error = 1'b0;
reg ct_match = 1'b0;
reg dec_match = 1'b0;

localparam [4:0]
    ST_WAIT_INIT        = 5'd0,
    ST_PRELOAD_PT       = 5'd1,
    ST_PRELOAD_PT_WAIT  = 5'd2,
    ST_PRELOAD_KEY      = 5'd3,
    ST_PRELOAD_KEY_WAIT = 5'd4,
    ST_PRELOAD_EXP      = 5'd5,
    ST_PRELOAD_EXP_WAIT = 5'd6,
    ST_IDLE_READY       = 5'd7,
    ST_READ_PT          = 5'd8,
    ST_READ_PT_WAIT     = 5'd9,
    ST_READ_KEY         = 5'd10,
    ST_READ_KEY_WAIT    = 5'd11,
    ST_ENC_START        = 5'd12,
    ST_ENC_WAIT_CLR     = 5'd13,
    ST_ENC_WAIT_DONE    = 5'd14,
    ST_WRITE_CT         = 5'd15,
    ST_WRITE_CT_WAIT    = 5'd16,
    ST_READ_CT          = 5'd17,
    ST_READ_CT_WAIT     = 5'd18,
    ST_DEC_START        = 5'd19,
    ST_DEC_WAIT_CLR     = 5'd20,
    ST_DEC_WAIT_DONE    = 5'd21,
    ST_WRITE_DEC        = 5'd22,
    ST_WRITE_DEC_WAIT   = 5'd23,
    ST_DONE             = 5'd24,
    ST_ERROR            = 5'd25;

reg [4:0] ctrl_state = ST_WAIT_INIT;

wire local_busy =
    (ctrl_state != ST_WAIT_INIT) &&
    (ctrl_state != ST_IDLE_READY) &&
    (ctrl_state != ST_DONE) &&
    (ctrl_state != ST_ERROR);

wire error_flag = init_err | op_error;

always @(posedge CLK100MHZ) begin
    rd_start      <= 1'b0;
    wr_start      <= 1'b0;
    aes_enc_start <= 1'b0;
    aes_dec_start <= 1'b0;

    if (rst) begin
        ctrl_state      <= ST_WAIT_INIT;
        sd_addr         <= DATA_BASE_ADDR;
        rd_target       <= RT_NONE;
        rd_capture_idx  <= 5'd0;
        wr_source       <= WS_ROM_PT;
        pt_block        <= 128'd0;
        key_block       <= 128'd0;
        ct_block        <= 128'd0;
        ct_read_block   <= 128'd0;
        dec_block       <= 128'd0;
        disp_digit      <= DISP_IDLE;
        show_digit      <= 1'b0;
        preload_done    <= 1'b0;
        ct_write_done   <= 1'b0;
        dec_write_done  <= 1'b0;
        verify_pass     <= 1'b0;
        op_done         <= 1'b0;
        op_error        <= 1'b0;
        ct_match        <= 1'b0;
        dec_match       <= 1'b0;
    end else begin
        if (rd_valid && (rd_capture_idx < 5'd16)) begin
            case (rd_target)
                RT_PT:  pt_block[rd_capture_idx*8 +: 8]      <= rd_data;
                RT_KEY: key_block[rd_capture_idx*8 +: 8]     <= rd_data;
                RT_CT:  ct_read_block[rd_capture_idx*8 +: 8] <= rd_data;
                default: begin end
            endcase
            rd_capture_idx <= rd_capture_idx + 1'b1;
        end

        if (init_err) begin
            ctrl_state <= ST_ERROR;
            op_error   <= 1'b1;
            disp_digit <= DISP_ERROR;
            show_digit <= 1'b1;
        end else begin
            case (ctrl_state)
                ST_WAIT_INIT: begin
                    disp_digit <= DISP_IDLE;
                    show_digit <= 1'b0;
                    if (init_done && !busy) begin
                        wr_source   <= WS_ROM_PT;
                        sd_addr     <= PT_SECTOR;
                        wr_start    <= 1'b1;
                        disp_digit  <= DISP_PRELOAD;
                        show_digit  <= 1'b1;
                        ctrl_state  <= ST_PRELOAD_PT_WAIT;
                    end
                end

                ST_PRELOAD_PT_WAIT: begin
                    if (wr_done) begin
                        wr_source  <= WS_ROM_KEY;
                        sd_addr    <= KEY_SECTOR;
                        wr_start   <= 1'b1;
                        ctrl_state <= ST_PRELOAD_KEY_WAIT;
                    end
                end

                ST_PRELOAD_KEY_WAIT: begin
                    if (wr_done) begin
                        wr_source  <= WS_ROM_EXP;
                        sd_addr    <= EXP_SECTOR;
                        wr_start   <= 1'b1;
                        ctrl_state <= ST_PRELOAD_EXP_WAIT;
                    end
                end

                ST_PRELOAD_EXP_WAIT: begin
                    if (wr_done) begin
                        preload_done <= 1'b1;
                        disp_digit   <= DISP_IDLE;
                        ctrl_state   <= ST_IDLE_READY;
                    end
                end

                ST_IDLE_READY: begin
                    show_digit <= 1'b1;
                    disp_digit <= op_done ? (verify_pass ? DISP_PASS : DISP_FAIL) : DISP_IDLE;
                    if (btn_start_pulse && !busy) begin
                        ct_write_done  <= 1'b0;
                        dec_write_done <= 1'b0;
                        verify_pass    <= 1'b0;
                        op_done        <= 1'b0;
                        op_error       <= 1'b0;
                        ct_match       <= 1'b0;
                        dec_match      <= 1'b0;
                        pt_block       <= 128'd0;
                        key_block      <= 128'd0;
                        ct_block       <= 128'd0;
                        ct_read_block  <= 128'd0;
                        dec_block      <= 128'd0;
                        rd_target      <= RT_PT;
                        rd_capture_idx <= 5'd0;
                        sd_addr        <= PT_SECTOR;
                        rd_start       <= 1'b1;
                        disp_digit     <= DISP_READ_PT;
                        ctrl_state     <= ST_READ_PT_WAIT;
                    end
                end

                ST_READ_PT_WAIT: begin
                    if (rd_done) begin
                        rd_target      <= RT_KEY;
                        rd_capture_idx <= 5'd0;
                        sd_addr        <= KEY_SECTOR;
                        rd_start       <= 1'b1;
                        disp_digit     <= DISP_READ_KEY;
                        ctrl_state     <= ST_READ_KEY_WAIT;
                    end
                end

                ST_READ_KEY_WAIT: begin
                    if (rd_done) begin
                        aes_enc_start <= 1'b1;
                        disp_digit    <= DISP_ENC;
                        ctrl_state    <= ST_ENC_WAIT_CLR;
                    end
                end

                ST_ENC_WAIT_CLR: begin
                    if (!aes_enc_done) begin
                        ctrl_state <= ST_ENC_WAIT_DONE;
                    end
                end

                ST_ENC_WAIT_DONE: begin
                    if (aes_enc_done) begin
                        ct_block    <= aes_enc_out;
                        wr_source   <= WS_CT;
                        sd_addr     <= CT_SECTOR;
                        wr_start    <= 1'b1;
                        disp_digit  <= DISP_WRITE_CT;
                        ctrl_state  <= ST_WRITE_CT_WAIT;
                    end
                end

                ST_WRITE_CT_WAIT: begin
                    if (wr_done) begin
                        ct_write_done <= 1'b1;
                        ct_read_block <= 128'd0;
                        rd_target     <= RT_CT;
                        rd_capture_idx<= 5'd0;
                        sd_addr       <= CT_SECTOR;
                        rd_start      <= 1'b1;
                        disp_digit    <= DISP_READ_CT;
                        ctrl_state    <= ST_READ_CT_WAIT;
                    end
                end

                ST_READ_CT_WAIT: begin
                    if (rd_done) begin
                        ct_match      <= (ct_read_block == ROM_EXP_BLOCK);
                        aes_dec_start <= 1'b1;
                        disp_digit    <= DISP_DEC;
                        ctrl_state    <= ST_DEC_WAIT_CLR;
                    end
                end

                ST_DEC_WAIT_CLR: begin
                    if (!aes_dec_done) begin
                        ctrl_state <= ST_DEC_WAIT_DONE;
                    end
                end

                ST_DEC_WAIT_DONE: begin
                    if (aes_dec_done) begin
                        dec_block   <= aes_dec_out;
                        dec_match   <= (aes_dec_out == pt_block);
                        wr_source   <= WS_DEC;
                        sd_addr     <= DEC_SECTOR;
                        wr_start    <= 1'b1;
                        disp_digit  <= DISP_WRITE_DC;
                        ctrl_state  <= ST_WRITE_DEC_WAIT;
                    end
                end

                ST_WRITE_DEC_WAIT: begin
                    if (wr_done) begin
                        dec_write_done <= 1'b1;
                        verify_pass    <= ct_match && dec_match;
                        op_done        <= 1'b1;
                        disp_digit     <= (ct_match && dec_match) ? DISP_PASS : DISP_FAIL;
                        ctrl_state     <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    ctrl_state <= ST_IDLE_READY;
                end

                ST_ERROR: begin
                    show_digit <= 1'b1;
                    disp_digit <= DISP_ERROR;
                end

                default: begin
                    ctrl_state <= ST_ERROR;
                    op_error   <= 1'b1;
                end
            endcase
        end
    end
end

// ------------------------------------------------------------------
// SD Controller instance
// ------------------------------------------------------------------
sd_spi_controller sd0 (
    .clk        (CLK100MHZ),
    .rst        (rst),
    .sd_cs      (sd_cs_w),
    .sd_sclk    (sd_sclk_w),
    .sd_mosi    (sd_mosi_w),
    .sd_miso    (SD_DAT0),
    .sd_reset   (SD_RESET),
    .init_start (1'b1),
    .init_done  (init_done),
    .init_err   (init_err),
    .rd_start   (rd_start),
    .rd_addr    (sd_addr),
    .rd_data    (rd_data),
    .rd_valid   (rd_valid),
    .rd_done    (rd_done),
    .wr_start   (wr_start),
    .wr_addr    (sd_addr),
    .wr_data    (wr_byte),
    .wr_byte_idx(wr_byte_idx),
    .wr_done    (wr_done),
    .busy       (busy),
    .debug_state(debug_state),
    .debug_last (debug_last)
);

// ------------------------------------------------------------------
// 7-segment display
// ------------------------------------------------------------------
seven_seg seg_disp (
    .clk       (CLK100MHZ),
    .digit     (disp_digit),
    .show_digit(show_digit),
    .init_ok   (init_done),
    .error_flag(error_flag),
    .an        (AN),
    .seg       (SEG)
);

// ------------------------------------------------------------------
// LEDs
// ------------------------------------------------------------------
assign LED[0]      = init_done;
assign LED[1]      = preload_done;
assign LED[2]      = ct_write_done;
assign LED[3]      = dec_write_done;
assign LED[4]      = verify_pass;
assign LED[5]      = ct_match;
assign LED[6]      = busy | local_busy;
assign LED[9:7]    = 3'b000;
assign LED[14:10]  = debug_last;
assign LED[15]     = error_flag;

// Keep otherwise-unused signals tied to avoid warnings.
wire _unused_btn_levels = btn_start_level ^ btn_rst_pulse;
wire [4:0] _unused_debug_state = debug_state;

endmodule
