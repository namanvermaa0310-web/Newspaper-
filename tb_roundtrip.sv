`timescale 1ns/1ps
module tb_roundtrip;
  localparam integer CPB = 16;
  reg clk = 0, rst_n = 0;
  reg  host_tx = 1'b1;
  wire fpga_tx;

  mlkem_uart_core #(.CLKS_PER_BIT(CPB)) dut (
    .clk(clk), .rst_n(rst_n), .uart_rx_i(host_tx), .uart_tx_o(fpga_tx)
  );
  always #5 clk = ~clk;

  reg [15:0] golden_s [0:255];
  integer errors = 0;
  integer k;
  reg [7:0] got;
  reg [15:0] got16;

  task host_send(input [7:0] b);
    integer i;
    begin
      host_tx = 1'b0; repeat (CPB) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        host_tx = b[i]; repeat (CPB) @(posedge clk);
      end
      host_tx = 1'b1; repeat (CPB) @(posedge clk);
    end
  endtask

  reg [7:0] rxq [0:8191];
  integer rxq_wr = 0, rxq_rd = 0;
  initial begin : uart_monitor
    reg [7:0] b; integer i;
    forever begin
      @(negedge fpga_tx);
      repeat (CPB + CPB/2) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        b[i] = fpga_tx;
        if (i < 7) repeat (CPB) @(posedge clk);
      end
      rxq[rxq_wr] = b; rxq_wr = rxq_wr + 1;
      repeat (CPB) @(posedge clk);
    end
  end
  task host_recv(output [7:0] b);
    begin
      while (rxq_rd == rxq_wr) @(posedge clk);
      b = rxq[rxq_rd]; rxq_rd = rxq_rd + 1;
    end
  endtask

  initial begin
    $readmemh("golden_s.hex", golden_s);
    $display("=== Round-trip test: NTT then INTT, must recover original s ===");
    rst_n = 0; repeat (10) @(posedge clk); rst_n = 1; repeat (10) @(posedge clk);

    host_send(8'hA5);
    host_recv(got);
    if (got !== 8'h5A) begin $display("FAIL ping"); errors=errors+1; end

    for (k = 0; k < 256; k = k + 1) begin
      host_send(8'h01); host_send(k[7:0]);
      host_send(golden_s[k][7:0]); host_send(golden_s[k][15:8]);
      host_recv(got);
    end
    $display("loaded s");

    host_send(8'h02); host_recv(got);   // forward NTT
    got = 8'h01; k=0;
    while (got[0]===1'b1 && k<300) begin host_send(8'h05); host_recv(got); k=k+1; end
    $display("forward NTT done after %0d polls", k);

    host_send(8'h03); host_recv(got);   // inverse NTT -- exercises ST_NORM
    got = 8'h01; k=0;
    while (got[0]===1'b1 && k<300) begin host_send(8'h05); host_recv(got); k=k+1; end
    $display("inverse NTT done after %0d polls", k);

    for (k = 0; k < 256; k = k + 1) begin
      host_send(8'h04); host_send(k[7:0]);
      host_recv(got16[7:0]); host_recv(got16[15:8]);
      if (got16 !== golden_s[k]) begin
        if (errors < 10) $display("MISMATCH s[%0d]: got %0d want %0d", k, got16, golden_s[k]);
        errors = errors + 1;
      end
    end

    if (errors == 0)
      $display("PASS -- round trip recovered original s exactly (ST_NORM correct)");
    else
      $display("FAIL -- %0d errors", errors);
    $finish;
  end
  initial begin #500_000_000; $display("TIMEOUT"); $finish; end
endmodule
