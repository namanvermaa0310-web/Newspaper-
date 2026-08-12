# Phase 2 with ILA Debug Cores -- Complete Steps

## First: does this need a new Vivado project?

**Yes -- but not because of the ILA.** Phase 2 is a different design with a
different top module (`kc705_keccak_top`), so it needs its own project
regardless of debug. Your Phase 1 project has `kc705_mlkem_top` as its top and
should be left alone as a known-good, hardware-validated build.

Adding an ILA to the Phase 2 project does **not** require a further project.

## What changed in the RTL

`keccak_uart_core.sv` now carries `(* MARK_DEBUG = "true" *)` on 14 signals.
That attribute does one thing: it stops synthesis from optimising the net away
or renaming it, so the net still exists and is findable after synthesis.

**It does not create an ILA by itself.** You insert the ILA with the Set Up
Debug wizard (step 5 below).

All six FIPS 202 vectors were re-run after adding the attributes and still
pass -- the attributes are synthesis directives, not logic.

Marked signals:

| Signal | Width | Why it is worth watching |
|---|---|---|
| `rx_data` | 8 | the command byte the FPGA actually received |
| `rx_valid` | 1 | strobe -- the natural ILA trigger |
| `tx_data` | 8 | the byte the FPGA is about to send back |
| `tx_send` | 1 | transmit strobe |
| `tx_busy` | 1 | transmitter occupied |
| `state` | 5 | command FSM position -- the single most useful probe |
| `sha_start` | 1 | SHA3 kick pulse |
| `sha_msg_len` | 10 | length the host asked for |
| `sha_busy`, `sha_done` | 1+1 | SHA3 engine handshake |
| `shk_start` | 1 | SHAKE kick pulse |
| `shk_msg_len`, `shk_out_len` | 10+10 | SHAKE lengths |
| `shk_busy`, `shk_done` | 1+1 | SHAKE engine handshake |

Total ~60 bits of probe data.

---

## Complete steps

### 1. New Vivado project
1. File -> New Project, name `kc705_keccak_debug`
2. RTL Project
3. Part: `xc7k325tffg900-2`

### 2. Add sources
**Design Sources** (9 files):
`keccak_pkg.sv`, `keccak_round.sv`, `keccak_f1600.sv`, `sha3_256.sv`,
`shake256.sv`, `uart_rx.sv`, `uart_tx.sv`, `keccak_uart_core.sv`,
`kc705_keccak_top.sv`

**Simulation Sources**: `tb_keccak_uart_core.sv`

**Constraints**: `kc705_keccak.xdc`

### 3. Simulate before synthesising
1. Set `tb_keccak_uart_core` as **simulation** top
2. Run Behavioral Simulation
3. In the Tcl console: `run 5ms` (the 1 us default is far too short -- this
   bit-bangs real UART waveforms)
4. Expect six PASS lines and the final banner

Do not proceed until this passes. Debugging a design that was already broken in
simulation wastes a synthesis cycle.

### 4. Synthesis
1. Set `kc705_keccak_top` as **design** top
2. Run Synthesis (not implementation yet)
3. When it finishes, choose **Open Synthesized Design**

### 5. Insert the ILA (Set Up Debug wizard)
1. In the synthesized design, menu **Tools -> Set Up Debug**
2. Click **Next**. The wizard lists the nets marked with `MARK_DEBUG` --
   all 14 should appear. Add or remove as you like.
3. **Next** -> on the "Specify Nets" page, confirm the clock domain shows
   `clk100`. If any net shows an undefined clock, click it and set the clock
   domain manually -- an ILA with an unset clock will fail implementation.
4. **Next** -> ILA core options:
   - **Sample of data depth**: `4096` (see the note on depth below)
   - Tick **Capture control** -- this is what lets you trigger on `rx_valid`
     instead of capturing 4096 cycles of idle
   - Leave Advanced trigger off unless you need it
5. **Next -> Finish**
6. **Ctrl+S** to save the constraints. Vivado will write the debug nets into
   your XDC (or offer to create a new constraints file -- either is fine).

### 6. Implementation
1. Run Implementation
2. **Report Timing Summary -- check WNS again.**

   This matters more than usual: the ILA adds logic and BRAM, and its probe
   routing can push a marginal design negative. If Phase 2 met timing before
   the ILA and fails after it, reduce the probe count or the sample depth
   rather than assuming the design is broken.

### 7. Bitstream and program
1. Generate Bitstream
2. Power the KC705 (12 V adapter), connect both USB cables (JTAG, and the
   separate mini-B USB UART)
3. Hardware Manager -> Open Target -> Auto Connect
4. Program Device -- select the `.bit`. Vivado should automatically find the
   matching `.ltx` probe file; if not, right-click the device -> **Add
   Configuration Memory / Specify Probes File** and point it at the `.ltx` in
   `<project>.runs/impl_1/`
5. A **hw_ila_1** window appears in the Hardware Manager

### 8. Set a trigger and capture
1. In the ILA dashboard, find the **Trigger Setup** pane
2. Click **+** and add `rx_valid`
3. Set its compare value to `1`
4. Set **Trigger position in window** to about `512` (so you capture some
   history *before* the trigger, not just after)
5. Click the **Run Trigger** button (blue play icon)
6. The ILA now waits, armed

### 9. Run the host script and watch
    py -m pip install pyserial
    py host_keccak.py COM6

The moment the first command byte arrives, the ILA fires and the waveform
populates.

---

## A practical warning about sample depth

The UART runs at 115200 baud while the ILA samples at 100 MHz. That is **868
clock cycles per bit**, so roughly **8,680 cycles per byte**.

A 4096-sample buffer therefore captures **less than one UART byte**. That is
fine -- and is exactly why you trigger on `rx_valid` rather than free-running:
you capture the *decoded* byte and the FSM's reaction to it, not the serial
waveform itself.

If you want to see a whole command-and-reply exchange, do **not** just increase
depth -- you would need ~50,000 samples for one byte pair, which will not fit.
Instead:
- Trigger on `rx_valid` and look at `rx_data` and `state`, or
- Trigger on a specific state value to catch one phase of the transaction

## What each probe tells you

| Symptom | Probe to look at | What it means |
|---|---|---|
| No reply to PING | `rx_valid`, `rx_data` | If neither ever toggles, the byte is not reaching the FPGA -- UART pins or CP210x driver, not the design |
| `rx_valid` fires but `rx_data` is garbage | `rx_data` | Baud mismatch, or `CLKS_PER_BIT` does not match the actual clock |
| Correct byte in, no reply out | `state` | FSM is stuck -- the state value tells you exactly where |
| Engine never finishes | `sha_busy`/`sha_done` | If `busy` stays high forever, the sponge FSM is hung; if `done` never rises, the handshake is the problem |
| Wrong digest | `sha_msg_len` | Confirms the length the host actually programmed |

## Removing the debug cores later

Once Phase 2 is validated on hardware, build a clean production bitstream:
1. **Tools -> Set Up Debug** -> remove the ILA, **or** delete the debug
   constraints from the XDC
2. Optionally strip the `(* MARK_DEBUG = "true" *)` attributes from
   `keccak_uart_core.sv` -- harmless to leave, but without an ILA they only
   block optimisations for no benefit
3. Re-run Synthesis -> Implementation -> Bitstream

Keep the debug build as a separate project or a saved checkpoint so you can
come back to it without redoing the wizard.

## Note on Phase 1 and 3

Phase 1 is already hardware-validated without debug cores, so it does not need
this. If Phase 3 gives trouble on the board, the same procedure applies -- mark
`state`, `rx_valid`, `rx_data` and the sampler's `busy`/`done`/`sample_error`
in `sampler_uart_core.sv` and repeat from step 4.
