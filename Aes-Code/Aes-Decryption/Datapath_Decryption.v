`timescale 1ns / 1ps

module Datapath_Decryption(
	output [127:0] Dout, output count_gt_0, count_eq_9, expand_done,
	input [127:0] encrypted_text_in, key_in, input isRound10, isRound9, init, dec_count, en_round_out, en_reg_inv_row_out, en_reg_inv_sub_out, en_reg_inv_col_out, en_Dout, key_init, key_step, store_key, clock, reset
	);

	wire [127:0] round_in, inv_sub_out, inv_row_out, inv_col_out, mux_out, Din;
	wire [127:0] encrypted_text, round_out, reg_inv_sub_out, reg_inv_row_out, reg_inv_col_out;
	wire [127:0] key_r_out;
	wire [3:0] count;

	//Registers
	Register #(128) Reg_encrypted_text(encrypted_text, encrypted_text_in, init, clock, reset);
	Register #(128) Reg_round_out(round_out, round_in, en_round_out, clock, reset);
	Register #(128) Reg_inv_sub_out(reg_inv_sub_out, inv_sub_out, en_reg_inv_sub_out, clock, reset);
	Register #(128) Reg_inv_row_out(reg_inv_row_out, inv_row_out, en_reg_inv_row_out, clock, reset);
	Register #(128) Reg_inv_col_out(reg_inv_col_out, inv_col_out, en_reg_inv_col_out, clock, reset);
	Register #(128) Reg_Dout(Dout, Din, en_Dout, clock, reset);

	//counter (decryption round counter, counts down from 10)
	Counter #(4) down(count, 4'd10, init, 1'b0, dec_count, clock, reset);
	assign count_gt_0 = count > 0;
	assign count_eq_9 = count == 9;

	// --- Key pre-expansion (replaces combinational Key_expansion) ---
	wire [127:0] expand_key, next_expand_key;
	wire [3:0] expand_count;

	// Expansion key register: key_in on init, next computed key on step
	wire [127:0] expand_key_input = key_init ? key_in : next_expand_key;
	Register #(128) Reg_expand_key(expand_key, expand_key_input, key_init | key_step, clock, reset);

	// Expansion counter: 0 on init, increments on step
	Counter #(4) expand_cnt(expand_count, 4'd0, key_init, key_step, 1'b0, clock, reset);
	assign expand_done = (expand_count == 4'd10);

	// Compute next round key (single function_g per cycle)
	Round_Key_Update rku(
	    .next_round_key(next_expand_key),
	    .current_round_key(expand_key),
	    .round_num(expand_count + 4'd1)
	);

	// Store keys into bank during expansion
	reg [127:0] key_bank [0:10];
	always @(posedge clock) begin
	    if (store_key)
	        key_bank[expand_count] <= expand_key;
	end

	// Read round key from bank during decryption
	assign key_r_out = key_bank[count];
	// --- End key pre-expansion ---

	//AES Blocks
	assign mux_out = (isRound9) ? round_out : reg_inv_col_out;
	Inv_shift_rows sr0(inv_row_out, mux_out);
	Inv_Sub_Bytes sb0(inv_sub_out, reg_inv_row_out);
	Inv_mix_cols mc(inv_col_out, round_out);

	assign round_in = ((isRound10) ? encrypted_text : reg_inv_sub_out) ^ key_r_out;
	assign Din = reg_inv_sub_out ^ key_r_out;

endmodule
