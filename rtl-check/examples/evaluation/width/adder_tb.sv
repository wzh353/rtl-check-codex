`timescale 1ns/1ps
module adder_tb;
    localparam integer W = `CASE_WIDTH;
    localparam integer HI = (1 <<< (W-1)) - 1;
    localparam integer LO = -(1 <<< (W-1));
    logic signed [W-1:0] a, b;
    wire signed [W-1:0] y;
    saturating_add #(.WIDTH(W)) dut (a, b, y);

    task automatic check(input integer lhs, rhs);
        integer expected;
        begin
            a = lhs; b = rhs;
            expected = lhs + rhs;
            if (expected > HI) expected = HI;
            if (expected < LO) expected = LO;
            #1;
            if ($signed(y) !== expected)
                $fatal(1, "width=%0d lhs=%0d rhs=%0d expected=%0d actual=%0d", W, lhs, rhs, expected, $signed(y));
        end
    endtask

    initial begin
        check(0, 0);
        check(4, -2);
        check(-5, -2);
        if (`SMALL_CASE == 0) begin
            check(HI-1, 1);
            check(HI, 1);
            check(LO, -1);
            check(LO, HI);
            check(HI, HI);
            check(LO, LO);
        end
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule