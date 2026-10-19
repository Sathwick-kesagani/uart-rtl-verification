`timescale 1ns/1ps
// uart_rx.sv - UART receiver, 8N1, LSB first.
// The input is synchronised with two flip-flops, the start bit is confirmed at
// its middle, and every following bit is sampled in its middle. A missing stop
// bit raises frame_err, and the receiver then waits for the line to go idle.
module uart_rx #(
    parameter int CLKS_PER_BIT = 16
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid,      // one-cycle pulse, data is good
    output logic       frame_err   // one-cycle pulse, stop bit was 0
);
    typedef enum logic [2:0] {IDLE, START_BIT, DATA_BITS, STOP_BIT, WAIT_IDLE} state_t;

    localparam int CW   = $clog2(CLKS_PER_BIT);
    localparam int LAST_I = CLKS_PER_BIT - 1;
    localparam logic [CW-1:0] LAST = LAST_I[CW-1:0];
    localparam logic [CW-1:0] ONE  = {{(CW-1){1'b0}}, 1'b1};
    localparam int MID_I = CLKS_PER_BIT / 2 - 1;
    localparam logic [CW-1:0] MID  = MID_I[CW-1:0];

    state_t        state;
    logic [CW-1:0] clk_cnt;
    logic [2:0]    bit_idx;
    logic [7:0]    shreg;
    logic          rx_s1, rx_s2;   // two-flop synchroniser

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s1 <= 1'b1;
            rx_s2 <= 1'b1;
        end else begin
            rx_s1 <= rx;
            rx_s2 <= rx_s1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            clk_cnt   <= '0;
            bit_idx   <= '0;
            shreg     <= '0;
            data      <= '0;
            valid     <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            valid     <= 1'b0;
            frame_err <= 1'b0;
            case (state)
                IDLE: begin
                    clk_cnt <= '0;
                    if (!rx_s2) state <= START_BIT;
                end
                START_BIT: begin
                    if (clk_cnt == MID) begin
                        clk_cnt <= '0;
                        bit_idx <= '0;
                        // still low in the middle: real start bit, else a glitch
                        state   <= rx_s2 ? IDLE : DATA_BITS;
                    end else begin
                        clk_cnt <= clk_cnt + ONE;
                    end
                end
                DATA_BITS: begin
                    if (clk_cnt == LAST) begin
                        clk_cnt <= '0;
                        shreg   <= {rx_s2, shreg[7:1]};   // LSB first
                        if (bit_idx == 3'd7) state <= STOP_BIT;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else begin
                        clk_cnt <= clk_cnt + ONE;
                    end
                end
                STOP_BIT: begin
                    if (clk_cnt == LAST) begin
                        clk_cnt <= '0;
                        if (rx_s2) begin
                            data  <= shreg;
                            valid <= 1'b1;
                            state <= IDLE;
                        end else begin
                            frame_err <= 1'b1;
                            state     <= WAIT_IDLE;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + ONE;
                    end
                end
                WAIT_IDLE: begin
                    if (rx_s2) state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
