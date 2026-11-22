`timescale 1ns/1ps
module blink_tb;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire led;
    integer cycle;
    integer count;
    reg expected_led;

    always #10 clk = ~clk;

    mes50hp_blink #(.COUNTER_BITS(3)) dut (.clk(clk), .rst_n(rst_n), .led(led));

    initial begin
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        for (cycle = 1; cycle <= 18; cycle = cycle + 1) begin
            @(posedge clk);
            #1;
            count = cycle <= 2 ? 0 : (cycle - 2) % 8;
            expected_led = count >= 4;
            if (led !== expected_led)
                $fatal(1, "blink cycle=%0d expected=%b actual=%b", cycle, expected_led, led);
        end
        $display("PANGO_BLINK_PASS");
        $finish;
    end
endmodule
