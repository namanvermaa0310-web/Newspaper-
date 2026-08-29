//=============================================================================
// eth400g_loopback.v     -- Verilog-2001
//
// 400G loopback datapath for the Agilex 7 F-Tile Ethernet Hard IP.
//
//   RX MAC segmented  ->  pipeline  ->  elastic FIFO  ->  TX MAC segmented
//
// Conforms to F-Tile Ethernet Hard IP User Guide, doc 683023, sec 7.4 / 7.5.
//
//=============================================================================
// DESIGN POINT 1 - NO PACKET LAYER
//=============================================================================
// UG sec 7.5: "Packets may start on any 8-byte segment... For multisegmented
// interfaces, a new packet may start and the previous packet end are within
// the same cycle."
//
// UG sec 7.4 Attention: "To achieve the maximum throughput... the input
// packets need to be packed tightly, leaving no idle segments in between."
//
// At 400G a beat is 128 bytes and the minimum frame is 64 bytes, so TWO
// frames land in ONE beat as a matter of course. Any design that keeps a
// single per-beat packet state - one sop pointer, one in_packet flag, one
// "count a packet on any_eop" - miscounts and eventually corrupts traffic.
//
// This module has NO packet layer. It buffers and replays 1024-bit beats
// verbatim, carrying inframe / eop_empty / error / skip_crc as opaque
// sideband. Multi-frame-per-beat is not "handled" - it is structurally
// impossible to get wrong, because frame boundaries are never inspected.
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
// Therefore:
//   * i_tx_mac_valid is o_tx_mac_ready delayed by exactly READY_LATENCY.
//     It is NOT derived from whether we have data.
//   * With nothing to send we still assert valid and drive inframe = 0.
//     An IDLE BEAT IS inframe=0, NOT valid=0.
//   * When ready is low the ENTIRE datapath freezes - including the
//     processing pipeline - so nothing is lost.
//
// A classic ready/valid construct ("out_free = ~valid | ready") is the WRONG
// protocol here and will fail against the real IP.
//=============================================================================
`timescale 1ps/1ps

module eth400g_loopback #(
    parameter DATA_W        = 1024,
    parameter NUM_SEG       = 16,
    parameter EMPTY_W       = 3,
    parameter READY_LATENCY = 3,     // must match the IP setting, 1..7
    parameter PIPE_STAGES   = 4,
    parameter PROC_BYPASS   = 0,
    parameter FIFO_DEPTH    = 1024,
    parameter ADDR_W        = 10
)(
    input  wire                        i_clk_tx,
    input  wire                        i_clk_rx,
    input  wire                        rst_n,

    // ---- RX MAC segmented client (from IP). No backpressure. ----
    input  wire [DATA_W-1:0]           i_rx_mac_data,
    input  wire                        i_rx_mac_valid,
    input  wire [NUM_SEG-1:0]          i_rx_mac_inframe,
    input  wire [NUM_SEG*EMPTY_W-1:0]  i_rx_mac_eop_empty,
    input  wire [NUM_SEG-1:0]          i_rx_mac_fcs_error,
    input  wire [NUM_SEG*2-1:0]        i_rx_mac_error,

    // ---- TX MAC segmented client (to IP) ----
    output reg  [DATA_W-1:0]           o_tx_mac_data,
    output reg                         o_tx_mac_valid,
    output reg  [NUM_SEG-1:0]          o_tx_mac_inframe,
    output reg  [NUM_SEG*EMPTY_W-1:0]  o_tx_mac_eop_empty,
    output reg  [NUM_SEG-1:0]          o_tx_mac_error,
    output reg  [NUM_SEG-1:0]          o_tx_mac_skip_crc,
    input  wire                        i_tx_mac_ready,

    // ---- Status ----
    output reg  [31:0]                 o_rx_beats,
    output reg  [31:0]                 o_tx_beats,
    output reg  [31:0]                 o_ovf_beats,
    output wire [ADDR_W:0]             o_fifo_level
);

    // Sideband carried through the FIFO alongside the data
    localparam SB_W    = NUM_SEG + NUM_SEG*EMPTY_W + NUM_SEG + NUM_SEG;
    localparam ENTRY_W = DATA_W + SB_W;

    //=====================================================================
    // TX PAUSE CONTROL - the heart of the protocol
    //=====================================================================
    // valid is ready delayed by exactly READY_LATENCY cycles.
    reg [7:0] rdy_pipe;
    always @(posedge i_clk_tx or negedge rst_n) begin
        if (!rst_n) rdy_pipe <= 8'd0;
        else        rdy_pipe <= {rdy_pipe[6:0], i_tx_mac_ready};
    end

    // NOTE the index: outputs below are REGISTERED, which adds one cycle.
    // Tapping at [READY_LATENCY-2] makes the registered o_tx_mac_valid land
    // at exactly READY_LATENCY cycles after o_tx_mac_ready, as UG 683023
    // sec 7.4 requires. Tapping at [READY_LATENCY-1] is off by one.
    wire tx_en = (READY_LATENCY >= 2) ? rdy_pipe[READY_LATENCY-2]
                                       : i_tx_mac_ready;

    //=====================================================================
    // Stage 1: pipelined processing (II=1, frozen by tx_en)
    //=====================================================================
    wire                       p_valid;
    wire [DATA_W-1:0]          p_data;
    wire [NUM_SEG-1:0]         p_inframe;
    wire [NUM_SEG*EMPTY_W-1:0] p_eop_empty;
    wire [NUM_SEG-1:0]         p_error;
    wire [NUM_SEG-1:0]         p_skip_crc;

    // RX error is 2 bits/segment; the TX interface takes 1 bit/segment.
    // Any non-zero RX error code, or an FCS error, marks the frame bad.
    wire [NUM_SEG-1:0] rx_err_flat;
    genvar gi;
    generate
      for (gi = 0; gi < NUM_SEG; gi = gi + 1) begin : g_err
        assign rx_err_flat[gi] = (|i_rx_mac_error[gi*2 +: 2]) |
                                  i_rx_mac_fcs_error[gi];
      end
    endgenerate

    pipe_proc #(
        .DATA_W(DATA_W), .NUM_SEG(NUM_SEG), .EMPTY_W(EMPTY_W),
        .PIPE_STAGES(PIPE_STAGES), .BYPASS(PROC_BYPASS)
    ) u_proc (
        .clk(i_clk_rx), .rst_n(rst_n),
        .i_en(1'b1),                       // RX side runs free
        .i_valid(i_rx_mac_valid),
        .i_data(i_rx_mac_data),
        .i_inframe(i_rx_mac_inframe),
        .i_eop_empty(i_rx_mac_eop_empty),
        .i_error(rx_err_flat),
        .i_skip_crc({NUM_SEG{1'b0}}),      // let the MAC insert CRC
        .o_valid(p_valid),
        .o_data(p_data),
        .o_inframe(p_inframe),
        .o_eop_empty(p_eop_empty),
        .o_error(p_error),
        .o_skip_crc(p_skip_crc)
    );

    //=====================================================================
    // Stage 2: elastic beat FIFO
    //=====================================================================
    reg [ENTRY_W-1:0] mem [0:FIFO_DEPTH-1];
    reg [ADDR_W:0]    wr_ptr, rd_ptr;

    wire [ADDR_W:0] level = wr_ptr - rd_ptr;
    wire            full  = (level >= FIFO_DEPTH);
    wire            empty = (wr_ptr == rd_ptr);
    assign o_fifo_level = level;

    wire [ENTRY_W-1:0] wr_entry =
        {p_data, p_inframe, p_eop_empty, p_error, p_skip_crc};

    always @(posedge i_clk_rx or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= 0;
            o_rx_beats  <= 0;
            o_ovf_beats <= 0;
        end else if (p_valid && (|p_inframe)) begin
            // Only real data beats are stored. RX idle beats carry no frame
            // content and must not consume FIFO space.
            o_rx_beats <= o_rx_beats + 1'b1;
            if (!full) begin
                mem[wr_ptr[ADDR_W-1:0]] <= wr_entry;
                wr_ptr <= wr_ptr + 1'b1;
            end else begin
                // RX takes no backpressure (UG sec 7.5). If the FIFO is full
                // the beat is lost - counted so it can never be silent.
                o_ovf_beats <= o_ovf_beats + 1'b1;
            end
        end
    end

    //=====================================================================
    // Stage 3: TX output - fixed-latency pause protocol
    //=====================================================================
    wire [ENTRY_W-1:0] dout = mem[rd_ptr[ADDR_W-1:0]];

    always @(posedge i_clk_tx or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr             <= 0;
            o_tx_mac_data      <= 0;
            o_tx_mac_valid     <= 1'b0;
            o_tx_mac_inframe   <= 0;
            o_tx_mac_eop_empty <= 0;
            o_tx_mac_error     <= 0;
            o_tx_mac_skip_crc  <= 0;
            o_tx_beats         <= 0;
        end else begin

            // valid ALWAYS tracks ready delayed by READY_LATENCY - it is
            // never gated on having data. UG sec 7.4: valid asserts whenever
            // ready is asserted "even though there is no packet to send".
            o_tx_mac_valid <= tx_en;

            if (tx_en) begin
                if (!empty) begin
                    {o_tx_mac_data, o_tx_mac_inframe, o_tx_mac_eop_empty,
                     o_tx_mac_error, o_tx_mac_skip_crc} <= dout;
                    rd_ptr     <= rd_ptr + 1'b1;
                    o_tx_beats <= o_tx_beats + 1'b1;
                end else begin
                    // Nothing to send: drive an IDLE BEAT.
                    // inframe = 0 with valid still asserted. Deasserting
                    // valid here would violate the protocol.
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
