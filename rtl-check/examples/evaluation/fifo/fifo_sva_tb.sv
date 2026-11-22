`timescale 1ns/1ps
module fifo_sva_tb;
    logic clk = 0, rst_n = 0, in_valid = 0, out_ready = 0;
    logic [7:0] in_data = 0;
    wire in_ready, out_valid;
    wire [7:0] out_data;
    stream_fifo dut (clk, rst_n, in_valid, in_ready, in_data, out_valid, out_ready, out_data);
    always #5 clk = ~clk;

    accepts_replacement: assert property (@(posedge clk) disable iff (!rst_n)
        (in_valid && out_valid && out_ready) |-> in_ready)
        else $error("Simultaneous consumption must allow a replacement. used=%0d in_ready=%b out_ready=%b",
                    $sampled(dut.used), $sampled(in_ready), $sampled(out_ready));

    task automatic cycle(
        input bit iv, input logic [7:0] data, input bit dr,
        input bit expect_valid, input logic [7:0] expected
    );
        @(negedge clk);
        in_valid = iv; in_data = data; out_ready = dr;
        @(posedge clk);
        if (out_valid !== expect_valid || (expect_valid && out_data !== expected))
            $fatal(1, "out_valid=%b expected_valid=%b out_data=%h expected_data=%h",
                   out_valid, expect_valid, out_data, expected);
        #1;
    endtask

    initial begin
        @(negedge clk);
        rst_n = 1;
        cycle(1, 8'h11, 0, 0, 8'h00);
        cycle(1, 8'h22, 0, 1, 8'h11);
        cycle(1, 8'h33, 0, 1, 8'h11);
        cycle(1, 8'h44, 0, 1, 8'h11);
        cycle(1, 8'h55, 1, 1, 8'h11);
        cycle(0, 8'h00, 1, 1, 8'h22);
        cycle(0, 8'h00, 1, 1, 8'h33);
        cycle(0, 8'h00, 1, 1, 8'h44);
        cycle(0, 8'h00, 1, 1, 8'h55);
        cycle(0, 8'h00, 1, 0, 8'h00);
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule