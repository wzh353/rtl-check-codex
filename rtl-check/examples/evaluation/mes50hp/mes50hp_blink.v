module mes50hp_blink #(
    parameter integer COUNTER_BITS = 25
) (
    input  wire clk,
    input  wire rst_n,
    output wire led
);
    reg [1:0] reset_sync;
    reg [COUNTER_BITS-1:0] ticks;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reset_sync <= 2'b00;
        else        reset_sync <= {reset_sync[0], 1'b1};
    end

    always @(posedge clk) begin
        if (!reset_sync[1]) ticks <= {COUNTER_BITS{1'b0}};
        else                ticks <= ticks + 1'b1;
    end

    assign led = ticks[COUNTER_BITS-1];
endmodule
