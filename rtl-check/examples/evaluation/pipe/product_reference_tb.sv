`timescale 1ns/1ps
module product_reference_tb;
    reg clk = 0, rst_n = 0;
    reg [7:0] a = 0, b = 0, c = 0;
    wire [23:0] y;
    integer seed = 47563;
    integer index;
    integer checks = 0;
    reg [31:0] queued = 0;
    reg [31:0] expected = 0;
    product_pipe dut (clk, rst_n, a, b, c, y);
    always #7 clk = ~clk;
    always @(posedge clk) begin
        expected = rst_n ? queued : 0;
        queued = rst_n ? (32'd1 * a * b * c) : 0;
        #1;
        if ({8'b0, y} !== expected)
            $fatal(1, "sample=%0d expected=%0d actual=%0d", checks, expected, y);
        checks = checks + 1;
    end
    initial begin
        for (index = 0; index < 512; index = index + 1) begin
            @(negedge clk);
            rst_n = (index % 31 != 0);
            a = $random(seed);
            b = $random(seed);
            c = $random(seed);
        end
        @(negedge clk);
        if (checks != 513) $fatal(1, "incomplete reference run");
        $display("TIMING_DEMO_REFERENCE_PASS");
        $finish;
    end
endmodule