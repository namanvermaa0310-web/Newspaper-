module ntt_engine (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        start,
  input  wire        mode,
  output wire        done,
  output wire        busy,
  input  wire [7:0]  wr_addr,
  input  wire [15:0] wr_data,
  input  wire        wr_en,
  input  wire [7:0]  rd_addr,
  output wire [15:0] rd_data
);
  import mlkem_pkg::*;

  //==========================================================================
  // Coefficient Memory
  //==========================================================================
  reg [15:0] coeff_mem [0:255];
  integer i;
  initial for (i = 0; i < 256; i = i + 1) coeff_mem[i] = 16'd0;

  always @(posedge clk) begin
    if (state == ST_WRITE) begin
      coeff_mem[internal_wr_addr_a] = internal_wr_a;
      coeff_mem[internal_wr_addr_b] = internal_wr_b;
    end else if (wr_en) begin
      coeff_mem[wr_addr] = wr_data;
    end
  end

  assign rd_data = coeff_mem[rd_addr];

  //==========================================================================
  // Twiddle ROM
  //==========================================================================
  wire [6:0]  twiddle_addr;
  wire [15:0] twiddle_data;
  twiddle_rom u_twiddle_rom (.addr(twiddle_addr), .data(twiddle_data));

  //==========================================================================
  // FSM
  // -- PIPELINE FIX: added ST_NORM as a separate state so the N^-1
  //    normalization multiply (needed only on the final INTT stage) is on
  //    its own clock edge instead of chained combinationally after the
  //    butterfly's own multiply+Barrett-reduce. The original single-cycle
  //    ST_COMPUTE chained TWO full 16x24-bit multiply-reduce sequences back
  //    to back, giving a ~27.6 ns worst path against a 10 ns (100 MHz)
  //    clock (WNS = -17.638 ns, 1391 failing endpoints). Splitting into
  //    ST_COMPUTE -> [ST_NORM] -> ST_WRITE halves the longest chain.
  //==========================================================================
  reg [2:0] state = ST_IDLE;
  localparam ST_IDLE    = 3'd0;
  localparam ST_READ    = 3'd1;
  localparam ST_COMPUTE = 3'd2;
  localparam ST_NORM    = 3'd3;
  localparam ST_WRITE   = 3'd4;

  wire need_norm = mode && last_stage;   // final INTT stage needs N^-1 scaling

  always @(posedge clk) begin
    if (!rst_n) state <= ST_IDLE;
    else begin
      case (state)
        ST_IDLE:    if (start) state <= ST_READ;
        ST_READ:    state <= ST_COMPUTE;
        ST_COMPUTE: state <= need_norm ? ST_NORM : ST_WRITE;
        ST_NORM:    state <= ST_WRITE;
        ST_WRITE:   state <= last_butterfly ? ST_IDLE : ST_READ;
        default:    state <= ST_IDLE;
      endcase
    end
  end

  assign busy = (state != ST_IDLE);
  assign done = (state == ST_IDLE) && was_last;

  //==========================================================================
  // Counters
  //==========================================================================
  reg [2:0] stage = 3'd0;
  reg [6:0] group = 7'd0;
  reg [7:0] offset = 8'd0;
  reg       was_last = 1'b0;

  always @(posedge clk) begin
    if (!rst_n) begin
      stage <= 3'd0; group <= 7'd0; offset <= 8'd0; was_last <= 1'b0;
    end else if (state == ST_IDLE && start) begin
      stage <= 3'd0; group <= 7'd0; offset <= 8'd0; was_last <= 1'b0;
    end else if (state == ST_WRITE) begin
      was_last <= last_butterfly;
      if (!last_offset) begin
        offset <= offset + 8'd1;
      end else begin
        offset <= 8'd0;
        if (!last_group) begin
          group <= group + 7'd1;
        end else begin
          group <= 7'd0;
          if (!last_stage) stage <= stage + 3'd1;
        end
      end
    end
  end

  //==========================================================================
  // Combinational: len, num_groups, intt_prev_groups
  //==========================================================================
  wire [7:0] len;
  wire [6:0] num_groups;
  wire [6:0] intt_prev_groups;

  assign len = (mode == MODE_NTT) ?
    ((stage == 3'd0) ? 8'd128 : (stage == 3'd1) ? 8'd64  : (stage == 3'd2) ? 8'd32  :
     (stage == 3'd3) ? 8'd16  : (stage == 3'd4) ? 8'd8   : (stage == 3'd5) ? 8'd4   :
     (stage == 3'd6) ? 8'd2   : 8'd128) :
    ((stage == 3'd0) ? 8'd2   : (stage == 3'd1) ? 8'd4   : (stage == 3'd2) ? 8'd8   :
     (stage == 3'd3) ? 8'd16  : (stage == 3'd4) ? 8'd32  : (stage == 3'd5) ? 8'd64  :
     (stage == 3'd6) ? 8'd128 : 8'd2);

  assign num_groups = (mode == MODE_NTT) ?
    ((stage == 3'd0) ? 7'd1  : (stage == 3'd1) ? 7'd2  : (stage == 3'd2) ? 7'd4  :
     (stage == 3'd3) ? 7'd8  : (stage == 3'd4) ? 7'd16 : (stage == 3'd5) ? 7'd32 :
     (stage == 3'd6) ? 7'd64 : 7'd1) :
    ((stage == 3'd0) ? 7'd64 : (stage == 3'd1) ? 7'd32 : (stage == 3'd2) ? 7'd16 :
     (stage == 3'd3) ? 7'd8  : (stage == 3'd4) ? 7'd4  : (stage == 3'd5) ? 7'd2  :
     (stage == 3'd6) ? 7'd1  : 7'd64);

  assign intt_prev_groups = (mode == MODE_NTT) ? 7'd0 :
    ((stage == 3'd0) ? 7'd0   : (stage == 3'd1) ? 7'd64  : (stage == 3'd2) ? 7'd96  :
     (stage == 3'd3) ? 7'd112 : (stage == 3'd4) ? 7'd120 : (stage == 3'd5) ? 7'd124 :
     (stage == 3'd6) ? 7'd126 : 7'd0);

  //==========================================================================
  // Combinational: last detection, addresses, twiddle
  //==========================================================================
  wire last_offset    = ({1'b0, offset} == (len - 8'd1));
  wire last_group     = (group == (num_groups - 7'd1));
  wire last_stage     = (stage == 3'd6);
  wire last_butterfly = last_offset && last_group && last_stage;

  wire [7:0] addr_a, addr_b;
  wire [15:0] start_addr_calc = {1'b0, group} * (len << 1);
  wire [7:0]  start_addr = start_addr_calc[7:0];
  assign addr_a = start_addr + offset[7:0];
  assign addr_b = addr_a + len[7:0];

  assign twiddle_addr = mode ? (7'd127 - intt_prev_groups - group)
                              : ((7'd1 << stage) + {1'b0, group});

  //==========================================================================
  // Butterfly Datapath -- Stage 1 (registered in ST_READ)
  //==========================================================================
  reg [15:0] data_a, data_b, zeta;
  reg [7:0]  internal_wr_addr_a = 8'd0;
  reg [7:0]  internal_wr_addr_b = 8'd0;
  reg [15:0] internal_wr_a = 16'd0;
  reg [15:0] internal_wr_b = 16'd0;

  always @(posedge clk) begin
    if (state == ST_READ) begin
      data_a <= coeff_mem[addr_a];
      data_b <= coeff_mem[addr_b];
      zeta   <= twiddle_data;
      internal_wr_addr_a <= addr_a;
      internal_wr_addr_b <= addr_b;
    end
  end

  //==========================================================================
  // Butterfly Datapath -- Stage 2 (combinational in ST_COMPUTE): ONE
  // multiply + Barrett-reduce chain per branch, no chained second multiply.
  //==========================================================================
  // NTT butterfly (inline)
  wire [31:0] ntt_prod = zeta * data_b;
  wire [38:0] ntt_barrett_prod = (ntt_prod[23:0] * 24'd20159) + 26'd33554432;
  wire [12:0] ntt_t_val = ntt_barrett_prod[38:26];
  wire [24:0] ntt_diff = ntt_prod[23:0] - (ntt_t_val * 25'd3329);
  wire [15:0] ntt_t;
  assign ntt_t = ntt_diff[24] ? (ntt_diff[15:0] + 16'd3329) :
                 (ntt_diff >= 25'd3329) ? (ntt_diff[15:0] - 16'd3329) :
                 ntt_diff[15:0];
  wire [16:0] ntt_sum = data_a + ntt_t;
  wire [15:0] ntt_out_a = (ntt_sum >= 17'd3329) ? (ntt_sum - 17'd3329) : ntt_sum[15:0];
  wire signed [16:0] ntt_sub = $signed(data_a) - $signed(ntt_t);
  wire [15:0] ntt_out_b = ntt_sub[16] ? (ntt_sub[15:0] + 16'd3329) : ntt_sub[15:0];

  // INTT butterfly (inline) -- pre-normalization result
  wire [16:0] intt_sum = data_a + data_b;
  wire [15:0] intt_out_a = (intt_sum >= 17'd3329) ? (intt_sum - 17'd3329) : intt_sum[15:0];
  wire signed [16:0] intt_diff_signed = $signed(data_b) - $signed(data_a);
  wire [15:0] intt_diff = intt_diff_signed[16] ? (intt_diff_signed[15:0] + 16'd3329) : intt_diff_signed[15:0];
  wire [31:0] intt_prod = zeta * intt_diff;
  wire [38:0] intt_barrett_prod = (intt_prod[23:0] * 24'd20159) + 26'd33554432;
  wire [12:0] intt_t_val = intt_barrett_prod[38:26];
  wire [24:0] intt_diff2 = intt_prod[23:0] - (intt_t_val * 25'd3329);
  wire [15:0] intt_out_b;
  assign intt_out_b = intt_diff2[24] ? (intt_diff2[15:0] + 16'd3329) :
                      (intt_diff2 >= 25'd3329) ? (intt_diff2[15:0] - 16'd3329) :
                      intt_diff2[15:0];

  // Pre-normalization result: final for NTT and for non-last INTT stages;
  // needs one more multiply+reduce pass (in ST_NORM) only on the last stage.
  wire [15:0] out_a_pre = mode ? intt_out_a : ntt_out_a;
  wire [15:0] out_b_pre = mode ? intt_out_b : ntt_out_b;

  reg [15:0] pre_a_reg, pre_b_reg;

  //==========================================================================
  // Butterfly Datapath -- Stage 3 (combinational, only used when state ==
  // ST_NORM, i.e. only on the final INTT stage): N^-1 normalization, its
  // own multiply+reduce chain, on a separate clock edge from the
  // butterfly's own multiply. Declared here (ahead of use) so the single
  // always block below can reference it -- this fixes DRC MDRV-1 (Multiple
  // Driver Nets on internal_wr_a/internal_wr_b), which the earlier version
  // caused by driving those regs from two separate always blocks.
  //==========================================================================
  wire [31:0] ninv_prod_a = pre_a_reg * 16'd3303;
  wire [38:0] ninv_barrett_prod_a = (ninv_prod_a[23:0] * 24'd20159) + 26'd33554432;
  wire [12:0] ninv_t_val_a = ninv_barrett_prod_a[38:26];
  wire [24:0] ninv_diff_a = ninv_prod_a[23:0] - (ninv_t_val_a * 25'd3329);
  wire [15:0] intt_out_a_norm;
  assign intt_out_a_norm = ninv_diff_a[24] ? (ninv_diff_a[15:0] + 16'd3329) :
                            (ninv_diff_a >= 25'd3329) ? (ninv_diff_a[15:0] - 16'd3329) :
                            ninv_diff_a[15:0];

  wire [31:0] ninv_prod_b = pre_b_reg * 16'd3303;
  wire [38:0] ninv_barrett_prod_b = (ninv_prod_b[23:0] * 24'd20159) + 26'd33554432;
  wire [12:0] ninv_t_val_b = ninv_barrett_prod_b[38:26];
  wire [24:0] ninv_diff_b = ninv_prod_b[23:0] - (ninv_t_val_b * 25'd3329);
  wire [15:0] intt_out_b_norm;
  assign intt_out_b_norm = ninv_diff_b[24] ? (ninv_diff_b[15:0] + 16'd3329) :
                            (ninv_diff_b >= 25'd3329) ? (ninv_diff_b[15:0] - 16'd3329) :
                            ninv_diff_b[15:0];

  // SINGLE always block driving internal_wr_a/internal_wr_b/pre_a_reg/
  // pre_b_reg. Both the ST_COMPUTE and ST_NORM cases live here now.
  always @(posedge clk) begin
    if (state == ST_COMPUTE) begin
      if (need_norm) begin
        // stash pre-normalization values; ST_NORM will finish the job
        pre_a_reg <= out_a_pre;
        pre_b_reg <= out_b_pre;
      end else begin
        // no normalization needed: this IS the final result
        internal_wr_a <= out_a_pre;
        internal_wr_b <= out_b_pre;
      end
    end else if (state == ST_NORM) begin
      internal_wr_a <= intt_out_a_norm;
      internal_wr_b <= intt_out_b_norm;
    end
  end

endmodule : ntt_engine
