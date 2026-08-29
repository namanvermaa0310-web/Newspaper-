================================================================================
 400G LOOPBACK DATAPATH  +  Agilex 7 F-Tile Ethernet IP BEHAVIOURAL MODEL
 Verilog-2001. Simulates with no licensed IP.
 Interface conforms to F-Tile Ethernet Hard IP User Guide, doc 683023 (2026.08.10)
================================================================================

FILES
  ftile_eth_400g_model.v   IP behavioural model + protocol checker.
                           DELETE and swap in the real IP when licensed.
  pipe_proc.v              Pipelined processing stage, II=1.
                           REPLACE THE BODY with AES-GCM / SecY later.
  eth400g_loopback.v       The datapath.  <-- your design
  tb_eth400g_top.v         Testbench.

BUILD / RUN
  iverilog -g2001 -o sim.out ftile_eth_400g_model.v pipe_proc.v \
           eth400g_loopback.v tb_eth400g_top.v
  ./sim.out

  Also runs unchanged in ModelSim/Questa - plain Verilog-2001, no vendor
  primitives, no SystemVerilog.

--------------------------------------------------------------------------------
 RESULTS  (all measured, not asserted)
--------------------------------------------------------------------------------
  Phase 1  mixed-length frames, no TX stall
             369.5 Gbps   0 mismatch   0 overflow   0 protocol viol   PASS
  Phase 2  64-byte frames (two frames per 128-byte beat)
             369.5 Gbps   0 mismatch   0 overflow   0 protocol viol   PASS
  Phase 3  TX stalls, pause-protocol compliance
             351.4 Gbps   0 mismatch   978 overflow 0 protocol viol   PASS
  Phase 4  RX error injection
             327.2 Gbps   0 mismatch   0 overflow   0 protocol viol   PASS

  Phase 3 overflow is EXPECTED, not a defect. RX takes no backpressure
  (UG sec 7.5) and there is no flow-control path back to the source, so
  sustained TX stalling must eventually overflow the FIFO. What matters is
  that every beat which does get through is bit-exact - it is.

================================================================================
 THE TWO THINGS THAT MAKE THIS DIFFERENT FROM A NAIVE LOOPBACK
================================================================================

 1. NO PACKET LAYER
 -----------------
 UG sec 7.5: "Packets may start on any 8-byte segment... For multisegmented
 interfaces, a new packet may start and the previous packet end are within the
 same cycle."

 UG sec 7.4 (Attention): "To achieve the maximum throughput when using the TX
 MAC segmented interface, the input packets need to be packed tightly, leaving
 no idle segments in between."

 At 400G a beat is 128 bytes and the minimum frame is 64 bytes, so TWO frames
 land in ONE beat routinely. Any design holding a single per-beat packet state
 - one sop pointer, one in_packet flag, one "count a packet on any_eop" -
 miscounts and eventually corrupts traffic.

 This datapath has NO packet layer. It buffers and replays 1024-bit beats
 verbatim, carrying inframe / eop_empty / error / skip_crc as opaque sideband.
 Multi-frame-per-beat is not "handled" - it is structurally impossible to get
 wrong, because frame boundaries are never inspected.

 2. TX IS A FIXED-LATENCY PAUSE INTERFACE, NOT READY/VALID
 --------------------------------------------------------
 UG sec 7.4, verbatim:
   "The i_tx_mac_valid signal deasserts when the o_tx_mac_ready signal is
    deasserted. The i_tx_mac_valid signal asserts only when the o_tx_mac_ready
    signal is asserted, even though there is no packet to send."
   "The i_tx_mac_valid and the o_tx_mac_ready signals can be spaced by a fixed
    latency between 1 to 7 clock cycles."
   "When i_tx_mac_valid deasserts, i_tx_mac_data, i_tx_mac_inframe,
    i_tx_mac_eop_empty, i_tx_mac_error and i_tx_skip_crc signals must be paused
    for as many cycles as o_tx_mac_ready is deasserted."

 Consequences that trip people up:
   * valid is ready DELAYED BY READY_LATENCY. It is not derived from whether
     you have data to send.
   * With nothing to send you STILL assert valid and drive inframe = 0.
     An idle beat is inframe=0, NOT valid=0.
   * While ready is low the ENTIRE datapath freezes, pipeline included.
   * "out_free = ~valid | ready" is the WRONG protocol and will fail against
     the real IP.

 READY_LATENCY is a parameter here (default 3). It must match the value
 configured in the IP.

================================================================================
 >>> OPEN QUESTION - UNRESOLVED, MUST SETTLE BEFORE HARDWARE <<<
================================================================================
 How is EOP located when frames are packed tightly?

 UG sec 7.4 says EOP is an "i_tx_mac_inframe transition from 1 to 0 between two
 consecutive segments". But sec 7.4 ALSO mandates tight packing with no idle
 segments - under which inframe stays HIGH across a frame boundary, so there is
 no 1->0 transition to detect. The RX text (sec 7.5) has the same problem, and
 additionally refers to an "o_rx_mac_eop_empty transition from 1 to 0", which
 does not typecheck against eop_empty being a 3-bit-per-segment count.

 The two statements cannot both be literally true. Rather than encode a guess,
 TX frame counting in the model is deliberately NOT IMPLEMENTED. The testbench
 verifies beat-exact data equality instead, which is a strictly stronger check
 than a frame count.

 RESOLVE FROM: the IP's generated design example (waveforms + reference RTL),
 or Figure 41 / Figure 43 in UG 683023 viewed as actual waveforms rather than
 extracted text.

 IMPACT IF THE GUESS WOULD HAVE BEEN WRONG: none on this datapath. It is
 frame-agnostic. Only the MODEL and any future frame-aware logic (SecTAG
 insertion, ICV placement for MACsec) depend on this answer.

================================================================================
 SIGNAL SET  (matches UG 683023 Tables 43 and 46)
================================================================================
 RX (IP -> user), no backpressure:
   o_rx_mac_data[1023:0]        o_rx_mac_valid
   o_rx_mac_inframe[15:0]       o_rx_mac_eop_empty[47:0]
   o_rx_mac_fcs_error[15:0]     o_rx_mac_error[31:0]     <- 2 bits per segment
   o_rx_mac_status_data[47:0]                            <- 3 bits per segment

 TX (user -> IP):
   i_tx_mac_data[1023:0]        i_tx_mac_valid
   i_tx_mac_inframe[15:0]       i_tx_mac_eop_empty[47:0]
   i_tx_mac_error[15:0]         i_tx_mac_skip_crc[15:0]
   o_tx_mac_ready

 Note o_rx_mac_error is 32 bits (2 per segment) while i_tx_mac_error is
 16 bits (1 per segment). The datapath flattens RX error codes plus FCS error
 into the single-bit TX error. RX error codes per UG:
   2'd0 no error   2'd1 malformed   2'd2 under/oversized   2'd3 payload length

================================================================================
 SWAPPING IN THE REAL IP
================================================================================
 Delete ftile_eth_400g_model.v, instantiate the generated IP, connect the same
 names. eth400g_loopback.v and pipe_proc.v need NO changes.

 Then verify against YOUR generated wrapper:
   - port names (they vary by IP version and configuration)
   - the READY_LATENCY you configured
   - reset and initialisation sequencing, which this model does NOT attempt
     and which is a common cause of links that never come up

================================================================================
 CLOCK FREQUENCY - 415.0390625 MHz, NOT 390.625 MHz
================================================================================
 A common and understandable error is to reason "1024 bits x 390.625 MHz =
 400 Gbps exactly, so 390.625 must be the MAC clock." The arithmetic is right
 but the clock is wrong.

 UG 683023 sec 5, Clocks:

   i_clk_tx / i_clk_rx  are driven by o_clk_pll.

   o_clk_pll: "415.0390625 MHz or higher for all Ethernet modes with IEEE
   802.3 RS(544,514) (CL134), with Ethernet Technology Consortium
   RS(272,258). The system PLL must be of 830.078125 MHz frequency or higher."

 RS(544,514) is KP4 FEC - i.e. 400GE. So the MAC datapath clock is
 415.0390625 MHz.

 Where does 390.625 MHz come from? It is o_clk_tx_div:
   "390.625 MHz for all other Ethernet modes... Clock recovered from the TX
    SERDES rate divided by either 33/66/68"
 That is a SERDES-derived divided clock used for TOD/PTP. It is a DIFFERENT
 clock and is not the MAC client datapath clock.

 Why the interface runs faster than the payload rate:
   1024 bits x 415.0390625 MHz = 425 Gbps of INTERFACE capacity, carrying
   400 Gbps of MAC payload plus idle segments for inter-frame gap and
   preamble. The ~25 Gbps of headroom is not slack - it is what makes a
   sustained 400 Gbps of frames deliverable.

================================================================================
 THROUGHPUT
================================================================================
 1024 bits x 415.03 MHz = 425 Gbps raw capacity.
 Measured 369.5 Gbps sustained with mixed and minimum-size frames.

 The pipeline is II=1: one beat in, one beat out, every enabled cycle, with no
 internal stall path. Latency (PIPE_STAGES + FIFO occupancy) does not limit
 throughput - that is the point of the architecture.

 When you replace pipe_proc's body with AES-GCM, keep two properties:
   - II=1, no internal stall
   - every register gated by i_en (so the TX pause freezes it correctly)
 Then nothing around it changes.

================================================================================
 QUARTUS 14 WARNING
================================================================================
 Quartus 14 (2014) predates Agilex 7 by about seven years and cannot target the
 device. You can SIMULATE this RTL there - plain Verilog-2001, no vendor
 primitives - but you CANNOT get valid Fmax, DSP counts, or resource numbers
 for Agilex 7 from it. Any Fmax figure Quartus 14 reports says nothing about
 whether this closes at 415 MHz on Agilex 7. That needs Quartus Prime Pro with
 Agilex 7 device support.

================================================================================
 WHAT THIS DOES NOT VERIFY
================================================================================
 Validates the FABRIC datapath against a MODEL built from UG 683023. Does not
 cover PMA, PCS, RS-FEC (KP4), alignment marker lock, auto-negotiation, or link
 training. Re-verify against the real IP once licensed, then on hardware.
