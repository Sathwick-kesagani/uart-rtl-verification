`timescale 1ns/1ps
// sync_fifo.sv - Synchronous FIFO, first-word fall-through (dout shows the
// oldest entry while not empty). DEPTH must be a power of two.
module sync_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             wr_en,
    input  logic [WIDTH-1:0] din,
    input  logic             rd_en,
    output logic [WIDTH-1:0] dout,
    output logic             full,
    output logic             empty,
    output logic [$clog2(DEPTH):0] count,
    output logic             overflow   // one-cycle pulse: write while full was dropped
);
    localparam int AW = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    localparam logic [AW:0] ONE = {{AW{1'b0}}, 1'b1};

    logic [AW:0]      wr_ptr, rd_ptr;   // extra bit tells full from empty

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    assign count = wr_ptr - rd_ptr;
    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign dout  = mem[rd_ptr[AW-1:0]];

    always_ff @(posedge clk) begin
        if (do_wr) mem[wr_ptr[AW-1:0]] <= din;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            overflow <= 1'b0;
        end else begin
            overflow <= wr_en && full;
            if (do_wr) wr_ptr <= wr_ptr + ONE;
            if (do_rd) rd_ptr <= rd_ptr + ONE;
        end
    end
endmodule
