`timescale 1ns / 1ps

module Counter #(n = 4)(output reg [n-1:0] count, input [n-1:0] loadValue, input load, increment, decrement, clock, reset);
	always @(posedge clock, posedge reset) begin
		if (reset)
			count <= 0;
		else if (load)
			count <= loadValue;
		else if (increment)
			count <= count + 1;
		else if (decrement)
			count <= count - 1;
	end

endmodule
