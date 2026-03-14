`timescale 1ns / 1ps

module ControlUnit_Decryption(
	output reg done, isRound10, isRound9, init, dec_count, en_round_out, en_reg_inv_row_out, en_reg_inv_sub_out, en_reg_inv_col_out, en_Dout, key_init, key_step, store_key,
	input decrypt, count_gt_0, count_eq_9, expand_done, clock, reset
	);
	parameter S0 = 3'd0, S1 = 3'd1, S2 = 3'd2, S3 = 3'd3, S4 = 3'd4, S5 = 3'd5, S6 = 3'd6, S_EXPAND = 3'd7;
	reg [2:0] current, next;

	always @(posedge clock, posedge reset) begin
		if (reset)
			current <= S0;
		else
			current <= next;
	end

	always @(*) begin
		// Default values for all outputs
		done = 0;
		isRound10 = 0;
		isRound9 = 0;
		init = 0;
		dec_count = 0;
		en_round_out = 0;
		en_reg_inv_row_out = 0;
		en_reg_inv_sub_out = 0;
		en_reg_inv_col_out = 0;
		en_Dout = 0;
		key_init = 0;
		key_step = 0;
		store_key = 0;

		// CRITICAL: Default value for next to prevent latch
		next = current;

		case (current)
			S0: begin
				if (decrypt) begin
					init = 1;
					key_init = 1;
					next = S_EXPAND;
				end
			end
			S_EXPAND: begin
				store_key = 1;
				if (!expand_done) begin
					key_step = 1;
					next = S_EXPAND;
				end
				else begin
					next = S1;
				end
			end
			S1: begin
				isRound10 = 1;
				en_round_out = 1;
				dec_count = 1;
				next = S2;
			end
			S2: begin
				if (count_eq_9) begin
					isRound9 = 1;
				end
				en_reg_inv_row_out = 1;
				next = S3;
			end
			S3: begin
				en_reg_inv_sub_out = 1;
				next = S4;
			end
			S4: begin
				en_round_out = 1;
				next = S5;
			end
			S5: begin
				if (count_gt_0) begin
					en_reg_inv_col_out = 1;
					dec_count = 1;
					next = S2;
				end
				else begin
					en_Dout = 1;
					next = S6;
				end
			end
			S6: begin
				done = 1;
				if (decrypt) begin
					init = 1;
					key_init = 1;
					next = S_EXPAND;
				end
			end
		endcase
	end
endmodule
