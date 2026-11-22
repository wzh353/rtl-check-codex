`timescale 1ns/1ps
module fifo_reference_tb;
    logic clk = 0, rst_n = 0, in_valid = 0, out_ready = 0;
    logic [7:0] in_data = 0;
    wire in_ready, out_valid;
    wire [7:0] out_data;
    stream_fifo dut (clk, rst_n, in_valid, in_ready, in_data, out_valid, out_ready, out_data);
    always #5 clk = ~clk;

    logic [7:0] sequence_data [0:3];
    int n = 0, wr = 0, rd = 0, seed = 15831, cycle_id, concurrent_full = 0;
    bit take_in, take_out, ready_expected, valid_expected;

    initial begin
        for (cycle_id = 0; cycle_id < 384; cycle_id++) begin
            @(negedge clk);
            rst_n = cycle_id % 49 != 0;
            in_valid = $unsigned($random(seed)) % 4 != 0;
            out_ready = $unsigned($random(seed)) % 3 != 0;
            in_data = $random(seed);
            @(posedge clk);
            if (!rst_n) begin
                n = 0; wr = 0; rd = 0;
            end else begin
                valid_expected = n > 0;
                ready_expected = n < 4 || (valid_expected && out_ready);
                take_out = valid_expected && out_ready;
                take_in = ready_expected && in_valid;
                if (out_valid !== valid_expected || in_ready !== ready_expected)
                    $fatal(1, "cycle=%0d depth=%0d valid=%b expected_valid=%b ready=%b expected_ready=%b",
                           cycle_id, n, out_valid, valid_expected, in_ready, ready_expected);
                if (valid_expected && out_data !== sequence_data[rd])
                    $fatal(1, "cycle=%0d FIFO ordering expected=%h actual=%h",
                           cycle_id, sequence_data[rd], out_data);
                if (n == 4 && take_in && take_out) concurrent_full++;
                if (take_out) begin rd = (rd + 1) % 4; n--; end
                if (take_in) begin sequence_data[wr] = in_data; wr = (wr + 1) % 4; n++; end
            end
            #1;
        end
        if (concurrent_full < 10) $fatal(1, "insufficient full-depth replacements: %0d", concurrent_full);
        $display("FIFO_REFERENCE_PASS");
        $finish;
    end
endmodule