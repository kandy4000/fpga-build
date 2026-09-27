module top(input clk, input rst_n, output [3:0] led);
  reg [23:0] cnt;
  always @(posedge clk)
    if (!rst_n) cnt <= 0;
    else        cnt <= cnt + 1;
  assign led = cnt[23:20];
endmodule
