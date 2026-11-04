//***************************************************************/
//
// Moudel Name    : ddr3_example_top.v
// Version        : 1.1
// Date Created   : 2023-02-23 10:37:59
// Last Modified  : 2023-02-24 15:27:41
// Abstract       : ---
//
//***************************************************************/
//Modification History
//1.initial
//***************************************************************/
`include "ddr3_controller/ddr3_parameter.vh"

`define Efinity_Debug
`timescale 1ps/1ps
// `define SOFT_JTAG

module system_top #
(
parameter                       RANK_RATIO         = 1,       // # of unique CS outputs per rank
parameter                       CK_RATIO           = `CK_RATIO, 
parameter                       ASYN_AXI_CLK       = `ASYN_AXI_CLK, 
parameter                       RANKS              = `RANKS,
parameter                       CK_WIDTH           = `CK_WIDTH,       // # of CK/CK# outputs to memory   
parameter                       CKE_WIDTH          = `CKE_WIDTH,       // # of cke outputs
parameter                       CS_WIDTH           = `CS_WIDTH,       // # of unique CS outputs
parameter                       BANK_WIDTH         = `BANK_WIDTH,       // # of bank bits
parameter                       ROW_WIDTH          = `ROW_WIDTH,       // DRAM address bus width
parameter                       COL_WIDTH          = `COL_WIDTH,      // column address width
parameter                       DM_WIDTH           = `DM_WIDTH,       // # of DM (data mask)
parameter                       DQS_WIDTH          = `DQS_WIDTH,       // # of DQS (strobe)
parameter                       DQ_WIDTH           = `DQ_WIDTH,      // # of DQ (data)
parameter                       ODT_WIDTH          = `ODT_WIDTH,
parameter                       DQ_CNT_WIDTH       = `DQ_CNT_WIDTH,       // = ceil(log2(DQ_WIDTH))
parameter                       DQS_CNT_WIDTH      = `DQS_CNT_WIDTH,       // = ceil(log2(DQS_WIDTH))  
parameter                       DRAM_WIDTH         = `DRAM_WIDTH,       // # of DQ per DQS   
parameter                       DATA_WIDTH         = `DATA_WIDTH,
parameter                       ADDR_WIDTH         = `ADDR_WIDTH,    
parameter                       AXI_ID_WIDTH       = `AXI_ID_WIDTH,
parameter                       AXI_ADDR_WIDTH     = `AXI_ADDR_WIDTH,
parameter                       AXI_DATA_WIDTH     = `AXI_DATA_WIDTH
)
(

   // Clock and reset ports
   input                              axi_clk,      
   input                              core_clk,     // CORE CLK @ 100MHz
   input                              sdram_clk,    // SDRAM CK @ 400MHz
   input                              rx_cal_clk,   // SDRAM CK @ 400MHz
   input                              tx_cal_clk,   // SDRAM CK @ 400MHz
   input                              tx_cal_clk_90edge,   // SDRAM CK @ 400MHz
   input                              pll_locked,
   input                              user_pll_locked,
  //  input                              peripheralClk,
   //&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&
   output  wire                       system_uart_0_io_txd,
   input                              system_uart_0_io_rxd,   
   input  [3:0]                       soc_gpio_IN,
   output [3:0]                       soc_gpio_OUT,
   output [3:0]                       soc_gpio_OE,
   // ==== DIAGNOSTIC LED OUTPUT (added 2026-10-12) ====================
   // Brings clock/reset health out to the four UNUSED board LEDs (LED4..LED7),
   // so it can be observed without trusting unstable JTAG reads.
   //   dbg_led[3] = pll_locked        (main PLL locked)
   //   dbg_led[2] = user_pll_locked   (user PLL locked)
   //   dbg_led[1] = sys_rst           (1 = out of reset, 0 = held in reset)
   //   dbg_led[0] = ddr_rstn          (1 = DDR out of reset)
   // LED logic is active-HIGH (vendor led_ctrl.v drives 'd0 for off).
   // Purely observational: drives nothing inside the design.
   output [3:0]                       dbg_led,
    // debug core ports
`ifdef  Efinity_Debug  //&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&& 
`ifdef SOFT_JTAG
  input                               io_jtag_tms,
  input                               io_jtag_tdi,
  output  wire                        io_jtag_tdo,
  input                               io_jtag_tck,
`else
  input                               jtag_inst1_CAPTURE ,
  input                               jtag_inst1_DRCK    ,
  input                               jtag_inst1_RESET   ,
  input                               jtag_inst1_RUNTEST ,
  input                               jtag_inst1_SEL     ,
  input                               jtag_inst1_SHIFT   ,
  input                               jtag_inst1_TCK     ,
  input                               jtag_inst1_TDI     ,
  input                               jtag_inst1_TMS     ,
  input                               jtag_inst1_UPDATE  ,
  output                              jtag_inst1_TDO     ,
`endif 

`endif  //&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&&
   // PLL status flags  
   output [2:0]                       pll_shift,  
   output [4:0]                       pll_shift_sel,
   output                             pll_shift_ena,  
   // memory interface ports
   output                             ddr_ck_hi,
   output                             ddr_ck_lo,
   output                             ddr_reset_n,
   output [CKE_WIDTH-1:0]             ddr_cke,     
   output [ROW_WIDTH-1:0]             ddr_addr,
   output [BANK_WIDTH-1:0]            ddr_ba,
   output                             ddr_cas_n,

   output [CS_WIDTH*RANK_RATIO-1:0]   ddr_cs_n,
   output                             ddr_ras_n,
   output                             ddr_we_n,
   
   input  [DQS_WIDTH-1:0]             ddr_dqs_in_hi,
   input  [DQS_WIDTH-1:0]             ddr_dqs_in_lo,
   input  [DQ_WIDTH-1:0]              ddr_dq_in_hi,
   input  [DQ_WIDTH-1:0]              ddr_dq_in_lo,
   
   output [DQS_WIDTH-1:0]             ddr_dqs_oe,
   output [DQS_WIDTH-1:0]             ddr_dqs_oe_n,
   output [DQ_WIDTH-1:0]              ddr_dq_oe,  
   output [DQS_WIDTH-1:0]             ddr_dqs_out_hi,
   output [DQS_WIDTH-1:0]             ddr_dqs_out_lo,
   output [DQ_WIDTH-1:0]              ddr_dq_out_hi,
   output [DQ_WIDTH-1:0]              ddr_dq_out_lo,
   output [DM_WIDTH-1:0]              ddr_dm_hi,
   output [DM_WIDTH-1:0]              ddr_dm_lo,
   output [ODT_WIDTH-1:0]             ddr_odt,

   input                              system_spi_0_io_data_0_IN,
   input                              system_spi_0_io_data_1_IN,
   output                             system_spi_0_io_ss,
   output                             system_spi_0_io_sclk_write,
   output                             system_spi_0_io_data_0_OUT,
   output                             system_spi_0_io_data_0_OE,
   output                             system_spi_0_io_data_1_OUT,
   output                             system_spi_0_io_data_1_OE,

   // ===================== HDMI output (TMDS over LVDS) =====================
   // The 10-bit parallel TMDS goes straight to top-level ports; the serialiser
   // and the LVDS driver live in the pin constraints, not in RTL. The outputs
   // are inverted to compensate for the swapped differential P/N pins on this
   // board (verified against the official 03_hdmi_tx_demo top level).
   //
   // pix_clk is driven by HDMI_PLL in the .peri.xml. Efinity connects a PLL
   // output to a same-named top-level input port, which is exactly how the
   // official 03_hdmi_tx_demo drives its hdmi_tx_slow_clk, so no change to the
   // port style is needed.
   //
   // The _TX_OE / _TX_RST ports are required by the lvds_info section of the
   // .peri.xml (oe_name / reset_name); without them those names resolve to
   // nothing. They are tied to constants exactly as the official design does.
   input                              pix_clk,
   output [9:0]                       tmds_data0_o,
   output [9:0]                       tmds_data1_o,
   output [9:0]                       tmds_data2_o,
   output [9:0]                       tmds_clk_o,
   output                             tmds_data0_TX_OE,
   output                             tmds_data0_TX_RST,
   output                             tmds_data1_TX_OE,
   output                             tmds_data1_TX_RST,
   output                             tmds_data2_TX_OE,
   output                             tmds_data2_TX_RST,
   output                             tmds_clk_TX_OE,
   output                             tmds_clk_TX_RST

   );

// ============================================================================
// Clocks, resets and the DDR3 controller side
// ============================================================================
parameter FREQ = 200;
localparam CNT_INIT = 300000;

localparam AIW = AXI_ID_WIDTH;
localparam ADW = AXI_DATA_WIDTH;
localparam ABN = AXI_DATA_WIDTH/8;

wire user_clk;
wire ddr_rstn;
wire sys_rst;
wire cal_done;
reg  [19:0] cnt;

generate
if (ASYN_AXI_CLK) begin
    assign user_clk = axi_clk;
end else begin
    assign user_clk = core_clk;
end
endgenerate

assign sys_rst = pll_locked & user_pll_locked;

always @(posedge user_clk or negedge sys_rst) begin
    if (!sys_rst) cnt <= 20'd0;
    else if (cnt != CNT_INIT) cnt <= cnt + 20'd1;
end
assign ddr_rstn = (cnt == CNT_INIT);

// SoC power-on reset: a fixed 167 ms window covers DDR3 calibration. The old
// design used the controller's cal_done, whose polarity could not be confirmed
// from the encrypted IP; a fixed delay is unambiguous.
reg [15:0] soc_por_cnt = 16'h0000;
always @(posedge user_clk) if (soc_por_cnt != 16'hFFFF) soc_por_cnt <= soc_por_cnt + 16'd1;
wire soc_por_done = (soc_por_cnt == 16'hFFFF);

reg [23:0] por_ext;
wire por_ext_full = (por_ext == 24'hFFFFFF);
always @(posedge user_clk or negedge sys_rst) begin
    if (!sys_rst) por_ext <= 24'd0;
    else if (!por_ext_full) por_ext <= por_ext + 24'd1;
end
wire soc_async_rst = ~(soc_por_done & pll_locked & user_pll_locked & por_ext_full);

assign dbg_led = { pll_locked, user_pll_locked, sys_rst, ddr_rstn };

// ============================================================================
// DDR3 controller master side (Axi_Mux -> ddr3_top)
// ============================================================================
wire [AXI_ID_WIDTH-1:0]    s_axi_awid;
wire [AXI_ADDR_WIDTH-1:0]  s_axi_awaddr;
wire [7:0]                 s_axi_awlen;
wire [2:0]                 s_axi_awsize;
wire [1:0]                 s_axi_awburst;
wire                       s_axi_awlock;
wire [3:0]                 s_axi_awcache;
wire [2:0]                 s_axi_awprot;
wire                       s_axi_awvalid;
wire                       s_axi_awready;
wire [AXI_DATA_WIDTH-1:0]  s_axi_wdata;
wire [(AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb;
wire                       s_axi_wlast;
wire                       s_axi_wvalid;
wire                       s_axi_wready;
wire                       s_axi_bready;
wire [AXI_ID_WIDTH-1:0]    s_axi_bid;
wire [1:0]                 s_axi_bresp;
wire                       s_axi_bvalid;
wire [AXI_ID_WIDTH-1:0]    s_axi_arid;
wire [AXI_ADDR_WIDTH-1:0]  s_axi_araddr;
wire [7:0]                 s_axi_arlen;
wire [2:0]                 s_axi_arsize;
wire [1:0]                 s_axi_arburst;
wire                       s_axi_arlock;
wire [3:0]                 s_axi_arcache;
wire [2:0]                 s_axi_arprot;
wire                       s_axi_arvalid;
wire                       s_axi_arready;
wire                       s_axi_rready;
wire [AXI_ID_WIDTH-1:0]    s_axi_rid;
wire [AXI_DATA_WIDTH-1:0]  s_axi_rdata;
wire [1:0]                 s_axi_rresp;
wire                       s_axi_rlast;
wire                       s_axi_rvalid;

// ============================================================================
// SoC DDR master
// ============================================================================
wire [7:0]        soc_ddrA_awid;
wire [31:0]       soc_ddrA_awaddr;
wire [7:0]        soc_ddrA_awlen;
wire [2:0]        soc_ddrA_awsize;
wire [1:0]        soc_ddrA_awburst;
wire              soc_ddrA_awlock;
wire [3:0]        soc_ddrA_awcache;
wire [2:0]        soc_ddrA_awprot;
wire [3:0]        soc_ddrA_awqos;
wire              soc_ddrA_awvalid;
wire              soc_ddrA_awready;
wire [127:0]      soc_ddrA_wdata;
wire [15:0]       soc_ddrA_wstrb;
wire              soc_ddrA_wlast;
wire              soc_ddrA_wvalid;
wire              soc_ddrA_wready;
wire [7:0]        soc_ddrA_bid;
wire [1:0]        soc_ddrA_bresp;
wire              soc_ddrA_bvalid;
wire              soc_ddrA_bready;
wire [7:0]        soc_ddrA_arid;
wire [31:0]       soc_ddrA_araddr;
wire [7:0]        soc_ddrA_arlen;
wire [2:0]        soc_ddrA_arsize;
wire [1:0]        soc_ddrA_arburst;
wire              soc_ddrA_arlock;
wire [3:0]        soc_ddrA_arcache;
wire [2:0]        soc_ddrA_arprot;
wire [3:0]        soc_ddrA_arqos;
wire              soc_ddrA_arvalid;
wire              soc_ddrA_arready;
wire [127:0]      soc_ddrA_rdata;
wire [7:0]        soc_ddrA_rid;
wire [1:0]        soc_ddrA_rresp;
wire              soc_ddrA_rlast;
wire              soc_ddrA_rvalid;
wire              soc_ddrA_rready;

// ============================================================================
// GFX master: ONE AXI4 port for engine reads, engine writes and scan-out.
// ============================================================================
wire [31:0]       gfx_araddr;
wire [7:0]        gfx_arlen;
wire [2:0]        gfx_arsize;
wire [1:0]        gfx_arburst;
wire              gfx_arvalid;
wire              gfx_arready;
wire [127:0]      gfx_rdata;
wire [1:0]        gfx_rresp;
wire              gfx_rlast;
wire              gfx_rvalid;
wire              gfx_rready;

wire [31:0]       gfx_awaddr;
wire [7:0]        gfx_awlen;
wire [2:0]        gfx_awsize;
wire [1:0]        gfx_awburst;
wire              gfx_awvalid;
wire              gfx_awready;
wire [127:0]      gfx_wdata;
wire [15:0]       gfx_wstrb;
wire              gfx_wlast;
wire              gfx_wvalid;
wire              gfx_wready;
wire [1:0]        gfx_bresp;
wire              gfx_bvalid;
wire              gfx_bready;
wire              gfx_irq;

// ============================================================================
// Register-file AXI slave (SoC axiA)
// ============================================================================
wire [7:0]        reg_awid;
wire [31:0]       reg_awaddr;
wire [7:0]        reg_awlen;
wire [2:0]        reg_awsize;
wire [1:0]        reg_awburst;
wire              reg_awlock;
wire [3:0]        reg_awcache;
wire [2:0]        reg_awprot;
wire [3:0]        reg_awqos;
wire [3:0]        reg_awregion;
wire              reg_awvalid;
wire              reg_awready;
wire [31:0]       reg_wdata;
wire [3:0]        reg_wstrb;
wire              reg_wlast;
wire              reg_wvalid;
wire              reg_wready;
wire [7:0]        reg_bid;
wire [1:0]        reg_bresp;
wire              reg_bvalid;
wire              reg_bready;
wire [7:0]        reg_arid;
wire [31:0]       reg_araddr;
wire [7:0]        reg_arlen;
wire [2:0]        reg_arsize;
wire [1:0]        reg_arburst;
wire              reg_arlock;
wire [3:0]        reg_arcache;
wire [2:0]        reg_arprot;
wire [3:0]        reg_arqos;
wire [3:0]        reg_arregion;
wire              reg_arvalid;
wire              reg_arready;
wire [7:0]        reg_rid;
wire [31:0]       reg_rdata;
wire [1:0]        reg_rresp;
wire              reg_rlast;
wire              reg_rvalid;
wire              reg_rready;

// ============================================================================
// Video
// ============================================================================
wire [23:0]       vid_rgb;
wire              vid_de, vid_hs, vid_vs;
wire [9:0]        tmds_data0, tmds_data1, tmds_data2, tmds_clk;
wire [31:0]       gfx_dbg;

// SoC GPIO is driven by the SoC itself; the debug observation that used to
// come back through soc_gpio_IN is gone with the old engine.

// ============================================================================
// Axi_Mux: two channels only (SoC + GFX). Mask bits 0 and 1.
// ============================================================================
Axi_Mux u_axi_mux (
    .Sys_Clk                            (user_clk),
    .Sys_Rst_N                          (ddr_rstn),

    // ---- S0: SoC DDR master ----
    .I_S0_AW_ID                         (soc_ddrA_awid),
    .I_S0_AW_ADDR                       (soc_ddrA_awaddr),
    .I_S0_AW_LEN                        (soc_ddrA_awlen),
    .I_S0_AW_SIZE                       (soc_ddrA_awsize),
    .I_S0_AW_BURST                      (soc_ddrA_awburst),
    .I_S0_AW_LOCK                       ({1'b0, soc_ddrA_awlock}),
    .I_S0_AW_VALID                      (soc_ddrA_awvalid),
    .O_S0_AW_READY                      (soc_ddrA_awready),
    .I_S0_W_ID                          (soc_ddrA_awid),
    .I_S0_W_DATA                        (soc_ddrA_wdata),
    .I_S0_W_LAST                        (soc_ddrA_wlast),
    .I_S0_W_STRB                        (soc_ddrA_wstrb),
    .I_S0_W_VALID                       (soc_ddrA_wvalid),
    .O_S0_W_READY                       (soc_ddrA_wready),
    .O_S0_B_ID                          (soc_ddrA_bid),
    .O_S0_B_VALID                       (soc_ddrA_bvalid),
    .I_S0_B_READY                       (soc_ddrA_bready),
    .I_S0_AR_ID                         (soc_ddrA_arid),
    .I_S0_AR_ADDR                       (soc_ddrA_araddr),
    .I_S0_AR_LEN                        (soc_ddrA_arlen),
    .I_S0_AR_SIZE                       (soc_ddrA_arsize),
    .I_S0_AR_BURST                      (soc_ddrA_arburst),
    .I_S0_AR_LOCK                       ({1'b0, soc_ddrA_arlock}),
    .I_S0_AR_VALID                      (soc_ddrA_arvalid),
    .O_S0_AR_READY                      (soc_ddrA_arready),
    .O_S0_R_ID                          (soc_ddrA_rid),
    .O_S0_R_DATA                        (soc_ddrA_rdata),
    .O_S0_R_LAST                        (soc_ddrA_rlast),
    .O_S0_R_RESP                        (soc_ddrA_rresp),
    .O_S0_R_VALID                       (soc_ddrA_rvalid),
    .I_S0_R_READY                       (soc_ddrA_rready),

    // ---- S1: GFX READ ONLY ----
    // The old design proved this usage: a slave port that only ever reads.
    // Offering AW and AR from the same port at the same time did not work on
    // silicon (all scan-out lines underran and every engine read timed out),
    // so reads and writes live on separate ports.
    .I_S1_AW_ID(8'h00), .I_S1_AW_ADDR(32'h0), .I_S1_AW_LEN(8'h00),
    .I_S1_AW_SIZE(3'h0), .I_S1_AW_BURST(2'b01), .I_S1_AW_LOCK(2'b00),
    .I_S1_AW_VALID(1'b0), .O_S1_AW_READY(),
    .I_S1_W_ID(8'h00), .I_S1_W_DATA(128'h0), .I_S1_W_LAST(1'b0),
    .I_S1_W_STRB(16'h0), .I_S1_W_VALID(1'b0), .O_S1_W_READY(),
    .O_S1_B_ID(), .O_S1_B_VALID(), .I_S1_B_READY(1'b0),
    .I_S1_AR_ID                         (8'h20),
    .I_S1_AR_ADDR                       (gfx_araddr),
    .I_S1_AR_LEN                        (gfx_arlen),
    .I_S1_AR_SIZE                       (gfx_arsize),
    .I_S1_AR_BURST                      (gfx_arburst),
    .I_S1_AR_LOCK                       (2'b00),
    .I_S1_AR_VALID                      (gfx_arvalid),
    .O_S1_AR_READY                      (gfx_arready),
    .O_S1_R_ID                          (),
    .O_S1_R_DATA                        (gfx_rdata),
    .O_S1_R_LAST                        (gfx_rlast),
    .O_S1_R_RESP                        (gfx_rresp),
    .O_S1_R_VALID                       (gfx_rvalid),
    .I_S1_R_READY                       (gfx_rready),

    // ---- S2: GFX WRITE ONLY ----
    .I_S2_AW_ID                         (8'h21),
    .I_S2_AW_ADDR                       (gfx_awaddr),
    .I_S2_AW_LEN                        (gfx_awlen),
    .I_S2_AW_SIZE                       (gfx_awsize),
    .I_S2_AW_BURST                      (gfx_awburst),
    .I_S2_AW_LOCK                       (2'b00),
    .I_S2_AW_VALID                      (gfx_awvalid),
    .O_S2_AW_READY                      (gfx_awready),
    .I_S2_W_ID                          (8'h21),
    .I_S2_W_DATA                        (gfx_wdata),
    .I_S2_W_LAST                        (gfx_wlast),
    .I_S2_W_STRB                        (gfx_wstrb),
    .I_S2_W_VALID                       (gfx_wvalid),
    .O_S2_W_READY                       (gfx_wready),
    .O_S2_B_ID                          (),
    .O_S2_B_VALID                       (gfx_bvalid),
    .I_S2_B_READY                       (gfx_bready),
    .I_S2_AR_ID(8'h00), .I_S2_AR_ADDR(32'h0), .I_S2_AR_LEN(8'h00),
    .I_S2_AR_SIZE(3'h0), .I_S2_AR_BURST(2'b01), .I_S2_AR_LOCK(2'b00),
    .I_S2_AR_VALID(1'b0), .O_S2_AR_READY(),
    .O_S2_R_ID(), .O_S2_R_DATA(), .O_S2_R_LAST(), .O_S2_R_RESP(),
    .O_S2_R_VALID(), .I_S2_R_READY(1'b0),

    // ---- S3/S4: unused ----
    .I_S3_AW_ID(8'h00), .I_S3_AW_ADDR(32'h0), .I_S3_AW_LEN(8'h00),
    .I_S3_AW_SIZE(3'h0), .I_S3_AW_BURST(2'b01), .I_S3_AW_LOCK(2'b00),
    .I_S3_AW_VALID(1'b0), .O_S3_AW_READY(),
    .I_S3_W_ID(8'h00), .I_S3_W_DATA(128'h0), .I_S3_W_LAST(1'b0),
    .I_S3_W_STRB(16'h0), .I_S3_W_VALID(1'b0), .O_S3_W_READY(),
    .O_S3_B_ID(), .O_S3_B_VALID(), .I_S3_B_READY(1'b0),
    .I_S3_AR_ID(8'h00), .I_S3_AR_ADDR(32'h0), .I_S3_AR_LEN(8'h00),
    .I_S3_AR_SIZE(3'h0), .I_S3_AR_BURST(2'b01), .I_S3_AR_LOCK(2'b00),
    .I_S3_AR_VALID(1'b0), .O_S3_AR_READY(),
    .O_S3_R_ID(), .O_S3_R_DATA(), .O_S3_R_LAST(), .O_S3_R_RESP(),
    .O_S3_R_VALID(), .I_S3_R_READY(1'b0),

    .I_S4_AW_ID(8'h00), .I_S4_AW_ADDR(32'h0), .I_S4_AW_LEN(8'h00),
    .I_S4_AW_SIZE(3'h0), .I_S4_AW_BURST(2'b01), .I_S4_AW_LOCK(2'b00),
    .I_S4_AW_VALID(1'b0), .O_S4_AW_READY(),
    .I_S4_W_ID(8'h00), .I_S4_W_DATA(128'h0), .I_S4_W_LAST(1'b0),
    .I_S4_W_STRB(16'h0), .I_S4_W_VALID(1'b0), .O_S4_W_READY(),
    .O_S4_B_ID(), .O_S4_B_VALID(), .I_S4_B_READY(1'b0),
    .I_S4_AR_ID(8'h00), .I_S4_AR_ADDR(32'h0), .I_S4_AR_LEN(8'h00),
    .I_S4_AR_SIZE(3'h0), .I_S4_AR_BURST(2'b01), .I_S4_AR_LOCK(2'b00),
    .I_S4_AR_VALID(1'b0), .O_S4_AR_READY(),
    .O_S4_R_ID(), .O_S4_R_DATA(), .O_S4_R_LAST(), .O_S4_R_RESP(),
    .O_S4_R_VALID(), .I_S4_R_READY(1'b0),

    .O_M_AW_ID                          (s_axi_awid),
    .O_M_AW_ADDR                        (s_axi_awaddr),
    .O_M_AW_LEN                         (s_axi_awlen),
    .O_M_AW_SIZE                        (s_axi_awsize),
    .O_M_AW_BURST                       (s_axi_awburst),
    .O_M_AW_LOCK                        (),
    .O_M_AW_VALID                       (s_axi_awvalid),
    .I_M_AW_READY                       (s_axi_awready),
    .O_M_W_ID                           (),
    .O_M_W_DATA                         (s_axi_wdata),
    .O_M_W_LAST                         (s_axi_wlast),
    .O_M_W_STRB                         (s_axi_wstrb),
    .O_M_W_VALID                        (s_axi_wvalid),
    .I_M_W_READY                        (s_axi_wready),
    .I_M_B_ID                           (s_axi_bid),
    .I_M_B_VALID                        (s_axi_bvalid),
    .O_M_B_READY                        (s_axi_bready),
    .O_M_AR_ID                          (s_axi_arid),
    .O_M_AR_ADDR                        (s_axi_araddr),
    .O_M_AR_LEN                         (s_axi_arlen),
    .O_M_AR_SIZE                        (s_axi_arsize),
    .O_M_AR_BURST                       (s_axi_arburst),
    .O_M_AR_LOCK                        (),
    .O_M_AR_VALID                       (s_axi_arvalid),
    .I_M_AR_READY                       (s_axi_arready),
    .I_M_R_ID                           (s_axi_rid),
    .I_M_R_DATA                         (s_axi_rdata),
    .I_M_R_LAST                         (s_axi_rlast),
    .I_M_R_RESP                         (s_axi_rresp),
    .I_M_R_VALID                        (s_axi_rvalid),
    .O_M_R_READY                        (s_axi_rready),

    .Cfg_Arb_Type                       (1'b0),
    .Cfg_Cnl_Mask                       (5'b00111),
    .O_AR_Cnl_Num                       (),
    .O_R_Cnl_Num                        (),
    .O_Dbg_Arb_AR                       ()
);

// ============================================================================
// GFX subsystem
// ============================================================================
gfx_top #(
    .H_ACT(1920), .H_FP(88), .H_SYNC(44), .H_BP(148),
    .V_ACT(1080), .V_FP(4), .V_SYNC(5), .V_BP(36)
) u_gfx (
    .clk        (user_clk),
    .rst_n      (ddr_rstn),
    .pclk       (pix_clk),
    .preset_n   (ddr_rstn),

    .s_awaddr   (reg_awaddr[7:0]),
    .s_awlen    (reg_awlen),
    .s_awsize   (reg_awsize),
    .s_awburst  (reg_awburst),
    .s_awvalid  (reg_awvalid),
    .s_awready  (reg_awready),
    .s_wdata    (reg_wdata),
    .s_wstrb    (reg_wstrb),
    .s_wlast    (reg_wlast),
    .s_wvalid   (reg_wvalid),
    .s_wready   (reg_wready),
    .s_bresp    (reg_bresp),
    .s_bvalid   (reg_bvalid),
    .s_bready   (reg_bready),
    .s_araddr   (reg_araddr[7:0]),
    .s_arlen    (reg_arlen),
    .s_arsize   (reg_arsize),
    .s_arburst  (reg_arburst),
    .s_arvalid  (reg_arvalid),
    .s_arready  (reg_arready),
    .s_rdata    (reg_rdata),
    .s_rresp    (reg_rresp),
    .s_rlast    (reg_rlast),
    .s_rvalid   (reg_rvalid),
    .s_rready   (reg_rready),
    .irq        (gfx_irq),

    .m_awaddr   (gfx_awaddr),
    .m_awlen    (gfx_awlen),
    .m_awsize   (gfx_awsize),
    .m_awburst  (gfx_awburst),
    .m_awvalid  (gfx_awvalid),
    .m_awready  (gfx_awready),
    .m_wdata    (gfx_wdata),
    .m_wstrb    (gfx_wstrb),
    .m_wlast    (gfx_wlast),
    .m_wvalid   (gfx_wvalid),
    .m_wready   (gfx_wready),
    .m_bresp    (gfx_bresp),
    .m_bvalid   (gfx_bvalid),
    .m_bready   (gfx_bready),
    .m_araddr   (gfx_araddr),
    .m_arlen    (gfx_arlen),
    .m_arsize   (gfx_arsize),
    .m_arburst  (gfx_arburst),
    .m_arvalid  (gfx_arvalid),
    .m_arready  (gfx_arready),
    .m_rdata    (gfx_rdata),
    .m_rresp    (gfx_rresp),
    .m_rlast    (gfx_rlast),
    .m_rvalid   (gfx_rvalid),
    .m_rready   (gfx_rready),

    .rgb        (vid_rgb),
    .de         (vid_de),
    .hs         (vid_hs),
    .vs         (vid_vs),
    .dbg_state  (gfx_dbg)
);

// ============================================================================
// HDMI encoder
// ============================================================================
dvi_encoder u_dvi_encoder (
    .pixelclk   (pix_clk),
    .rstin      (~ddr_rstn),
    .blue_din   (vid_rgb[7:0]),
    .green_din  (vid_rgb[15:8]),
    .red_din    (vid_rgb[23:16]),
    .hsync      (vid_hs),
    .vsync      (vid_vs),
    .de         (vid_de),
    .tmds_data0 (tmds_data0),
    .tmds_data1 (tmds_data1),
    .tmds_data2 (tmds_data2),
    .tmds_clk   (tmds_clk)
);

assign tmds_clk_o   = ~tmds_clk;
assign tmds_data0_o = ~tmds_data0;
assign tmds_data1_o = ~tmds_data1;
assign tmds_data2_o = ~tmds_data2;

assign tmds_data0_TX_OE  = 1'b1;   assign tmds_data0_TX_RST = 1'b0;
assign tmds_data1_TX_OE  = 1'b1;   assign tmds_data1_TX_RST = 1'b0;
assign tmds_data2_TX_OE  = 1'b1;   assign tmds_data2_TX_RST = 1'b0;
assign tmds_clk_TX_OE    = 1'b1;   assign tmds_clk_TX_RST   = 1'b0;

ddr3_top                 u_ddr3_top
      (
      
    .axi_clk                (user_clk             ),
    .core_clk               (core_clk            ),
    .sdram_clk              (sdram_clk           ),  
    .rx_cal_clk             (rx_cal_clk          ),
    .tx_cal_clk             (tx_cal_clk          ),
    .tx_cal_clk_90edge      (tx_cal_clk_90edge   ),
    .rstn                   (ddr_rstn            ),      
    .pll_shift              (pll_shift           ),
    .pll_shift_sel          (pll_shift_sel       ),
    .pll_shift_ena          (pll_shift_ena       ), 
///////////////DDR BUS
    .ddr_ck_hi              (ddr_ck_hi           ),
    .ddr_ck_lo              (ddr_ck_lo           ),
    .ddr_cke                (ddr_cke             ),    
    .ddr_reset_n            (ddr_reset_n         ),
    .ddr_cs_n               (ddr_cs_n            ),
    .ddr_ras_n              (ddr_ras_n           ),
    .ddr_cas_n              (ddr_cas_n           ),
    .ddr_we_n               (ddr_we_n            ),     
    .ddr_addr               (ddr_addr            ),
    .ddr_ba                 (ddr_ba              ),

    .ddr_dqs_oe             (ddr_dqs_oe          ),
    .ddr_dqs_oe_n           (ddr_dqs_oe_n        ),
    .ddr_dq_oe              (ddr_dq_oe           ),
    .ddr_dqs_in_hi          (ddr_dqs_in_hi       ),
    .ddr_dqs_in_lo          (ddr_dqs_in_lo       ),
    .ddr_dq_in_hi           (ddr_dq_in_hi        ),
    .ddr_dq_in_lo           (ddr_dq_in_lo        ),

    .ddr_dqs_out_hi         (ddr_dqs_out_hi      ),
    .ddr_dqs_out_lo         (ddr_dqs_out_lo      ),
    .ddr_dq_out_hi          (ddr_dq_out_hi       ),
    .ddr_dq_out_lo          (ddr_dq_out_lo       ),
    
    .ddr_dm_hi              (ddr_dm_hi           ),
    .ddr_dm_lo              (ddr_dm_lo           ),
    .ddr_odt                (ddr_odt             ),

// Application interface ports
       .app_sr_req                     (1'b0),
       .app_ref_req                    (1'b0),
       .app_zq_req                     (1'b0),
       .app_sr_active                  (app_sr_active),
       .app_ref_ack                    (app_ref_ack),
       .app_zq_ack                     (app_zq_ack),

// Slave Interface Write Address Ports
       .s_axi_awid                     (s_axi_awid        ),
       .s_axi_awaddr                   (s_axi_awaddr      ),
       .s_axi_awlen                    (s_axi_awlen       ),
       .s_axi_awsize                   (s_axi_awsize      ),
       .s_axi_awburst                  (s_axi_awburst     ),
       .s_axi_awlock                   (s_axi_awlock      ),
       .s_axi_awcache                  (s_axi_awcache     ),
       .s_axi_awprot                   (s_axi_awprot      ),
       .s_axi_awqos                    (4'h0              ),
       .s_axi_awvalid                  (s_axi_awvalid     ),
       .s_axi_awready                  (s_axi_awready     ),
// Slave Interface Write Data Ports
       .s_axi_wdata                    (s_axi_wdata       ),
       .s_axi_wstrb                    (s_axi_wstrb       ),
       .s_axi_wlast                    (s_axi_wlast       ),
       .s_axi_wvalid                   (s_axi_wvalid      ),
       .s_axi_wready                   (s_axi_wready      ),
// Slave Interface Write Response Ports
       .s_axi_bid                      (s_axi_bid         ),
       .s_axi_bresp                    (s_axi_bresp       ),
       .s_axi_bvalid                   (s_axi_bvalid      ),
       .s_axi_bready                   (s_axi_bready      ),
// Slave Interface Read Address Ports
       .s_axi_arid                     (s_axi_arid        ),
       .s_axi_araddr                   (s_axi_araddr      ),
       .s_axi_arlen                    (s_axi_arlen       ),
       .s_axi_arsize                   (s_axi_arsize      ),
       .s_axi_arburst                  (s_axi_arburst     ),
       .s_axi_arlock                   (s_axi_arlock      ),
       .s_axi_arcache                  (s_axi_arcache     ),
       .s_axi_arprot                   (s_axi_arprot      ),
       .s_axi_arqos                    (4'h0              ),
       .s_axi_arvalid                  (s_axi_arvalid     ),
       .s_axi_arready                  (s_axi_arready     ),
// Slave Interface Read Data Ports
       .s_axi_rid                      (s_axi_rid         ),
       .s_axi_rdata                    (s_axi_rdata       ),
       .s_axi_rresp                    (s_axi_rresp       ),
       .s_axi_rlast                    (s_axi_rlast       ),
       .s_axi_rvalid                   (s_axi_rvalid      ),
       .s_axi_rready                   (s_axi_rready      ),
//DEBUG       
       .wrlvl_dq_check                 (wrlvl_dq_check    ) ,
       .rd_level_dqs_check             (rd_level_dqs_check) ,
       .rdlvl_shift                    (rdlvl_shift) ,
       .wrlvl_shift                    (wrlvl_shift) ,
       .init_cur_state                 (init_cur_state    ) ,
       .idelay_ld                      (idelay_ld         ) ,
       .mpr_rdlvl_dly                  (mpr_rdlvl_dly     ) ,
       .ddr_debug_port                 (ddr_debug_port    ) ,
       .cal_done                       (cal_done          ) 
       );

soc u_sapphire_soc(
    .io_asyncReset                      (soc_async_rst                      ),
    .io_systemClk                       (user_clk                           ),

    //UART 0
    .system_uart_0_io_txd               (system_uart_0_io_txd               ),
    .system_uart_0_io_rxd               (system_uart_0_io_rxd               ),
    .io_memoryClk                       (user_clk                           ),
    .io_memoryReset                     (                                   ),
    .io_systemReset                     (                                   ),
    //External Memory AXI4 Interface
    .io_ddrA_aw_payload_prot            (                                  ),//(                                  ),
    .io_ddrA_aw_payload_qos             (                                  ),//(                                  ),
    .io_ddrA_aw_payload_cache           (                                  ),//(                                  ),
    .io_ddrA_aw_payload_lock            (soc_ddrA_awlock                     ),//(m1_axi_awlock                     ),
    .io_ddrA_aw_payload_burst           (soc_ddrA_awburst                    ),//(m1_axi_awburst                    ),
    .io_ddrA_aw_payload_size            (soc_ddrA_awsize                     ),//(m1_axi_awsize                     ),
    .io_ddrA_aw_payload_len             (soc_ddrA_awlen                      ),//(m1_axi_awlen                      ),
    .io_ddrA_aw_payload_region          (                                 ),//(                                  ),
    .io_ddrA_aw_payload_id              (soc_ddrA_awid                       ),//(m1_axi_awid                       ),
    .io_ddrA_aw_payload_addr            (soc_ddrA_awaddr                     ),//(m1_axi_awaddr                     ),
    .io_ddrA_aw_ready                   (soc_ddrA_awready                    ),//(m1_axi_awready                    ),
    .io_ddrA_aw_valid                   (soc_ddrA_awvalid                    ),//(m1_axi_awvalid                    ),
    .io_ddrA_w_payload_last             (soc_ddrA_wlast                      ),//(m1_axi_wlast                      ),
    .io_ddrA_w_ready                    (soc_ddrA_wready                     ),//(m1_axi_wready                     ),
    .io_ddrA_w_valid                    (soc_ddrA_wvalid                     ),  //(m1_axi_wvalid                     ),    
    .io_ddrA_w_payload_strb             (soc_ddrA_wstrb                      ),//(m1_axi_wstrb                      ),
    .io_ddrA_w_payload_data             (soc_ddrA_wdata                      ),//(m1_axi_wdata                      ),
    .io_ddrA_b_payload_resp             (                                 ),//(                                  ),
    .io_ddrA_b_payload_id               (soc_ddrA_bid                        ),//(m1_axi_bid                        ),
    .io_ddrA_b_ready                    (soc_ddrA_bready                     ),//(m1_axi_bready                     ),
    .io_ddrA_b_valid                    (soc_ddrA_bvalid                     ),//(m1_axi_bvalid                     ),
    .io_ddrA_ar_payload_prot            (                                 ),//(                                  ),
    .io_ddrA_ar_payload_qos             (                                 ),//(                                  ),
    .io_ddrA_ar_payload_cache           (                                 ),//(                                  ),
    .io_ddrA_ar_payload_region          (                                 ),//(                                  ),
    .io_ddrA_ar_payload_lock            (soc_ddrA_arlock                     ),//(m1_axi_arlock                     ),
    .io_ddrA_ar_payload_burst           (soc_ddrA_arburst                    ),//(m1_axi_arburst                    ),
    .io_ddrA_ar_payload_size            (soc_ddrA_arsize                     ),//(m1_axi_arsize                     ),
    .io_ddrA_ar_payload_len             (soc_ddrA_arlen                      ),//(m1_axi_arlen                      ),
    .io_ddrA_ar_payload_id              (soc_ddrA_arid                       ),//(m1_axi_arid                       ),
    .io_ddrA_ar_payload_addr            (soc_ddrA_araddr                     ),//(m1_axi_araddr                     ),
    .io_ddrA_ar_ready                   (soc_ddrA_arready                    ),//(m1_axi_arready                    ),
    .io_ddrA_ar_valid                   (soc_ddrA_arvalid                    ),//(m1_axi_arvalid                    ),
    .io_ddrA_r_payload_last             (soc_ddrA_rlast                      ),//(m1_axi_rlast                      ),
    .io_ddrA_r_payload_resp             (soc_ddrA_rresp                      ),//(m1_axi_rresp                      ),
    .io_ddrA_r_payload_id               (soc_ddrA_rid                        ),//(m1_axi_rid                        ),
    .io_ddrA_r_payload_data             (soc_ddrA_rdata                      ),//(m1_axi_rdata                      ),
    .io_ddrA_r_ready                    (soc_ddrA_rready                     ),//(m1_axi_rready                     ),
    .io_ddrA_r_valid                    (soc_ddrA_rvalid                     ),//(m1_axi_rvalid                     ),

    // ============ AXI slave port: BitBlt register file ============
    // 16 MB window at 0xE1000000 (matches "Base_M_AXIS" in the SoC settings).
    // 32-bit data, which is exactly what bitblt_axi_slave implements, so no
    // width adaptation is needed between them.
    .axiA_awid                          (reg_awid                           ),
    .axiA_awaddr                        (reg_awaddr                         ),
    .axiA_awlen                         (reg_awlen                          ),
    .axiA_awsize                        (reg_awsize                         ),
    .axiA_awburst                       (reg_awburst                        ),
    .axiA_awlock                        (reg_awlock                         ),
    .axiA_awcache                       (reg_awcache                        ),
    .axiA_awprot                        (reg_awprot                         ),
    .axiA_awqos                         (reg_awqos                          ),
    .axiA_awregion                      (reg_awregion                       ),
    .axiA_awvalid                       (reg_awvalid                        ),
    .axiA_awready                       (reg_awready                        ),
    .axiA_wdata                         (reg_wdata                          ),
    .axiA_wstrb                         (reg_wstrb                          ),
    .axiA_wlast                         (reg_wlast                          ),
    .axiA_wvalid                        (reg_wvalid                         ),
    .axiA_wready                        (reg_wready                         ),
    .axiA_bid                           (reg_bid                            ),
    .axiA_bresp                         (reg_bresp                          ),
    .axiA_bvalid                        (reg_bvalid                         ),
    .axiA_bready                        (reg_bready                         ),
    .axiA_arid                          (reg_arid                           ),
    .axiA_araddr                        (reg_araddr                         ),
    .axiA_arlen                         (reg_arlen                          ),
    .axiA_arsize                        (reg_arsize                         ),
    .axiA_arburst                       (reg_arburst                        ),
    .axiA_arlock                        (reg_arlock                         ),
    .axiA_arcache                       (reg_arcache                        ),
    .axiA_arprot                        (reg_arprot                         ),
    .axiA_arqos                         (reg_arqos                          ),
    .axiA_arregion                      (reg_arregion                       ),
    .axiA_arvalid                       (reg_arvalid                        ),
    .axiA_arready                       (reg_arready                        ),
    .axiA_rid                           (reg_rid                            ),
    .axiA_rdata                         (reg_rdata                          ),
    .axiA_rresp                         (reg_rresp                          ),
    .axiA_rlast                         (reg_rlast                          ),
    .axiA_rvalid                        (reg_rvalid                         ),
    .axiA_rready                        (reg_rready                         ),
    .axiAInterrupt                      (gfx_irq                      ),
     //SPI 0
    .system_spi_0_io_sclk_write         (system_spi_0_io_sclk_write         ),
    .system_spi_0_io_data_0_writeEnable (system_spi_0_io_data_0_OE ),
    .system_spi_0_io_data_0_read        (system_spi_0_io_data_0_IN        ),
    .system_spi_0_io_data_0_write       (system_spi_0_io_data_0_OUT       ),
    .system_spi_0_io_data_1_writeEnable (system_spi_0_io_data_1_OE ),
    .system_spi_0_io_data_1_read        (system_spi_0_io_data_1_IN        ),
    .system_spi_0_io_data_1_write       (system_spi_0_io_data_1_OUT       ),
    .system_spi_0_io_data_2_writeEnable (                                   ),
    .system_spi_0_io_data_2_read        (                                   ),
    .system_spi_0_io_data_2_write       (                                   ),
    .system_spi_0_io_data_3_writeEnable (                                   ),
    .system_spi_0_io_data_3_read        (                                   ),
    .system_spi_0_io_data_3_write       (                                   ),
    .system_spi_0_io_ss                 (system_spi_0_io_ss                 ),
    //APB 0
    .io_apbSlave_0_PADDR                (apb_paddr                          ),
    .io_apbSlave_0_PSEL                 (apb_psel                           ),
    .io_apbSlave_0_PENABLE              (apb_penable                        ),
    .io_apbSlave_0_PREADY               (apb_pready                         ),
    .io_apbSlave_0_PWRITE               (apb_pwrite                         ),
    .io_apbSlave_0_PWDATA               (apb_pwdata                         ),
    .io_apbSlave_0_PRDATA               (apb_prdata                         ),
    .io_apbSlave_0_PSLVERROR            (apb_pslverror                      ),

    .system_gpio_0_io_write             ( soc_gpio_OUT                      ),//,
    // DEBUG 2026-10-13: bit0 = R handshake seen, bit1 = AR handshake seen,
    // bit2 = RVALID now, bit3 = read active. Read from software at 0xF8015000.
    // (soc_gpio_IN is unused by this design.)
    // DEBUG 2026-10-13: now carrying the Axi_Mux AR arbitration state instead
    // of bitblt_top's dbg_observ.
    // DEBUG 2026-10-13: the DECISIVE pair. rd1_arvalid is the channel-side
    // ARVALID; s_axi_arvalid is what the mux actually forwards to the DDR
    // controller. If s_axi_arvalid is LOW the mux is not even presenting the
    // request (internal deadlock); if it is HIGH while arready stays low, the
    // DDR controller is refusing it.
    //   bit2 = s_axi_arvalid   bit3 = s_axi_arready
    // Measured 0x6 (arvalid=1, arready=0 repeatedly): the mux DOES forward the
    // AR; the DDR controller refuses it. Most likely the controller is in-order
    // and still owes R data for an earlier read that the mux will not accept.
    //   bit0 = s_axi_rvalid   bit1 = s_axi_rready
    // Measured 0x5: rvalid=1 and rready=0 -- the DDR controller HAS data to
    // hand over and the mux will not take it, so the in-order controller
    // refuses the next AR. Now identify WHO the R bus is routed to and whether
    // that channel is actually asking for data.
    //   bit0 = rd0_rready   bit1 = rd1_rready
    //   bit2..3 = r_cnl_num[1:0]
    // 2026-10-17: was {r_cnl_num[1:0], rd1_rready, rd0_rready}, which read 0x0 in
    // both states. Now the 4-group observation mux defined above.
    .system_gpio_0_io_read              ( 4'h0                              ),//
    .system_gpio_0_io_writeEnable       ( soc_gpio_OE                       ),//, 


    //Hard Jtag Tap
    .jtagCtrl_tck                       (jtag_inst1_TCK                     ),
    .jtagCtrl_tdi                       (jtag_inst1_TDI                     ),
    .jtagCtrl_tdo                       (jtag_inst1_TDO                     ),
    .jtagCtrl_enable                    (jtag_inst1_SEL                     ),
    .jtagCtrl_capture                   (jtag_inst1_CAPTURE                 ),
    .jtagCtrl_shift                     (jtag_inst1_SHIFT                   ),
    .jtagCtrl_update                    (jtag_inst1_UPDATE                  ),
    .jtagCtrl_reset                     (jtag_inst1_RESET                   )

);

endmodule
