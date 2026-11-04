// =====================================================================
// tb_bridge.v -- 联合仿真：【真实的 SoC 桥 RTL】 + 【真实的 bitblt_axi_slave】
// 链路：BMB BFM -> BmbToAxi4SharedBridge_1 -> axiA_adapt -> bitblt_axi_slave
// 目的：复现板上「纯读正常 / 写一次之后读永久失效」。
// 说明：不使用任何手写的 AXI 主模型（避免 docs/56 的"共享错误假设"）。
// =====================================================================
`timescale 1ns / 1ps

module tb_bridge;
  reg clk   = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;            // 100 MHz

  integer cycle = 0;
  integer errors = 0;
  // ★ 2026-10-13: 应用的真实时序里，两次引擎访问之间夹着很长一段"只写 DDR、
  // 完全不碰引擎"的时间（main.c 的 init_sprite() 是 4096 次 DDR 写）。原来的
  // 仿真阶段之间只隔几拍，覆盖不到长空闲。这个参数就是那段时间。
  localparam integer GAP_CYCLES = 2000;

  // ---------------- BMB 主 BFM ----------------
  reg         cmd_valid;
  wire        cmd_ready;
  reg         cmd_last;
  reg  [0:0]  cmd_source;
  reg  [0:0]  cmd_opcode;          // 1=write 0=read
  reg  [31:0] cmd_addr;
  reg  [5:0]  cmd_len;
  reg  [31:0] cmd_data;
  reg  [3:0]  cmd_mask;
  reg  [0:0]  cmd_context;
  wire        rsp_valid;
  reg         rsp_ready;
  wire        rsp_last;
  wire [0:0]  rsp_source, rsp_opcode, rsp_context;
  wire [31:0] rsp_data;

  // ---------------- 桥输出（arw/w/b/r）----------------
  wire        arw_valid, arw_ready;
  wire [31:0] arw_addr;
  wire [7:0]  arw_len;
  wire [2:0]  arw_size;
  wire [3:0]  arw_cache;
  wire [2:0]  arw_prot;
  wire        arw_write;
  wire        w_valid, w_ready;
  wire [31:0] w_data;
  wire [3:0]  w_strb;
  wire        w_last;
  wire        b_valid, b_ready;
  wire [1:0]  b_resp;
  wire        r_valid, r_ready;
  wire [31:0] r_data;
  wire [1:0]  r_resp;
  wire        r_last;

  // ---------------- 从机侧 ----------------
  wire        awvalid, awready;
  wire [7:0]  awid;
  wire [31:0] awaddr;
  wire [7:0]  awlen;
  wire [2:0]  awsize;
  wire [1:0]  awburst;
  wire        awlock;
  wire [3:0]  awcache;
  wire [2:0]  awprot;
  wire [3:0]  awqos, awregion;
  wire        wvalid_s, wready_s, wlast_s;
  wire [31:0] wdata_s;
  wire [3:0]  wstrb_s;
  wire        bvalid_s, bready_s;
  wire [1:0]  bresp_s;
  wire [7:0]  bid_s;
  wire        arvalid, arready;
  wire [7:0]  arid;
  wire [31:0] araddr;
  wire [7:0]  arlen;
  wire [2:0]  arsize;
  wire [1:0]  arburst;
  wire        arlock;
  wire [3:0]  arcache;
  wire [2:0]  arprot;
  wire [3:0]  arqos, arregion;
  wire        rvalid_s, rready_s, rlast_s;
  wire [31:0] rdata_s;
  wire [1:0]  rresp_s;
  wire [7:0]  rid_s;

  wire        axi_interrupt;
  wire [3:0]  dbg_observ;
  wire [31:0] reg_ctrl, reg_op, reg_src_addr, reg_dst_addr, reg_width_h;
  wire [31:0] reg_src_stride, reg_dst_stride, reg_fill_color, reg_alpha, reg_key_color;
  wire [31:0] reg_frame_cnt, reg_fb_base, reg_spr_table, reg_status;
  wire [3:0]  reg_bpp;
  wire [15:0] reg_fb_width, reg_fb_height, reg_fb_stride, reg_spr_count, reg_spr_rt_sel;
  wire        reg_fb_enable, reg_spr_enable;
  wire        reg_spr_retire_en;
  wire [15:0] reg_spr_retire_idx;
  wire        reg_spr_pos_req;
  wire [15:0] reg_spr_pos_idx;
  wire [15:0] reg_mon_clr_mask;
  wire [3:0]  reg_mon_cnt_sel;
  wire        reg_mon_clr_count;
  wire        reg_start_pulse;

  // ---------------- DUT: 真实桥 ----------------
  BmbToAxi4SharedBridge_1_469dfaa85da54d55815c0d2324d480a8 u_bridge (
    .io_input_cmd_valid                   (cmd_valid),
    .io_input_cmd_ready                   (cmd_ready),
    .io_input_cmd_payload_last            (cmd_last),
    .io_input_cmd_payload_fragment_source (cmd_source),
    .io_input_cmd_payload_fragment_opcode (cmd_opcode),
    .io_input_cmd_payload_fragment_address(cmd_addr),
    .io_input_cmd_payload_fragment_length (cmd_len),
    .io_input_cmd_payload_fragment_data   (cmd_data),
    .io_input_cmd_payload_fragment_mask   (cmd_mask),
    .io_input_cmd_payload_fragment_context(cmd_context),
    .io_input_rsp_valid                   (rsp_valid),
    .io_input_rsp_ready                   (rsp_ready),
    .io_input_rsp_payload_last            (rsp_last),
    .io_input_rsp_payload_fragment_source (rsp_source),
    .io_input_rsp_payload_fragment_opcode (rsp_opcode),
    .io_input_rsp_payload_fragment_data   (rsp_data),
    .io_input_rsp_payload_fragment_context(rsp_context),
    .io_output_arw_valid                  (arw_valid),
    .io_output_arw_ready                  (arw_ready),
    .io_output_arw_payload_addr           (arw_addr),
    .io_output_arw_payload_len            (arw_len),
    .io_output_arw_payload_size           (arw_size),
    .io_output_arw_payload_cache          (arw_cache),
    .io_output_arw_payload_prot           (arw_prot),
    .io_output_arw_payload_write          (arw_write),
    .io_output_w_valid                    (w_valid),
    .io_output_w_ready                    (w_ready),
    .io_output_w_payload_data             (w_data),
    .io_output_w_payload_strb             (w_strb),
    .io_output_w_payload_last             (w_last),
    .io_output_b_valid                    (b_valid),
    .io_output_b_ready                    (b_ready),
    .io_output_b_payload_resp             (b_resp),
    .io_output_r_valid                    (r_valid),
    .io_output_r_ready                    (r_ready),
    .io_output_r_payload_data             (r_data),
    .io_output_r_payload_resp             (r_resp),
    .io_output_r_payload_last             (r_last),
    .io_systemClk                         (clk),
    .systemCd_logic_outputReset           (~rst_n)
  );

  // ---------------- 适配层 ----------------
  axiA_adapt u_adapt (
    .clk(clk), .resetn(rst_n),
    .arw_valid(arw_valid), .arw_ready(arw_ready), .arw_addr(arw_addr),
    .arw_len(arw_len), .arw_size(arw_size), .arw_cache(arw_cache),
    .arw_prot(arw_prot), .arw_write(arw_write),
    .w_valid(w_valid), .w_ready(w_ready), .w_data(w_data), .w_strb(w_strb), .w_last(w_last),
    .b_valid(b_valid), .b_ready(b_ready), .b_resp(b_resp),
    .r_valid(r_valid), .r_ready(r_ready), .r_data(r_data), .r_resp(r_resp), .r_last(r_last),
    .awvalid(awvalid), .awready(awready), .awid(awid), .awaddr(awaddr), .awlen(awlen),
    .awsize(awsize), .awburst(awburst), .awlock(awlock), .awcache(awcache),
    .awprot(awprot), .awqos(awqos), .awregion(awregion),
    .wvalid_s(wvalid_s), .wready_s(wready_s), .wdata_s(wdata_s), .wstrb_s(wstrb_s), .wlast_s(wlast_s),
    .bvalid_s(bvalid_s), .bready_s(bready_s), .bresp_s(bresp_s), .bid_s(bid_s),
    .arvalid(arvalid), .arready(arready), .arid(arid), .araddr(araddr), .arlen(arlen),
    .arsize(arsize), .arburst(arburst), .arlock(arlock), .arcache(arcache),
    .arprot(arprot), .arqos(arqos), .arregion(arregion),
    .rvalid_s(rvalid_s), .rready_s(rready_s), .rdata_s(rdata_s), .rresp_s(rresp_s),
    .rlast_s(rlast_s), .rid_s(rid_s)
  );

  // ---------------- DUT: 真实从机 ----------------
  bitblt_axi_slave dut (
    .axi_interrupt(axi_interrupt), .axi_aclk(clk), .axi_resetn(rst_n),
    .axi_awid(awid), .axi_awaddr(awaddr), .axi_awlen(awlen), .axi_awsize(awsize),
    .axi_awburst(awburst), .axi_awlock(awlock), .axi_awcache(awcache),
    .axi_awprot(awprot), .axi_awqos(awqos), .axi_awregion(awregion),
    .axi_awvalid(awvalid), .axi_awready(awready),
    .axi_wdata(wdata_s), .axi_wstrb(wstrb_s), .axi_wlast(wlast_s),
    .axi_wvalid(wvalid_s), .axi_wready(wready_s),
    .axi_bid(bid_s), .axi_bresp(bresp_s), .axi_bvalid(bvalid_s), .axi_bready(bready_s),
    .axi_arid(arid), .axi_araddr(araddr), .axi_arlen(arlen), .axi_arsize(arsize),
    .axi_arburst(arburst), .axi_arlock(arlock), .axi_arcache(arcache),
    .axi_arprot(arprot), .axi_arqos(arqos), .axi_arregion(arregion),
    .axi_arvalid(arvalid), .axi_arready(arready),
    .axi_rid(rid_s), .axi_rdata(rdata_s), .axi_rresp(rresp_s),
    .axi_rlast(rlast_s), .axi_rvalid(rvalid_s), .axi_rready(rready_s),
    .dbg_observ(dbg_observ),
    .reg_ctrl(reg_ctrl), .reg_op(reg_op), .reg_src_addr(reg_src_addr),
    .reg_dst_addr(reg_dst_addr), .reg_width_h(reg_width_h),
    .reg_src_stride(reg_src_stride), .reg_dst_stride(reg_dst_stride),
    .reg_fill_color(reg_fill_color), .reg_alpha(reg_alpha),
    .reg_key_color(reg_key_color), .reg_frame_cnt(reg_frame_cnt), .reg_bpp(reg_bpp),
    .reg_fb_base(reg_fb_base), .reg_fb_width(reg_fb_width),
    .reg_fb_height(reg_fb_height), .reg_fb_stride(reg_fb_stride),
    .reg_fb_enable(reg_fb_enable),
    .reg_spr_table(reg_spr_table), .reg_spr_count(reg_spr_count),
    .reg_spr_enable(reg_spr_enable),
    .reg_spr_rt_sel(reg_spr_rt_sel), .spr_rt_bits(32'h0),
    .reg_spr_retire_en(reg_spr_retire_en), .reg_spr_retire_idx(reg_spr_retire_idx),
    .scan_blanking(1'b0), .scan_short_count(8'h0), .addr_oob_addr(32'h0),
    .mon_sticky(16'h0), .mon_cnt(32'h0),
    .reg_mon_clr_mask(reg_mon_clr_mask), .reg_mon_cnt_sel(reg_mon_cnt_sel),
    .reg_mon_clr_count(reg_mon_clr_count),
    .reg_spr_pos_req(reg_spr_pos_req), .reg_spr_pos_idx(reg_spr_pos_idx),
    .spr_pos_xy(32'h0), .spr_pos_valid(1'b0),
    .reg_status(reg_status), .reg_start_pulse(reg_start_pulse)
  );

  // ---------------- 逐拍跟踪 ----------------
  always @(posedge clk) begin
    cycle <= cycle + 1;
    if (cycle < 300 || (cycle > GAP_CYCLES - 15 && cycle < GAP_CYCLES + 90)) begin
      $display("t=%0d | arw v=%b r=%b wr=%b | W v=%b r=%b last=%b | b v=%b r=%b | r v=%b r=%b | s: bus=%0d awreg=%b | brg: lock=%b selR=%b cmdv=%b zz=%b wcrdy=%b rcrdy=%b",
        cycle, arw_valid, arw_ready, arw_write, w_valid, w_ready, w_last, b_valid, b_ready,
        r_valid, r_ready, dut.busState, dut.awreadyReg,
        u_bridge.rspSelLock, u_bridge.rspSelRead, u_bridge.cmdStage_valid,
        u_bridge._zz_io_output_arw_valid,
        u_bridge.writeCmdInfo_fifo_io_push_ready, u_bridge.readCmdInfo_fifo_io_push_ready);
    end
  end

  // ---------------- BMB 命令 ----------------
  task bmb_cmd(input wr, input [31:0] addr, input [31:0] data, input [255:0] tag);
    integer g;
    begin
      @(negedge clk);
      cmd_opcode  = wr;
      cmd_addr    = addr;
      cmd_data    = data;
      cmd_mask    = wr ? 4'hF : 4'h0;
      cmd_len     = 6'd0;
      cmd_last    = 1'b1;
      cmd_source  = 1'b0;
      cmd_context = 1'b1;
      cmd_valid   = 1'b1;
      g = 0;
      while (cmd_ready !== 1'b1 && g < 500) begin g = g + 1; @(negedge clk); end
      if (cmd_ready !== 1'b1) begin
        $display("!! [%0s] BMB cmd 未被接受 (cmd_ready 恒 0)", tag);
        errors = errors + 1;
      end
      @(negedge clk);
      cmd_valid = 1'b0;
    end
  endtask

  task bmb_wait_rsp(input [255:0] tag, input integer limit);
    integer g;
    begin
      g = 0;
      while (rsp_valid !== 1'b1 && g < limit) begin g = g + 1; @(negedge clk); end
      if (rsp_valid !== 1'b1) begin
        $display("!! [%0s] 超时 %0d 拍仍无 BMB 响应 -> ${DEADLOCK}", tag, limit);
        errors = errors + 1;
      end else begin
        @(negedge clk);
        $display("== [%0s] 收到响应 data=%h (等待 %0d 拍)", tag, rsp_data, g);
      end
    end
  endtask

  initial begin
    cmd_valid = 0; cmd_opcode = 0; cmd_addr = 0; cmd_data = 0; cmd_mask = 0;
    cmd_len = 0; cmd_last = 1; cmd_source = 0; cmd_context = 0;
    rsp_ready = 1'b1;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    $display("\n########## 阶段 1：纯读（先不做任何写）##########");
    bmb_cmd(1'b0, 32'hE1000030, 32'h0, "纯读BPP");
    bmb_wait_rsp("纯读BPP", 200);

    $display("\n########## 阶段 1.5：空闲 %0d 拍（模拟 CPU 去写 DDR）##########", GAP_CYCLES);
    repeat (GAP_CYCLES) @(posedge clk);
    $display("########## 空闲结束，t=%0d，接下来写 ##########", cycle);

    $display("\n########## 阶段 2：写一次 BPP=4 ##########");
    bmb_cmd(1'b1, 32'hE1000030, 32'h00000004, "写BPP");
    bmb_wait_rsp("写BPP", 200);

    $display("\n########## 阶段 3：写之后再读同一个地址 ##########");
    bmb_cmd(1'b0, 32'hE1000030, 32'h0, "写后读BPP");
    bmb_wait_rsp("写后读BPP", 200);

    $display("\n########## 阶段 4：再读另一个地址 ##########");
    bmb_cmd(1'b0, 32'hE100002C, 32'h0, "写后读FRAME_CNT");
    bmb_wait_rsp("写后读FRAME_CNT", 200);

    $display("\n===== 结果：errors=%0d =====", errors);
    if (errors == 0) $display("RESULT: NO-DEADLOCK (四阶段全部完成)");
    else             $display("RESULT: DEADLOCK-REPRODUCED (errors=%0d)", errors);
    $finish;
  end
endmodule
