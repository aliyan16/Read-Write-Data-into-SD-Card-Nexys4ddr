`timescale 1ns / 1ps

module Register #(parameter n = 128) (output reg [n-1:0] Q, input [n-1:0] D, input enable, clock, reset);
	always @(posedge clock, posedge reset) begin
		if (reset)
			Q <= 128'd0;
		else if (enable)
			Q <= D;
	end
endmodule
