`timescale 1ns/1ps
// uart_tx.sv - UART transmitter, 8 data bits, no parity, 1 stop bit (8N1), LSB first.
// CLKS_PER_BIT = clock frequency / baud rate.
module uart_tx #(
    parameter int CLKS_PER_BIT = 16
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] data,
    input  logic       start,   // one-cycle request; ignored while busy
    output logic       tx,
    output logic       busy,
    output logic       done     // one-cycle pulse after the stop bit
);
    typedef enum logic [1:0] {IDLE, START_BIT, DATA_BITS, STOP_BIT} state_t;

    localparam int CW = $clog2(CLKS_PER_BIT);
    localparam int LAST_I = CLKS_PER_BIT - 1;
    localparam logic [CW-1:0] LAST = LAST_I[CW-1:0];
    localparam logic [CW-1:0] ONE  = {{(CW-1){1'b0}}, 1'b1};

    state_t        state;
    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shreg;

    assign busy = (state != IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            clk_cnt <= '0;
            bit_idx <= '0;
            shreg   <= '0;
            tx      <= 1'b1;
            done    <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        shreg   <= data;
                        clk_cnt <= '0;
                        tx      <= 1'b0;          // start bit
                        state   <= START_BIT;
                    end
                end
                START_BIT: begin
                    if (clk_cnt == LAST) begin
                        clk_cnt <= '0;
                        bit_idx <= '0;
                        tx      <= shreg[0];
                        state   <= DATA_BITS;
                    end else begin
                        clk_cnt <= clk_cnt + ONE;
                    end
                end
                DATA_BITS: begin
                    if (clk_cnt == LAST) begin
                        clk_cnt <= '0;
                        if (bit_idx == 3'd7) begin
                            tx    <= 1'b1;            // stop bit
                            state <= STOP_BIT;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                            tx      <= shreg[bit_idx + 3'd1];
                        end
                    end else begin
                        clk_cnt <= clk_cnt + ONE;
                    end
                end
                STOP_BIT: begin
                    if (clk_cnt == LAST) begin
                        clk_cnt <= '0;
                        done    <= 1'b1;
                        state   <= IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + ONE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
