module counter_wave_observer;
    time drive_tick;
    integer previous_cycle = 0;
    logic [7:0] expected = 'x;

    initial $display("RTL_WAVE_SEED|none");

    // step drives rst_n and en at this edge. Strobe observes both after the assignments.
    always @(negedge counter_tb.clk) begin
        drive_tick = $simtime();
        $strobe("RTL_WAVE_DRIVE|%0d|rst_n=%b,en=%b", drive_tick, counter_tb.rst_n, counter_tb.en);
    end

    function automatic void record_check();
        string scene;
        if (counter_tb.cycle > previous_cycle) begin
            previous_cycle = counter_tb.cycle;
            if (counter_tb.rst_n === 1'b0) begin
                expected = 0;
                scene = "Synchronous reset";
            end else if (counter_tb.rst_n === 1'b1 && counter_tb.en === 1'b0) begin
                scene = "Hold";
            end else if (counter_tb.rst_n === 1'b1 && counter_tb.en === 1'b1) begin
                scene = expected === 8'd255 ? "Wrap 255 to 0" : "Increment";
                expected = expected + 8'd1;
            end else begin
                expected = 'x;
                scene = "Unknown control value";
            end
            $display("RTL_WAVE_SAMPLE|%0d|%0d|%s|step|count=%b|count=%b",
                drive_tick, $simtime(), scene, expected, counter_tb.count);
        end
    endfunction

    // The testbench increments cycle immediately before its assertion after #1.
    always @(counter_tb.cycle) record_check();
    // The last assertion and $finish can run in the same active event.
    final record_check();
endmodule
