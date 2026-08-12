// =============================================================================
// keccak_uart_core.sv -- UART command bridge for the Phase 2 Keccak engines
// -----------------------------------------------------------------------------
// Same architecture as Phase 1's mlkem_uart_core: board-INDEPENDENT, plain
// clock/reset plus one UART RX and one UART TX pin, so the whole thing is
// simulatable. All KC705-specific glue (IBUFDS, MMCM, pin names) stays in
// kc705_keccak_top.sv.
//
// Exposes both FIPS 202 primitives built in Phase 2:
//   SHA3-256  -- fixed 32-byte digest, rate 136, domain byte 0x06
//   SHAKE-256 -- variable-length XOF,  rate 136, domain byte 0x1F
//
// COMMAND PROTOCOL (host -> FPGA), 8N1, LSB first:
//
//   0xA5                                   PING            -> 0x5A
//
//   -- SHA3-256 --------------------------------------------------------
//   0x30 <a_lo> <a_hi> <data>              write msg byte  -> 0x30
//   0x31 <len_lo> <len_hi>                 start (msg_len) -> 0x31
//   0x32                                   status          -> {6'b0,done,busy}
//   0x33 <idx>                             read digest[idx] (0..31) -> byte
//
//   -- SHAKE-256 -------------------------------------------------------
//   0x40 <a_lo> <a_hi> <data>              write msg byte  -> 0x40
//   0x41 <ml_lo> <ml_hi> <ol_lo> <ol_hi>   start           -> 0x41
//   0x42                                   status          -> {6'b0,done,busy}
//   0x43 <i_lo> <i_hi>                     read out[idx]   -> byte
//
// Message-buffer addresses and lengths are 16-bit little-endian on the wire
// (only the low 9/10 bits are used internally). Digest byte 0 is the most
// significant byte, matching the convention SHA3-256("") = a7ffc6f8...
//
// DEBUG INSTRUMENTATION
// Signals carrying (* MARK_DEBUG = "true" *) are preserved through synthesis
// and appear in Vivado's Set Up Debug wizard for ILA probing. The attribute
// only stops the tool optimising the net away and renaming it -- it does NOT
// itself create an ILA. Insert the ILA with the wizard (see README) or remove
// these attributes if you want a smaller, debug-free build.
// =============================================================================
module keccak_uart_core #(
  parameter integer CLKS_PER_BIT = 868,   // 100 MHz / 115200 baud
  parameter integer MAX_MSG      = 512,
  parameter integer MAX_OUT      = 272
)(
  input  wire clk,
  input  wire rst_n,
  input  wire uart_rx_i,
  output wire uart_tx_o
);

  // ---------------------------------------------------------------------------
  // UART physical layer (reused unchanged from Phase 1)
  // ---------------------------------------------------------------------------
  (* MARK_DEBUG = "true" *) wire [7:0] rx_data;
  (* MARK_DEBUG = "true" *) wire       rx_valid;

  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
    .clk(clk), .rst_n(rst_n), .rx(uart_rx_i),
    .data(rx_data), .valid(rx_valid)
  );

  (* MARK_DEBUG = "true" *) reg        tx_send;
  (* MARK_DEBUG = "true" *) reg  [7:0] tx_data;
  (* MARK_DEBUG = "true" *) wire       tx_busy;

  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
    .clk(clk), .rst_n(rst_n), .send(tx_send), .data(tx_data),
    .tx(uart_tx_o), .busy(tx_busy)
  );

  // ---------------------------------------------------------------------------
  // SHA3-256
  // ---------------------------------------------------------------------------
  (* MARK_DEBUG = "true" *) reg          sha_start;
  (* MARK_DEBUG = "true" *) reg  [9:0]   sha_msg_len;
  reg  [8:0]   sha_wr_addr;
  reg  [7:0]   sha_wr_data;
  reg          sha_wr_en;
  (* MARK_DEBUG = "true" *) wire         sha_busy, sha_done;
  wire [255:0] sha_hash;

  sha3_256_mb #(.MAX_MSG_BYTES(MAX_MSG)) u_sha3 (
    .clk(clk), .rst_n(rst_n), .start(sha_start),
    .msg_len(sha_msg_len),
    .wr_addr(sha_wr_addr), .wr_data(sha_wr_data), .wr_en(sha_wr_en),
    .busy(sha_busy), .done(sha_done), .hash_out(sha_hash)
  );

  // ---------------------------------------------------------------------------
  // SHAKE-256
  // ---------------------------------------------------------------------------
  (* MARK_DEBUG = "true" *) reg        shk_start;
  (* MARK_DEBUG = "true" *) reg  [9:0] shk_msg_len;
  (* MARK_DEBUG = "true" *) reg  [9:0] shk_out_len;
  reg  [8:0] shk_wr_addr;
  reg  [7:0] shk_wr_data;
  reg        shk_wr_en;
  reg  [9:0] shk_rd_addr;
  wire [7:0] shk_rd_data;
  (* MARK_DEBUG = "true" *) wire       shk_busy, shk_done;

  shake256 #(.MAX_MSG_BYTES(MAX_MSG), .MAX_OUT_BYTES(MAX_OUT)) u_shake (
    .clk(clk), .rst_n(rst_n), .start(shk_start),
    .msg_len(shk_msg_len),
    .wr_addr(shk_wr_addr), .wr_data(shk_wr_data), .wr_en(shk_wr_en),
    .out_len(shk_out_len),
    .busy(shk_busy), .done(shk_done),
    .rd_addr(shk_rd_addr), .rd_data(shk_rd_data)
  );

  // ---------------------------------------------------------------------------
  // Digest byte select: byte 0 is the MSB of hash_out
  // ---------------------------------------------------------------------------
  reg [4:0] dig_idx;
  wire [7:0] dig_byte = sha_hash[(31 - dig_idx)*8 +: 8];

  // ---------------------------------------------------------------------------
  // Command FSM
  // ---------------------------------------------------------------------------
  localparam [7:0] C_PING      = 8'hA5;
  localparam [7:0] PING_REPLY  = 8'h5A;
  localparam [7:0] C_SHA_WR    = 8'h30;
  localparam [7:0] C_SHA_GO    = 8'h31;
  localparam [7:0] C_SHA_ST    = 8'h32;
  localparam [7:0] C_SHA_RD    = 8'h33;
  localparam [7:0] C_SHK_WR    = 8'h40;
  localparam [7:0] C_SHK_GO    = 8'h41;
  localparam [7:0] C_SHK_ST    = 8'h42;
  localparam [7:0] C_SHK_RD    = 8'h43;

  localparam ST_CMD      = 5'd0;
  localparam ST_SHAW_A0  = 5'd1;   // SHA3 write: addr low
  localparam ST_SHAW_A1  = 5'd2;   // SHA3 write: addr high
  localparam ST_SHAW_D   = 5'd3;   // SHA3 write: data, commit
  localparam ST_SHAG_L0  = 5'd4;   // SHA3 start: len low
  localparam ST_SHAG_L1  = 5'd5;   // SHA3 start: len high, kick
  localparam ST_SHAR_I   = 5'd6;   // SHA3 read: index
  localparam ST_SHAR_W   = 5'd7;   // SHA3 read: settle
  localparam ST_SHKW_A0  = 5'd8;
  localparam ST_SHKW_A1  = 5'd9;
  localparam ST_SHKW_D   = 5'd10;
  localparam ST_SHKG_M0  = 5'd11;  // SHAKE start: msg_len low
  localparam ST_SHKG_M1  = 5'd12;  // SHAKE start: msg_len high
  localparam ST_SHKG_O0  = 5'd13;  // SHAKE start: out_len low
  localparam ST_SHKG_O1  = 5'd14;  // SHAKE start: out_len high, kick
  localparam ST_SHKR_I0  = 5'd15;  // SHAKE read: index low
  localparam ST_SHKR_I1  = 5'd16;  // SHAKE read: index high
  localparam ST_SHKR_W   = 5'd17;  // SHAKE read: settle
  localparam ST_REPLY    = 5'd18;
  localparam ST_TX_WAIT  = 5'd19;

  (* MARK_DEBUG = "true" *) reg [4:0] state;
  reg [4:0] next_after_tx;
  reg [7:0] pending_tx;
  reg [7:0] tmp_lo;

  always @(posedge clk) begin
    if (!rst_n) begin
      state <= ST_CMD; next_after_tx <= ST_CMD;
      tx_send <= 1'b0; tx_data <= 8'd0; pending_tx <= 8'd0; tmp_lo <= 8'd0;
      sha_start <= 1'b0; sha_msg_len <= 10'd0; sha_wr_addr <= 9'd0;
      sha_wr_data <= 8'd0; sha_wr_en <= 1'b0; dig_idx <= 5'd0;
      shk_start <= 1'b0; shk_msg_len <= 10'd0; shk_out_len <= 10'd0;
      shk_wr_addr <= 9'd0; shk_wr_data <= 8'd0; shk_wr_en <= 1'b0;
      shk_rd_addr <= 10'd0;
    end else begin
      tx_send   <= 1'b0;
      sha_start <= 1'b0;
      sha_wr_en <= 1'b0;
      shk_start <= 1'b0;
      shk_wr_en <= 1'b0;

      case (state)
        ST_CMD: if (rx_valid) begin
          case (rx_data)
            C_SHA_WR: state <= ST_SHAW_A0;
            C_SHA_GO: state <= ST_SHAG_L0;
            C_SHA_RD: state <= ST_SHAR_I;
            C_SHK_WR: state <= ST_SHKW_A0;
            C_SHK_GO: state <= ST_SHKG_M0;
            C_SHK_RD: state <= ST_SHKR_I0;

            C_SHA_ST: begin
              pending_tx <= {6'd0, sha_done, sha_busy};
              state <= ST_REPLY;
            end
            C_SHK_ST: begin
              pending_tx <= {6'd0, shk_done, shk_busy};
              state <= ST_REPLY;
            end
            C_PING: begin
              pending_tx <= PING_REPLY;
              state <= ST_REPLY;
            end
            default: state <= ST_CMD;
          endcase
        end

        // ---- SHA3-256 write ------------------------------------------------
        ST_SHAW_A0: if (rx_valid) begin tmp_lo <= rx_data; state <= ST_SHAW_A1; end
        ST_SHAW_A1: if (rx_valid) begin
          sha_wr_addr <= {rx_data[0], tmp_lo};
          state <= ST_SHAW_D;
        end
        ST_SHAW_D: if (rx_valid) begin
          sha_wr_data <= rx_data;
          sha_wr_en   <= 1'b1;
          pending_tx  <= C_SHA_WR;
          state <= ST_REPLY;
        end

        // ---- SHA3-256 start ------------------------------------------------
        ST_SHAG_L0: if (rx_valid) begin tmp_lo <= rx_data; state <= ST_SHAG_L1; end
        ST_SHAG_L1: if (rx_valid) begin
          sha_msg_len <= {rx_data[1:0], tmp_lo};
          sha_start   <= 1'b1;
          pending_tx  <= C_SHA_GO;
          state <= ST_REPLY;
        end

        // ---- SHA3-256 digest read ------------------------------------------
        ST_SHAR_I: if (rx_valid) begin
          dig_idx <= rx_data[4:0];
          state <= ST_SHAR_W;
        end
        ST_SHAR_W: begin
          pending_tx <= dig_byte;
          state <= ST_REPLY;
        end

        // ---- SHAKE-256 write -----------------------------------------------
        ST_SHKW_A0: if (rx_valid) begin tmp_lo <= rx_data; state <= ST_SHKW_A1; end
        ST_SHKW_A1: if (rx_valid) begin
          shk_wr_addr <= {rx_data[0], tmp_lo};
          state <= ST_SHKW_D;
        end
        ST_SHKW_D: if (rx_valid) begin
          shk_wr_data <= rx_data;
          shk_wr_en   <= 1'b1;
          pending_tx  <= C_SHK_WR;
          state <= ST_REPLY;
        end

        // ---- SHAKE-256 start -----------------------------------------------
        ST_SHKG_M0: if (rx_valid) begin tmp_lo <= rx_data; state <= ST_SHKG_M1; end
        ST_SHKG_M1: if (rx_valid) begin
          shk_msg_len <= {rx_data[1:0], tmp_lo};
          state <= ST_SHKG_O0;
        end
        ST_SHKG_O0: if (rx_valid) begin tmp_lo <= rx_data; state <= ST_SHKG_O1; end
        ST_SHKG_O1: if (rx_valid) begin
          shk_out_len <= {rx_data[1:0], tmp_lo};
          shk_start   <= 1'b1;
          pending_tx  <= C_SHK_GO;
          state <= ST_REPLY;
        end

        // ---- SHAKE-256 output read -----------------------------------------
        ST_SHKR_I0: if (rx_valid) begin tmp_lo <= rx_data; state <= ST_SHKR_I1; end
        ST_SHKR_I1: if (rx_valid) begin
          shk_rd_addr <= {rx_data[1:0], tmp_lo};
          state <= ST_SHKR_W;
        end
        ST_SHKR_W: begin
          pending_tx <= shk_rd_data;      // rd_data is combinational
          state <= ST_REPLY;
        end

        // ---- reply / tx handshake ------------------------------------------
        ST_REPLY: if (!tx_busy && !tx_send) begin
          tx_data <= pending_tx;
          tx_send <= 1'b1;
          next_after_tx <= ST_CMD;
          state <= ST_TX_WAIT;
        end

        ST_TX_WAIT: begin
          if (tx_busy) state <= ST_TX_WAIT;
          else if (!tx_send) state <= next_after_tx;
        end

        default: state <= ST_CMD;
      endcase
    end
  end
endmodule : keccak_uart_core
