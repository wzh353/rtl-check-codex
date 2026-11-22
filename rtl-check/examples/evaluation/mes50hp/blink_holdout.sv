`timescale 1ns/1ps
module blink_holdout;
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    wire led;

    always #10 clk = ~clk;

    mes50hp_blink #(.COUNTER_BITS(2)) dut (.clk(clk), .rst_n(rst_n), .led(led));

    initial begin
        @(negedge clk);
        #3 rst_n = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        if (led !== 1'b1) $fatal(1, "LED never rose after reset release");
        #2 rst_n = 1'b0;
        #1;
        if (led !== 1'b1) $fatal(1, "LED changed before a rising clock edge");
        @(posedge clk);
        #1;
        if (led !== 1'b0) $fatal(1, "LED did not clear on the next rising edge");
        $display("PANGO_BLINK_HOLDOUT_PASS");
        $finish;
    end
endmodule
