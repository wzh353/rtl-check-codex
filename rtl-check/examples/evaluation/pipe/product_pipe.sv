module product_pipe(input logic clk, rst_n, input logic [7:0] a, b, c, output logic [23:0] y);
    logic [15:0] ab;
    logic [7:0] c_delayed;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ab <= '0;
            c_delayed <= '0;
            y <= '0;
        end else begin
            ab <= a * b;
            c_delayed <= c;
            y <= ab * c_delayed;
        end
    end
endmodule