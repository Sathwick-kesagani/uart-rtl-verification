`timescale 1ns/1ps
// uart_core.sv - UART with a receive FIFO.
module uart_core #(
    parameter int CLKS_PER_BIT = 16,
    parameter int FIFO_DEPTH   = 16
) (
    input  logic       clk,
    input  logic       rst_n,
    // transmit side
    input  logic [7:0] tx_data,
    input  logic       tx_start,
    output logic       tx_busy,
    output logic       tx_done,
    output logic       tx,
    // receive side
    input  logic       rx,
    input  logic       rx_rd_en,
    output logic [7:0] rx_data,
    output logic       rx_empty,
    output logic       rx_full,
    output logic       rx_overflow,
    output logic [$clog2(FIFO_DEPTH):0] rx_count,
    output logic       rx_frame_err
);
    logic [7:0] rx_byte;
    logic       rx_valid;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst_n(rst_n), .data(tx_data), .start(tx_start),
        .tx(tx), .busy(tx_busy), .done(tx_done)
    );

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(rx), .data(rx_byte), .valid(rx_valid), .frame_err(rx_frame_err)
    );

    sync_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(rx_valid), .din(rx_byte),
        .rd_en(rx_rd_en), .dout(rx_data),
        .full(rx_full), .empty(rx_empty), .count(rx_count),
        .overflow(rx_overflow)
    );
endmodule
