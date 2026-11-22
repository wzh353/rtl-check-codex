`timescale 1ns/1ps
module adder_holdout;
    logic signed [8:0] a, b;
    wire signed [8:0] y;
    integer seed = 919237;
    integer sample, expected;
    saturating_add #(.WIDTH(9)) dut (a, b, y);

    initial begin
        for (sample = 0; sample < 384; sample++) begin
            a = $random(seed);
            b = $random(seed);
            expected = $signed(a);
            expected = expected + $signed(b);
            if (expected > 255) expected = 255;
            if (expected < -256) expected = -256;
            #1;
            if ($signed(y) !== expected)
                $fatal(1, "validation sample=%0d expected=%0d actual=%0d", sample, expected, $signed(y));
        end
        $display("ADDER_HOLDOUT_PASS");
        $finish;
    end
endmodule