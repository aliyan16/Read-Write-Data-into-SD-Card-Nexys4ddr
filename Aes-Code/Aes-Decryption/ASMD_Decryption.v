`timescale 1ns / 1ps

module ASMD_Decryption(output done, output [127:0] Dout, input [127:0] encrypted_text_in, key_in, input decrypt, clock, reset);
	wire isRound10, isRound9, init, dec_count, en_round_out, en_reg_inv_row_out, en_reg_inv_sub_out, en_reg_inv_col_out, en_Dout, count_gt_0, count_eq_9;
	wire key_init, key_step, store_key;  // CU -> DP
	wire expand_done;                     // DP -> CU

	ControlUnit_Decryption cu_dec(done, isRound10, isRound9, init, dec_count, en_round_out, en_reg_inv_row_out, en_reg_inv_sub_out, en_reg_inv_col_out, en_Dout, key_init, key_step, store_key, decrypt, count_gt_0, count_eq_9, expand_done, clock, reset);
	Datapath_Decryption dp_dec(Dout, count_gt_0, count_eq_9, expand_done, encrypted_text_in, key_in, isRound10, isRound9, init, dec_count, en_round_out, en_reg_inv_row_out, en_reg_inv_sub_out, en_reg_inv_col_out, en_Dout, key_init, key_step, store_key, clock, reset);

endmodule
