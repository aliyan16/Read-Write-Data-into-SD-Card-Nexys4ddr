// ============================================================
// top.v -- Autonomous SD -> AES -> SD image pipeline
//
// FLOW:
//   1. After SD init, preload the image metadata block, AES key, and
//      original image blocks from image.hex into DATA.BIN sectors.
//   2. BTNC starts one full operation over every 16-byte image block:
//        read key from SD
//        read plaintext image block from SD
//        AES encrypt
//        write ciphertext block to SD
//        read ciphertext block back from SD
//        AES decrypt
//        write decrypted block to SD
//   3. Verification passes only if every ciphertext readback matches
//      what was written and every decrypted block matches plaintext.
//
// SD LAYOUT (DATA.BIN sectors 20+):
//   sector 20               : image metadata block from image.hex[0]
//   sector 21               : AES key block
//   sectors 22..217         : original image blocks (196 x 16-byte blocks)
//   sectors 218..413        : encrypted image blocks
//   sectors 414..609        : decrypted image blocks
//
// Each sector carries exactly one 16-byte payload in bytes 0..15.
// Bytes 16..511 are zero.
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
localparam [31:0] DATA_BASE_ADDR      = 32'd20;
localparam [31:0] META_SECTOR         = DATA_BASE_ADDR + 32'd0;
localparam [31:0] KEY_SECTOR          = DATA_BASE_ADDR + 32'd1;
localparam [31:0] PLAIN_BASE_SECTOR   = DATA_BASE_ADDR + 32'd2;
localparam [127:0] ROM_KEY_BLOCK      = 128'h000102030405060708090A0B0C0D0E0F;

localparam integer IMAGE_ROM_BLOCKS = 197;
localparam integer IMAGE_FILE_BLOCKS = 196;
localparam [31:0] IMAGE_FILE_SIZE_BYTES = 32'h00000C36;
reg [7:0] image_rom_addr = 8'd0;
wire [127:0] image_rom_dout;
reg [127:0] rom_block = 128'd0;

image_rom_bram image_rom_u (
    .clk (CLK100MHZ),
    .addr(image_rom_addr),
    .dout(image_rom_dout)
);

localparam [31:0] CT_BASE_SECTOR      = PLAIN_BASE_SECTOR + IMAGE_FILE_BLOCKS;
localparam [31:0] DEC_BASE_SECTOR     = CT_BASE_SECTOR + IMAGE_FILE_BLOCKS;

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

// ------------------------------------------------------------------
// Write source / read target selectors
// ------------------------------------------------------------------
localparam [2:0]
    WS_META    = 3'd0,
    WS_KEY     = 3'd1,
    WS_ROM_IMG = 3'd2,
    WS_CT      = 3'd3,
    WS_DEC     = 3'd4;

localparam [1:0]
    RT_NONE = 2'd0,
    RT_KEY  = 2'd1,
    RT_PT   = 2'd2,
    RT_CT   = 2'd3;

reg [2:0] wr_source = WS_META;
reg [1:0] rd_target = RT_NONE;
reg [4:0] rd_capture_idx = 5'd0;
reg [8:0] preload_idx = 9'd0;
reg [8:0] block_idx   = 9'd0;

reg [127:0] wr_block;

always @(*) begin
    case (wr_source)
        WS_META:    wr_block = rom_block;
        WS_KEY:     wr_block = ROM_KEY_BLOCK;
        WS_ROM_IMG: wr_block = rom_block;
        WS_CT:      wr_block = ct_block;
        default:    wr_block = dec_block;
    endcase
end

wire [7:0] wr_byte;
assign wr_byte =
    (wr_byte_idx < 9'd16) ? block_byte(wr_block, wr_byte_idx[3:0]) :
                            8'h00;

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

reg preload_done   = 1'b0;
reg ct_write_done  = 1'b0;
reg dec_write_done = 1'b0;
reg verify_pass    = 1'b0;
reg op_done        = 1'b0;
reg op_error       = 1'b0;
reg all_ct_match   = 1'b0;
reg all_dec_match  = 1'b0;

localparam [4:0]
    ST_WAIT_INIT         = 5'd0,
    ST_PRELOAD_META_REQ  = 5'd1,
    ST_PRELOAD_META_LATCH= 5'd2,
    ST_PRELOAD_META_WAIT = 5'd3,
    ST_PRELOAD_KEY_WAIT  = 5'd4,
    ST_PRELOAD_IMG_REQ   = 5'd5,
    ST_PRELOAD_IMG_LATCH = 5'd6,
    ST_PRELOAD_IMG_WAIT  = 5'd7,
    ST_IDLE_READY        = 5'd8,
    ST_READ_KEY_WAIT     = 5'd9,
    ST_READ_PT_WAIT      = 5'd10,
    ST_ENC_WAIT_CLR      = 5'd11,
    ST_ENC_WAIT_DONE     = 5'd12,
    ST_WRITE_CT_WAIT     = 5'd13,
    ST_READ_CT_WAIT      = 5'd14,
    ST_DEC_WAIT_CLR      = 5'd15,
    ST_DEC_WAIT_DONE     = 5'd16,
    ST_WRITE_DEC_WAIT    = 5'd17,
    ST_DONE              = 5'd18,
    ST_ERROR             = 5'd19;

reg [4:0] ctrl_state = ST_WAIT_INIT;

wire local_busy =
    (ctrl_state != ST_WAIT_INIT) &&
    (ctrl_state != ST_IDLE_READY) &&
    (ctrl_state != ST_DONE) &&
    (ctrl_state != ST_ERROR);

wire error_flag = init_err | op_error;
wire [4:0] led_debug_state = error_flag ? debug_last : debug_state;
wire [3:0] ui_digit =
    error_flag ? debug_last[3:0] :
    ((!init_done && busy) ? debug_state[3:0] : disp_digit);
wire ui_show_digit = show_digit | (!init_done && busy) | error_flag;

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
        wr_source       <= WS_META;
        preload_idx     <= 9'd0;
        block_idx       <= 9'd0;
        image_rom_addr  <= 8'd0;
        rom_block       <= 128'd0;
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
        all_ct_match    <= 1'b0;
        all_dec_match   <= 1'b0;
    end else begin
        if (rd_valid && (rd_capture_idx < 5'd16)) begin
            case (rd_target)
                RT_KEY: key_block[rd_capture_idx*8 +: 8]     <= rd_data;
                RT_PT:  pt_block[rd_capture_idx*8 +: 8]      <= rd_data;
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
                        disp_digit  <= DISP_PRELOAD;
                        show_digit  <= 1'b1;
                        image_rom_addr <= 8'd0;
                        ctrl_state  <= ST_PRELOAD_META_REQ;
                    end
                end

                ST_PRELOAD_META_REQ: begin
                    ctrl_state <= ST_PRELOAD_META_LATCH;
                end

                ST_PRELOAD_META_LATCH: begin
                    rom_block <= image_rom_dout;
                    wr_source <= WS_META;
                    sd_addr   <= META_SECTOR;
                    wr_start  <= 1'b1;
                    ctrl_state <= ST_PRELOAD_META_WAIT;
                end

                ST_PRELOAD_META_WAIT: begin
                    if (wr_done) begin
                        wr_source  <= WS_KEY;
                        sd_addr    <= KEY_SECTOR;
                        wr_start   <= 1'b1;
                        ctrl_state <= ST_PRELOAD_KEY_WAIT;
                    end
                end

                ST_PRELOAD_KEY_WAIT: begin
                    if (wr_done) begin
                        preload_idx <= 9'd0;
                        image_rom_addr <= 8'd1;
                        ctrl_state  <= ST_PRELOAD_IMG_REQ;
                    end
                end

                ST_PRELOAD_IMG_REQ: begin
                    ctrl_state <= ST_PRELOAD_IMG_LATCH;
                end

                ST_PRELOAD_IMG_LATCH: begin
                    rom_block  <= image_rom_dout;
                    wr_source  <= WS_ROM_IMG;
                    sd_addr    <= PLAIN_BASE_SECTOR + preload_idx;
                    wr_start   <= 1'b1;
                    ctrl_state <= ST_PRELOAD_IMG_WAIT;
                end

                ST_PRELOAD_IMG_WAIT: begin
                    if (wr_done) begin
                        if (preload_idx == IMAGE_FILE_BLOCKS - 1) begin
                            preload_done <= 1'b1;
                            disp_digit   <= DISP_IDLE;
                            ctrl_state   <= ST_IDLE_READY;
                        end else begin
                            preload_idx <= preload_idx + 1'b1;
                            image_rom_addr <= preload_idx + 9'd2;
                            ctrl_state  <= ST_PRELOAD_IMG_REQ;
                        end
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
                        all_ct_match   <= 1'b1;
                        all_dec_match  <= 1'b1;
                        block_idx      <= 9'd0;
                        pt_block       <= 128'd0;
                        key_block      <= 128'd0;
                        ct_block       <= 128'd0;
                        ct_read_block  <= 128'd0;
                        dec_block      <= 128'd0;
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
                        pt_block       <= 128'd0;
                        rd_target      <= RT_PT;
                        rd_capture_idx <= 5'd0;
                        sd_addr        <= PLAIN_BASE_SECTOR + block_idx;
                        rd_start       <= 1'b1;
                        disp_digit     <= DISP_READ_PT;
                        ctrl_state     <= ST_READ_PT_WAIT;
                    end
                end

                ST_READ_PT_WAIT: begin
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
                        sd_addr     <= CT_BASE_SECTOR + block_idx;
                        wr_start    <= 1'b1;
                        disp_digit  <= DISP_WRITE_CT;
                        ctrl_state  <= ST_WRITE_CT_WAIT;
                    end
                end

                ST_WRITE_CT_WAIT: begin
                    if (wr_done) begin
                        if (block_idx == IMAGE_FILE_BLOCKS - 1) begin
                            ct_write_done <= 1'b1;
                        end
                        ct_read_block  <= 128'd0;
                        rd_target      <= RT_CT;
                        rd_capture_idx <= 5'd0;
                        sd_addr        <= CT_BASE_SECTOR + block_idx;
                        rd_start       <= 1'b1;
                        disp_digit     <= DISP_READ_CT;
                        ctrl_state     <= ST_READ_CT_WAIT;
                    end
                end

                ST_READ_CT_WAIT: begin
                    if (rd_done) begin
                        all_ct_match  <= all_ct_match & (ct_read_block == ct_block);
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
                        dec_block     <= aes_dec_out;
                        all_dec_match <= all_dec_match & (aes_dec_out == pt_block);
                        wr_source     <= WS_DEC;
                        sd_addr       <= DEC_BASE_SECTOR + block_idx;
                        wr_start      <= 1'b1;
                        disp_digit    <= DISP_WRITE_DC;
                        ctrl_state    <= ST_WRITE_DEC_WAIT;
                    end
                end

                ST_WRITE_DEC_WAIT: begin
                    if (wr_done) begin
                        if (block_idx == IMAGE_FILE_BLOCKS - 1) begin
                            dec_write_done <= 1'b1;
                            verify_pass    <= all_ct_match & all_dec_match;
                            op_done        <= 1'b1;
                            disp_digit     <= (all_ct_match & all_dec_match) ? DISP_PASS : DISP_FAIL;
                            ctrl_state     <= ST_DONE;
                        end else begin
                            block_idx      <= block_idx + 1'b1;
                            pt_block       <= 128'd0;
                            ct_block       <= 128'd0;
                            ct_read_block  <= 128'd0;
                            dec_block      <= 128'd0;
                            rd_target      <= RT_PT;
                            rd_capture_idx <= 5'd0;
                            sd_addr        <= PLAIN_BASE_SECTOR + block_idx + 32'd1;
                            rd_start       <= 1'b1;
                            disp_digit     <= DISP_READ_PT;
                            ctrl_state     <= ST_READ_PT_WAIT;
                        end
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
    .digit     (ui_digit),
    .show_digit(ui_show_digit),
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
assign LED[5]      = all_ct_match;
assign LED[6]      = busy | local_busy;
assign LED[9:7]    = 3'b000;
assign LED[14:10]  = led_debug_state;
assign LED[15]     = error_flag;

// Keep otherwise-unused signals tied to avoid warnings.
wire _unused_btn_levels = btn_start_level ^ btn_rst_pulse;
wire [31:0] _unused_image_file_size;
assign _unused_image_file_size = IMAGE_FILE_SIZE_BYTES;

endmodule

module image_rom_bram (
    input  wire        clk,
    input  wire [7:0]  addr,
    output reg  [127:0] dout
);

(* rom_style = "block", ram_style = "block" *)
reg [127:0] image_rom [0:255];
integer i;

initial begin
    for (i = 0; i < 256; i = i + 1) begin
        image_rom[i] = 128'd0;
    end
`include "image_rom.vh"
end

always @(posedge clk) begin
    dout <= image_rom[addr];
end

endmodule
