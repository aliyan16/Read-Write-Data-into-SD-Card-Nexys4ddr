`timescale 1ns / 1ps

module Inv_Sub_Bytes(output [127:0] D_out, input [127:0] D_in);

	wire [127:0] inv_S_out;
	
	genvar i;
	for(i=0; i<16; i=i+1) begin : Inverse
		inv_S_box inv_S1(inv_S_out[(8*i+7):8*i], D_in[(8*i+7):8*i]); 	
	end
	assign D_out = inv_S_out;

endmodule
