//=============================================================================
// pipe_proc.v     -- Verilog-2001
//
// Fully-pipelined processing stage for the 400G datapath.
//
// THROUGHPUT CONTRACT
//   Initiation interval = 1. One 1024-bit beat in, one out, EVERY enabled
//   cycle. No stall path inside. Latency = PIPE_STAGES and is irrelevant to
//   throughput - that is the entire point.
//
//   1024 bits/cycle x 415.03 MHz = 425 Gbps.
//
// FREEZE INPUT
//   i_en gates every pipeline register. It exists because the F-Tile TX MAC
//   uses a FIXED-LATENCY PAUSE protocol (UG 683023 sec 7.4), not ready/valid:
//   when o_tx_mac_ready deasserts the WHOLE bus must freeze. Gating the
//   pipeline is how that freeze propagates backwards without losing data.
//
// REPLACING THIS WITH CRYPTO
//   Swap the body for AES-GCM / SecY. Keep two things identical:
//     - II=1, no internal stall
//     - every register gated by i_en
//   Then the datapath around it needs no change.
//=============================================================================
`timescale 1ps/1ps

module pipe_proc #(
    parameter DATA_W      = 1024,
    parameter NUM_SEG     = 16,
    parameter EMPTY_W     = 3,
    parameter PIPE_STAGES = 4,
    parameter BYPASS      = 0
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        i_en,        // freeze when low

    input  wire                        i_valid,
    input  wire [DATA_W-1:0]           i_data,
    input  wire [NUM_SEG-1:0]          i_inframe,
    input  wire [NUM_SEG*EMPTY_W-1:0]  i_eop_empty,
    input  wire [NUM_SEG-1:0]          i_error,
    input  wire [NUM_SEG-1:0]          i_skip_crc,

    output wire                        o_valid,
    output wire [DATA_W-1:0]           o_data,
    output wire [NUM_SEG-1:0]          o_inframe,
    output wire [NUM_SEG*EMPTY_W-1:0]  o_eop_empty,
    output wire [NUM_SEG-1:0]          o_error,
    output wire [NUM_SEG-1:0]          o_skip_crc
);

    localparam SEG_W = DATA_W / NUM_SEG;
    localparam SB_W  = 1 + NUM_SEG + NUM_SEG*EMPTY_W + NUM_SEG + NUM_SEG;

    //---------------------------------------------------------------------
    // Sideband delay line, matched to the data path length
    //---------------------------------------------------------------------
    reg [SB_W-1:0] sb [0:PIPE_STAGES-1];
    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < PIPE_STAGES; k = k + 1) sb[k] <= 0;
        end else if (i_en) begin
            sb[0] <= {i_valid, i_inframe, i_eop_empty, i_error, i_skip_crc};
            for (k = 1; k < PIPE_STAGES; k = k + 1) sb[k] <= sb[k-1];
        end
    end

    assign {o_valid, o_inframe, o_eop_empty, o_error, o_skip_crc} =
           sb[PIPE_STAGES-1];

    //---------------------------------------------------------------------
    // Data path
    //---------------------------------------------------------------------
    generate
    if (BYPASS != 0) begin : g_bypass

        reg [DATA_W-1:0] d [0:PIPE_STAGES-1];
        integer j;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) for (j=0;j<PIPE_STAGES;j=j+1) d[j] <= 0;
            else if (i_en) begin
                d[0] <= i_data;
                for (j=1;j<PIPE_STAGES;j=j+1) d[j] <= d[j-1];
            end
        end
        assign o_data = d[PIPE_STAGES-1];

    end else begin : g_proc

        // Stage 0: capture
        reg [DATA_W-1:0] s0;
        always @(posedge clk or negedge rst_n)
            if (!rst_n)     s0 <= 0;
            else if (i_en)  s0 <= i_data;

        // Stage 1: per-segment 32x32 multiply (infers DSP blocks)
        reg [63:0]       s1_mul [0:NUM_SEG-1];
        reg [DATA_W-1:0] s1;
        integer m;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                for (m=0;m<NUM_SEG;m=m+1) s1_mul[m] <= 0;
                s1 <= 0;
            end else if (i_en) begin
                for (m=0;m<NUM_SEG;m=m+1)
                    s1_mul[m] <= s0[m*SEG_W +: 32] * s0[m*SEG_W+32 +: 32];
                s1 <= s0;
            end
        end

        // Stage 2: add round constant
        reg [63:0]       s2_acc [0:NUM_SEG-1];
        reg [DATA_W-1:0] s2;
        integer n;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                for (n=0;n<NUM_SEG;n=n+1) s2_acc[n] <= 0;
                s2 <= 0;
            end else if (i_en) begin
                for (n=0;n<NUM_SEG;n=n+1)
                    s2_acc[n] <= s1_mul[n] + 64'h9E3779B9_7F4A7C15;
                s2 <= s1;
            end
        end

        // Stage 3: XOR fold, output register
        reg [DATA_W-1:0] s3;
        integer q;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) s3 <= 0;
            else if (i_en)
                for (q=0;q<NUM_SEG;q=q+1)
                    s3[q*SEG_W +: SEG_W] <= s2[q*SEG_W +: SEG_W] ^ s2_acc[q];
        end

        assign o_data = s3;

    end
    endgenerate

endmodule
