// tb_top.sv - Top level for the class-based testbench.
// Select a test with +TEST=random_test | all_values_test | overflow_test, and a seed with +seed=N.
`timescale 1ns/1ps
module tb_top;
    import uart_tb_pkg::*;

    uart_if    vif ();
    tb_ctrl_if ctrl ();
    always #5 vif.clk = ~vif.clk;         // 100 MHz

    logic rx_rd_en;
    assign rx_rd_en = ctrl.reader_en && !vif.rx_empty;

    uart_core #(.CLKS_PER_BIT(16), .FIFO_DEPTH(16)) dut (
        .clk(vif.clk), .rst_n(vif.rst_n),
        .tx_data(vif.tx_data), .tx_start(vif.tx_start), .tx_busy(vif.tx_busy), .tx_done(vif.tx_done), .tx(vif.tx),
        .rx(vif.rx), .rx_rd_en(rx_rd_en), .rx_data(vif.rx_data), .rx_empty(vif.rx_empty), .rx_full(vif.rx_full),
        .rx_overflow(vif.rx_overflow), .rx_count(), .rx_frame_err(vif.rx_frame_err)
    );

    initial begin
        string    test_name;
        int       seed;
        base_test t;
        if (!$value$plusargs("TEST=%s", test_name)) test_name = "random_test";
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));
        $display("class-based UART testbench: %s, seed %0d", test_name, seed);
        case (test_name)
            "all_values_test": begin all_values_test x = new(vif, ctrl); t = x; end
            "overflow_test":   begin overflow_test   x = new(vif, ctrl); t = x; end
            default:           begin random_test     x = new(vif, ctrl); t = x; end
        endcase
        t.run_test();
        $finish;
    end

    initial begin
        #200_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
