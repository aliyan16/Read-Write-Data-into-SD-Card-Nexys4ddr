// ============================================================
// sd_spi_controller.v  -  Clean rewrite
// SPI-mode SD/SDHC controller for Nexys4 DDR (Artix-7)
// Supports: Init, CMD17 read, CMD24 write
//
// SD_RESET : active LOW  on Nexys4 DDR (LOW = slot powered)
// SPI Mode 0 (CPOL=0, CPHA=0)
// SPI clock : 100MHz / (2*200) = 250 kHz (safe for init + debug)
// ============================================================
module sd_spi_controller (
    input  wire        clk,
    input  wire        rst,

    output reg         sd_cs,
    output reg         sd_sclk,
    output reg         sd_mosi,
    input  wire        sd_miso,
    output reg         sd_reset,    // LOW = card powered

    input  wire        init_start,  // tie to 1
    output reg         init_done,
    output reg         init_err,

    input  wire        rd_start,
    input  wire [31:0] rd_addr,
    output reg  [7:0]  rd_data,
    output reg         rd_valid,
    output reg         rd_done,

    input  wire        wr_start,
    input  wire [31:0] wr_addr,
    input  wire [7:0]  wr_data,
    output reg         wr_done,

    output reg         busy,
    output wire [4:0]  debug_state,   // current FSM state
    output wire [4:0]  debug_last     // last state before error
);

// ------------------------------------------------------------------
// SPI clock divider  ->  250 kHz
// ------------------------------------------------------------------
parameter CLK_DIV = 200;

reg [7:0] clk_cnt  = 0;
reg       spi_tick = 0;

always @(posedge clk) begin
    spi_tick <= 0;
    if (rst) begin
        clk_cnt <= 0;
    end else begin
        if (clk_cnt >= CLK_DIV - 1) begin
            clk_cnt  <= 0;
            spi_tick <= 1;
        end else begin
            clk_cnt <= clk_cnt + 1;
        end
    end
end

// ------------------------------------------------------------------
// SPI byte engine  (Mode 0: sample rising, shift falling)
// ------------------------------------------------------------------
reg [7:0] spi_tx      = 8'hFF;
reg       spi_req     = 0;
reg [7:0] spi_rx_byte = 8'hFF;
reg       spi_done    = 0;
reg       spi_busy    = 0;
reg [2:0] spi_bit     = 0;
reg       spi_phase   = 0;

always @(posedge clk) begin
    spi_done <= 0;
    if (rst) begin
        spi_busy  <= 0;
        sd_sclk   <= 0;
        sd_mosi   <= 1;
        spi_phase <= 0;
    end else if (spi_req && !spi_busy) begin
        spi_busy  <= 1;
        spi_bit   <= 7;
        spi_phase <= 0;
        sd_sclk   <= 0;
        sd_mosi   <= spi_tx[7];
    end else if (spi_busy && spi_tick) begin
        if (spi_phase == 0) begin
            sd_sclk     <= 1;
            spi_rx_byte <= {spi_rx_byte[6:0], sd_miso};
            spi_phase   <= 1;
        end else begin
            sd_sclk   <= 0;
            spi_phase <= 0;
            if (spi_bit == 0) begin
                spi_busy <= 0;
                spi_done <= 1;
            end else begin
                spi_bit <= spi_bit - 1;
                sd_mosi <= spi_tx[spi_bit - 1];
            end
        end
    end
end

// ------------------------------------------------------------------
// States
// ------------------------------------------------------------------
localparam [4:0]
    ST_PWRUP       = 0,
    ST_PWRDLY      = 1,
    ST_DUMMY       = 2,
    ST_CMD0        = 3,
    ST_CMD0_RESP   = 4,
    ST_CMD8        = 5,
    ST_CMD8_RESP   = 6,
    ST_CMD55       = 7,
    ST_CMD55_RESP  = 8,
    ST_ACMD41      = 9,
    ST_ACMD41_RESP = 10,
    ST_READY       = 11,
    ST_RD_LOAD     = 12,   // one-cycle buffer: cmd_buf settles before ST_RD_CMD
    ST_RD_CMD      = 13,
    ST_RD_RESP     = 14,
    ST_RD_TOKEN    = 15,
    ST_RD_DATA     = 16,
    ST_RD_CRC      = 17,
    ST_WR_LOAD     = 18,   // one-cycle buffer: cmd_buf settles before ST_WR_CMD
    ST_WR_CMD      = 19,
    ST_WR_RESP     = 20,
    ST_WR_TOKEN    = 21,
    ST_WR_DATA     = 22,
    ST_WR_CRC      = 23,
    ST_WR_DRESP    = 24,
    ST_WR_BUSY     = 25,
    ST_ERROR       = 26;

reg [4:0]  state      = ST_PWRUP;
reg [4:0]  last_state = ST_PWRUP;   // captures state before ST_ERROR
assign debug_state = state;
assign debug_last  = last_state;
reg [31:0] delay_cnt  = 0;
reg [2:0]  cmd_idx    = 0;
reg [7:0]  cmd_buf    [0:5];
reg [9:0]  byte_cnt   = 0;
reg [15:0] retry      = 0;
reg [15:0] poll_cnt   = 0;
reg        token_sent = 0;

// ------------------------------------------------------------------
// Main FSM
// ------------------------------------------------------------------
always @(posedge clk) begin
    spi_req  <= 0;
    rd_valid <= 0;
    rd_done  <= 0;
    wr_done  <= 0;

    // Track last state before error
    if (state != ST_ERROR) last_state <= state;

    if (rst) begin
        state      <= ST_PWRUP;
        sd_reset   <= 1;  // keep slot power OFF while resetting
        sd_cs      <= 1;
        init_done  <= 0;
        init_err   <= 0;
        busy       <= 1;
        delay_cnt  <= 0;
        cmd_idx    <= 0;
        byte_cnt   <= 0;
        retry      <= 0;
        poll_cnt   <= 0;
        token_sent <= 0;
    end else begin
        case (state)

        // ── 1ms power-up hold ────────────────────────────────────
        ST_PWRUP: begin
            sd_cs    <= 1;
            sd_reset <= 1; // power OFF
            if (delay_cnt < 32'd100_000)
                delay_cnt <= delay_cnt + 1;
            else begin
                sd_reset  <= 0;     // power card ON (active LOW)
                delay_cnt <= 0;
                state     <= ST_PWRDLY;
            end
        end

        // ── 250ms stabilise after power-on ───────────────────────
        ST_PWRDLY: begin
            sd_cs <= 1;
            if (delay_cnt < 32'd25_000_000)
                delay_cnt <= delay_cnt + 1;
            else begin
                delay_cnt <= 0;
                cmd_idx   <= 0;
                poll_cnt  <= 0;
                state     <= ST_DUMMY;
            end
        end

        // ── 80 dummy clocks, CS high ─────────────────────────────
        ST_DUMMY: begin
            sd_cs <= 1;
            if (delay_cnt < 10) begin
                if (!spi_busy && !spi_req) begin
                    spi_tx    = 8'hFF;
                    spi_req   <= 1;
                    delay_cnt <= delay_cnt + 1;
                end
            end else begin
                delay_cnt  <= 0;
                cmd_idx    <= 0;
                poll_cnt   <= 0;
                cmd_buf[0] = 8'h40; cmd_buf[1] = 8'h00;
                cmd_buf[2] = 8'h00; cmd_buf[3] = 8'h00;
                cmd_buf[4] = 8'h00; cmd_buf[5] = 8'h95;
                state <= ST_CMD0;
            end
        end

        // ── CMD0: GO_IDLE ─────────────────────────────────────────
        ST_CMD0: begin
            sd_cs <= 0;
            if (!spi_busy && !spi_req) begin
                if (cmd_idx < 6) begin
                    spi_tx  = cmd_buf[cmd_idx];
                    spi_req <= 1;
                    cmd_idx <= cmd_idx + 1;
                end else begin
                    cmd_idx  <= 0;
                    poll_cnt <= 0;
                    state    <= ST_CMD0_RESP;
                end
            end
        end

        ST_CMD0_RESP: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if (spi_rx_byte == 8'h01) begin
                        // R1=0x01 idle - good
                        sd_cs      <= 1;
                        cmd_idx    <= 0;
                        poll_cnt   <= 0;
                        cmd_buf[0] = 8'h48; cmd_buf[1] = 8'h00;
                        cmd_buf[2] = 8'h00; cmd_buf[3] = 8'h01;
                        cmd_buf[4] = 8'hAA; cmd_buf[5] = 8'h87;
                        state <= ST_CMD8;
                    end else if (spi_rx_byte == 8'hFF) begin
                        poll_cnt <= poll_cnt + 1;
                        if (poll_cnt >= 16'd50000) state <= ST_ERROR;
                    end
                    // other bytes: keep polling
                end
            end
        end

        // ── CMD8: SEND_IF_COND ────────────────────────────────────
        ST_CMD8: begin
            sd_cs <= 0;
            if (!spi_busy && !spi_req) begin
                if (cmd_idx < 6) begin
                    spi_tx  = cmd_buf[cmd_idx];
                    spi_req <= 1;
                    cmd_idx <= cmd_idx + 1;
                end else begin
                    cmd_idx  <= 0;
                    poll_cnt <= 0;
                    state    <= ST_CMD8_RESP;
                end
            end
        end

        ST_CMD8_RESP: begin
            // Drain 6 bytes of R7 response - don't check content
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    poll_cnt <= poll_cnt + 1;
                    if (poll_cnt >= 6) begin
                        sd_cs      <= 1;
                        cmd_idx    <= 0;
                        poll_cnt   <= 0;
                        retry      <= 0;
                        cmd_buf[0] = 8'h77; cmd_buf[1] = 8'h00;
                        cmd_buf[2] = 8'h00; cmd_buf[3] = 8'h00;
                        cmd_buf[4] = 8'h00; cmd_buf[5] = 8'hFF;
                        state <= ST_CMD55;
                    end
                end
            end
        end

        // ── CMD55 ─────────────────────────────────────────────────
        ST_CMD55: begin
            sd_cs <= 0;
            if (!spi_busy && !spi_req) begin
                if (cmd_idx < 6) begin
                    spi_tx  = cmd_buf[cmd_idx];
                    spi_req <= 1;
                    cmd_idx <= cmd_idx + 1;
                end else begin
                    cmd_idx  <= 0;
                    poll_cnt <= 0;
                    state    <= ST_CMD55_RESP;
                end
            end
        end

        ST_CMD55_RESP: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if (spi_rx_byte != 8'hFF) begin
                        // Got R1 - proceed to ACMD41 regardless of value
                        sd_cs      <= 1;
                        cmd_idx    <= 0;
                        poll_cnt   <= 0;
                        // ACMD41 with HCS=1 (0x40000000) for SDHC
                        cmd_buf[0] = 8'h69; cmd_buf[1] = 8'h40;
                        cmd_buf[2] = 8'h00; cmd_buf[3] = 8'h00;
                        cmd_buf[4] = 8'h00; cmd_buf[5] = 8'hFF;
                        state <= ST_ACMD41;
                    end else begin
                        poll_cnt <= poll_cnt + 1;
                        if (poll_cnt >= 16'd50000) state <= ST_ERROR;
                    end
                end
            end
        end

        // ── ACMD41 ────────────────────────────────────────────────
        ST_ACMD41: begin
            sd_cs <= 0;
            if (!spi_busy && !spi_req) begin
                if (cmd_idx < 6) begin
                    spi_tx  = cmd_buf[cmd_idx];
                    spi_req <= 1;
                    cmd_idx <= cmd_idx + 1;
                end else begin
                    cmd_idx  <= 0;
                    poll_cnt <= 0;
                    state    <= ST_ACMD41_RESP;
                end
            end
        end

        ST_ACMD41_RESP: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if (spi_rx_byte == 8'h00) begin
                        // Init complete
                        sd_cs     <= 1;
                        init_done <= 1;
                        busy      <= 0;
                        state     <= ST_READY;
                    end else if (spi_rx_byte == 8'h01) begin
                        // Still initialising, retry CMD55+ACMD41
                        sd_cs    <= 1;
                        cmd_idx  <= 0;
                        poll_cnt <= 0;
                        retry    <= retry + 1;
                        if (retry >= 16'd5000) begin
                            state <= ST_ERROR;
                        end else begin
                            cmd_buf[0] = 8'h77; cmd_buf[1] = 8'h00;
                            cmd_buf[2] = 8'h00; cmd_buf[3] = 8'h00;
                            cmd_buf[4] = 8'h00; cmd_buf[5] = 8'hFF;
                            state <= ST_CMD55;
                        end
                    end
                    // 0xFF or other = keep polling
                end
            end
        end

        // ── READY ─────────────────────────────────────────────────
        ST_READY: begin
            busy <= 0;
            if (rd_start) begin
                rd_done    <= 0;
                byte_cnt   <= 0;
                cmd_idx    <= 0;
                poll_cnt   <= 0;
                busy       <= 1;
                cmd_buf[0] = 8'h51;
                cmd_buf[1] = rd_addr[31:24];
                cmd_buf[2] = rd_addr[23:16];
                cmd_buf[3] = rd_addr[15:8];
                cmd_buf[4] = rd_addr[7:0];
                cmd_buf[5] = 8'hFF;
                state <= ST_RD_LOAD;   // wait one cycle for cmd_buf to settle
            end else if (wr_start) begin
                wr_done    <= 0;
                byte_cnt   <= 0;
                cmd_idx    <= 0;
                poll_cnt   <= 0;
                busy       <= 1;
                cmd_buf[0] = 8'h58;
                cmd_buf[1] = wr_addr[31:24];
                cmd_buf[2] = wr_addr[23:16];
                cmd_buf[3] = wr_addr[15:8];
                cmd_buf[4] = wr_addr[7:0];
                cmd_buf[5] = 8'hFF;
                state <= ST_WR_LOAD;   // wait one cycle for cmd_buf to settle
            end
        end

        // One-cycle buffer: cmd_buf settles AND cs asserts before first byte
        ST_RD_LOAD: begin sd_cs <= 0; state <= ST_RD_CMD; end
        ST_WR_LOAD: begin sd_cs <= 0; state <= ST_WR_CMD; end

        // ── READ CMD17 ────────────────────────────────────────────
        ST_RD_CMD: begin
            sd_cs <= 0;
            if (!spi_busy && !spi_req) begin
                if (cmd_idx < 6) begin
                    spi_tx  = cmd_buf[cmd_idx];
                    spi_req <= 1;
                    cmd_idx <= cmd_idx + 1;
                end else begin
                    cmd_idx  <= 0;
                    poll_cnt <= 0;
                    state    <= ST_RD_RESP;
                end
            end
        end

        ST_RD_RESP: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if (spi_rx_byte == 8'h00 || spi_rx_byte == 8'h01) begin
                        // Valid R1 response - now wait for data token
                        poll_cnt <= 0;
                        state    <= ST_RD_TOKEN;
                    end else if (spi_rx_byte == 8'hFF) begin
                        // No response yet, keep polling
                        poll_cnt <= poll_cnt + 1;
                        if (poll_cnt >= 16'd50000) state <= ST_ERROR;
                    end
                    // Any other byte: keep polling, don't error
                end
            end
        end

        ST_RD_TOKEN: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if (spi_rx_byte == 8'hFE) begin
                        // Data start token received
                        byte_cnt <= 0;
                        state    <= ST_RD_DATA;
                    end else begin
                        // Keep polling - 0xFF means waiting, other values also ok to skip
                        poll_cnt <= poll_cnt + 1;
                        if (poll_cnt >= 16'd50000) state <= ST_ERROR;
                    end
                end
            end
        end

        ST_RD_DATA: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    rd_data  <= spi_rx_byte;
                    rd_valid <= 1;
                    byte_cnt <= byte_cnt + 1;
                    if (byte_cnt == 511) begin
                        byte_cnt <= 0;
                        state    <= ST_RD_CRC;
                    end
                end
            end
        end

        ST_RD_CRC: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    byte_cnt <= byte_cnt + 1;
                    if (byte_cnt == 1) begin
                        sd_cs    <= 1;
                        rd_done  <= 1;
                        busy     <= 0;
                        byte_cnt <= 0;
                        state    <= ST_READY;
                    end
                end
            end
        end

        // ── WRITE CMD24 ───────────────────────────────────────────
        ST_WR_CMD: begin
            sd_cs <= 0;
            if (!spi_busy && !spi_req) begin
                if (cmd_idx < 6) begin
                    spi_tx  = cmd_buf[cmd_idx];
                    spi_req <= 1;
                    cmd_idx <= cmd_idx + 1;
                end else begin
                    cmd_idx  <= 0;
                    poll_cnt <= 0;
                    state    <= ST_WR_RESP;
                end
            end
        end

        ST_WR_RESP: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if (spi_rx_byte == 8'h00 || spi_rx_byte == 8'h01) begin
                        // Valid R1: 0x00=ready, 0x01=idle (both OK after CMD24)
                        token_sent <= 0;
                        poll_cnt   <= 0;
                        state      <= ST_WR_TOKEN;
                    end else if (spi_rx_byte == 8'hFF) begin
                        // No response yet, keep polling
                        poll_cnt <= poll_cnt + 1;
                        if (poll_cnt >= 16'd50000) state <= ST_ERROR;
                    end
                    // Any other value: keep polling (don't error)
                end
            end
        end

        ST_WR_TOKEN: begin
            if (!spi_busy && !spi_req) begin
                if (!token_sent) begin
                    spi_tx     = 8'hFE;
                    spi_req    <= 1;
                    token_sent <= 1;
                end else if (spi_done) begin
                    byte_cnt <= 0;
                    state    <= ST_WR_DATA;
                end
            end
        end

        ST_WR_DATA: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = wr_data;
                spi_req <= 1;
                if (spi_done) begin
                    byte_cnt <= byte_cnt + 1;
                    if (byte_cnt == 511) begin
                        byte_cnt <= 0;
                        state    <= ST_WR_CRC;
                    end
                end
            end
        end

        ST_WR_CRC: begin
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    byte_cnt <= byte_cnt + 1;
                    if (byte_cnt == 1) begin
                        byte_cnt <= 0;
                        poll_cnt <= 0;
                        state    <= ST_WR_DRESP;
                    end
                end
            end
        end

        ST_WR_DRESP: begin
            // Card sends data response token: 0bxxx00101 = accepted (0x05 in lower 5 bits)
            // After token, card pulls MISO LOW (0x00) while internally writing - go to ST_WR_BUSY
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if ((spi_rx_byte & 8'h1F) == 8'h05) begin
                        // Data accepted - now wait for busy to clear
                        poll_cnt <= 0;
                        state    <= ST_WR_BUSY;
                    end else if (spi_rx_byte == 8'h00) begin
                        // 0x00 = card is busy (MISO pulled low) - also go wait
                        poll_cnt <= 0;
                        state    <= ST_WR_BUSY;
                    end else if (spi_rx_byte == 8'hFF) begin
                        // No response yet, keep polling
                        poll_cnt <= poll_cnt + 1;
                        if (poll_cnt >= 16'd50000) state <= ST_ERROR;
                    end
                    // Other values (0x0B=CRC error, 0x0D=write error): keep polling
                    // to let card finish transmitting before deciding
                end
            end
        end

        ST_WR_BUSY: begin
            // Wait until MISO goes HIGH (0xFF) = card done writing internally
            // Card holds MISO LOW (0x00) while busy - this can take up to 250ms
            if (!spi_busy && !spi_req) begin
                spi_tx  = 8'hFF;
                spi_req <= 1;
                if (spi_done) begin
                    if (spi_rx_byte == 8'hFF) begin
                        // Card is no longer busy - write complete
                        sd_cs   <= 1;
                        wr_done <= 1;
                        busy    <= 0;
                        state   <= ST_READY;
                    end else begin
                        // Still busy (0x00) - keep polling with large timeout
                        poll_cnt <= poll_cnt + 1;
                        if (poll_cnt >= 16'd50000) state <= ST_ERROR;
                    end
                end
            end
        end

        ST_ERROR: begin
            init_err <= 1;
            sd_cs    <= 1;
            busy     <= 0;
        end

        default: state <= ST_ERROR;

        endcase
    end
end

endmodule
