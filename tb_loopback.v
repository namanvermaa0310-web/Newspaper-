//=============================================================================
// tb_loopback.v     -- Verilog-2001
//
//  STAGE 2 TESTBENCH  -  model -> loopback -> model
//
//  SET THE FRAME SIZE IN ONE PLACE, JUST BELOW.
//  Every frame in the run will be exactly that size.
//=============================================================================
`timescale 1ps/1ps

module tb_loopback;

//=============================================================================
//  >>>>>>>>>>>>>>>>>>>>   SET FRAME SIZE HERE   <<<<<<<<<<<<<<<<<<<<
//=============================================================================
//
//   FRAME_LEN = 64    -> 8 segments per frame  -> 2 frames per beat
//   FRAME_LEN = 128   -> 16 segments           -> 1 frame  per beat
//   FRAME_LEN = 256   -> 32 segments           -> 1 frame per 2 beats
//   FRAME_LEN = 1400  -> 175 segments          -> ~1 frame per 11 beats
//   FRAME_LEN = 1518  -> 190 segments          -> ~1 frame per 12 beats
//
//   Legal range 64 .. 1518 bytes.
//
//   A beat is 128 bytes (16 segments x 8 bytes). So:
//       frames per beat = 128 / FRAME_LEN
//
//   eop_empty is non-zero only when FRAME_LEN is NOT a multiple of 8.
//       64, 128, 1400  -> eop_empty = 0   (ends exactly on a segment)
//       1401, 1518     -> eop_empty > 0
//
    localparam FRAME_LEN  = 64;      // <-- CHANGE THIS
    localparam STALL_RATE = 0;       // 0 = TX never stalls, 40 = stalls often
    localparam RUN_CYCLES = 20000;
    localparam INJECT_ERR = 0;       // 1 = flag every frame as bad
//
//=============================================================================

    localparam DATA_W  = 1024;
    localparam NUM_SEG = 16;
    localparam EMPTY_W = 3;
    localparam RDY_LAT = 3;

    // MAC datapath clock 415.0390625 MHz  (UG 683023 sec 5)
    localparam CLK_HALF = 1204.75;

    //=========================================================================
    // Clock and reset
    //=========================================================================
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_HALF) clk = ~clk;

    reg run = 1'b0;

    //=========================================================================
    // Wires between the model and the loopback
    //=========================================================================
    wire [DATA_W-1:0]          rx_data;
    wire                       rx_valid;
    wire [NUM_SEG-1:0]         rx_inframe;
    wire [NUM_SEG*EMPTY_W-1:0] rx_eop_empty;
    wire [NUM_SEG-1:0]         rx_fcs_error;
    wire [NUM_SEG*2-1:0]       rx_error;
    wire [NUM_SEG*3-1:0]       rx_status;

    wire [DATA_W-1:0]          tx_data;
    wire                       tx_valid;
    wire [NUM_SEG-1:0]         tx_inframe;
    wire [NUM_SEG*EMPTY_W-1:0] tx_eop_empty;
    wire [NUM_SEG-1:0]         tx_error;
    wire [NUM_SEG-1:0]         tx_skip_crc;
    wire                       tx_ready;

    wire [31:0] frames, m_tx_frames, viol;
    wire [31:0] rx_beats, tx_beats, ovf_beats;
    wire [9:0]  fifo_level;

    //=========================================================================
    // The IP model  (stands in for the F-Tile Ethernet Hard IP)
    //=========================================================================
    ftile_eth_400g_model #(
        .DATA_W(DATA_W), .NUM_SEG(NUM_SEG), .EMPTY_W(EMPTY_W),
        .READY_LATENCY(RDY_LAT), .MIN_LEN(64), .MAX_LEN(1518)
    ) u_ip (
        .i_clk_tx           (clk),
        .i_clk_rx           (clk),
        .rst_n              (rst_n),
        .i_gen_enable       (run),
        .i_force_len        (FRAME_LEN[15:0]),   // every frame this size
        .i_inject_error     (INJECT_ERR[0]),
        .i_tx_stall_rate    (STALL_RATE[7:0]),
        .o_rx_mac_data      (rx_data),
        .o_rx_mac_valid     (rx_valid),
        .o_rx_mac_inframe   (rx_inframe),
        .o_rx_mac_eop_empty (rx_eop_empty),
        .o_rx_mac_fcs_error (rx_fcs_error),
        .o_rx_mac_error     (rx_error),
        .o_rx_mac_status_data(rx_status),
        .i_tx_mac_data      (tx_data),
        .i_tx_mac_valid     (tx_valid),
        .i_tx_mac_inframe   (tx_inframe),
        .i_tx_mac_eop_empty (tx_eop_empty),
        .i_tx_mac_error     (tx_error),
        .i_tx_mac_skip_crc  (tx_skip_crc),
        .o_tx_mac_ready     (tx_ready),
        .o_model_rx_frames  (frames),
        .o_model_tx_frames  (m_tx_frames),
        .o_model_proto_viol (viol)
    );

    //=========================================================================
    // The design under test
    //=========================================================================
    eth400g_loopback #(
        .DATA_W(DATA_W), .NUM_SEG(NUM_SEG), .EMPTY_W(EMPTY_W),
        .READY_LATENCY(RDY_LAT), .FIFO_DEPTH(512), .ADDR_W(9)
    ) u_lb (
        .i_clk_tx           (clk),
        .i_clk_rx           (clk),
        .rst_n              (rst_n),
        .i_rx_mac_data      (rx_data),
        .i_rx_mac_valid     (rx_valid),
        .i_rx_mac_inframe   (rx_inframe),
        .i_rx_mac_eop_empty (rx_eop_empty),
        .i_rx_mac_fcs_error (rx_fcs_error),
        .i_rx_mac_error     (rx_error),
        .o_tx_mac_data      (tx_data),
        .o_tx_mac_valid     (tx_valid),
        .o_tx_mac_inframe   (tx_inframe),
        .o_tx_mac_eop_empty (tx_eop_empty),
        .o_tx_mac_error     (tx_error),
        .o_tx_mac_skip_crc  (tx_skip_crc),
        .i_tx_mac_ready     (tx_ready),
        .o_rx_beats         (rx_beats),
        .o_tx_beats         (tx_beats),
        .o_ovf_beats        (ovf_beats),
        .o_fifo_level       (fifo_level)
    );

    //=========================================================================
    // Data integrity check
    //
    // Every beat leaving the loopback must equal the beat that entered.
    // A beat comparison, not a frame comparison - it does not care how many
    // frames are packed into a beat, which is exactly what we want.
    //=========================================================================
    localparam REF_W = DATA_W + NUM_SEG + NUM_SEG*EMPTY_W;

    reg [REF_W-1:0] refq [0:8191];
    integer wr_i, rd_i;
    integer mismatch;

    // Enqueue on the DUT's real write event, not on the RX input event.
    // If a beat is dropped the two would drift apart and every later compare
    // would falsely fail.
    wire dut_wrote = rx_valid && (|rx_inframe) && !u_lb.full;
    wire dut_sent  = tx_valid && (|tx_inframe);

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_i     <= 0;
            rd_i     <= 0;
            mismatch <= 0;
        end else begin
            if (dut_wrote) begin
                refq[wr_i % 8192] <= {rx_data, rx_inframe, rx_eop_empty};
                wr_i <= wr_i + 1;
            end
            if (dut_sent) begin
                if (refq[rd_i % 8192] !== {tx_data, tx_inframe, tx_eop_empty})
                    mismatch <= mismatch + 1;
                rd_i <= rd_i + 1;
            end
        end
    end

    //=========================================================================
    // Run
    //=========================================================================
    real t0, t1, gbps, fpb;
    integer beats_active;

    initial begin
        // reset
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // run traffic
        t0  = $realtime;
        run = 1'b1;
        repeat (RUN_CYCLES) @(posedge clk);
        run = 1'b0;
        t1  = $realtime;
        beats_active = tx_beats;

        // let the pipe drain
        repeat (2000) @(posedge clk);

        // rate measured over the ACTIVE window only
        gbps = (beats_active * DATA_W) / ((t1 - t0) / 1000.0);
        fpb  = (rx_beats == 0) ? 0.0 : (frames * 1.0) / rx_beats;

        $display("");
        $display("=====================================================");
        $display(" STAGE 2  -  loopback datapath");
        $display("=====================================================");
        $display(" frame size set      : %0d bytes", FRAME_LEN);
        $display(" TX stall rate       : %0d", STALL_RATE);
        $display("-----------------------------------------------------");
        $display(" frames received     : %0d", frames);
        $display(" beats  rx / tx      : %0d / %0d", rx_beats, tx_beats);
        $display(" FRAMES PER BEAT     : %0.3f   (expect %0.3f)",
                 fpb, 128.0/FRAME_LEN);
        $display(" fifo overflow beats : %0d", ovf_beats);
        $display("-----------------------------------------------------");
        $display(" DATA MISMATCHES     : %0d", mismatch);
        $display(" TX protocol viol.   : %0d", viol);
        $display(" interface rate      : %0.1f Gbps of 425  (%0.1f%%)",
                 gbps, gbps*100.0/425.0);
        $display("=====================================================");

        if (mismatch == 0 && viol == 0 && tx_beats != 0)
            $display(" PASS");
        else
            $display(" FAIL");
        $display("=====================================================");
        $display("");
        $finish;
    end

    //=========================================================================
    initial begin
        $dumpfile("tb_loopback.vcd");
        $dumpvars(0, tb_loopback);
    end

    initial begin
        #900000000;
        $display("** TIMEOUT");
        $finish;
    end

endmodule
