// uart_tb_pkg.sv - Class-based, UVM-style verification environment for uart_core.
//
// Structure (same roles as a UVM testbench, written in plain SystemVerilog so it
// runs on open-source simulators):
//
//   test -> env -+- rx agent: rx_sequence -> serial_driver --(rx pin)--> DUT receiver
//                |                           fifo_monitor <--(FIFO read)-- DUT
//                +- tx agent: tx_sequence -> tx_driver --(tx_data/tx_start)--> DUT transmitter
//                |                           serial_monitor <--(tx pin)-- DUT
//                +- scoreboard  (expected vs observed, both directions, in order)
//                +- coverage    (byte values, item kinds, baud error, FIFO events)
//
// Drivers report what they sent to the scoreboard (like a UVM analysis port);
// monitors report what the DUT produced.
`timescale 1ns/1ps

package uart_tb_pkg;

    typedef enum int {GOOD = 0, BAD_STOP = 1, GLITCH = 2} item_kind_e;

    // ------------------------------------------------------------------ config
    class uart_cfg;
        int  clks_per_bit = 16;
        real clk_ns       = 10.0;
        int  fifo_depth   = 16;
        function real bit_ns();
            return clk_ns * clks_per_bit;
        endfunction
    endclass

    // -------------------------------------------------------------- transaction
    class uart_item;
        bit [7:0]   data;
        item_kind_e kind          = GOOD;
        int         baud_pct      = 0;   // sender bit-time error in percent
        bit         expect_stored = 1;   // 0 when the test expects the FIFO to drop it

        // Weighted randomization (85% good, 10% bad stop bit, 5% glitch),
        // baud error in -2..+2 % on good frames.
        function void randomize_item(bit allow_errors);
            int r;
            data = 8'($urandom_range(255, 0));
            r    = $urandom_range(99, 0);
            if (!allow_errors || r < 85) kind = GOOD;
            else if (r < 95)             kind = BAD_STOP;
            else                         kind = GLITCH;
            baud_pct = (kind == GOOD) ? $urandom_range(4, 0) - 2 : 0;
        endfunction

        function string convert2string();
            return $sformatf("%s data=0x%02h baud=%0d%%", kind.name(), data, baud_pct);
        endfunction
    endclass

    // ------------------------------------------------------------- coverage
    class uart_coverage;
        bit [255:0] rx_values, tx_values;
        int kind_cnt [3];
        int baud_cnt [5];            // -2..+2 %
        int overflow_cnt, full_cycles, back_to_back_tx;

        function void sample_rx_item(uart_item it);
            kind_cnt[int'(it.kind)]++;
            if (it.kind == GOOD) baud_cnt[it.baud_pct + 2]++;
        endfunction

        function void sample_rx_byte(bit [7:0] b); rx_values[b] = 1'b1; endfunction
        function void sample_tx_byte(bit [7:0] b); tx_values[b] = 1'b1; endfunction

        function int count_bits(bit [255:0] v);
            int n = 0;
            for (int i = 0; i < 256; i++) if (v[i]) n++;
            return n;
        endfunction

        // returns the number of empty coverage bins
        function int report(bit need_errors, bit need_overflow, bit need_all_values);
            int holes = 0;
            $display("------------------------- COVERAGE -------------------------");
            $display("  RX byte values           %0d / 256", count_bits(rx_values));
            $display("  TX byte values           %0d / 256", count_bits(tx_values));
            $display("  RX items  good/bad-stop/glitch   %0d / %0d / %0d", kind_cnt[0], kind_cnt[1], kind_cnt[2]);
            $display("  baud error -2/-1/0/+1/+2 %%       %0d / %0d / %0d / %0d / %0d",
                     baud_cnt[0], baud_cnt[1], baud_cnt[2], baud_cnt[3], baud_cnt[4]);
            $display("  back-to-back TX bytes    %0d", back_to_back_tx);
            $display("  FIFO full cycles         %0d", full_cycles);
            $display("  FIFO overflows           %0d", overflow_cnt);
            if (need_all_values && count_bits(rx_values) < 256) holes++;
            if (need_all_values && count_bits(tx_values) < 256) holes++;
            if (kind_cnt[0] == 0) holes++;
            if (need_errors) begin
                if (kind_cnt[1] == 0) holes++;
                if (kind_cnt[2] == 0) holes++;
                foreach (baud_cnt[i]) if (baud_cnt[i] == 0) holes++;
            end
            if (need_overflow && (overflow_cnt == 0 || full_cycles == 0)) holes++;
            $display("  coverage holes           %0d", holes);
            return holes;
        endfunction
    endclass

    // ------------------------------------------------------------ scoreboard
    class uart_scoreboard;
        bit [7:0] rx_exp[$];
        bit [7:0] tx_exp[$];
        int rx_checked, tx_checked, errors;
        int frame_err_exp, frame_err_obs;

        function void error(string msg);
            errors++;
            $display("[%0t] SCOREBOARD ERROR: %s", $time, msg);
        endfunction

        // from drivers (what was sent)
        function void write_rx_expected(uart_item it);
            if (it.kind == GOOD && it.expect_stored) rx_exp.push_back(it.data);
            if (it.kind == BAD_STOP) frame_err_exp++;
        endfunction
        function void write_tx_expected(bit [7:0] b); tx_exp.push_back(b); endfunction

        // from monitors (what the DUT produced)
        function void write_rx_observed(bit [7:0] b);
            bit [7:0] e;
            if (rx_exp.size() == 0) begin
                error($sformatf("RX: unexpected byte 0x%02h", b));
                return;
            end
            e = rx_exp.pop_front();
            rx_checked++;
            if (b !== e) error($sformatf("RX: got 0x%02h expected 0x%02h", b, e));
        endfunction

        function void write_tx_observed(bit [7:0] b, bit stop_ok);
            bit [7:0] e;
            if (!stop_ok) error($sformatf("TX: byte 0x%02h sent with a bad stop bit", b));
            if (tx_exp.size() == 0) begin
                error($sformatf("TX: unexpected byte 0x%02h on the line", b));
                return;
            end
            e = tx_exp.pop_front();
            tx_checked++;
            if (b !== e) error($sformatf("TX: got 0x%02h expected 0x%02h", b, e));
        endfunction

        function void write_frame_err(); frame_err_obs++; endfunction

        function bit drained();
            return rx_exp.size() == 0 && tx_exp.size() == 0;
        endfunction

        function void check_end();
            if (rx_exp.size() != 0) error($sformatf("RX: %0d expected bytes never arrived", rx_exp.size()));
            if (tx_exp.size() != 0) error($sformatf("TX: %0d expected bytes never appeared on the line", tx_exp.size()));
            if (frame_err_obs != frame_err_exp)
                error($sformatf("framing errors: observed %0d, expected %0d", frame_err_obs, frame_err_exp));
            $display("------------------------- SCOREBOARD -----------------------");
            $display("  RX bytes checked         %0d", rx_checked);
            $display("  TX bytes checked         %0d", tx_checked);
            $display("  framing errors           %0d observed / %0d expected", frame_err_obs, frame_err_exp);
            $display("  errors                   %0d", errors);
        endfunction
    endclass

    // ------------------------------------------------------- rx agent: driver
    // Drives the DUT's rx pin like an external UART would, including errors.
    class serial_driver;
        virtual uart_if   vif;
        uart_cfg          cfg;
        mailbox #(uart_item) seq_mbx;
        uart_scoreboard   sb;
        uart_coverage     cov;
        bit               busy;

        task run();
            uart_item it;
            vif.rx = 1'b1;
            forever begin
                seq_mbx.get(it);
                busy = 1;
                sb.write_rx_expected(it);
                cov.sample_rx_item(it);
                drive(it);
                busy = 0;
            end
        endtask

        task drive(uart_item it);
            real t = cfg.bit_ns() * (1.0 + it.baud_pct / 100.0);
            if (it.kind == GLITCH) begin
                vif.rx = 1'b0; #(cfg.bit_ns() * 0.25);
                vif.rx = 1'b1; #(cfg.bit_ns() * 12.0);
                return;
            end
            vif.rx = 1'b0; #(t);                                   // start bit
            for (int i = 0; i < 8; i++) begin vif.rx = it.data[i]; #(t); end
            vif.rx = (it.kind == GOOD); #(t);                      // stop bit
            vif.rx = 1'b1; #(t * ((it.kind == GOOD) ? 1.0 : 2.0)); // idle
        endtask
    endclass

    // ------------------------------------------------- rx agent: FIFO monitor
    class fifo_monitor;
        virtual uart_if    vif;
        virtual tb_ctrl_if ctrl;
        uart_scoreboard sb;
        uart_coverage   cov;

        task run();
            forever begin
                @(posedge vif.clk);
                if (ctrl.reader_en && !vif.rx_empty) begin   // FIFO read this cycle
                    sb.write_rx_observed(vif.rx_data);
                    cov.sample_rx_byte(vif.rx_data);
                end
                if (vif.rx_frame_err) sb.write_frame_err();
                if (vif.rx_overflow)  cov.overflow_cnt++;
                if (vif.rx_full)      cov.full_cycles++;
            end
        endtask
    endclass

    // ------------------------------------------------------- tx agent: driver
    class tx_driver;
        virtual uart_if   vif;
        mailbox #(uart_item) seq_mbx;
        uart_scoreboard   sb;
        uart_coverage     cov;
        bit               busy;

        task run();
            uart_item it;
            vif.tx_start = 1'b0;
            vif.tx_data  = '0;
            forever begin
                seq_mbx.get(it);
                busy = 1;
                @(negedge vif.clk);
                if (vif.tx_busy) begin
                    while (vif.tx_busy) @(negedge vif.clk);
                    cov.back_to_back_tx++;   // queued while the previous byte was still going out
                end
                vif.tx_data  = it.data;
                vif.tx_start = 1'b1;
                sb.write_tx_expected(it.data);
                @(negedge vif.clk);
                vif.tx_start = 1'b0;
                busy = 0;
            end
        endtask
    endclass

    // ---------------------------------------------- tx agent: serial monitor
    // Decodes the DUT's tx pin independently of the DUT's own receiver.
    class serial_monitor;
        virtual uart_if vif;
        uart_cfg        cfg;
        uart_scoreboard sb;
        uart_coverage   cov;

        task run();
            bit [7:0] b;
            bit       stop;
            forever begin
                @(negedge vif.tx);
                if (!vif.rst_n) continue;
                #(cfg.bit_ns() / 2.0);                 // middle of the start bit
                if (vif.tx !== 1'b0) begin
                    sb.error("TX: start bit not held low");
                    continue;
                end
                for (int i = 0; i < 8; i++) begin
                    #(cfg.bit_ns());
                    b[i] = vif.tx;
                end
                #(cfg.bit_ns());
                stop = vif.tx;
                sb.write_tx_observed(b, stop);
                cov.sample_tx_byte(b);
            end
        endtask
    endclass

    // --------------------------------------------------------------- sequences
    class base_sequence;
        int n = 0;
        virtual task body(mailbox #(uart_item) mbx); endtask
    endclass

    class random_sequence extends base_sequence;
        bit allow_errors = 1;
        virtual task body(mailbox #(uart_item) mbx);
            uart_item it;
            repeat (n) begin
                it = new();
                it.randomize_item(allow_errors);
                mbx.put(it);
            end
        endtask
    endclass

    class all_values_sequence extends base_sequence;
        virtual task body(mailbox #(uart_item) mbx);
            uart_item it;
            for (int v = 0; v < 256; v++) begin
                it = new();
                it.data = 8'(v);
                mbx.put(it);
            end
        endtask
    endclass

    // fill the FIFO past full: the first 'keep' bytes must survive, the rest are dropped
    class overflow_sequence extends base_sequence;
        int keep = 16;
        virtual task body(mailbox #(uart_item) mbx);
            uart_item it;
            for (int i = 0; i < n; i++) begin
                it = new();
                it.data          = 8'(8'hC0 + i);
                it.expect_stored = (i < keep);
                mbx.put(it);
            end
        endtask
    endclass

    // ---------------------------------------------------------------------- env
    class uart_env;
        uart_cfg           cfg;
        virtual uart_if    vif;
        virtual tb_ctrl_if ctrl;
        mailbox #(uart_item) rx_mbx, tx_mbx;
        serial_driver   rx_drv;
        fifo_monitor    rx_mon;
        tx_driver       tx_drv;
        serial_monitor  tx_mon;
        uart_scoreboard sb;
        uart_coverage   cov;

        function new(virtual uart_if vif, virtual tb_ctrl_if ctrl, uart_cfg cfg);
            this.vif  = vif;
            this.ctrl = ctrl;
            this.cfg  = cfg;
        endfunction

        function void build();
            rx_mbx = new(1);    // depth 1: the sequence waits for the driver
            tx_mbx = new(1);
            sb     = new();
            cov    = new();
            rx_drv = new();  tx_drv = new();
            rx_mon = new();  tx_mon = new();
        endfunction

        function void connect();
            rx_drv.vif = vif; rx_drv.cfg = cfg; rx_drv.seq_mbx = rx_mbx; rx_drv.sb = sb; rx_drv.cov = cov;
            rx_mon.vif = vif; rx_mon.ctrl = ctrl; rx_mon.sb = sb; rx_mon.cov = cov;
            tx_drv.vif = vif; tx_drv.seq_mbx = tx_mbx; tx_drv.sb = sb; tx_drv.cov = cov;
            tx_mon.vif = vif; tx_mon.cfg = cfg; tx_mon.sb = sb; tx_mon.cov = cov;
        endfunction

        task run();
            fork
                rx_drv.run();
                rx_mon.run();
                tx_drv.run();
                tx_mon.run();
            join_none
        endtask

        // wait until both drivers are idle and every expected byte was seen
        task wait_drain(int max_bits);
            int n = 0;
            while (n < max_bits * cfg.clks_per_bit &&
                   (rx_drv.busy || tx_drv.busy || rx_mbx.num() != 0 || tx_mbx.num() != 0 ||
                    vif.tx_busy || !sb.drained())) begin
                @(posedge vif.clk);
                n++;
            end
            repeat (4 * cfg.clks_per_bit) @(posedge vif.clk);
        endtask
    endclass

    // -------------------------------------------------------------------- tests
    class base_test;
        uart_env env;
        uart_cfg cfg;
        string   name = "base_test";
        bit      need_errors, need_overflow, need_all_values;

        function new(virtual uart_if vif, virtual tb_ctrl_if ctrl);
            cfg = new();
            env = new(vif, ctrl, cfg);
        endfunction

        virtual task body(); endtask

        task run_test();
            int holes;
            $display("=== %s ===", name);
            env.build();
            env.connect();
            env.ctrl.reader_en = 1'b1;
            env.vif.rst_n = 1'b0;
            repeat (5) @(posedge env.vif.clk);
            env.vif.rst_n = 1'b1;
            repeat (5) @(posedge env.vif.clk);
            env.run();
            body();
            env.wait_drain(400);
            env.sb.check_end();
            holes = env.cov.report(need_errors, need_overflow, need_all_values);
            if (env.sb.errors == 0 && holes == 0) $display("RESULT: PASS (%s)", name);
            else $display("RESULT: FAIL (%s: %0d errors, %0d coverage holes)", name, env.sb.errors, holes);
        endtask
    endclass

    // Full duplex: random traffic in both directions at the same time,
    // with bad stop bits, glitches and +/-2% baud error on the receive side.
    class random_test extends base_test;
        function new(virtual uart_if vif, virtual tb_ctrl_if ctrl); super.new(vif, ctrl); name = "random_test"; need_errors = 1; endfunction
        virtual task body();
            random_sequence rx_seq = new();
            random_sequence tx_seq = new();
            rx_seq.n = 400;
            tx_seq.n = 400; tx_seq.allow_errors = 0;
            fork
                rx_seq.body(env.rx_mbx);
                tx_seq.body(env.tx_mbx);
            join
        endtask
    endclass

    class all_values_test extends base_test;
        function new(virtual uart_if vif, virtual tb_ctrl_if ctrl); super.new(vif, ctrl); name = "all_values_test"; need_all_values = 1; endfunction
        virtual task body();
            all_values_sequence rx_seq = new();
            all_values_sequence tx_seq = new();
            fork
                rx_seq.body(env.rx_mbx);
                tx_seq.body(env.tx_mbx);
            join
        endtask
    endclass

    class overflow_test extends base_test;
        function new(virtual uart_if vif, virtual tb_ctrl_if ctrl); super.new(vif, ctrl); name = "overflow_test"; need_overflow = 1; endfunction
        virtual task body();
            overflow_sequence seq = new();
            seq.n    = cfg.fifo_depth + 4;
            seq.keep = cfg.fifo_depth;
            env.ctrl.reader_en = 1'b0;          // nobody reads: the FIFO must fill and overflow
            seq.body(env.rx_mbx);
            while (env.rx_drv.busy || env.rx_mbx.num() != 0) @(posedge env.vif.clk);
            repeat (2 * cfg.clks_per_bit) @(posedge env.vif.clk);
            if (env.cov.overflow_cnt != 4)
                env.sb.error($sformatf("expected 4 overflow pulses, saw %0d", env.cov.overflow_cnt));
            env.ctrl.reader_en = 1'b1;          // now drain and check the 16 kept bytes
        endtask
    endclass

endpackage
