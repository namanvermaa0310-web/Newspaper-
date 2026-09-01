//=============================================================================
// eth400g_loopback.v     -- Verilog-2001
//
//  STAGE 2 : 400G LOOPBACK DATAPATH
//
//  RX MAC segmented  ->  elastic beat FIFO  ->  TX MAC segmented
//
//  No processing stage. That is STAGE 3 (pipe_proc).
//
//  Conforms to F-Tile Ethernet Hard IP User Guide, doc 683023, sec 7.4 / 7.5.
//
//=============================================================================
// DESIGN POINT 1 - THERE IS NO PACKET LAYER
//=============================================================================
// UG sec 7.5:
//   "Packets may start on any 8-byte segment... For multisegmented
//    interfaces, a new packet may start and the previous packet end are
//    within the same cycle."
//
// UG sec 7.4 (Attention):
//   "To achieve the maximum throughput when using the TX MAC segmented
//    interface, the input packets need to be packed tightly, leaving no idle
//    segments in between."
//
// A beat is 1024 bits = 128 bytes. The minimum Ethernet frame is 64 bytes.
// So TWO complete frames arrive in ONE clock cycle as a matter of routine,
// not as a corner case. Stage 1 demonstrated exactly 2.000 frames per beat.
//
// Any design holding ONE packet state per beat - a single sop pointer, a
// single in_packet flag, "count a packet on any_eop" - miscounts and
// eventually commits truncated frames. It passes light testing and corrupts
// traffic under load.
//
// This module therefore has NO packet layer. It buffers and replays 1024-bit
// beats verbatim, carrying inframe / eop_empty / error / skip_crc through as
// opaque sideband. Frame boundaries are never inspected, so multi-frame-per-
// beat is not "handled" - it is structurally impossible to get wrong.
//
// Handling it with packet bookkeeping would need 16 parallel packet state
// machines. For a loopback that buys nothing: what goes out is exactly what
// came in.
//
//=============================================================================
// DESIGN POINT 2 - TX IS A FIXED-LATENCY PAUSE INTERFACE, NOT READY/VALID
//=============================================================================
// UG sec 7.4, verbatim:
//   "The i_tx_mac_valid signal deasserts when the o_tx_mac_ready signal is
//    deasserted. The i_tx_mac_valid signal asserts only when the
//    o_tx_mac_ready signal is asserted, even though there is no packet to
//    send."
//   "The i_tx_mac_valid and the o_tx_mac_ready signals can be spaced by a
//    fixed latency between 1 to 7 clock cycles."
//   "When i_tx_mac_valid deasserts, i_tx_mac_data, i_tx_mac_inframe,
//    i_tx_mac_eop_empty, i_tx_mac_error and i_tx_skip_crc signals must be
//    paused for as many cycles as o_tx_mac_ready is deasserted."
//
// Consequences:
//   * o_tx_mac_valid is i_tx_mac_ready DELAYED by READY_LATENCY.
//     It is NOT derived from whether we have data.
//   * With nothing to send we STILL assert valid and drive inframe = 0.
//     An IDLE BEAT IS inframe=0, NOT valid=0.
//   * While ready is low the entire output bus freezes.
//
// A classic handshake ("out_free = ~valid | ready") is the WRONG protocol
// here. It compiles, it passes a naive testbench, and it fails on silicon.
//
//=============================================================================
// DESIGN POINT 3 - REGISTERED FIFO READ (fitting)
//=============================================================================
// An asynchronous read  ( wire dout = mem[rd_ptr]; )  makes Quartus infer
// MLAB / distributed LUTRAM. At 1120 bits x 1024 deep that is ~1792 MLABs,
// built from ALMs - enormous logic, and it will not close 415 MHz.
//
// A REGISTERED read infers M20K: ~56 blocks, trivial on an 027 device.
// Cost is one cycle of read latency, absorbed by the output stage.
//=============================================================================
`timescale 1ps/1ps

module eth400g_loopback #(
    parameter DATA_W        = 1024,
    parameter NUM_SEG       = 16,
    parameter EMPTY_W       = 3,
    parameter READY_LATENCY = 3,     // MUST match the IP configuration, 1..7
    parameter FIFO_DEPTH    = 512,
    parameter ADDR_W        = 9
)(
    input  wire                        i_clk_tx,
    input  wire                        i_clk_rx,
    input  wire                        rst_n,

    // ---- RX MAC segmented client (from IP). Takes NO backpressure. ----
    input  wire [DATA_W-1:0]           i_rx_mac_data,
    input  wire                        i_rx_mac_valid,
    input  wire [NUM_SEG-1:0]          i_rx_mac_inframe,
    input  wire [NUM_SEG*EMPTY_W-1:0]  i_rx_mac_eop_empty,
    input  wire [NUM_SEG-1:0]          i_rx_mac_fcs_error,
    input  wire [NUM_SEG*2-1:0]        i_rx_mac_error,     // 2 bits/segment

    // ---- TX MAC segmented client (to IP) ----
    output reg  [DATA_W-1:0]           o_tx_mac_data,
    output reg                         o_tx_mac_valid,
    output reg  [NUM_SEG-1:0]          o_tx_mac_inframe,
    output reg  [NUM_SEG*EMPTY_W-1:0]  o_tx_mac_eop_empty,
    output reg  [NUM_SEG-1:0]          o_tx_mac_error,     // 1 bit/segment
    output reg  [NUM_SEG-1:0]          o_tx_mac_skip_crc,
    input  wire                        i_tx_mac_ready,

    // ---- Status / observability ----
    output reg  [31:0]                 o_rx_beats,
    output reg  [31:0]                 o_tx_beats,
    output reg  [31:0]                 o_ovf_beats,
    output wire [ADDR_W:0]             o_fifo_level
);

    // Sideband carried through the FIFO alongside the data
    localparam SB_W    = NUM_SEG + NUM_SEG*EMPTY_W + NUM_SEG + NUM_SEG;
    localparam ENTRY_W = DATA_W + SB_W;

    //=====================================================================
    // RX ERROR FLATTENING
    //
    // UG Table 46: o_rx_mac_error is 2 bits per segment.
    // UG Table 43: i_tx_mac_error is 1 bit per segment.
    //
    // RX error codes:  0 none, 1 malformed, 2 under/oversized,
    //                  3 payload length error
    // Any non-zero code, or an FCS error, becomes the single TX error bit.
    //=====================================================================
    wire [NUM_SEG-1:0] rx_err_flat;
    genvar gi;
    generate
      for (gi = 0; gi < NUM_SEG; gi = gi + 1) begin : g_err
        assign rx_err_flat[gi] = (|i_rx_mac_error[gi*2 +: 2]) |
                                  i_rx_mac_fcs_error[gi];
      end
    endgenerate

    //=====================================================================
    // ELASTIC BEAT FIFO
    //
    // Simple dual-port: write on the RX clock, read on the TX clock.
    // Explicit ramstyle keeps it in M20K, not MLAB.
    //=====================================================================
    (* ramstyle = "M20K, no_rw_check" *)
    reg [ENTRY_W-1:0] mem [0:FIFO_DEPTH-1];

    reg [ADDR_W:0] wr_ptr, rd_ptr;

    wire [ADDR_W:0] level = wr_ptr - rd_ptr;
    wire            full  = (level >= FIFO_DEPTH);
    wire            empty = (wr_ptr == rd_ptr);
    assign o_fifo_level = level;

    wire [ENTRY_W-1:0] wr_entry = { i_rx_mac_data,
                                    i_rx_mac_inframe,
                                    i_rx_mac_eop_empty,
                                    rx_err_flat,
                                    {NUM_SEG{1'b0}} };   // skip_crc = 0

    //---------------------------------------------------------------------
    // WRITE SIDE
    //
    // i_rx_mac_valid qualifies the whole interface cycle.
    // i_rx_mac_inframe says which segments carry frame data.
    // These mean DIFFERENT things - both are required. A beat with valid=1
    // but inframe=0 carries no frame content and must not occupy the FIFO.
    //---------------------------------------------------------------------
    always @(posedge i_clk_rx or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= 0;
            o_rx_beats  <= 0;
            o_ovf_beats <= 0;
        end else if (i_rx_mac_valid && (|i_rx_mac_inframe)) begin
            o_rx_beats <= o_rx_beats + 1'b1;
            if (!full) begin
                mem[wr_ptr[ADDR_W-1:0]] <= wr_entry;
                wr_ptr <= wr_ptr + 1'b1;
            end else begin
                // UG sec 7.5: "The interface does not take direct
                // backpressure." RX cannot be stalled, so a full FIFO means
                // the beat is lost. Counted here so it can never be silent.
                //
                // The production answer is PAUSE/PFC flow control (UG
                // sec 4.2.3), which stops the far end rather than dropping.
                o_ovf_beats <= o_ovf_beats + 1'b1;
            end
        end
    end

    //=====================================================================
    // TX PAUSE CONTROL - the heart of the protocol
    //=====================================================================
    reg [7:0] rdy_pipe;
    always @(posedge i_clk_tx or negedge rst_n) begin
        if (!rst_n) rdy_pipe <= 8'd0;
        else        rdy_pipe <= {rdy_pipe[6:0], i_tx_mac_ready};
    end

    // The outputs below are REGISTERED, which adds one cycle. Tapping at
    // [READY_LATENCY-2] makes o_tx_mac_valid land exactly READY_LATENCY
    // cycles after i_tx_mac_ready. Tapping at [READY_LATENCY-1] is off by
    // one - a real bug caught by the model's protocol checker.
    wire tx_en = (READY_LATENCY >= 2) ? rdy_pipe[READY_LATENCY-2]
                                       : i_tx_mac_ready;

    //=====================================================================
    // TX OUTPUT with registered FIFO read
    //=====================================================================
    reg [ENTRY_W-1:0] mem_q;      // registered read data
    reg               rd_vld_d;   // a read was issued last cycle

    always @(posedge i_clk_tx) begin
        if (tx_en) mem_q <= mem[rd_ptr[ADDR_W-1:0]];
    end

    always @(posedge i_clk_tx or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr             <= 0;
            rd_vld_d           <= 1'b0;
            o_tx_mac_data      <= 0;
            o_tx_mac_valid     <= 1'b0;
            o_tx_mac_inframe   <= 0;
            o_tx_mac_eop_empty <= 0;
            o_tx_mac_error     <= 0;
            o_tx_mac_skip_crc  <= 0;
            o_tx_beats         <= 0;
        end else begin

            // valid ALWAYS tracks ready delayed by READY_LATENCY. Never
            // gated on having data. UG sec 7.4: valid asserts whenever ready
            // is asserted "even though there is no packet to send".
            o_tx_mac_valid <= tx_en;

            if (tx_en) begin
                // Issue the next read one cycle ahead
                if (!empty) begin
                    rd_ptr   <= rd_ptr + 1'b1;
                    rd_vld_d <= 1'b1;
                end else begin
                    rd_vld_d <= 1'b0;
                end

                // Drive the beat fetched last cycle
                if (rd_vld_d) begin
                    {o_tx_mac_data, o_tx_mac_inframe, o_tx_mac_eop_empty,
                     o_tx_mac_error, o_tx_mac_skip_crc} <= mem_q;
                    o_tx_beats <= o_tx_beats + 1'b1;
                end else begin
                    // IDLE BEAT: inframe = 0 with valid still asserted.
                    // Deasserting valid here would break the protocol.
                    o_tx_mac_data      <= 0;
                    o_tx_mac_inframe   <= 0;
                    o_tx_mac_eop_empty <= 0;
                    o_tx_mac_error     <= 0;
                    o_tx_mac_skip_crc  <= 0;
                end
            end
            // tx_en low: every output register holds. The whole bus is
            // frozen, exactly as UG sec 7.4 requires.
        end
    end

endmodule
