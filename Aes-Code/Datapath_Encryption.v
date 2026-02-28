`timescale 1ns / 1ps

module Datapath_Encryption(
	output [127:0] Dout, output count_lt_10,
	input [127:0] key_in, plain_text_in, input init, isRound0, en_round_out, inc_count, en_reg_sub_out, en_reg_row_out, en_reg_col_out, en_Dout, reset, clock
);
	wire [127:0] round_in, sub_out, row_out, col_out, mux_out, Din;
	wire [127:0] plain_text, key, round_out, reg_sub_out, reg_row_out, reg_col_out;
	wire [127:0] current_round_key, next_round_key, round_key_input;
	wire [3:0] count;

	//Registers
	Register #(128) Reg_key(key, key_in, init, clock, reset);
	Register #(128) Reg_plain_text(plain_text, plain_text_in, init, clock, reset);

	Register #(128) Reg_round_out(round_out, round_in, en_round_out, clock, reset);
	Register #(128) Reg_sub_out(reg_sub_out, sub_out, en_reg_sub_out, clock, reset);
	Register #(128) Reg_row_out(reg_row_out, row_out, en_reg_row_out, clock, reset);
	Register #(128) Reg_col_out(reg_col_out, col_out, en_reg_col_out, clock, reset);

	Register #(128) Reg_Dout(Dout, Din, en_Dout, clock, reset);

	// Round key register - stores current round key (key_r[count])
	// Initialize with original key on init, update with next_round_key on inc_count
	assign round_key_input = init ? key_in : next_round_key;
	Register #(128) Reg_round_key(current_round_key, round_key_input, init | inc_count, clock, reset);

	//Counter - load=init to reset counter when starting new encryption
	Counter #(4) up(count, 4'd0, init, inc_count, 1'b0, clock, reset);
	assign count_lt_10 = count < 10;

	//AES blocks - On-the-fly round key expansion
	// Computes next round key from current round key (breaks critical timing path)
	Round_Key_Update rku(
		.next_round_key(next_round_key),
		.current_round_key(current_round_key),
		.round_num(count + 4'd1)  // Compute key_r[count+1] from key_r[count]
	);

	Sub_Bytes sb0(sub_out, round_out);
	shift_rows sr0(row_out, reg_sub_out);
	mix_cols mc(col_out, reg_row_out);

	// Use current_round_key directly (no mux needed - single cycle delay)
	assign round_in = ((isRound0) ? plain_text : reg_col_out) ^ current_round_key;
	assign Din = reg_row_out ^ current_round_key;
endmodule