`timescale 1ns/1ps
module product_tb;
    reg clk = 0, rst_n = 0;
    reg [7:0] a = 0, b = 0, c = 0;
    wire [23:0] y;
    reg [23:0] previous = 0;
    product_pipe dut (clk, rst_n, a, b, c, y);
    always #7 clk = ~clk;
    task cycle(input reg active, input reg [7:0] aa, bb, cc);
        begin
            @(negedge clk);
            rst_n = active;
            a = aa; b = bb; c = cc;
            @(posedge clk);
            #1;
            if (y !== (active ? previous : 24'd0))
                $fatal(1, "a=%0d b=%0d c=%0d expected=%0d actual=%0d", aa, bb, cc, active ? previous : 24'd0, y);
            previous = active ? aa * bb * cc : 24'd0;
        end
    endtask
    initial begin
        cycle(0, 0, 0, 0);
        cycle(1, 8'd13, 8'd17, 8'd29);
        cycle(1, 8'hff, 8'hff, 8'hff);
        cycle(1, 8'd5, 8'd31, 8'd151);
        cycle(1, 8'hff, 8'hff, 8'd0);
        cycle(1, 8'd1, 8'hff, 8'hff);
        cycle(0, 8'hff, 8'hff, 8'hff);
        cycle(1, 8'd24, 8'd32, 8'd48);
        cycle(1, 0, 0, 0);
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule