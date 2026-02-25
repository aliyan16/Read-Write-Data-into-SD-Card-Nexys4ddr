// ============================================================
// seven_seg.v
// Drives the 8-digit 7-segment display on Nexys4 DDR
// Shows a 4-bit digit (0-9) on rightmost digit
// and status messages on left digits
// ============================================================
module seven_seg (
    input  wire        clk,
    input  wire [3:0]  digit,        // digit to display (0-9)
    input  wire        show_digit,   // 1 = show digit, 0 = show dashes
    input  wire        init_ok,
    input  wire        error_flag,
    output reg  [7:0]  an,           // anodes  (active low)
    output reg  [6:0]  seg           // cathodes (active low): gfedcba
);

// Multiplexing counter (~1kHz refresh)
reg [16:0] refresh_cnt = 0;
reg [2:0]  digit_sel   = 0;

always @(posedge clk) begin
    refresh_cnt <= refresh_cnt + 1;
    if (refresh_cnt == 0) digit_sel <= digit_sel + 1;
end

// Segment decode (active low)
function [6:0] seg_decode;
    input [3:0] d;
    case (d)
        4'd0: seg_decode = 7'b1000000;
        4'd1: seg_decode = 7'b1111001;
        4'd2: seg_decode = 7'b0100100;
        4'd3: seg_decode = 7'b0110000;
        4'd4: seg_decode = 7'b0011001;
        4'd5: seg_decode = 7'b0010010;
        4'd6: seg_decode = 7'b0000010;
        4'd7: seg_decode = 7'b1111000;
        4'd8: seg_decode = 7'b0000000;
        4'd9: seg_decode = 7'b0010000;
        default: seg_decode = 7'b0111111; // dash
    endcase
endfunction

// What to show on each digit position
// Digit 7 (leftmost) to 0 (rightmost)
// We show: [XXXX----] where rightmost = the read digit
// Or [Err-----] on error
// Or [----    ] while waiting

always @(*) begin
    an  = 8'b11111111; // default all off
    seg = 7'b0111111;  // dash

    case (digit_sel)
    3'd0: begin  // rightmost: show the digit value when read mode
        an = 8'b11111110;
        if (show_digit)  seg = seg_decode(digit);
        else             seg = 7'b0111111; // dash
    end
    3'd1: begin  // second from right: always dash
        an  = 8'b11111101;
        seg = 7'b0111111;
    end
    3'd2: begin
        an  = 8'b11111011;
        seg = 7'b0111111;
    end
    3'd3: begin
        an  = 8'b11110111;
        seg = 7'b0111111;
    end
    3'd4: begin  // show 'd' for "done" or '-' for waiting
        an = 8'b11101111;
        if (error_flag)  seg = 7'b0100001; // 'E' shape
        else if (init_ok) seg = 7'b0100001; // 'E' - shows status
        else             seg = 7'b0111111;
    end
    3'd5: begin
        an = 8'b11011111;
        seg = 7'b0111111;
    end
    3'd6: begin
        an = 8'b10111111;
        seg = 7'b0111111;
    end
    3'd7: begin  // leftmost: show 'r' for read, 'u' for write (wr), '-' idle
        an = 8'b01111111;
        seg = 7'b0111111;
    end
    endcase
end

endmodule