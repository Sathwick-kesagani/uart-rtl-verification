// tb_uart.sv - Self-checking testbench for uart_core.
//
// Stimulus  : TX->RX loopback, plus a bus-functional model (BFM) that drives
//             the RX line directly with chosen baud error, bad stop bits and glitches.
// Checking  : a scoreboard compares every byte read from the RX FIFO with the
//             byte that was sent, in order. Error pulses are counted and checked.
// Coverage  : counters for all 256 byte values and each scenario; the test fails
//             if any coverage bin was never hit.
// Run       : make sim   (Icarus Verilog), optional +seed=<n> +vcd
`timescale 1ns/1ps

module tb_uart;
    localparam int CLKS_PER_BIT = 16;
    localparam int FIFO_DEPTH   = 16;
    localparam real CLK_NS      = 10.0;                 // 100 MHz
    localparam real BIT_NS      = CLK_NS * CLKS_PER_BIT;

    // ---------------------------------------------------------------- DUT
    logic       clk = 0, rst_n = 0;
    logic [7:0] tx_data = 0;
    logic       tx_start = 0, tx_busy, tx_done, tx;
    logic       rx, rx_rd_en;
    logic [7:0] rx_data;
    logic       rx_empty, rx_full, rx_overflow, rx_frame_err;
    logic [$clog2(FIFO_DEPTH):0] rx_count;

    logic loopback = 1;     // 1: rx = tx, 0: rx driven by the BFM
    logic bfm_line = 1;
    assign rx = loopback ? tx : bfm_line;

    uart_core #(.CLKS_PER_BIT(CLKS_PER_BIT), .FIFO_DEPTH(FIFO_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .tx_data(tx_data), .tx_start(tx_start), .tx_busy(tx_busy), .tx_done(tx_done), .tx(tx),
        .rx(rx), .rx_rd_en(rx_rd_en), .rx_data(rx_data), .rx_empty(rx_empty), .rx_full(rx_full),
        .rx_overflow(rx_overflow), .rx_count(rx_count), .rx_frame_err(rx_frame_err)
    );

    always #(CLK_NS / 2) clk = ~clk;

    // --------------------------------------------------------- scoreboard
    logic [7:0] expected [0:8191];
    int exp_wr = 0, exp_rd = 0;
    int errors = 0;
    int checks = 0;
    logic reader_en = 1;

    assign rx_rd_en = reader_en && !rx_empty;

    always @(posedge clk) begin
        if (rx_rd_en) begin
            checks++;
            if (exp_rd >= exp_wr) begin
                errors++;
                $display("[%0t] ERROR unexpected byte 0x%02h (nothing was sent)", $time, rx_data);
            end else begin
                if (rx_data !== expected[exp_rd]) begin
                    errors++;
                    $display("[%0t] ERROR byte %0d: got 0x%02h expected 0x%02h",
                             $time, exp_rd, rx_data, expected[exp_rd]);
                end
                exp_rd++;
            end
        end
    end

    // ----------------------------------------------------------- coverage
    logic [255:0] value_seen = '0;
    int frame_err_cnt = 0, overflow_cnt = 0, full_seen = 0;
    int cov_back_to_back = 0, cov_baud_fast = 0, cov_baud_slow = 0;
    int cov_glitch_rejected = 0, cov_recover_after_frame_err = 0;

    always @(posedge clk) begin
        if (rx_frame_err) frame_err_cnt++;
        if (rx_overflow)  overflow_cnt++;
        if (rx_full)      full_seen++;
        if (dut.u_rx.valid) value_seen[dut.u_rx.data] = 1'b1;
    end

    task automatic check(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            errors++;
            $display("[%0t] ERROR %s", $time, msg);
        end
    endtask

    // ------------------------------------------------------ stimulus tasks
    // Send one byte through the DUT transmitter (loopback).
    task automatic tx_send(input logic [7:0] b, input bit expect_rx);
        @(negedge clk);
        while (tx_busy) @(negedge clk);
        tx_data  = b;
        tx_start = 1;
        if (expect_rx) begin
            expected[exp_wr] = b;
            exp_wr++;
        end
        @(negedge clk);
        tx_start = 0;
    endtask

    // Drive the RX line directly. pct = baud error in percent (+ = slower sender).
    task automatic bfm_send(input logic [7:0] b, input bit good_stop, input real pct);
        real t;
        t = BIT_NS * (1.0 + pct / 100.0);
        bfm_line = 0;              #(t);
        for (int i = 0; i < 8; i++) begin
            bfm_line = b[i];       #(t);
        end
        bfm_line = good_stop;      #(t);
        bfm_line = 1;              #(t);   // idle gap
    endtask

    task automatic wait_tx_idle();
        @(negedge clk);
        while (tx_busy) @(negedge clk);
        repeat (2 * CLKS_PER_BIT) @(negedge clk);    // let the receiver finish
    endtask

    task automatic wait_drain(input int max_bits);
        int n = 0;
        while (exp_rd < exp_wr && n < max_bits * CLKS_PER_BIT) begin
            @(negedge clk);
            n++;
        end
        check(exp_rd == exp_wr, $sformatf("drain timeout: %0d of %0d bytes received", exp_rd, exp_wr));
    endtask

    // --------------------------------------------------------------- tests
    integer seed = 1;
    int fe_before, ov_before;
    logic [7:0] r;

    initial begin
        if ($value$plusargs("seed=%d", seed)) $display("using seed from command line");
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/tb_uart.vcd");
            $dumpvars(0, tb_uart);
        end
        $display("UART testbench, seed=%0d, CLKS_PER_BIT=%0d", seed, CLKS_PER_BIT);

        repeat (5) @(negedge clk);
        // T1 reset state
        check(tx === 1'b1, "TX line must idle high after reset");
        check(rx_empty === 1'b1, "RX FIFO must be empty after reset");
        rst_n = 1;
        repeat (5) @(negedge clk);

        // T2 every byte value through loopback
        $display("T2 directed: all 256 byte values");
        for (int v = 0; v < 256; v++) tx_send(v[7:0], 1);
        wait_drain(40);

        // T3 random back-to-back bytes
        $display("T3 random: 500 back-to-back bytes");
        for (int i = 0; i < 500; i++) begin
            r = $random(seed);
            tx_send(r, 1);
        end
        cov_back_to_back = 500;
        wait_drain(40);

        // T4 baud-rate tolerance with the BFM (+2% and -2%)
        $display("T4 baud tolerance: +/-2%%");
        loopback = 0;
        for (int i = 0; i < 100; i++) begin
            r = $random(seed);
            expected[exp_wr] = r; exp_wr++;
            bfm_send(r, 1, 2.0);
            cov_baud_slow++;
        end
        for (int i = 0; i < 100; i++) begin
            r = $random(seed);
            expected[exp_wr] = r; exp_wr++;
            bfm_send(r, 1, -2.0);
            cov_baud_fast++;
        end
        wait_drain(40);

        // T5 framing error: no byte stored, error flagged, receiver recovers
        $display("T5 framing error and recovery");
        fe_before = frame_err_cnt;
        bfm_send(8'h55, 0, 0.0);
        repeat (2 * CLKS_PER_BIT) @(negedge clk);
        check(frame_err_cnt == fe_before + 1, "bad stop bit must raise exactly one frame_err");
        check(rx_empty === 1'b1, "a byte with a bad stop bit must not be stored");
        expected[exp_wr] = 8'hA7; exp_wr++;
        bfm_send(8'hA7, 1, 0.0);
        wait_drain(20);
        if (exp_rd == exp_wr) cov_recover_after_frame_err++;

        // T6 glitch shorter than half a bit is ignored
        $display("T6 start-bit glitch rejection");
        fe_before = frame_err_cnt;
        bfm_line = 0; #(BIT_NS * 0.25); bfm_line = 1;
        repeat (12 * CLKS_PER_BIT) @(negedge clk);
        check(rx_empty === 1'b1, "a glitch must not produce a byte");
        check(frame_err_cnt == fe_before, "a glitch must not produce a frame error");
        if (rx_empty && frame_err_cnt == fe_before) cov_glitch_rejected++;
        loopback = 1;

        // T7 FIFO full and overflow: send DEPTH+4 bytes while nobody reads
        $display("T7 FIFO full and overflow");
        reader_en = 0;
        ov_before = overflow_cnt;
        for (int i = 0; i < FIFO_DEPTH + 4; i++) tx_send(8'hC0 + i[7:0], i < FIFO_DEPTH);
        wait_tx_idle();
        check(rx_full === 1'b1, "FIFO must be full");
        check(rx_count == FIFO_DEPTH, $sformatf("FIFO count %0d, expected %0d", rx_count, FIFO_DEPTH));
        check(overflow_cnt == ov_before + 4, $sformatf("expected 4 overflow pulses, saw %0d", overflow_cnt - ov_before));
        reader_en = 1;
        wait_drain(10);
        check(rx_empty === 1'b1, "FIFO must be empty after draining");

        // ------------------------------------------------------ summary
        report();
        $finish;
    end

    task automatic report();
        int values = 0;
        int holes  = 0;
        for (int i = 0; i < 256; i++) if (value_seen[i]) values++;
        $display("");
        $display("==================== COVERAGE ====================");
        $display("  byte values received      %0d / 256", values);
        $display("  back-to-back bytes        %0d", cov_back_to_back);
        $display("  slow sender (+2%%) bytes   %0d", cov_baud_slow);
        $display("  fast sender (-2%%) bytes   %0d", cov_baud_fast);
        $display("  framing errors detected   %0d", frame_err_cnt);
        $display("  recovered after error     %0d", cov_recover_after_frame_err);
        $display("  glitches rejected         %0d", cov_glitch_rejected);
        $display("  FIFO full cycles          %0d", full_seen);
        $display("  FIFO overflows detected   %0d", overflow_cnt);
        if (values < 256)                     holes++;
        if (cov_back_to_back == 0)            holes++;
        if (cov_baud_slow == 0)               holes++;
        if (cov_baud_fast == 0)               holes++;
        if (frame_err_cnt == 0)               holes++;
        if (cov_recover_after_frame_err == 0) holes++;
        if (cov_glitch_rejected == 0)         holes++;
        if (full_seen == 0)                   holes++;
        if (overflow_cnt == 0)                holes++;
        $display("==================================================");
        $display("  bytes checked by scoreboard %0d, checks %0d", exp_rd, checks);
        if (errors == 0 && holes == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL (%0d errors, %0d coverage holes)", errors, holes);
    endtask

    // global timeout
    initial begin
        #(50_000_000);
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
