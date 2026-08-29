//=============================================================================
// tb_eth400g_top.v     -- Verilog-2001
//
// Testbench: Agilex 7 F-Tile Ethernet IP model  <->  400G loopback datapath.
//
//   +--------------------------------+
//   |    ftile_eth_400g_model        |
//   |  (delete, swap in real IP)     |
//   +-----+--------------------+-----+
//     RX  |                    | TX
//         v                    ^
//   +-----+--------------------+-----+
//   |      eth400g_loopback          |
//   |   pipe_proc -> beat FIFO       |
//   +--------------------------------+
//
// Phases:
//   1  Mixed-length frames, no TX stall   - baseline + throughput
//   2  64-byte frames                     - multi-frame-per-beat stress
//   3  TX stalls                          - pause-protocol compliance
//   4  RX error injection                 - sideband integrity
//=============================================================================
`timescale 1ps/1ps

module tb_eth400g_top;

    localparam DATA_W  = 1024;
    localparam NUM_SEG = 16;
    localparam EMPTY_W = 3;
    localparam RDY_LAT = 3;      // 1..7 per UG 683023

    // ------------------------------------------------------------------
    // MAC datapath clock = 415.0390625 MHz
    //
    // UG 683023 sec 5: i_clk_tx / i_clk_rx are driven by o_clk_pll, and
    // o_clk_pll is "415.0390625 MHz or higher for all Ethernet modes with
    // IEEE 802.3 RS(544,514) (CL134)" - which is KP4 FEC, i.e. 400GE.
    //
    // Do NOT use 390.625 MHz here. That is o_clk_tx_div, a SERDES-derived
    // divided clock (TX SERDES rate / 68) used for TOD/PTP - it is a
    // DIFFERENT clock, not the MAC client datapath clock.
    //
    // 1024 bits x 415.0390625 MHz = 425 Gbps of INTERFACE capacity, which
    // carries 400 Gbps of MAC payload plus the idle segments that represent
    // inter-frame gap and preamble. The headroom is not an error - it is
    // what makes 400 Gbps of frames deliverable.
    // ------------------------------------------------------------------
    localparam CLK_HALF = 1204.75;   // half period, ps

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    reg        gen_enable   = 1'b0;
    reg [15:0] force_len    = 16'd0;
    reg        inject_error = 1'b0;
    reg [7:0]  stall_rate   = 8'd0;

    // RX: model -> loopback
    wire [DATA_W-1:0]          rx_data;
    wire                       rx_valid;
    wire [NUM_SEG-1:0]         rx_inframe;
    wire [NUM_SEG*EMPTY_W-1:0] rx_eop_empty;
    wire [NUM_SEG-1:0]         rx_fcs_error;
    wire [NUM_SEG*2-1:0]       rx_error;
    wire [NUM_SEG*3-1:0]       rx_status;

    // TX: loopback -> model
    wire [DATA_W-1:0]          tx_data;
    wire                       tx_valid;
    wire [NUM_SEG-1:0]         tx_inframe;
    wire [NUM_SEG*EMPTY_W-1:0] tx_eop_empty;
    wire [NUM_SEG-1:0]         tx_error;
    wire [NUM_SEG-1:0]         tx_skip_crc;
    wire                       tx_ready;

    wire [31:0] m_rx_frames, m_tx_frames, m_viol;
    wire [31:0] rx_beats, tx_beats, ovf_beats;
    wire [10:0] fifo_level;

    //---------------------------------------------------------------------
    ftile_eth_400g_model #(
        .DATA_W(DATA_W), .NUM_SEG(NUM_SEG), .EMPTY_W(EMPTY_W),
        .READY_LATENCY(RDY_LAT), .MIN_LEN(64), .MAX_LEN(1518)
    ) u_ip (
        .i_clk_tx(clk), .i_clk_rx(clk), .rst_n(rst_n),
        .i_gen_enable(gen_enable),
        .i_force_len(force_len),
        .i_inject_error(inject_error),
        .i_tx_stall_rate(stall_rate),
        .o_rx_mac_data(rx_data),
        .o_rx_mac_valid(rx_valid),
        .o_rx_mac_inframe(rx_inframe),
        .o_rx_mac_eop_empty(rx_eop_empty),
        .o_rx_mac_fcs_error(rx_fcs_error),
        .o_rx_mac_error(rx_error),
        .o_rx_mac_status_data(rx_status),
        .i_tx_mac_data(tx_data),
        .i_tx_mac_valid(tx_valid),
        .i_tx_mac_inframe(tx_inframe),
        .i_tx_mac_eop_empty(tx_eop_empty),
        .i_tx_mac_error(tx_error),
        .i_tx_mac_skip_crc(tx_skip_crc),
        .o_tx_mac_ready(tx_ready),
        .o_model_rx_frames(m_rx_frames),
        .o_model_tx_frames(m_tx_frames),
        .o_model_proto_viol(m_viol)
    );

    eth400g_loopback #(
        .DATA_W(DATA_W), .NUM_SEG(NUM_SEG), .EMPTY_W(EMPTY_W),
        .READY_LATENCY(RDY_LAT), .PIPE_STAGES(4), .PROC_BYPASS(1),
        .FIFO_DEPTH(1024), .ADDR_W(10)
    ) u_lb (
        .i_clk_tx(clk), .i_clk_rx(clk), .rst_n(rst_n),
        .i_rx_mac_data(rx_data),
        .i_rx_mac_valid(rx_valid),
        .i_rx_mac_inframe(rx_inframe),
        .i_rx_mac_eop_empty(rx_eop_empty),
        .i_rx_mac_fcs_error(rx_fcs_error),
        .i_rx_mac_error(rx_error),
        .o_tx_mac_data(tx_data),
        .o_tx_mac_valid(tx_valid),
        .o_tx_mac_inframe(tx_inframe),
        .o_tx_mac_eop_empty(tx_eop_empty),
        .o_tx_mac_error(tx_error),
        .o_tx_mac_skip_crc(tx_skip_crc),
        .i_tx_mac_ready(tx_ready),
        .o_rx_beats(rx_beats),
        .o_tx_beats(tx_beats),
        .o_ovf_beats(ovf_beats),
        .o_fifo_level(fifo_level)
    );

    //---------------------------------------------------------------------
    // Data integrity: every DATA beat out must equal the DATA beat in, in
    // order. Idle beats (inframe==0) are excluded from the comparison on
    // both sides, since idle insertion is legitimate.
    //---------------------------------------------------------------------
    localparam QD = 8192;
    reg [DATA_W+NUM_SEG+NUM_SEG*EMPTY_W-1:0] refq [0:QD-1];
    integer qw, qr, mismatch;

    always @(posedge clk) begin
        if (!rst_n) begin
            qw <= 0; qr <= 0; mismatch <= 0;
        end else begin
            // Enqueue on the DUT's ACTUAL FIFO write event, with the exact
            // data it stores. Gating on the RX input event instead
            // desynchronises the queue the moment a beat is dropped, turning
            // one drop into an unbounded run of false mismatches.
            if (u_lb.p_valid && (|u_lb.p_inframe) && !u_lb.full) begin
                refq[qw % QD] <= {u_lb.p_data, u_lb.p_inframe, u_lb.p_eop_empty};
                qw <= qw + 1;
            end
            if (tx_valid && (|tx_inframe)) begin
                if (refq[qr % QD] !== {tx_data, tx_inframe, tx_eop_empty})
                    mismatch <= mismatch + 1;
                qr <= qr + 1;
            end
        end
    end

    //---------------------------------------------------------------------
    integer errors;
    real    t0, t1, gbps, mpps;

    task run_phase;
        input [400*8-1:0] name;
        input integer     cycles;
        input [15:0]      len;
        input [7:0]       stall;
        input             err;
        begin
            gen_enable = 1'b0;
            rst_n      = 1'b0;
            repeat (20) @(posedge clk);
            rst_n      = 1'b1;
            repeat (10) @(posedge clk);

            force_len    = len;
            stall_rate   = stall;
            inject_error = err;

            t0 = $realtime;
            gen_enable = 1'b1;
            repeat (cycles) @(posedge clk);
            gen_enable = 1'b0;
            repeat (3000) @(posedge clk);
            t1 = $realtime;

            gbps = (tx_beats * DATA_W) / ((t1 - t0) / 1000.0);
            mpps = (m_rx_frames * 1000000.0) / (t1 - t0);   // frames per us

            $display("--------------------------------------------------------");
            $display("%0s", name);
            $display("  frames generated  : %0d  (TX frame count: see README)", m_rx_frames);
            $display("  beats    rx / tx  : %0d / %0d", rx_beats, tx_beats);
            $display("  fifo overflow     : %0d", ovf_beats);
            $display("  data mismatches   : %0d", mismatch);
            $display("  TX protocol viol. : %0d", m_viol);
            $display("  interface rate    : %0.1f Gbps (of 425 Gbps capacity)", gbps);
            $display("  packet rate       : %0.2f Mpps", mpps);

            if (mismatch != 0) begin
                $display("  ** FAIL: data mismatch"); errors = errors + 1;
            end
            if (m_viol != 0) begin
                $display("  ** FAIL: TX protocol violation"); errors = errors + 1;
            end
            if (tx_beats == 0) begin
                $display("  ** FAIL: no traffic"); errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;

        run_phase("PHASE 1: mixed-length frames, no TX stall",
                  20000, 16'd0, 8'd0, 1'b0);

        run_phase("PHASE 2: 64B frames (two frames per 128B beat)",
                  20000, 16'd64, 8'd0, 1'b0);

        run_phase("PHASE 3: TX stalls (pause-protocol compliance)",
                  20000, 16'd0, 8'd40, 1'b0);

        run_phase("PHASE 4: RX error injection",
                  10000, 16'd0, 8'd0, 1'b1);

        $display("========================================================");
        if (errors == 0) $display("RESULT: ALL PHASES PASSED");
        else             $display("RESULT: %0d FAILURE(S)", errors);
        $display("========================================================");
        $display("SCOPE: this models the 400GE MAC SEGMENTED CLIENT INTERFACE");
        $display("of the F-Tile Ethernet Hard IP - NOT the complete IP.");
        $display("NOT modelled: PMA, PCS, RS-FEC(KP4), lane distribution,");
        $display("gearbox, CDR, alignment marker lock, AN/LT, link training,");
        $display("PTP/TOD, CSR/Avalon-MM, reset and init sequencing.");
        $finish;
    end

    initial begin
        #900000000;
        $display("** TIMEOUT");
        $finish;
    end

endmodule
