module stream_fifo (
    input  logic       clk, rst_n,
    input  logic       in_valid,
    output logic       in_ready,
    input  logic [7:0] in_data,
    output logic       out_valid,
    input  logic       out_ready,
    output logic [7:0] out_data
);
    logic [7:0] slots [0:3];
    logic [1:0] read_ptr, write_ptr;
    logic [2:0] used;
    wire pop = out_valid && out_ready;
    wire push = in_valid && in_ready;

    assign in_ready = (used < 3'd4) || pop;
    assign out_valid = used != 3'd0;
    assign out_data = slots[read_ptr];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_ptr <= 0;
            write_ptr <= 0;
            used <= 0;
        end else begin
            if (pop) read_ptr <= read_ptr + 1'b1;
            if (push) begin
                slots[write_ptr] <= in_data;
                write_ptr <= write_ptr + 1'b1;
            end
            case ({push, pop})
                2'b10: used <= used + 1'b1;
                2'b01: used <= used - 1'b1;
                default: used <= used;
            endcase
        end
    end
endmodule