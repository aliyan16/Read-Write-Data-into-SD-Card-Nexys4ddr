// ============================================================
// top.v -- SD + AES with separate action buttons
//
// Controls:
//   SW0=1 + BTNC : write switch digit to selected location
//   SW0=0 + BTNC : read selected location and show on 7-seg
//   BTNU         : encrypt selected location, write to next location
//   BTNR         : decrypt selected location, write to next location
//   BTNL         : delete selected location (write zeros)
//   BTND         : reset
// ============================================================
module top (
    input  wire        CLK100MHZ,

    // Switches
    input  wire        SW0,       // 1=write, 0=read (for BTNC)
    input  wire [3:0]  SW4_1,     // digit input (BCD)
    input  wire [10:0] SW15_5,    // DATA.BIN block address (0..2047)

    // Buttons
    input  wire        BTNC,      // read/write action
    input  wire        BTNU,      // encrypt action
    input  wire        BTNR,      // decrypt action
    input  wire        BTNL,      // delete action
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
wire btn_rw_pulse,  btn_rw_level;
wire btn_enc_pulse, btn_enc_level;
wire btn_dec_pulse, btn_dec_level;
wire btn_del_pulse, btn_del_level;
wire btn_rst_pulse, btn_rst_level;
wire rst = btn_rst_level;

debounce db_rw (
    .clk(CLK100MHZ), .btn_in(BTNC),
    .btn_out(btn_rw_level), .btn_pulse(btn_rw_pulse)
);

debounce db_enc (
    .clk(CLK100MHZ), .btn_in(BTNU),
    .btn_out(btn_enc_level), .btn_pulse(btn_enc_pulse)
);

debounce db_dec (
    .clk(CLK100MHZ), .btn_in(BTNR),
    .btn_out(btn_dec_level), .btn_pulse(btn_dec_pulse)
);

debounce db_del (
    .clk(CLK100MHZ), .btn_in(BTNL),
    .btn_out(btn_del_level), .btn_pulse(btn_del_pulse)
);

debounce db_rst (
    .clk(CLK100MHZ), .btn_in(BTND),
    .btn_out(btn_rst_level), .btn_pulse(btn_rst_pulse)
);

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
// Address/data helpers
// ------------------------------------------------------------------
wire [31:0] input_addr = 32'd20 + {21'b0, SW15_5};
wire [31:0] next_addr  = (SW15_5 == 11'd2047) ? input_addr : (input_addr + 32'd1);
wire [7:0]  input_ascii = {4'h3, SW4_1};

// ------------------------------------------------------------------
// AES engine signals
// ------------------------------------------------------------------
localparam [127:0] AES_KEY = 128'h00112233445566778899AABBCCDDEEFF;

reg  [127:0] read_block      = 128'd0;
reg  [127:0] plain_block     = 128'd0;
reg  [127:0] dec_input_block = 128'd0;
reg  [127:0] block_to_write  = 128'd0;

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

wire [7:0] wr_byte = (wr_byte_idx < 9'd16) ? block_byte(block_to_write, wr_byte_idx[3:0]) : 8'h00;

// ------------------------------------------------------------------
// UI state
// ------------------------------------------------------------------
reg [3:0] disp_digit = 4'd0;
reg       show_digit = 1'b0;

reg write_led = 1'b0;
reg read_led  = 1'b0;
reg enc_led   = 1'b0;
reg dec_led   = 1'b0;
reg del_led   = 1'b0;

reg [9:0] read_byte_cnt = 10'd0;
reg [1:0] read_mode = 2'd0;
reg [31:0] op_src_addr = 32'd20;
reg [31:0] op_dst_addr = 32'd21;
localparam [1:0]
    RM_NORMAL  = 2'd0,
    RM_ENCRYPT = 2'd1,
    RM_DECRYPT = 2'd2;

reg [4:0] ctrl_state = 5'd0;
localparam [4:0]
    CS_IDLE             = 5'd0,
    CS_WAIT_WR_WRITE    = 5'd1,
    CS_WAIT_RD_NORMAL   = 5'd2,
    CS_WAIT_RD_CRYPT    = 5'd3,
    CS_ENC_START        = 5'd4,
    CS_ENC_WAIT_CLR     = 5'd5,
    CS_ENC_WAIT_DONE    = 5'd6,
    CS_WAIT_WR_ENC      = 5'd7,
    CS_DEC_START        = 5'd8,
    CS_DEC_WAIT_CLR     = 5'd9,
    CS_DEC_WAIT_DONE    = 5'd10,
    CS_WAIT_WR_DEC      = 5'd11,
    CS_WAIT_WR_DELETE   = 5'd12;

always @(posedge CLK100MHZ) begin
    rd_start      <= 1'b0;
    wr_start      <= 1'b0;
    aes_enc_start <= 1'b0;
    aes_dec_start <= 1'b0;

    if (rst) begin
        ctrl_state      <= CS_IDLE;
        sd_addr         <= 32'd20;
        read_block      <= 128'd0;
        plain_block     <= 128'd0;
        dec_input_block <= 128'd0;
        block_to_write  <= 128'd0;
        read_byte_cnt   <= 10'd0;
        read_mode       <= RM_NORMAL;
        op_src_addr     <= 32'd20;
        op_dst_addr     <= 32'd21;
        disp_digit      <= 4'd0;
        show_digit      <= 1'b0;
        write_led       <= 1'b0;
        read_led        <= 1'b0;
        enc_led         <= 1'b0;
        dec_led         <= 1'b0;
        del_led         <= 1'b0;
    end else begin
        case (ctrl_state)
            CS_IDLE: begin
                if (init_done && !busy) begin
                    if (btn_rw_pulse) begin
                        write_led <= 1'b0;
                        read_led  <= 1'b0;
                        enc_led   <= 1'b0;
                        dec_led   <= 1'b0;
                        del_led   <= 1'b0;
                        if (SW0) begin
                            // Write switch digit to selected location.
                            op_src_addr     <= input_addr;
                            op_dst_addr     <= input_addr;
                            block_to_write <= {120'd0, input_ascii};
                            sd_addr        <= input_addr;
                            wr_start       <= 1'b1;
                            ctrl_state     <= CS_WAIT_WR_WRITE;
                        end else begin
                            // Read selected location and display first byte nibble.
                            op_src_addr    <= input_addr;
                            op_dst_addr    <= input_addr;
                            sd_addr       <= input_addr;
                            rd_start      <= 1'b1;
                            read_byte_cnt <= 10'd0;
                            read_block    <= 128'd0;
                            read_mode     <= RM_NORMAL;
                            ctrl_state    <= CS_WAIT_RD_NORMAL;
                        end
                    end else if (btn_enc_pulse) begin
                        write_led <= 1'b0;
                        read_led  <= 1'b0;
                        enc_led   <= 1'b0;
                        dec_led   <= 1'b0;
                        del_led   <= 1'b0;
                        // Read source block first, then encrypt and write to next block.
                        op_src_addr    <= input_addr;
                        op_dst_addr    <= next_addr;
                        sd_addr       <= input_addr;
                        rd_start      <= 1'b1;
                        read_byte_cnt <= 10'd0;
                        read_block    <= 128'd0;
                        read_mode     <= RM_ENCRYPT;
                        ctrl_state    <= CS_WAIT_RD_CRYPT;
                    end else if (btn_dec_pulse) begin
                        write_led <= 1'b0;
                        read_led  <= 1'b0;
                        enc_led   <= 1'b0;
                        dec_led   <= 1'b0;
                        del_led   <= 1'b0;
                        // Read source block first, then decrypt and write to next block.
                        op_src_addr    <= input_addr;
                        op_dst_addr    <= next_addr;
                        sd_addr       <= input_addr;
                        rd_start      <= 1'b1;
                        read_byte_cnt <= 10'd0;
                        read_block    <= 128'd0;
                        read_mode     <= RM_DECRYPT;
                        ctrl_state    <= CS_WAIT_RD_CRYPT;
                    end else if (btn_del_pulse) begin
                        write_led <= 1'b0;
                        read_led  <= 1'b0;
                        enc_led   <= 1'b0;
                        dec_led   <= 1'b0;
                        del_led   <= 1'b0;
                        // Delete selected location by writing zeros.
                        op_src_addr     <= input_addr;
                        op_dst_addr     <= input_addr;
                        block_to_write <= 128'd0;
                        sd_addr        <= input_addr;
                        wr_start       <= 1'b1;
                        ctrl_state     <= CS_WAIT_WR_DELETE;
                    end
                end
            end

            CS_WAIT_WR_WRITE: begin
                if (wr_done) begin
                    write_led  <= 1'b1;
                    disp_digit <= SW4_1;
                    show_digit <= 1'b1;
                    ctrl_state <= CS_IDLE;
                end
            end

            CS_WAIT_RD_NORMAL: begin
                if (rd_valid) begin
                    if (read_byte_cnt < 10'd16) begin
                        case (read_byte_cnt[3:0])
                            4'd0:  read_block[7:0]     <= rd_data;
                            4'd1:  read_block[15:8]    <= rd_data;
                            4'd2:  read_block[23:16]   <= rd_data;
                            4'd3:  read_block[31:24]   <= rd_data;
                            4'd4:  read_block[39:32]   <= rd_data;
                            4'd5:  read_block[47:40]   <= rd_data;
                            4'd6:  read_block[55:48]   <= rd_data;
                            4'd7:  read_block[63:56]   <= rd_data;
                            4'd8:  read_block[71:64]   <= rd_data;
                            4'd9:  read_block[79:72]   <= rd_data;
                            4'd10: read_block[87:80]   <= rd_data;
                            4'd11: read_block[95:88]   <= rd_data;
                            4'd12: read_block[103:96]  <= rd_data;
                            4'd13: read_block[111:104] <= rd_data;
                            4'd14: read_block[119:112] <= rd_data;
                            4'd15: read_block[127:120] <= rd_data;
                            default: ;
                        endcase
                    end
                    read_byte_cnt <= read_byte_cnt + 10'd1;
                end

                if (rd_done) begin
                    read_led   <= 1'b1;
                    disp_digit <= read_block[3:0];
                    show_digit <= 1'b1;
                    ctrl_state <= CS_IDLE;
                end
            end

            CS_WAIT_RD_CRYPT: begin
                if (rd_valid) begin
                    if (read_byte_cnt < 10'd16) begin
                        case (read_byte_cnt[3:0])
                            4'd0:  read_block[7:0]     <= rd_data;
                            4'd1:  read_block[15:8]    <= rd_data;
                            4'd2:  read_block[23:16]   <= rd_data;
                            4'd3:  read_block[31:24]   <= rd_data;
                            4'd4:  read_block[39:32]   <= rd_data;
                            4'd5:  read_block[47:40]   <= rd_data;
                            4'd6:  read_block[55:48]   <= rd_data;
                            4'd7:  read_block[63:56]   <= rd_data;
                            4'd8:  read_block[71:64]   <= rd_data;
                            4'd9:  read_block[79:72]   <= rd_data;
                            4'd10: read_block[87:80]   <= rd_data;
                            4'd11: read_block[95:88]   <= rd_data;
                            4'd12: read_block[103:96]  <= rd_data;
                            4'd13: read_block[111:104] <= rd_data;
                            4'd14: read_block[119:112] <= rd_data;
                            4'd15: read_block[127:120] <= rd_data;
                            default: ;
                        endcase
                    end
                    read_byte_cnt <= read_byte_cnt + 10'd1;
                end

                if (rd_done) begin
                    if (read_mode == RM_ENCRYPT) begin
                        plain_block <= read_block;
                        ctrl_state  <= CS_ENC_START;
                    end else begin
                        dec_input_block <= read_block;
                        ctrl_state      <= CS_DEC_START;
                    end
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
                    block_to_write <= aes_enc_out;
                    sd_addr        <= op_dst_addr;
                    wr_start       <= 1'b1;
                    ctrl_state     <= CS_WAIT_WR_ENC;
                end
            end

            CS_WAIT_WR_ENC: begin
                if (wr_done) begin
                    enc_led    <= 1'b1;
                    disp_digit <= aes_enc_out[3:0];
                    show_digit <= 1'b1;
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
                    block_to_write <= aes_dec_out;
                    sd_addr        <= op_dst_addr;
                    wr_start       <= 1'b1;
                    ctrl_state     <= CS_WAIT_WR_DEC;
                end
            end

            CS_WAIT_WR_DEC: begin
                if (wr_done) begin
                    dec_led    <= 1'b1;
                    disp_digit <= aes_dec_out[3:0];
                    show_digit <= 1'b1;
                    ctrl_state <= CS_IDLE;
                end
            end

            CS_WAIT_WR_DELETE: begin
                if (wr_done) begin
                    del_led    <= 1'b1;
                    disp_digit <= 4'd0;
                    show_digit <= 1'b1;
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
assign LED[4]      = del_led;
assign LED[5]      = read_led;
assign LED[6]      = busy;
assign LED[9:7]    = 3'b000;
assign LED[14:10]  = debug_last;
assign LED[15]     = init_err;

// Keep otherwise-unused ports tied to avoid warnings.
wire _unused_cd = SD_CD;
wire _unused_btn_levels = btn_rw_level ^ btn_enc_level ^ btn_dec_level ^ btn_del_level ^ btn_rst_pulse;
wire [4:0] _unused_debug_state = debug_state;

endmodule
