`timescale 1ns/1ps

module counter (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       en,
    output logic [7:0] count
);
    wire [7:0] step;
    step_value increment(.value(step));
    always_ff @(posedge clk) begin
        if (!rst_n)
            count <= 8'd0;
        else if (en)
            count <= count + step;
    end
endmodule
