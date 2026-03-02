// ============================================================
// top.v -- Single-sector Image Plain/Encrypt/Decrypt flow
//
// FLOW:
//   BTNC : load plain image block into selected sector
//   BTNU : encrypt current plain block, store in same selected sector
//   BTNR : decrypt current encrypted block, store in same selected sector
//   BTNL : clear selected sector payload
//
// STORAGE LAYOUT INSIDE ONE 512-byte SECTOR:
//   bytes  0..15  : plain AES block
//   bytes 16..31  : encrypted AES block
//   bytes 32..47  : decrypted AES block
//   bytes 48..511 : 0x00
// ============================================================
module top (
    input  wire        CLK100MHZ,

    // Switches
    input  wire        SW0,       // unused (kept for pin compatibility)
    input  wire [3:0]  SW4_1,     // unused in image flow (kept for pin compatibility)
    input  wire [10:0] SW15_5,    // image block index + sector index

    // Buttons
    input  wire        BTNC,      // load image + write plain
    input  wire        BTNU,      // encrypt
    input  wire        BTNR,      // decrypt
    input  wire        BTNL,      // clear
    input  wire        BTND,      // reset

    // SD card (J1 microSD slot)
    output wire        SD_RESET,
    output wire        SD_SCK,
    output wire        SD_CMD,
    input  wire        SD_DAT0,
    output wire        SD_DAT3,
    input  wire        SD_CD,

    // 7-segment display
    output wire [7:0]  AN,
    output wire [6:0]  SEG,

    // LEDs
    output wire [15:0] LED
);

// ------------------------------------------------------------------
// Debounced buttons
// ------------------------------------------------------------------
wire btn_wr_pulse,  btn_wr_level;
wire btn_enc_pulse, btn_enc_level;
wire btn_dec_pulse, btn_dec_level;
wire btn_clr_pulse, btn_clr_level;
wire btn_rst_pulse, btn_rst_level;
wire rst = btn_rst_level;

debounce db_wr  (.clk(CLK100MHZ), .btn_in(BTNC), .btn_out(btn_wr_level),  .btn_pulse(btn_wr_pulse));
debounce db_enc (.clk(CLK100MHZ), .btn_in(BTNU), .btn_out(btn_enc_level), .btn_pulse(btn_enc_pulse));
debounce db_dec (.clk(CLK100MHZ), .btn_in(BTNR), .btn_out(btn_dec_level), .btn_pulse(btn_dec_pulse));
debounce db_clr (.clk(CLK100MHZ), .btn_in(BTNL), .btn_out(btn_clr_level), .btn_pulse(btn_clr_pulse));
debounce db_rst (.clk(CLK100MHZ), .btn_in(BTND), .btn_out(btn_rst_level), .btn_pulse(btn_rst_pulse));

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

reg        rd_start = 1'b0; // unused in this flow
reg        wr_start = 1'b0;
reg [31:0] sd_addr  = 32'd20;

assign SD_SCK  = sd_sclk_w;
assign SD_CMD  = sd_mosi_w;
assign SD_DAT3 = sd_cs_w;

wire [31:0] input_addr  = 32'd20 + {21'b0, SW15_5};

// ------------------------------------------------------------------
// AES engine
// ------------------------------------------------------------------
localparam [127:0] AES_KEY = 128'h00112233445566778899AABBCCDDEEFF;
localparam integer IMAGE_BLOCK_COUNT_I = 197;
localparam [10:0]  IMAGE_BLOCK_COUNT   = 11'd197;

reg [127:0] image_rom [0:IMAGE_BLOCK_COUNT_I-1];

initial begin
    $readmemh("image_input.hex", image_rom);
end

reg  [127:0] plain_block     = 128'd0;
reg  [127:0] enc_block       = 128'd0;
reg  [127:0] dec_block       = 128'd0;
reg  [127:0] dec_input_block = 128'd0;

reg  aes_enc_start = 1'b0;
wire aes_enc_done;
wire [127:0] aes_enc_out;

reg  aes_dec_start = 1'b0;
wire aes_dec_done;
wire [127:0] aes_dec_out;

ASMD_Encryption aes_enc_u (
    .done         (aes_enc_done),
    .Dout         (aes_enc_out),
    .plain_text_in(plain_block),
    .key_in       (AES_KEY),
    .encrypt      (aes_enc_start),
    .clock        (CLK100MHZ),
    .reset        (rst)
);

ASMD_Decryption aes_dec_u (
    .done             (aes_dec_done),
    .Dout             (aes_dec_out),
    .encrypted_text_in(dec_input_block),
    .key_in           (AES_KEY),
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

wire [7:0] wr_byte =
    (wr_byte_idx < 9'd16) ? block_byte(plain_block, wr_byte_idx[3:0]) :
    (wr_byte_idx < 9'd32) ? block_byte(enc_block,   wr_byte_idx[3:0]) :
    (wr_byte_idx < 9'd48) ? block_byte(dec_block,   wr_byte_idx[3:0]) :
                            8'h00;

// ------------------------------------------------------------------
// UI & Control FSM
// ------------------------------------------------------------------
reg [3:0] disp_digit = 4'd0;
reg       show_digit = 1'b0;
reg [2:0] disp_msg   = 3'd0;

reg write_led = 1'b0;
reg enc_led   = 1'b0;
reg dec_led   = 1'b0;
reg clr_led   = 1'b0;

reg [31:0] op_addr = 32'd20;

reg [3:0] ctrl_state = 4'd0;
localparam [2:0]
    MSG_IDLE = 3'd0,
    MSG_LOAD = 3'd1,
    MSG_ENC  = 3'd2,
    MSG_DEC  = 3'd3,
    MSG_CLR  = 3'd4;

localparam [3:0]
    CS_IDLE           = 4'd0,
    CS_WAIT_WR_PLAIN  = 4'd1,
    CS_ENC_START      = 4'd2,
    CS_ENC_WAIT_CLR   = 4'd3,
    CS_ENC_WAIT_DONE  = 4'd4,
    CS_WAIT_WR_ENC    = 4'd5,
    CS_DEC_START      = 4'd6,
    CS_DEC_WAIT_CLR   = 4'd7,
    CS_DEC_WAIT_DONE  = 4'd8,
    CS_WAIT_WR_DEC    = 4'd9,
    CS_WAIT_WR_CLR    = 4'd10,
    CS_PREP_WR_PLAIN  = 4'd11,
    CS_PREP_WR_ENC    = 4'd12,
    CS_PREP_WR_DEC    = 4'd13,
    CS_PREP_WR_CLR    = 4'd14;

always @(posedge CLK100MHZ) begin
    rd_start      <= 1'b0;
    wr_start      <= 1'b0;
    aes_enc_start <= 1'b0;
    aes_dec_start <= 1'b0;

    if (rst) begin
        ctrl_state      <= CS_IDLE;
        sd_addr         <= 32'd20;
        op_addr         <= 32'd20;
        plain_block     <= 128'd0;
        enc_block       <= 128'd0;
        dec_block       <= 128'd0;
        dec_input_block <= 128'd0;
        disp_digit      <= 4'd0;
        show_digit      <= 1'b0;
        disp_msg        <= MSG_IDLE;
        write_led       <= 1'b0;
        enc_led         <= 1'b0;
        dec_led         <= 1'b0;
        clr_led         <= 1'b0;
    end else begin
        case (ctrl_state)
            CS_IDLE: begin
                if (init_done && !busy) begin
                    if (btn_wr_pulse) begin
                        write_led   <= 1'b0;
                        enc_led     <= 1'b0;
                        dec_led     <= 1'b0;
                        clr_led     <= 1'b0;

                        // Load one 16-byte image block selected by SW15_5.
                        if (SW15_5 < IMAGE_BLOCK_COUNT) begin
                            plain_block <= image_rom[SW15_5];
                        end else begin
                            plain_block <= 128'd0;
                        end
                        enc_block   <= 128'd0;
                        dec_block   <= 128'd0;

                        op_addr     <= input_addr;
                        ctrl_state  <= CS_PREP_WR_PLAIN;
                    end else if (btn_enc_pulse) begin
                        write_led      <= 1'b0;
                        enc_led        <= 1'b0;
                        dec_led        <= 1'b0;
                        clr_led        <= 1'b0;

                        op_addr        <= input_addr;
                        ctrl_state     <= CS_ENC_START;
                    end else if (btn_dec_pulse) begin
                        write_led      <= 1'b0;
                        enc_led        <= 1'b0;
                        dec_led        <= 1'b0;
                        clr_led        <= 1'b0;

                        dec_input_block <= enc_block;
                        op_addr         <= input_addr;
                        ctrl_state      <= CS_DEC_START;
                    end else if (btn_clr_pulse) begin
                        write_led   <= 1'b0;
                        enc_led     <= 1'b0;
                        dec_led     <= 1'b0;
                        clr_led     <= 1'b0;

                        plain_block <= 128'd0;
                        enc_block   <= 128'd0;
                        dec_block   <= 128'd0;

                        op_addr     <= input_addr;
                        ctrl_state  <= CS_PREP_WR_CLR;
                    end
                end
            end

            CS_PREP_WR_PLAIN: begin
                sd_addr    <= op_addr;
                wr_start   <= 1'b1;
                ctrl_state <= CS_WAIT_WR_PLAIN;
            end

            CS_WAIT_WR_PLAIN: begin
                if (wr_done) begin
                    write_led  <= 1'b1;
                    disp_digit <= plain_block[3:0];
                    show_digit <= 1'b1;
                    disp_msg   <= MSG_LOAD;
                    ctrl_state <= CS_IDLE;
                end
            end

            CS_ENC_START: begin
                aes_enc_start <= 1'b1;
                ctrl_state    <= CS_ENC_WAIT_CLR;
            end

            CS_ENC_WAIT_CLR: begin
                if (!aes_enc_done) ctrl_state <= CS_ENC_WAIT_DONE;
            end

            CS_ENC_WAIT_DONE: begin
                if (aes_enc_done) begin
                    enc_block  <= aes_enc_out;
                    ctrl_state <= CS_PREP_WR_ENC;
                end
            end

            CS_PREP_WR_ENC: begin
                sd_addr    <= op_addr;
                wr_start   <= 1'b1;
                ctrl_state <= CS_WAIT_WR_ENC;
            end

            CS_WAIT_WR_ENC: begin
                if (wr_done) begin
                    enc_led    <= 1'b1;
                    disp_digit <= aes_enc_out[3:0];
                    show_digit <= 1'b1;
                    disp_msg   <= MSG_ENC;
                    ctrl_state <= CS_IDLE;
                end
            end

            CS_DEC_START: begin
                aes_dec_start <= 1'b1;
                ctrl_state    <= CS_DEC_WAIT_CLR;
            end

            CS_DEC_WAIT_CLR: begin
                if (!aes_dec_done) ctrl_state <= CS_DEC_WAIT_DONE;
            end

            CS_DEC_WAIT_DONE: begin
                if (aes_dec_done) begin
                    dec_block  <= aes_dec_out;
                    ctrl_state <= CS_PREP_WR_DEC;
                end
            end

            CS_PREP_WR_DEC: begin
                sd_addr    <= op_addr;
                wr_start   <= 1'b1;
                ctrl_state <= CS_WAIT_WR_DEC;
            end

            CS_WAIT_WR_DEC: begin
                if (wr_done) begin
                    dec_led    <= 1'b1;
                    disp_digit <= aes_dec_out[3:0];
                    show_digit <= 1'b1;
                    disp_msg   <= MSG_DEC;
                    ctrl_state <= CS_IDLE;
                end
            end

            CS_PREP_WR_CLR: begin
                sd_addr    <= op_addr;
                wr_start   <= 1'b1;
                ctrl_state <= CS_WAIT_WR_CLR;
            end

            CS_WAIT_WR_CLR: begin
                if (wr_done) begin
                    clr_led    <= 1'b1;
                    disp_digit <= 4'd0;
                    show_digit <= 1'b1;
                    disp_msg   <= MSG_CLR;
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
    .status_msg(disp_msg),
    .init_ok   (init_done),
    .error_flag(init_err),
    .an        (AN),
    .seg       (SEG)
);

// ------------------------------------------------------------------
// LEDs
// ------------------------------------------------------------------
assign LED[0]      = init_done;
assign LED[1]      = write_led;
assign LED[2]      = enc_led;
assign LED[3]      = dec_led;
assign LED[4]      = clr_led;
assign LED[5]      = 1'b0;
assign LED[6]      = busy;
assign LED[9:7]    = 3'b000;
assign LED[14:10]  = debug_last;
assign LED[15]     = init_err;

// Keep otherwise-unused ports tied to avoid warnings.
wire _unused_sw0 = SW0;
wire _unused_sw41 = ^SW4_1;
wire _unused_cd  = SD_CD;
wire _unused_btn_levels = btn_wr_level ^ btn_enc_level ^ btn_dec_level ^ btn_clr_level ^ btn_rst_pulse;
wire _unused_rd = rd_valid ^ rd_done ^ rd_data[0];
wire [4:0] _unused_debug_state = debug_state;

endmodule
