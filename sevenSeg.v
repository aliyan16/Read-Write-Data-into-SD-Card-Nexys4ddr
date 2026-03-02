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
    input  wire [2:0]  status_msg,   // 0=idle 1=LOAD 2=ENCR 3=DECR 4=CLr
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
        4'd10: seg_decode = 7'b0001000; // A
        4'd11: seg_decode = 7'b0000011; // b
        4'd12: seg_decode = 7'b1000110; // C
        4'd13: seg_decode = 7'b0100001; // d
        4'd14: seg_decode = 7'b0000110; // E
        4'd15: seg_decode = 7'b0001110; // F
        default: seg_decode = 7'b0111111; // dash
    endcase
endfunction

localparam [2:0]
    MSG_IDLE = 3'd0,
    MSG_LOAD = 3'd1,
    MSG_ENCR = 3'd2,
    MSG_DECR = 3'd3,
    MSG_CLR  = 3'd4,
    MSG_ERR  = 3'd5;

localparam [4:0]
    CH_DASH  = 5'd0,
    CH_L     = 5'd1,
    CH_O     = 5'd2,
    CH_A     = 5'd3,
    CH_d     = 5'd4,
    CH_E     = 5'd5,
    CH_n     = 5'd6,
    CH_C     = 5'd7,
    CH_r     = 5'd8;

function [6:0] seg_char;
    input [4:0] ch;
    begin
        case (ch)
            CH_DASH: seg_char = 7'b0111111; // '-'
            CH_L:    seg_char = 7'b1000111; // 'L'
            CH_O:    seg_char = 7'b1000000; // 'O' (same as 0)
            CH_A:    seg_char = 7'b0001000; // 'A'
            CH_d:    seg_char = 7'b0100001; // 'd'
            CH_E:    seg_char = 7'b0000110; // 'E'
            CH_n:    seg_char = 7'b0101011; // 'n' approximation
            CH_C:    seg_char = 7'b1000110; // 'C'
            CH_r:    seg_char = 7'b0101111; // 'r' approximation
            default: seg_char = 7'b0111111;
        endcase
    end
endfunction

function [4:0] msg_char;
    input [2:0] msg;
    input [1:0] pos; // 0..3 for digits 7..4
    begin
        case (msg)
            MSG_LOAD: begin
                case (pos)
                    2'd0: msg_char = CH_L;
                    2'd1: msg_char = CH_O;
                    2'd2: msg_char = CH_A;
                    default: msg_char = CH_d;
                endcase
            end
            MSG_ENCR: begin
                case (pos)
                    2'd0: msg_char = CH_E;
                    2'd1: msg_char = CH_n;
                    2'd2: msg_char = CH_C;
                    default: msg_char = CH_r;
                endcase
            end
            MSG_DECR: begin
                case (pos)
                    2'd0: msg_char = CH_d;
                    2'd1: msg_char = CH_E;
                    2'd2: msg_char = CH_C;
                    default: msg_char = CH_r;
                endcase
            end
            MSG_CLR: begin
                case (pos)
                    2'd0: msg_char = CH_C;
                    2'd1: msg_char = CH_L;
                    2'd2: msg_char = CH_r;
                    default: msg_char = CH_DASH;
                endcase
            end
            MSG_ERR: begin
                case (pos)
                    2'd0: msg_char = CH_E;
                    2'd1: msg_char = CH_r;
                    2'd2: msg_char = CH_r;
                    default: msg_char = CH_DASH;
                endcase
            end
            default: msg_char = CH_DASH;
        endcase
    end
endfunction

wire [2:0] active_msg = error_flag ? MSG_ERR : (init_ok ? status_msg : MSG_IDLE);

// What to show on each digit position
// Digit 7 (leftmost) to 0 (rightmost)
// We show: [XXXX----] where rightmost = the read digit
// Or [Err-----] on error
// Or [----    ] while waiting

always @(*) begin
    an  = 8'b11111111; // default all off
    seg = 7'b0111111;  // dash

    case (digit_sel)
        3'd0: begin
            an = 8'b11111110;
            if (show_digit) seg = seg_decode(digit);
            else            seg = 7'b0111111;
        end
        3'd1: begin
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
        3'd4: begin
            an  = 8'b11101111;
            seg = seg_char(msg_char(active_msg, 2'd3));
        end
        3'd5: begin
            an  = 8'b11011111;
            seg = seg_char(msg_char(active_msg, 2'd2));
        end
        3'd6: begin
            an  = 8'b10111111;
            seg = seg_char(msg_char(active_msg, 2'd1));
        end
        3'd7: begin
            an  = 8'b01111111;
            seg = seg_char(msg_char(active_msg, 2'd0));
        end
    endcase
end

endmodule
