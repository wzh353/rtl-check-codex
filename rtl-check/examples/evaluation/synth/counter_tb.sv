`timescale 1ns/1ps
module counter_tb;
    reg clk = 0, rst_n = 0, en = 1;
    wire [7:0] count;
    counter dut (clk, rst_n, en, count);
    initial begin
        #5 clk = 1;
        #1;
        if (count !== 0) $fatal(1, "reset failed");
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule