module step_value_tb;
    wire [7:0] value;
    step_value dut (.value(value));
    initial begin
        #1;
        if (value !== 8'd1) $fatal(1, "step value must be one, actual=%0d", value);
        $display("RTL_CHECK_PASS");
        $finish;
    end
endmodule