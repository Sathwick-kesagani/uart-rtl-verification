// uart_if.sv - Interfaces used by the class-based testbench.
//   uart_if     : every DUT pin the testbench drives or watches
//   tb_ctrl_if  : testbench-only controls (kept separate so no combinational
//                 logic reads and writes the same interface)
`timescale 1ns/1ps
interface uart_if;
    logic       clk = 1'b0;
    logic       rst_n;
    // transmit side
    logic [7:0] tx_data;
    logic       tx_start;
    logic       tx_busy;
    logic       tx_done;
    logic       tx;
    // receive side
    logic       rx;
    logic [7:0] rx_data;
    logic       rx_empty;
    logic       rx_full;
    logic       rx_overflow;
    logic       rx_frame_err;
endinterface

interface tb_ctrl_if;
    logic reader_en;   // 1: read the RX FIFO whenever it is not empty
endinterface
