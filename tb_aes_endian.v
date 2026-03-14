`timescale 1ns/1ps
module tb_aes_endian;
  reg clk=0, rst=1;
  always #5 clk=~clk;

  function [127:0] rev_bytes;
    input [127:0] x;
    integer i;
    begin
      for (i=0;i<16;i=i+1) begin
        rev_bytes[i*8 +: 8] = x[(15-i)*8 +: 8];
      end
    end
  endfunction

  reg [127:0] pt;
  reg [127:0] key;
  reg enc_start=0;
  wire enc_done;
  wire [127:0] ct;

  reg dec_start=0;
  reg [127:0] dec_in;
  wire dec_done;
  wire [127:0] dt;

  ASMD_Encryption u_enc(
    .done(enc_done), .Dout(ct), .plain_text_in(pt), .key_in(key),
    .encrypt(enc_start), .clock(clk), .reset(rst)
  );

  ASMD_Decryption u_dec(
    .done(dec_done), .Dout(dt), .encrypted_text_in(dec_in), .key_in(key),
    .decrypt(dec_start), .clock(clk), .reset(rst)
  );

  task run_dec;
    input [127:0] inblk;
    input [255:0] label;
    begin
      dec_in = inblk;
      #20 dec_start=1;
      #10 dec_start=0;
      wait(dec_done==1);
      $display("%0s in=%032h out=%032h", label, inblk, dt);
      $display("  cmp out==pt:%0d, out==rev(pt):%0d", (dt==pt), (dt==rev_bytes(pt)));
      rst=1; #20; rst=0; #20;
    end
  endtask

  initial begin
    pt  = 128'h00000000000000000000000000003232;
    key = 128'h00112233445566778899AABBCCDDEEFF;
    dec_in = 0;

    #30 rst=0;
    #20 enc_start=1;
    #10 enc_start=0;
    wait(enc_done==1);
    $display("enc ct=%032h rev(ct)=%032h", ct, rev_bytes(ct));

    run_dec(ct, "dec(ct)");
    run_dec(rev_bytes(ct), "dec(rev_ct)");

    #20 $finish;
  end
endmodule
