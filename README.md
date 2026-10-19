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

## Results

The testbench passes on two independent simulators, Icarus Verilog 12 (in CI) and
Verilator 5.030 (`make vsim`), on 5 random seeds each, and the RTL is Verilator `-Wall` lint clean.

```text
  byte values received      256 / 256
  back-to-back bytes        500
  slow sender (+2%) bytes   100
  fast sender (-2%) bytes   100
  framing errors detected   1
  recovered after error     1
  glitches rejected         1
  FIFO overflows detected   4
  bytes checked by scoreboard 973
RESULT: PASS
```

### Does the testbench actually catch bugs?

A testbench that always passes proves nothing, so four bugs were injected into the RTL one at a
time. The testbench failed on every one:

| Injected bug | Result |
|---|---|
| Receiver shifts bits in MSB-first | FAIL, 467 scoreboard errors |
| Start bit not re-checked at mid-bit (no glitch filter) | FAIL, glitch produced a byte |
| Stop bit ignored | FAIL, framing error missed |
| FIFO overwrites data when full | FAIL, 8 scoreboard errors |

## Class-based (UVM-style) testbench

`tb/uvm_style/` verifies the same RTL with an object-oriented environment built the way a UVM
testbench is organized, in plain SystemVerilog so it runs on open-source Verilator:

```text
test --> env --+-- RX agent:  sequence -> serial_driver ---(rx pin)--> DUT receiver
               |                         fifo_monitor <---(FIFO reads)-- DUT
               +-- TX agent:  sequence -> tx_driver ---(tx_data/start)--> DUT transmitter
               |                         serial_monitor <---(tx pin)---- DUT
               +-- scoreboard  (expected vs observed, both directions, in order)
               +-- coverage    (byte values, frame kinds, baud-error bins, FIFO events)
```

| Class | UVM role |
|---|---|
| `uart_item` | sequence item (data, kind: good / bad stop bit / glitch, baud error) with weighted randomization |
| `random_sequence`, `all_values_sequence`, `overflow_sequence` | sequences |
| `serial_driver`, `tx_driver` | drivers (through a `virtual uart_if`) |
| `fifo_monitor`, `serial_monitor` | monitors; the serial monitor decodes the TX pin on its own |
| `uart_scoreboard` | scoreboard with expected queues; drivers and monitors call its `write_*` methods like analysis ports |
| `uart_coverage` | coverage collector with bins and a hole count |
| `uart_env`, `base_test` and 3 tests | environment with build / connect / run phases, and tests |

Tests: `random_test` (400 random frames each way at the same time, full duplex, with bad stop bits,
glitches and -2..+2 % baud error), `all_values_test` (all 256 values each way), and `overflow_test`
(reader stopped, FIFO must fill, keep 16 bytes and flag 4 overflows).

**Results:** 15 of 15 runs pass (3 tests x 5 seeds). The class-based testbench also catches every
injected bug, including one the first testbench could only see indirectly:

| Injected bug | Tests failing |
|---|---|
| Receiver bit order reversed | 3 of 3 |
| No mid-bit start check (glitch filter) | 1 (random_test) |
| Stop bit ignored | 1 (random_test) |
| FIFO overwrites when full | 1 (overflow_test) |
| Transmitter repeats a bit | 2 (TX scoreboard) |

It is UVM-style, not the UVM library: no factory, config DB or phasing engine, because the
open-source simulators used here do not fully support UVM yet.

## Run it

Needs [Icarus Verilog](https://steveicarus.github.io/iverilog/) and, for lint,
[Verilator](https://verilator.org).

```bash
make lint            # Verilator -Wall on the RTL
make sim             # one run, prints coverage and RESULT: PASS/FAIL
make sim SEED=42     # different random seed
make regress         # 5 seeds
make wave            # dump sim/tb_uart.vcd and open it in GTKWave
make vsim            # same testbench on Verilator
make uvm             # class-based testbench, TEST=random_test|all_values_test|overflow_test
make uvm_regress     # 3 class-based tests x 5 seeds
```

No local install? Paste the files into [EDA Playground](https://www.edaplayground.com) with
Icarus Verilog 12.

## Roadmap

- [ ] Add SystemVerilog assertions (SVA) for protocol rules and run them in a simulator that supports them
- [ ] Add parity and configurable stop bits
- [x] Port the testbench to a UVM-style structure (driver, monitor, scoreboard as classes)
- [ ] Move the class-based testbench onto the real UVM library in a simulator that supports it
- [ ] Synthesize for a Basys 3 / Arty FPGA and loop back to a PC through USB-UART
