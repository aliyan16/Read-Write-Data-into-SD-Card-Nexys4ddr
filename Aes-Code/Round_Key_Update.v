`timescale 1ns / 1ps

// On-the-fly AES-128 round key expansion
// Computes next round key from current round key
// This breaks the critical timing path by computing only one round at a time
module Round_Key_Update(
    output [127:0] next_round_key,
    input [127:0] current_round_key,
    input [3:0] round_num
);
    wire [31:0] w0, w1, w2, w3;  // Current round key words
    wire [31:0] w4, w5, w6, w7;  // Next round key words
    wire [31:0] g_out;

    // Split current round key into words (big-endian)
    assign w0 = current_round_key[127:96];
    assign w1 = current_round_key[95:64];
    assign w2 = current_round_key[63:32];
    assign w3 = current_round_key[31:0];

    // Apply function_g to last word with current round constant
    function_g fg(
        .w(w3),
        .i(round_num),
        .D_out(g_out)
    );

    // Compute next round key words using AES key expansion
    assign w4 = w0 ^ g_out;
    assign w5 = w1 ^ w4;
    assign w6 = w2 ^ w5;
    assign w7 = w3 ^ w6;

    // Assemble next round key
    assign next_round_key = {w4, w5, w6, w7};

endmodule
