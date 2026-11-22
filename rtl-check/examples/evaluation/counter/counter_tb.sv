`timescale 1ns/1ps

module counter_tb;
    logic clk = 0;
    logic rst_n = 0;
    logic en = 0;
    wire [7:0] count;
    integer cycle = 0;
    integer expected;

    counter dut (clk, rst_n, en, count);
    always #5 clk = ~clk;

    task automatic step(input logic reset_released, input logic enable,
                        input logic [7:0] expected_count);
        @(negedge clk);
        rst_n = reset_released;
        en = enable;
        @(posedge clk);
        #1;
        cycle = cycle + 1;
        if (count !== expected_count)
            $fatal(1, "cycle=%0d rst_n=%b en=%b expected=%0d actual=%0d",
                   cycle, rst_n, en, expected_count, count);
    endtask

    initial begin
        step(0, 1, 0);
        step(1, 0, 0);
        step(1, 1, 1);
        step(1, 0, 1);
        for (expected = 2; expected <= 255; expected = expected + 1)
            step(1, 1, expected[7:0]);
        step(1, 1, 0);
        step(1, 1, 1);
        step(0, 1, 0);
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule
