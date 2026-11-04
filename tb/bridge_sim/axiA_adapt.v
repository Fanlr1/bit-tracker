// =====================================================================
// axiA_adapt.v -- 逐字复现 soc.v 里 axiA 端口的适配层
//   1) 桥的 io_output_arw_* 是 AW/AR 共用的（半双工），这里按 write 分流
//      -- 对应 soc.v L5151-L5210
//   2) AXI 端口的 R 上有一个 SpinalHDL Stream m2sPipe
//      -- 对应 soc.v L5211-L5218 / L6204-L6209 / L6415-L6416
// 本文件只是"搬运"，逻辑与 soc.v 一致，不改行为。
// =====================================================================
`timescale 1ns / 1ps

module axiA_adapt (
  input  wire        clk,
  input  wire        resetn,

  // ---- 桥侧：共用的 arw ----
  input  wire        arw_valid,
  output wire        arw_ready,
  input  wire [31:0] arw_addr,
  input  wire [7:0]  arw_len,
  input  wire [2:0]  arw_size,
  input  wire [3:0]  arw_cache,
  input  wire [2:0]  arw_prot,
  input  wire        arw_write,
  // ---- 桥侧：W / B / R ----
  input  wire        w_valid,
  output wire        w_ready,
  input  wire [31:0] w_data,
  input  wire [3:0]  w_strb,
  input  wire        w_last,
  output wire        b_valid,
  input  wire        b_ready,
  output wire [1:0]  b_resp,
  output wire        r_valid,
  input  wire        r_ready,
  output wire [31:0] r_data,
  output wire [1:0]  r_resp,
  output wire        r_last,

  // ---- 从机侧：标准 AXI4 ----
  output wire        awvalid,
  input  wire        awready,
  output wire [7:0]  awid,
  output wire [31:0] awaddr,
  output wire [7:0]  awlen,
  output wire [2:0]  awsize,
  output wire [1:0]  awburst,
  output wire        awlock,
  output wire [3:0]  awcache,
  output wire [2:0]  awprot,
  output wire [3:0]  awqos,
  output wire [3:0]  awregion,

  output wire        wvalid_s,
  input  wire        wready_s,
  output wire [31:0] wdata_s,
  output wire [3:0]  wstrb_s,
  output wire        wlast_s,

  input  wire        bvalid_s,
  output wire        bready_s,
  input  wire [1:0]  bresp_s,
  input  wire [7:0]  bid_s,

  output wire        arvalid,
  input  wire        arready,
  output wire [7:0]  arid,
  output wire [31:0] araddr,
  output wire [7:0]  arlen,
  output wire [2:0]  arsize,
  output wire [1:0]  arburst,
  output wire        arlock,
  output wire [3:0]  arcache,
  output wire [2:0]  arprot,
  output wire [3:0]  arqos,
  output wire [3:0]  arregion,

  input  wire        rvalid_s,
  output wire        rready_s,
  input  wire [31:0] rdata_s,
  input  wire [1:0]  rresp_s,
  input  wire        rlast_s,
  input  wire [7:0]  rid_s
);
  // ---- soc.v L5151: arw_ready = write ? aw_ready : ar_ready ----
  assign arw_ready = arw_write ? awready : arready;

  // ---- soc.v L5152-L5163: AR ----
  assign arvalid  = arw_valid && (!arw_write);
  assign araddr   = arw_addr;
  assign arid     = 8'h0;                    // soc.v L5154
  assign arlen    = arw_len;
  assign arsize   = arw_size;
  assign arburst  = 2'b01;                   // soc.v L5159
  assign arlock   = 1'b0;
  assign arcache  = arw_cache;
  assign arqos    = 4'b0000;
  assign arprot   = arw_prot;
  assign arregion = 4'b0000;

  // ---- soc.v L5164-L5175: AW ----
  assign awvalid  = arw_valid && arw_write;
  assign awaddr   = arw_addr;
  assign awid     = 8'h0;                    // soc.v L5166
  assign awlen    = arw_len;
  assign awsize   = arw_size;
  assign awburst  = 2'b01;                   // soc.v L5171
  assign awlock   = 1'b0;
  assign awcache  = arw_cache;
  assign awqos    = 4'b0000;
  assign awprot   = arw_prot;
  assign awregion = 4'b0000;

  // ---- W: 直通 ----
  assign wvalid_s = w_valid;
  assign w_ready  = wready_s;
  assign wdata_s  = w_data;
  assign wstrb_s  = w_strb;
  assign wlast_s  = w_last;

  // ---- B: 直通（桥只接 resp，不接 id；SoC 的 id 恒 0）----
  assign b_valid  = bvalid_s;
  assign bready_s = b_ready;
  assign b_resp   = bresp_s;

  // ---- R: SpinalHDL Stream m2sPipe（soc.v L5211-L5218 / L6204-L6209 / L6415）----
  reg  [31:0] rData_q;
  reg  [1:0]  rResp_q;
  reg         rLast_q;
  reg         rValid_q;

  assign r_valid  = rValid_q;
  assign r_data   = rData_q;
  assign r_resp   = rResp_q;
  assign r_last   = rLast_q;
  // soc.v L5212/L5218: axiA_rready = m2sPipe_ready; 若 pipe 空则恒 1
  assign rready_s = (!rValid_q) ? 1'b1 : r_ready;

  always @(posedge clk or negedge resetn) begin
    if (!resetn)              rValid_q <= 1'b0;
    else if (rready_s)        rValid_q <= rvalid_s;
  end
  always @(posedge clk) begin
    if (rready_s) begin
      rData_q <= rdata_s;
      rResp_q <= rresp_s;
      rLast_q <= rlast_s;
    end
  end
endmodule
