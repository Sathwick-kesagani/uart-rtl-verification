# UART RTL Design and Self-Checking Verification

[![RTL verification](https://github.com/Sathwick-kesagani/uart-rtl-verification/actions/workflows/ci.yml/badge.svg)](https://github.com/Sathwick-kesagani/uart-rtl-verification/actions/workflows/ci.yml)
![SystemVerilog](https://img.shields.io/badge/SystemVerilog-IEEE%201800-blue)
![Icarus](https://img.shields.io/badge/sim-Icarus%20Verilog-lightgrey)
![License](https://img.shields.io/badge/License-MIT-yellow)

A UART (8N1) transmitter and receiver with a receive FIFO, written in synthesizable
SystemVerilog, and a self-checking testbench with a scoreboard, randomized stimulus, a
bus-functional model for error injection, and functional coverage counters. Every push runs
Verilator lint, a simulation, and a 5-seed regression in GitHub Actions.

> Simulation-only project (Icarus Verilog + Verilator lint). It has not been synthesized or run
> on an FPGA yet; that is on the roadmap.

## Design

```text
             +-------------------------------- uart_core ---------------------------------+
 tx_data --->|  uart_tx  (IDLE -> START -> DATA x8 -> STOP)  ------------------------------|---> tx
 tx_start -->|                                                                            |
             |                                                                            |
 rx -------->|  2-FF sync -> uart_rx (start confirmed mid-bit, bits sampled mid-bit,      |
             |                         stop checked, WAIT_IDLE after a framing error)     |
             |                      |  valid + data                                       |
             |                      v                                                     |
 rx_rd_en -->|  sync_fifo (16 x 8, first-word fall-through, full/empty/count/overflow) --|---> rx_data
             +----------------------------------------------------------------------------+
```

| File | What it is |
|---|---|
| `rtl/uart_tx.sv` | Transmitter FSM, `CLKS_PER_BIT` = clock / baud |
| `rtl/uart_rx.sv` | Receiver: two-flop synchroniser, glitch rejection, framing-error detection |
| `rtl/sync_fifo.sv` | Synchronous FIFO with an extra pointer bit to tell full from empty |
| `rtl/uart_core.sv` | Top level wiring TX, RX and the RX FIFO |
| `tb/tb_uart.sv` | Testbench: stimulus, BFM, scoreboard, coverage, pass/fail |

## Verification plan

| # | Test | Stimulus | Checked |
|---|---|---|---|
| T1 | Reset | hold reset | TX idles high, FIFO empty |
| T2 | All byte values | 0x00-0xFF through TX -> RX loopback | scoreboard, in order |
| T3 | Random traffic | 500 random back-to-back bytes | scoreboard, in order |
| T4 | Baud tolerance | BFM sends 100 bytes at +2% and 100 at -2% bit time | scoreboard |
| T5 | Framing error | BFM sends a byte with stop bit = 0, then a good byte | 1 error pulse, nothing stored, recovery |
| T6 | Glitch | 1/4-bit low pulse on RX | no byte, no error |
| T7 | FIFO overflow | 20 bytes with the reader stopped | full, count = 16, 4 overflow pulses, first 16 bytes intact |

**Coverage bins** (the test fails if any stays at zero): all 256 byte values received,
back-to-back bytes, slow and fast sender, framing error detected, recovery after error,
glitch rejected, FIFO full, FIFO overflow.

## Run it

Needs [Icarus Verilog](https://steveicarus.github.io/iverilog/) and, for lint,
[Verilator](https://verilator.org).

```bash
make lint            # Verilator -Wall on the RTL
make sim             # one run, prints coverage and RESULT: PASS/FAIL
make sim SEED=42     # different random seed
make regress         # 5 seeds
make wave            # dump sim/tb_uart.vcd and open it in GTKWave
```

No local install? Paste the files into [EDA Playground](https://www.edaplayground.com) with
Icarus Verilog 12.

## Roadmap

- [ ] Add SystemVerilog assertions (SVA) for protocol rules and run them in a simulator that supports them
- [ ] Add parity and configurable stop bits
- [ ] Port the testbench to a UVM-style structure (driver, monitor, scoreboard as classes)
- [ ] Synthesize for a Basys 3 / Arty FPGA and loop back to a PC through USB-UART
