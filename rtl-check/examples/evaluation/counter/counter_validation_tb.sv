`timescale 1ns/1ps

module counter_validation_tb;
    logic clk = 0;
    logic rst_n = 0;
    logic en = 1;
    wire [7:0] count;

    counter dut (clk, rst_n, en, count);
    always #5 clk = ~clk;

    initial begin
        @(negedge clk);
        rst_n = 1;
        @(negedge clk);
        rst_n = 0;
        #1;
        if (count !== 8'd1)
            $fatal(1, "independent reset check: reset changed count before the clock (expected=1 actual=%0d)", count);
        @(posedge clk);
        #1;
        if (count !== 8'd0)
            $fatal(1, "independent reset check: reset did not take effect at the clock (expected=0 actual=%0d)", count);
        $display("VALIDATION_PASS");
        $finish;
    end
endmodule
