# make sim         run the testbench once (Icarus Verilog), SEED=n to change the seed
# make regress     run 5 seeds
# make lint        lint the RTL with Verilator -Wall
# make wave        run with a VCD waveform dump (open sim/tb_uart.vcd in GTKWave)

RTL  := rtl/uart_tx.sv rtl/uart_rx.sv rtl/sync_fifo.sv rtl/uart_core.sv
TB   := tb/tb_uart.sv
SEED ?= 1

.PHONY: sim regress lint wave clean
sim:
	mkdir -p sim
	iverilog -g2012 -Wall -o sim/tb_uart.vvp $(RTL) $(TB)
	vvp -n sim/tb_uart.vvp +seed=$(SEED) | tee sim/sim_seed$(SEED).log
	@grep -q "RESULT: PASS" sim/sim_seed$(SEED).log

regress:
	@set -e; for s in 1 7 42 1234 99999; do $(MAKE) --no-print-directory sim SEED=$$s > /dev/null && echo "seed $$s: PASS"; done

lint:
	verilator --lint-only -Wall --top-module uart_core $(RTL)

wave:
	mkdir -p sim
	iverilog -g2012 -o sim/tb_uart.vvp $(RTL) $(TB)
	vvp -n sim/tb_uart.vvp +seed=$(SEED) +vcd

clean:
	rm -rf sim/*.vvp sim/*.log sim/*.vcd
