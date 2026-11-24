`timescale 1ns/1ps

module counter_hold_tb;
    logic clk = 0;
    logic rst_n = 0;
    logic en = 0;
    wire [7:0] count;

    counter dut (clk, rst_n, en, count);
    always #5 clk = ~clk;

    initial begin
        @(negedge clk);
        rst_n = 1;
        en = 1;
        repeat (127) @(posedge clk);
        @(negedge clk);
        if (count !== 8'd127)
            $fatal(1, "before disabling expected=127 actual=%0d", count);
        en = 0;
        @(posedge clk);
        #1;
        if (count !== 8'd127)
            $fatal(1, "disabled at 127 expected=127 actual=%0d", count);
        $display("HOLD_PASS");
        $finish;
    end
endmodule
