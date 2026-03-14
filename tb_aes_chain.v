`timescale 1ns/1ps
module tb_aes_chain;
  reg clk=0, rst=1;
  always #5 clk=~clk;

  reg [127:0] pt;
  reg [127:0] key;
  reg enc_start=0;
  wire enc_done;
  wire [127:0] ct;

  reg dec_start=0;
  wire dec_done;
  wire [127:0] dt;

  ASMD_Encryption u_enc(
    .done(enc_done), .Dout(ct), .plain_text_in(pt), .key_in(key),
    .encrypt(enc_start), .clock(clk), .reset(rst)
  );

  ASMD_Decryption u_dec(
    .done(dec_done), .Dout(dt), .encrypted_text_in(ct), .key_in(key),
    .decrypt(dec_start), .clock(clk), .reset(rst)
  );

  initial begin
    pt  = 128'h00000000000000000000000000003232;
    key = 128'h00112233445566778899AABBCCDDEEFF;

    #30 rst=0;

    // start encrypt for one cycle
    #20 enc_start=1;
    #10 enc_start=0;

    wait(enc_done==1);
    $display("ENC DONE ct=%032h", ct);

    // start decrypt for one cycle
    #20 dec_start=1;
    #10 dec_start=0;

    wait(dec_done==1);
    $display("DEC DONE dt=%032h", dt);

    if (dt==pt) $display("MATCH");
    else $display("MISMATCH");

    #50 $finish;
  end
endmodule
