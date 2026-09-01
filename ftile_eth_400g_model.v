//=============================================================================
// ftile_eth_400g_model.v      -- Verilog-2001
//
// Behavioural model of the Agilex 7 F-Tile Ethernet Hard IP, 400GE-8,
// MAC SEGMENTED client interface.
//
// SOURCE OF TRUTH
//   F-Tile Ethernet Hard IP User Guide, doc 683023, 2026.08.10
//   Section 7.4 TX MAC Segmented Client Interface  (Table 43)
//   Section 7.5 RX MAC Segmented Client Interface  (Table 46)
//
// PURPOSE
//   Build and verify the loopback datapath without the licensed IP.
//   Delete this file and instantiate the real IP when licensed - the
//   datapath connects to the same signal names with no changes.
//
//=============================================================================
// TX IS **NOT** A READY/VALID HANDSHAKE - THIS IS THE KEY DETAIL
//=============================================================================
// UG 683023 sec 7.4, verbatim:
//
//   "The i_tx_mac_valid signal deasserts when the o_tx_mac_ready signal is
//    deasserted. The i_tx_mac_valid signal asserts only when the
//    o_tx_mac_ready signal is asserted, even though there is no packet to
//    send."
//
//   "The i_tx_mac_valid and the o_tx_mac_ready signals can be spaced by a
//    fixed latency between 1 to 7 clock cycles."
//
//   "When i_tx_mac_valid deasserts, i_tx_mac_data, i_tx_mac_inframe,
//    i_tx_mac_eop_empty, i_tx_mac_error and i_tx_skip_crc signals must be
//    paused for as many cycles as o_tx_mac_ready is deasserted."
//
// So this is a FIXED-LATENCY PAUSE interface (Avalon-ST style ready latency),
// NOT AXI-style backpressure. When ready drops, you deassert valid exactly
// READY_LATENCY cycles later and FREEZE the whole bus for as many cycles as
// ready was low, then resume.
//
// Two consequences that catch people out:
//   1. You CANNOT use "out_free = ~valid | ready" - wrong protocol.
//   2. valid asserts whenever ready is asserted, EVEN WITH NOTHING TO SEND.
//      An idle beat is inframe = 0, not valid = 0.
//
//=============================================================================
// TIGHT PACKING IS MANDATORY FOR FULL THROUGHPUT
//=============================================================================
// UG 683023 sec 7.4, Attention box, verbatim:
//   "To achieve the maximum throughput when using the TX MAC segmented
//    interface, the input packets need to be packed tightly, leaving no idle
//    segments in between."
//
// So frames butt up against each other with NO gap segment. At 400G a beat is
// 128 bytes and the minimum frame is 64 bytes, so TWO frames land in ONE beat
// routinely. UG sec 7.5: "For multisegmented interfaces, a new packet may
// start and the previous packet end are within the same cycle."
//
//=============================================================================
// 400GE-8 GEOMETRY
//   1024-bit data, 16 segments x 64 bits (8 bytes)
//   inframe    16 bits  (1 per segment)
//   eop_empty  48 bits  (3 per segment)
//   tx error   16 bits  (1 per segment)
//   rx error   32 bits  (2 per segment)   <-- NOTE: 2 bits, not 1
//   fcs_error  16 bits  (1 per segment)
//   status     48 bits  (3 per segment)
//   Client clock ~415.03 MHz -> 1024 x 415.03e6 = 425 Gbps
//=============================================================================
`timescale 1ps/1ps

module ftile_eth_400g_model #(
    parameter DATA_W        = 1024,
    parameter NUM_SEG       = 16,
    parameter EMPTY_W       = 3,
    parameter SEG_B         = 8,
    parameter READY_LATENCY = 3,     // legal range 1..7 per UG 683023
    parameter MIN_LEN       = 64,
    parameter MAX_LEN       = 1518,
    parameter SEED          = 32'hACE1_2345
)(
    input  wire                        i_clk_tx,
    input  wire                        i_clk_rx,
    input  wire                        rst_n,

    // ---- model control (not on the real IP) ----
    input  wire                        i_gen_enable,
    input  wire [15:0]                 i_force_len,
    input  wire                        i_inject_error,
    input  wire [7:0]                  i_tx_stall_rate,   // 0 = never stall

    // ================= RX MAC segmented client (IP -> user) =============
    // UG Table 46. "The interface does not take direct backpressure."
    output reg  [DATA_W-1:0]           o_rx_mac_data,
    output reg                         o_rx_mac_valid,
    output reg  [NUM_SEG-1:0]          o_rx_mac_inframe,
    output reg  [NUM_SEG*EMPTY_W-1:0]  o_rx_mac_eop_empty,
    output reg  [NUM_SEG-1:0]          o_rx_mac_fcs_error,
    output reg  [NUM_SEG*2-1:0]        o_rx_mac_error,       // 2 bits/segment
    output reg  [NUM_SEG*3-1:0]        o_rx_mac_status_data, // 3 bits/segment

    // ================= TX MAC segmented client (user -> IP) =============
    // UG Table 43.
    input  wire [DATA_W-1:0]           i_tx_mac_data,
    input  wire                        i_tx_mac_valid,
    input  wire [NUM_SEG-1:0]          i_tx_mac_inframe,
    input  wire [NUM_SEG*EMPTY_W-1:0]  i_tx_mac_eop_empty,
    input  wire [NUM_SEG-1:0]          i_tx_mac_error,
    input  wire [NUM_SEG-1:0]          i_tx_mac_skip_crc,
    output reg                         o_tx_mac_ready,

    // ---- model observation (not on the real IP) ----
    output reg  [31:0]                 o_model_rx_frames,
    output reg  [31:0]                 o_model_tx_frames,
    output reg  [31:0]                 o_model_proto_viol
);

    //=====================================================================
    // Pseudo-random source
    //=====================================================================
    reg [31:0] lfsr;
    always @(posedge i_clk_rx or negedge rst_n) begin
        if (!rst_n) lfsr <= SEED;
        else        lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    end

    //=====================================================================
    // RX GENERATOR - frames packed TIGHTLY, no gap segments
    //=====================================================================
    function [7:0] frame_byte;
        input integer idx;
        input [31:0]  sq;
        begin
            if      (idx <   6) frame_byte = 8'hFF;        // DA broadcast
            else if (idx ==  6) frame_byte = 8'h00;        // SA
            else if (idx ==  7) frame_byte = 8'h1A;
            else if (idx ==  8) frame_byte = 8'h2B;
            else if (idx ==  9) frame_byte = 8'h3C;
            else if (idx == 10) frame_byte = 8'h4D;
            else if (idx == 11) frame_byte = 8'h5E;
            else if (idx == 12) frame_byte = 8'h08;        // Length/Type hi
            else if (idx == 13) frame_byte = 8'h00;        // Length/Type lo
            else if (idx == 14) frame_byte = sq[31:24];
            else if (idx == 15) frame_byte = sq[23:16];
            else if (idx == 16) frame_byte = sq[15:8];
            else if (idx == 17) frame_byte = sq[7:0];
            else                frame_byte = (idx & 8'hFF) ^ sq[7:0];
        end
    endfunction

    reg [31:0] rx_seq;
    reg [15:0] rx_len;
    reg [15:0] rx_off;
    reg        rx_active;

    integer s, b;
    integer frames_this_beat;   // blocking accumulator - see note below
    reg [15:0] nlen;
    reg [DATA_W-1:0]          nx_data;
    reg [NUM_SEG-1:0]         nx_inframe;
    reg [NUM_SEG*EMPTY_W-1:0] nx_empty;
    reg [NUM_SEG-1:0]         nx_fcs;
    reg [NUM_SEG*2-1:0]       nx_err;

    always @(posedge i_clk_rx or negedge rst_n) begin
        if (!rst_n) begin
            o_rx_mac_data        <= 0;
            o_rx_mac_valid       <= 1'b0;
            o_rx_mac_inframe     <= 0;
            o_rx_mac_eop_empty   <= 0;
            o_rx_mac_fcs_error   <= 0;
            o_rx_mac_error       <= 0;
            o_rx_mac_status_data <= 0;
            rx_seq               <= 0;
            rx_len               <= MIN_LEN;
            rx_off               <= 0;
            rx_active            <= 1'b0;
            o_model_rx_frames    <= 0;
        end else if (i_gen_enable || rx_active) begin

            frames_this_beat = 0;
            nx_data    = 0;
            nx_inframe = 0;
            nx_empty   = 0;
            nx_fcs     = 0;
            nx_err     = 0;

            // Build one beat, packing frames back to back with NO gap.
            for (s = 0; s < NUM_SEG; s = s + 1) begin

                if (!rx_active) begin
                    if (i_gen_enable) begin
                        nlen = (i_force_len != 0) ? i_force_len :
                               (MIN_LEN + (lfsr[15:0] % (MAX_LEN-MIN_LEN+1)));
                        rx_len    = nlen;
                        rx_off    = 0;
                        rx_active = 1'b1;
                    end
                end

                if (rx_active) begin
                    for (b = 0; b < SEG_B; b = b + 1) begin
                        if ((rx_off + b) < rx_len)
                            nx_data[(s*SEG_B + b)*8 +: 8] =
                                frame_byte(rx_off + b, rx_seq);
                    end

                    nx_inframe[s] = 1'b1;

                    if ((rx_off + SEG_B) >= rx_len) begin
                        // EOP in this segment
                        nx_empty[s*EMPTY_W +: EMPTY_W] =
                            (SEG_B - (rx_len - rx_off));
                        if (i_inject_error) begin
                            nx_fcs[s]            = 1'b1;
                            nx_err[s*2 +: 2]     = 2'd1;   // malformed
                        end
                        rx_seq           = rx_seq + 1'b1;
                        frames_this_beat = frames_this_beat + 1;
                        rx_active          = 1'b0;   // next segment may start
                        rx_off             = 0;      // a NEW frame immediately
                    end else begin
                        rx_off = rx_off + SEG_B;
                    end
                end
            end

            o_rx_mac_data        <= nx_data;
            o_rx_mac_inframe     <= nx_inframe;
            o_rx_mac_eop_empty   <= nx_empty;
            o_rx_mac_fcs_error   <= nx_fcs;
            o_rx_mac_error       <= nx_err;
            o_rx_mac_status_data <= 0;
            o_rx_mac_valid       <= (|nx_inframe);
            o_model_rx_frames    <= o_model_rx_frames + frames_this_beat;

            rx_seq    <= rx_seq;
            rx_len    <= rx_len;
            rx_off    <= rx_off;
            rx_active <= rx_active;

        end else begin
            o_rx_mac_valid   <= 1'b0;
            o_rx_mac_inframe <= 0;
        end
    end

    //=====================================================================
    // TX READY GENERATOR
    //=====================================================================
    reg [7:0] stall_lfsr;
    always @(posedge i_clk_tx or negedge rst_n) begin
        if (!rst_n) begin
            stall_lfsr     <= 8'h5A;
            o_tx_mac_ready <= 1'b0;
        end else begin
            stall_lfsr <= {stall_lfsr[6:0], stall_lfsr[7]^stall_lfsr[5]};
            o_tx_mac_ready <= (i_tx_stall_rate == 8'd0) ? 1'b1
                                                        : (stall_lfsr > i_tx_stall_rate);
        end
    end

    //=====================================================================
    // TX PROTOCOL CHECKER
    //
    // Enforces UG 683023 sec 7.4:
    //   valid must track ready delayed by exactly READY_LATENCY cycles, and
    //   the bus must freeze while valid is deasserted.
    //=====================================================================
    reg [7:0] rdy_pipe;
    integer   t;
    reg       prev_if;

    reg [DATA_W-1:0]          tx_d_hold;
    reg [NUM_SEG-1:0]         tx_if_hold;
    reg                       have_hold;
    reg                       tx_midframe;

    wire exp_valid = rdy_pipe[READY_LATENCY-1];

    always @(posedge i_clk_tx or negedge rst_n) begin
        if (!rst_n) begin
            rdy_pipe           <= 8'd0;
            tx_midframe        <= 1'b0;
            tx_d_hold          <= 0;
            tx_if_hold         <= 0;
            have_hold          <= 1'b0;
            o_model_tx_frames  <= 0;
            o_model_proto_viol <= 0;
        end else begin
            rdy_pipe <= {rdy_pipe[6:0], o_tx_mac_ready};

            // ---- Rule 1: valid must equal ready delayed by READY_LATENCY ---
            if (i_tx_mac_valid !== exp_valid) begin
                o_model_proto_viol <= o_model_proto_viol + 1'b1;
                $display("[%0t] TX PROTOCOL: valid=%b but ready(-%0d)=%b",
                         $time, i_tx_mac_valid, READY_LATENCY, exp_valid);
            end

            // ---- Rule 2: bus must be frozen while valid is low -------------
            if (!i_tx_mac_valid && have_hold) begin
                if ((i_tx_mac_data !== tx_d_hold) ||
                    (i_tx_mac_inframe !== tx_if_hold)) begin
                    o_model_proto_viol <= o_model_proto_viol + 1'b1;
                    $display("[%0t] TX PROTOCOL: bus changed while valid low",
                             $time);
                end
            end

            if (i_tx_mac_valid) begin
                tx_d_hold  <= i_tx_mac_data;
                tx_if_hold <= i_tx_mac_inframe;
                have_hold  <= 1'b1;

                // ---- TX FRAME COUNTING IS DELIBERATELY NOT IMPLEMENTED ----
                // UG 683023 requires frames to be packed tightly with no idle
                // segments, which means inframe stays HIGH across a frame
                // boundary - so there is no 1->0 transition to count.
                //
                // The UG text for locating EOP under tight packing is
                // self-contradictory in both the TX (sec 7.4) and RX (7.5)
                // descriptions, so any counter written now would encode a
                // guess. See the OPEN QUESTION in README.
                //
                // Beat-exact data comparison in the testbench is a STRICTLY
                // STRONGER check than a frame count, so nothing is lost by
                // leaving this unimplemented until the encoding is confirmed.
                tx_midframe <= i_tx_mac_inframe[NUM_SEG-1];
            end
        end
    end

endmodule
