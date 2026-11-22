module saturating_add #(parameter integer WIDTH = 8) (
    input  logic signed [WIDTH-1:0] a, b,
    output logic signed [WIDTH-1:0] y
);
    wire signed [WIDTH:0] total = $signed({a[WIDTH-1], a}) + $signed({b[WIDTH-1], b});
    localparam logic signed [WIDTH-1:0] MAX_VALUE = {1'b0, {(WIDTH-1){1'b1}}};
    localparam logic signed [WIDTH-1:0] MIN_VALUE = {1'b1, {(WIDTH-1){1'b0}}};

    // The sum fits in WIDTH bits when its two highest bits agree.
    wire overflow = total[WIDTH] ^ total[WIDTH-1];
    assign y = overflow ? (total[WIDTH] ? MIN_VALUE : MAX_VALUE) : total[WIDTH-1:0];
endmodule