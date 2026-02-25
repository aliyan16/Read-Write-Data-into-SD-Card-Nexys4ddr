// ============================================================
// debounce.v
// Simple button debouncer - 20ms @ 100MHz
// ============================================================
module debounce (
    input  wire clk,
    input  wire btn_in,
    output reg  btn_out   = 0, // level (debounced)
    output reg  btn_pulse = 0  // single-clock pulse on press
);

reg [20:0] cnt = 0;
reg        btn_sync0 = 0, btn_sync1 = 0;

always @(posedge clk) begin
    btn_sync0 <= btn_in;
    btn_sync1 <= btn_sync0;
end

always @(posedge clk) begin
    btn_pulse <= 0;
    if (btn_sync1 != btn_out) begin
        cnt <= cnt + 1;
        if (cnt == 21'd2_000_000) begin // 20ms
            cnt     <= 0;
            btn_out <= btn_sync1;
            if (btn_sync1 == 1) btn_pulse <= 1;
        end
    end else begin
        cnt <= 0;
    end
end

endmodule
