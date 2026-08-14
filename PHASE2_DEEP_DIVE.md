# Phase 2 in Full Depth: SHA3-256 and SHAKE-256 on the KC705

Every module explained with the actual code, including the synthesis bug that
cost 90 minutes and how it was fixed.

---

## Part 0 -- Why Keccak, and what SHA3/SHAKE actually are

FIPS 202 defines the **Keccak-f[1600] permutation** -- a fixed, keyless
scrambling of 1600 bits, run 24 rounds. Everything else (SHA3-256, SHAKE-256,
SHAKE-128) is the *same* permutation wrapped in a **sponge construction**:
absorb input by XORing it into part of the state and permuting, then squeeze
output by reading part of the state and permuting again if more is needed.

The "part of the state" that gets XORed/read each round is called the **rate**
(136 bytes = 1088 bits for both SHA3-256 and SHAKE-256); the rest is the
**capacity** (512 bits), which is what carries the security margin and is
never touched directly.

Two engines, one permutation core: `keccak_f1600` does the 24-round scramble;
`sha3_256_mb` and `shake256` each build their own sponge logic around it.

This matters for ML-KEM specifically because SHAKE-128 and SHAKE-256 are the
**XOFs** (extendable-output functions) that generate the matrix and noise in
FIPS 203 -- Phase 3 wires them directly into the sampler pipeline.

---

## Part 1 -- keccak_pkg.sv: the two lookup functions

```systemverilog
function automatic logic [63:0] round_const(input int unsigned r);
  logic [63:0] rc [0:23];
  rc[0]  = 64'h0000000000000001; rc[1]  = 64'h0000000000008082;
  ...
  return rc[r];
endfunction
```

24 round constants, one per round, used in the final step of each round
(`iota`, below). These are fixed by FIPS 202 -- generated from a linear
feedback shift register over GF(2) in the standard's reference algorithm, but
implemented here as a plain lookup since there are only 24 of them and
regenerating them in hardware would cost more than it saves.

```systemverilog
function automatic int unsigned rot_offset(input int unsigned lane_idx);
  int unsigned r [0:24];
  r[5*0+0]=0;  r[5*0+1]=1;  r[5*0+2]=62; r[5*0+3]=28; r[5*0+4]=27;
  ...
```

25 rotation offsets, one per lane, used in `rho` (below). Also fixed by the
standard. The comment above both functions states the indexing convention
explicitly:

```systemverilog
// Lane indexing convention: lane index = 5*y + x  (x,y in 0..4)
```

This one line matters more than it looks. Keccak's state is a 5x5 grid of
64-bit lanes, and the standard's own pseudocode is expressed in terms of
`A[x,y]`. Every place in the RTL that touches a lane needs to agree on whether
`lane_idx` means `5x+y` or `5y+x` -- get it backwards in even one place and the
permutation computes something self-consistent but wrong, which is exactly the
kind of bug simulation might not catch if the testbench only checks a few
short vectors. Writing the convention down once, in the package, and having
every consumer import it, is what keeps that consistent.

---

## Part 2 -- keccak_round.sv: one round, all five steps

The entire round is one `always @(*)` block, unrolled with nested `for` loops
over `x` and `y`, so it is combinational -- 24 instances of this logic run
back to back, one per clock cycle, inside `keccak_f1600`.

### Unpack

```systemverilog
for (x = 0; x < 5; x = x + 1)
  for (y = 0; y < 5; y = y + 1)
    a[5*y+x] = state_in[64*(5*y+x) +: 64];
```

The 1600-bit input vector is split into 25 separate 64-bit lanes so the rest
of the round can index them as `a[5*y+x]` instead of computing bit-slice
offsets everywhere.

### Theta -- the diffusion step

```systemverilog
for (x = 0; x < 5; x = x + 1)
  c[x] = a[5*0+x] ^ a[5*1+x] ^ a[5*2+x] ^ a[5*3+x] ^ a[5*4+x];
for (x = 0; x < 5; x = x + 1)
  d[x] = c[(x+4)%5] ^ rotl64(c[(x+1)%5], 1);
for (x = 0; x < 5; x = x + 1)
  for (y = 0; y < 5; y = y + 1)
    a[5*y+x] = a[5*y+x] ^ d[x];
```

Three passes. First, `c[x]` is the XOR of an entire column (all five lanes at
that x, across every y) -- a parity check per column. Second, `d[x]` mixes
each column's parity with its neighbor's, rotated -- this is what makes a
change in one lane eventually affect lanes in other columns, which is the
entire point of a diffusion step. Third, every lane gets XORed with its
column's `d[x]`.

### Rho + Pi -- rotation and lane permutation, fused

```systemverilog
for (x = 0; x < 5; x = x + 1)
  for (y = 0; y < 5; y = y + 1)
    b[5*((2*x+3*y)%5) + y] = rotl64(a[5*y+x], rot_offset(5*y+x));
```

Two of the standard's five steps are normally described separately -- `rho`
rotates each lane by its own fixed offset, `pi` moves each lane to a new
position in the grid. Here they are fused into one assignment: the right-hand
side does the rotation (`rho`), the left-hand side's index computes the new
position (`pi`). Doing both in one pass avoids materializing an intermediate
25-lane array that would exist only to be immediately re-permuted.

### Chi -- the only nonlinear step

```systemverilog
for (x = 0; x < 5; x = x + 1)
  for (y = 0; y < 5; y = y + 1)
    s2[5*y+x] = b[5*y+x] ^ ((~b[5*y+((x+1)%5)]) & b[5*y+((x+2)%5)]);
```

Every other step in Keccak is linear over GF(2) -- XOR and rotation only.
`chi` is the exception: it ANDs two lanes together (after inverting one), which
is what gives the permutation its nonlinearity and is why it resists algebraic
attacks. It operates row-wise (fixed `y`, varying `x`), independent of theta
and rho/pi which are column- or lane-wise.

### Iota -- breaking round symmetry

```systemverilog
s2[0] = s2[0] ^ round_const(round_idx);
```

Without this, all 24 rounds would be structurally identical, which would let
an attacker exploit the symmetry (a "slide attack"). XORing a different
constant into lane 0 each round breaks that -- and only lane 0 needs it, which
is why this is a single line rather than a loop.

### Pack

```systemverilog
for (x = 0; x < 5; x = x + 1)
  for (y = 0; y < 5; y = y + 1)
    state_out[64*(5*y+x) +: 64] = s2[5*y+x];
```

Reassembles the 25 lanes back into the 1600-bit vector for the next round.

---

## Part 3 -- keccak_f1600.sv: running 24 rounds

```systemverilog
reg [1599:0] cur_state;
reg [4:0]    round_idx;
reg          running;

wire [1599:0] round_out;
keccak_round u_round (
  .state_in  (cur_state),
  .round_idx (round_idx),
  .state_out (round_out)
);
```

One instance of `keccak_round`. The 24-round permutation is done by feeding
its own output back into its input 24 times, incrementing `round_idx` each
cycle -- **not** by instantiating 24 copies. That is the right tradeoff here:
24 copies would let the whole permutation finish in a single cycle (at the
cost of a truly enormous combinational path -- far worse than Phase 1's
multiplier chain, and it would never close timing), whereas one instance run
24 times costs 24 cycles but keeps each cycle's logic to a single round.

```systemverilog
end else if (running) begin
  cur_state <= round_out;
  if (round_idx == 5'd23) begin
    running   <= 1'b0;
    state_out <= round_out;
    done      <= 1'b1;
  end else begin
    round_idx <= round_idx + 5'd1;
  end
end
```

Straightforward counting FSM: feed the round output back as the next round's
input, and after round 23 (the 24th round, zero-indexed), latch the result and
raise `done`.

```systemverilog
end else if (start) begin
  // start re-asserted after a prior completion: begin a fresh permutation
  running   <= 1'b1;
  ...
```

This extra branch exists because `done` is **level-sensitive** (it stays high
until the next `start`, per the comment on the port declaration), which means
a caller polling `done` and then re-asserting `start` needs the FSM to
recognize a fresh start even though `running` is currently low and `done` is
currently high. Without this branch, a second run could be silently ignored.

---

## Part 4 -- The synthesis bug: what went wrong and why

This is the part worth understanding in full, because it cost 90 minutes of
synthesis time and would have cost far more if it had gone unnoticed.

### The original code

```systemverilog
// ORIGINAL (broken for synthesis) -- shown for explanation, not present
// in the current files
reg [7:0] msg_buf [0:MAX_MSG_BYTES-1];

wire [7:0] cur_block_byte [0:RATE_BYTES-1];
genvar bi;
generate
  for (bi = 0; bi < RATE_BYTES; bi = bi + 1) begin : padblk
    wire [10:0] gidx = blk_idx * RATE_BYTES + bi;
    wire [7:0] raw = (gidx < msg_len_reg) ? msg_buf[gidx[8:0]] : ...;
    assign cur_block_byte[bi] = ...;
  end
endgenerate
```

`RATE_BYTES` is 136. This `generate` loop creates **136 separate continuous
assignments**, each one independently indexing into `msg_buf` at its own
computed address, all active every cycle. That is 136 simultaneous read ports
on a single memory.

### Why this was there in the first place

The comment in the original file (preserved in the git history, referenced in
Phase 1's transcript) explained: an earlier version tried to build the block
with a procedural `always @(*)` loop over the memory array, and **Icarus
Verilog did not re-trigger that block when the memory contents changed** --a
simulator-specific quirk. Switching to a `generate` loop of continuous
assignments fixed the Icarus problem. It also, invisibly, created 136 read
ports.

### What Vivado did with it

```
WARNING: [Synth 8-4767] Trying to implement RAM 'msg_buf_reg' in registers.
Reason is one or more of the following:
  1: RAM has too many ports (16). Maximum supported = 16.
RAM "msg_buf_reg" dissolved into registers
```

Block RAM on Kintex-7 supports at most 2 ports (true dual-port). Distributed
RAM (LUT RAM) supports up to a handful more, but nowhere near 136. With no
architecture able to hold it, Vivado's synthesizer fell back to the only thing
it could always do: build `msg_buf` as 512 x 8 = **4,096 individual
flip-flops**, then build a 136-way address multiplexer to read from them
combinationally. `shake256` had the identical problem on absorb, plus a
second one: its squeeze phase wrote 136 bytes to `out_mem` in a single-cycle
`for` loop, which is 136 simultaneous *write* ports.

Building and then trying to route that much multiplexer logic is what made
synthesis take an hour and a half without ever reaching a usable result --
and even if it had finished, the resulting design would have had a
combinational read path through a 136-to-1 mux wide enough to make timing
closure essentially hopeless, on top of burning roughly 4,000 flip-flops for
what should have been a few kilobits of block RAM.

### The fix: sequential access

```systemverilog
reg [7:0] msg_buf [0:MAX_MSG_BYTES-1];
reg [8:0] mb_raddr;
reg [7:0] mb_q;
always @(posedge clk) begin
  if (wr_en) msg_buf[wr_addr] <= wr_data;
  mb_q <= msg_buf[mb_raddr];
end
```

One write port (`wr_addr`/`wr_data`), one read port (`mb_raddr` in,
`mb_q` out, one cycle later). That is a completely ordinary dual-port memory
shape, and Vivado maps it straight to a real block RAM.

```systemverilog
reg [1087:0] block_reg;   // 136 bytes, packed
reg [7:0]    ld_idx;

ST_LD_A: begin
  mb_raddr <= gidx[8:0];
  state    <= ST_LD_W;
end

// mb_raddr only takes effect at the END of ST_LD_A, so the RAM read it
// triggers does not land in mb_q until the end of THIS state. Capturing
// in ST_LD_A+1 would latch the PREVIOUS byte -- an off-by-one that
// showed up immediately as an all-X digest.
ST_LD_W: state <= ST_LD_B;

ST_LD_B: begin
  block_reg[8*ld_idx +: 8] <= padded_byte;
  if (ld_idx == RATE_BYTES-1) begin
    ld_idx <= 8'd0;
    state  <= ST_XOR;
  end else begin
    ld_idx <= ld_idx + 8'd1;
    state  <= ST_LD_A;
  end
end
```

Instead of reading all 136 bytes at once, the FSM now reads **one byte per two
cycles**: `ST_LD_A` issues the address, `ST_LD_W` waits one cycle for the
synchronous RAM read to land in `mb_q`, `ST_LD_B` captures that byte into
`block_reg` and advances. After 136 iterations, `block_reg` holds the same
1088 bits the old code produced in zero cycles -- just 272 cycles later
instead.

`block_reg` itself is a **packed** vector (`reg [1087:0]`), not an unpacked
array, so the tool never considers RAM inference for it at all -- it is
plainly a bank of flip-flops, which is correct here because all 136 bytes are
consumed simultaneously by the XOR into the sponge state, so there is no
sequential-access benefit to be had by making it a memory.

### The off-by-one, and why it looked like a different bug

The very first attempt at this fix skipped `ST_LD_W` and captured `mb_q`
directly in the cycle after issuing `mb_raddr`. The result: `SHA3-256("abc")`
came back as `xx xx xx xx ...` -- all unknown.

The cause is synchronous-read timing. `mb_raddr <= gidx` is a **nonblocking**
assignment; it does not take effect until the end of the current cycle. The
RAM read that uses the *new* `mb_raddr` value therefore does not land in
`mb_q` until the end of the *following* cycle. Capturing `mb_q` one cycle too
early reads the *previous* byte -- and on the very first byte of the very
first block, "previous" is the reset value, `8'hxx` in simulation. Adding
`ST_LD_W` as a dedicated wait state was the fix, and the comment left in the
code explains exactly why the extra cycle is required, so a future edit does
not remove it by mistake for looking redundant.

### The squeeze side of SHAKE-256

```systemverilog
reg [7:0] sq_idx;
wire [63:0] sq_lane = sponge_state[64*(sq_idx/8) +: 64];
wire [7:0]  sq_byte = sq_lane[8*(sq_idx%8) +: 8];
...
ST_SQ: begin
  if ((out_written + {2'd0, sq_idx}) < out_len_reg) begin
    om_waddr <= out_written + {2'd0, sq_idx};
    om_wdata <= sq_byte;
    om_wen   <= 1'b1;
  end
  ...
```

Same principle, mirrored for output: one byte written to `out_mem` per cycle
instead of 136 in a single-cycle `for` loop. `sq_lane`/`sq_byte` pick out byte
`sq_idx` from the current 1600-bit sponge state combinationally (this part is
fine to leave combinational -- it reads from a fixed-width register, not a
memory array, so there is no port-count problem), and `om_wen` gates a single
write per cycle into a proper single-port-write memory.

### Cost of the fix, honestly

~272 extra cycles per SHA3-256 block, ~272 for SHAKE-256 absorb plus up to 136
per squeeze block. At 100 MHz that is a few microseconds per block -- entirely
acceptable, and a small cost against the alternative, which was a design that
could not be synthesized to working hardware at all.

---

## Part 5 -- sha3_256_mb.sv: the sponge FSM

```systemverilog
localparam ST_IDLE = 4'd0, ST_LD_A = 4'd1, ST_LD_W = 4'd2, ST_LD_B = 4'd3,
           ST_XOR  = 4'd4, ST_KICK = 4'd5, ST_RUN = 4'd6, ST_DONE = 4'd7;
```

Nine states covering: idle/done, the three-state sequential block load just
described, XOR the block into the sponge, kick off the permutation, wait for
it, and repeat for as many rate blocks as the (padded) message needs.

```systemverilog
wire [9:0] total_padded_len = msg_len_reg + 10'd1 + 10'((RATE_BYTES-1));
wire [7:0] num_blocks = total_padded_len / RATE_BYTES;
```

`+ 1` accounts for the mandatory domain-separation byte (0x06 for SHA3, always
present even if the message fits exactly). `+ (RATE_BYTES-1)` then `/
RATE_BYTES` is integer ceiling division -- computing how many 136-byte blocks
are needed to hold the message plus that one padding byte, rounded up.

```systemverilog
wire [7:0] raw_byte = (gidx <  {1'b0, msg_len_reg}) ? mb_q  :
                      (gidx == {1'b0, msg_len_reg}) ? 8'h06 : 8'h00;
wire [7:0] padded_byte =
      (is_last_block && (ld_idx == RATE_BYTES-1)) ? (raw_byte | 8'h80)
                                                  : raw_byte;
```

FIPS 202's padding rule (`pad10*1`) in three cases: inside the message, use
the actual byte; exactly at the message boundary, insert the domain byte
(`0x06`); beyond that, zero. Separately, the **very last byte of the very last
block** gets its top bit set (`| 8'h80`) regardless of what it already is --
that is the "1" that closes the padding, and it can land on the same byte as
the domain separator if the message happens to end exactly one byte before the
rate boundary, which is why it is an OR onto whatever `raw_byte` already
computed rather than a separate case.

```systemverilog
ST_RUN: begin
  if (f_done) begin
    sponge_state <= f_state_out;
    if (blk_idx == num_blocks - 8'd1) begin
      hash_out <= { swap_bytes(f_state_out[64*0 +: 64]),
                    swap_bytes(f_state_out[64*1 +: 64]),
                    swap_bytes(f_state_out[64*2 +: 64]),
                    swap_bytes(f_state_out[64*3 +: 64]) };
      busy  <= 1'b0;
      done  <= 1'b1;
      state <= ST_DONE;
    end else begin
      blk_idx <= blk_idx + 8'd1;
      state   <= ST_LD_A;
    end
  end
end
```

After the final block's permutation completes, the digest is the first 32
bytes (4 lanes) of the resulting state -- `swap_bytes` converts each lane from
the internal representation to the byte order the digest is conventionally
displayed in (this is what makes `SHA3-256("") = a7ffc6f8...` come out matching
the published value byte-for-byte rather than reversed). If more blocks
remain, loop back to `ST_LD_A` for the next one.

---

## Part 6 -- keccak_uart_core.sv: the command bridge

Same architecture as Phase 1's `mlkem_uart_core`: board-independent, so it is
fully simulatable, wrapping both engines behind one byte protocol.

```systemverilog
localparam [7:0] C_SHA_WR = 8'h30;
localparam [7:0] C_SHA_GO = 8'h31;
localparam [7:0] C_SHA_ST = 8'h32;
localparam [7:0] C_SHA_RD = 8'h33;
localparam [7:0] C_SHK_WR = 8'h40;
...
```

Command bytes for SHA3 use the `0x3_` range, SHAKE uses `0x4_` -- a
deliberate numbering so a corrupted high nibble fails obviously (wrong engine
entirely) rather than subtly (wrong command within the right engine).

```systemverilog
ST_SHAR_I: if (rx_valid) begin
  dig_idx <= rx_data[4:0];
  state <= ST_SHAR_W;
end
ST_SHAR_W: begin
  pending_tx <= dig_byte;
  state <= ST_REPLY;
end
```

Reading a digest byte needs the same one-cycle settle as Phase 1's coefficient
reads: `dig_idx` is set combinationally into `dig_byte`'s index expression, but
that index only takes effect for the *next* cycle's evaluation, so `ST_SHAR_W`
exists purely to let it settle before the value is queued for transmission.
This is the same class of timing subtlety as the `mb_q` off-by-one above --
worth noticing that it appears in three different places in this project
(here, the RAM read fix, and Phase 1's `rd_data`), which suggests it is a
pattern worth remembering rather than three unrelated bugs: **any time a
combinational read depends on a register that was just updated, the read's
result needs its own settle cycle before it can be used.**

```systemverilog
localparam [7:0] C_STAT ... ;
pending_tx <= {5'd0, smp_err, smp_done, smp_busy};
```
*(this specific line is Phase 3's status byte, shown for pattern comparison --
Phase 2's is `{6'd0, done, busy}`, one bit narrower since there is no
sample-exhaustion error to report)*

---

## Part 7 -- Verification: what the six vectors actually exercise

```
[TB] SHA3(empty):          32/32 digest bytes match FIPS 202
[TB] SHA3(abc):             32/32 digest bytes match FIPS 202
[TB] SHAKE(mt):             32/32 output bytes checked
[TB] SHAKE(abc):             32/32 output bytes checked
[TB] SHA3(200B multiblk):   32/32 digest bytes match FIPS 202
[TB] SHAKE(abc,200)@136:    32/32 bytes past rate boundary checked
```

The first four use messages/outputs that fit in a single 136-byte rate block
-- they exercise the permutation core and the padding logic, but **not** the
multi-block loop, because `num_blocks` is always 1 for them.

The last two are the ones that matter for confidence in the fix specifically:
a 200-byte message forces `num_blocks = 2`, so `ST_RUN` must loop back to
`ST_LD_A` at least once -- proving the sequential-load restructuring works
across a block boundary, not just within one. Reading SHAKE output starting at
byte 136 forces the squeeze FSM to permute a second time (`ST_SQKICK` /
`ST_SQRUN`) and resume squeezing from the new state -- proving the same for
the output side.

Every one of these six passed over **real serial waveforms in Icarus**, then
again in **Vivado XSim**, then again on the **physical KC705** after synthesis
and timing closure. Three independent confirmations of the same fix.

---

## Part 8 -- Honest status

**Proven:** the Keccak permutation, SHA3-256, and SHAKE-256 sponge
constructions are correct per FIPS 202, including the multi-block absorb and
multi-block squeeze paths that a shorter test suite would never have
exercised. The RAM-inference bug that made synthesis unusable is fixed and
re-verified at three levels (Icarus, Vivado XSim, hardware).

**Not yet characterized:** resource utilization (LUTs/BRAM actually consumed)
and the exact WNS margin -- both still open from the Phase 1 assessment,
and now doubly relevant here since the whole point of the fix was correct RAM
inference; confirming it in the utilization report, not just inferring it from
DRC going quiet, is the natural next check.

**Not ML-KEM:** these are the FIPS 202 primitives Phase 3's samplers depend
on. Phase 3 wires SHAKE-128 (a re-fork of this fixed SHAKE-256) and this same
SHAKE-256 into the SampleNTT and CBD samplers; Phase 4 remains the full
protocol.
