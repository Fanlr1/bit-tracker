// ============================================================================
// gfx_top.v -- the whole graphics subsystem behind ONE AXI4 master.
//
//   AXI4-Lite slave  <- SoC register window (0xE1000000)
//   AXI4 master      -> Axi_Mux port 1 (reads and writes)
//   video out        -> dvi_encoder
//
// Merging four masters into one is the architectural change that removes the
// old deadlock: Axi_Mux routes its R channel to one slave until RLAST, and the
// old design had four clients that could each stall the bus. Here the single
// client keeps RREADY high for an entire burst and allows exactly one burst in
// flight, so the bus can never be held by a client that is not consuming.
// ============================================================================
`default_nettype none

module gfx_top #(
    parameter H_ACT = 1920,
    parameter H_FP  = 88,
    parameter H_SYNC = 44,
    parameter H_BP  = 148,
    parameter V_ACT = 1080,
    parameter V_FP  = 4,
    parameter V_SYNC = 5,
    parameter V_BP  = 36
)(
    input  wire         clk,            // 100 MHz AXI domain
    input  wire         rst_n,
    input  wire         pclk,           // 148.5 MHz pixel domain
    input  wire         preset_n,

    // ---------------- AXI4-Lite slave: register file ----------------
    input  wire [7:0]   s_awaddr,
    input  wire [7:0]   s_awlen,
    input  wire [2:0]   s_awsize,
    input  wire [1:0]   s_awburst,
    input  wire         s_awvalid,
    output wire         s_awready,
    input  wire [31:0]  s_wdata,
    input  wire [3:0]   s_wstrb,
    input  wire         s_wlast,
    input  wire         s_wvalid,
    output wire         s_wready,
    output wire [1:0]   s_bresp,
    output wire         s_bvalid,
    input  wire         s_bready,
    input  wire [7:0]   s_araddr,
    input  wire [7:0]   s_arlen,
    input  wire [2:0]   s_arsize,
    input  wire [1:0]   s_arburst,
    input  wire         s_arvalid,
    output wire         s_arready,
    output wire [31:0]  s_rdata,
    output wire [1:0]   s_rresp,
    output wire         s_rlast,
    output wire         s_rvalid,
    input  wire         s_rready,
    output wire         irq,

    // ---------------- AXI4 master ----------------
    output wire [31:0]  m_awaddr,
    output wire [7:0]   m_awlen,
    output wire [2:0]   m_awsize,
    output wire [1:0]   m_awburst,
    output wire         m_awvalid,
    input  wire         m_awready,
    output wire [127:0] m_wdata,
    output wire [15:0]  m_wstrb,
    output wire         m_wlast,
    output wire         m_wvalid,
    input  wire         m_wready,
    input  wire [1:0]   m_bresp,
    input  wire         m_bvalid,
    output wire         m_bready,
    output wire [31:0]  m_araddr,
    output wire [7:0]   m_arlen,
    output wire [2:0]   m_arsize,
    output wire [1:0]   m_arburst,
    output wire         m_arvalid,
    input  wire         m_arready,
    input  wire [127:0] m_rdata,
    input  wire [1:0]   m_rresp,
    input  wire         m_rlast,
    input  wire         m_rvalid,
    output wire         m_rready,

    // ---------------- video ----------------
    output wire [23:0]  rgb,
    output wire         de,
    output wire         hs,
    output wire         vs,

    // ---------------- debug ----------------
    output wire [31:0]  dbg_state
);

    // ------------------------------------------------------------ command bus
    wire         cmd_valid;
    wire         cmd_ready;
    wire [351:0] cmd_data;
    wire [4:0]   cmd_level;

    // ------------------------------------------------------------ engine status
    wire         core_busy;
    wire [31:0]  core_done;
    wire         core_error;
    wire         core_clipped;
    wire [31:0]  core_err_addr;
    wire [31:0]  core_pix_cnt;

    // ------------------------------------------------------------ scan config
    wire [31:0]  cfg_fb_base;
    wire [15:0]  cfg_fb_stride;
    wire [15:0]  cfg_fb_w, cfg_fb_h;
    wire         cfg_fb_enable;
    wire [31:0]  cfg_fb_next, cfg_fb_seq;
    wire         cfg_fb_commit;

    wire [31:0]  sc_accepted;
    wire [31:0]  sc_underruns;
    wire [31:0]  sc_shown;
    wire [31:0]  sc_axi_err;
    wire [31:0]  sc_frames;
    wire [15:0]  sc_lines;
    wire         sc_blanking;
    wire [10:0]  sc_first_under;
    wire [15:0]  sc_rd_wait_max, sc_rd_gap_max;
    wire [15:0]  sc_pf_cnt, sc_pf_stall_max;
    wire [31:0]  sc_rd_cyc_sum;

    // ------------------------------------------------------------ AXI clients
    wire         rd0_req, rd0_gnt, rd0_valid, rd0_last;
    wire [31:0]  rd0_addr;
    wire [8:0]   rd0_beats;
    wire [127:0] rd0_data;

    wire         rd1_req, rd1_gnt, rd1_valid, rd1_last;
    wire [31:0]  rd1_addr;
    wire [8:0]   rd1_beats;
    wire [127:0] rd1_data;

    wire         rd2_req, rd2_gnt, rd2_valid, rd2_last;
    wire [31:0]  rd2_addr;
    wire [8:0]   rd2_beats;
    wire [127:0] rd2_data;

    wire         wr_req, wr_gnt, wr_valid, wr_ready, wr_last;
    wire [31:0]  wr_addr;
    wire [4:0]   wr_beats;
    wire [127:0] wr_data;
    wire [15:0]  wr_strb;

    // ------------------------------------------------------------ scan counters CDC
    // These live in the pixel domain. A stable-sample synchroniser is used
    // instead of a plain two-flop chain for the multi-bit values: the counter
    // is accepted only when two consecutive samples agree, so software can never
    // read a value that mixes two counts.
    reg [31:0] u0, u1, u_stable;
    reg [31:0] s0, s1, s_stable;
    reg [31:0] f0, f1, f_stable;
    reg [31:0] a0, a1, a_stable;
    reg [15:0] l0, l1, l_stable;
    reg        b0, b1, b_stable;
    reg [10:0] fu0, fu1, fu_stable;

    always @(posedge clk) begin
        if (!rst_n) begin
            u0 <= 0; u1 <= 0; u_stable <= 0;
            s0 <= 0; s1 <= 0; s_stable <= 0;
            f0 <= 0; f1 <= 0; f_stable <= 0;
            a0 <= 0; a1 <= 0; a_stable <= 0;
            l0 <= 0; l1 <= 0; l_stable <= 0;
            b0 <= 0; b1 <= 0; b_stable <= 0;
            fu0 <= 0; fu1 <= 0; fu_stable <= 0;
        end else begin
            u0 <= sc_underruns; u1 <= u0; if (u0 == u1) u_stable <= u0;
            s0 <= sc_shown;     s1 <= s0; if (s0 == s1) s_stable <= s0;
            f0 <= sc_frames;    f1 <= f0; if (f0 == f1) f_stable <= f0;
            a0 <= sc_axi_err;   a1 <= a0; if (a0 == a1) a_stable <= a0;
            l0 <= sc_lines;     l1 <= l0; if (l0 == l1) l_stable <= l0;
            b0 <= sc_blanking;  b1 <= b0; b_stable <= b1;
            fu0 <= sc_first_under; fu1 <= fu0; if (fu0 == fu1) fu_stable <= fu0;
        end
    end

    // ------------------------------------------------------------ register file
    gfx_regs #(
        .FIFO_DEPTH (8),
        .ID_VALUE   (32'h4746_5801),
        .DEF_W      (H_ACT[15:0]),
        .DEF_H      (V_ACT[15:0])
    ) u_regs (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_awaddr    (s_awaddr),
        .s_awvalid   (s_awvalid),
        .s_awready   (s_awready),
        .s_wdata     (s_wdata),
        .s_wstrb     (s_wstrb),
        .s_wvalid    (s_wvalid),
        .s_wready    (s_wready),
        .s_bresp     (s_bresp),
        .s_bvalid    (s_bvalid),
        .s_bready    (s_bready),
        .s_araddr    (s_araddr),
        .s_arvalid   (s_arvalid),
        .s_arready   (s_arready),
        .s_rdata     (s_rdata),
        .s_rresp     (s_rresp),
        .s_rlast     (s_rlast),
        .s_rvalid    (s_rvalid),
        .s_rready    (s_rready),
        .irq         (irq),
        .cmd_valid   (cmd_valid),
        .cmd_ready   (cmd_ready),
        .cmd_data    (cmd_data),
        .cmd_level   (cmd_level),
        .core_busy   (core_busy),
        .core_done_cnt (core_done),
        .core_error  (core_error),
        .core_clipped(core_clipped),
        .core_err_addr(core_err_addr),
        .core_pix_cnt(core_pix_cnt),
        .cfg_fb_base (cfg_fb_base),
        .cfg_fb_stride(cfg_fb_stride),
        .cfg_fb_w    (cfg_fb_w),
        .cfg_fb_h    (cfg_fb_h),
        .cfg_fb_enable(cfg_fb_enable),
        .cfg_fb_next (cfg_fb_next),
        .cfg_fb_seq  (cfg_fb_seq),
        .cfg_fb_commit(cfg_fb_commit),
        .scan_accepted(sc_accepted),
        .scan_underruns(u_stable),
        .scan_shown  (s_stable),
        .scan_axi_err(a_stable),
        .scan_frames (f_stable),
        .scan_lines  (l_stable),
        .scan_blanking(b_stable),
        .scan_first_under(fu_stable),
        .scan_rd_wait_max(sc_rd_wait_max),
        .scan_rd_gap_max(sc_rd_gap_max),
        .scan_pf_cnt(sc_pf_cnt),
        .scan_pf_stall_max(sc_pf_stall_max),
        .scan_rd_cyc_sum(sc_rd_cyc_sum),
        .dbg_in      (dbg_state)
    );

    // ------------------------------------------------------------ engine
    gfx_core u_core (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd_valid  (cmd_valid),
        .cmd_ready  (cmd_ready),
        .cmd_data   (cmd_data),
        .busy       (core_busy),
        .done_cnt   (core_done),
        .error      (core_error),
        .clipped    (core_clipped),
        .err_addr   (core_err_addr),
        .pix_cnt    (core_pix_cnt),
        .dbg_state  (core_dbg),
        .rd1_req    (rd1_req),
        .rd1_addr   (rd1_addr),
        .rd1_beats  (rd1_beats),
        .rd1_gnt    (rd1_gnt),
        .rd1_valid  (rd1_valid),
        .rd1_data   (rd1_data),
        .rd1_last   (rd1_last),
        .rd2_req    (rd2_req),
        .rd2_addr   (rd2_addr),
        .rd2_beats  (rd2_beats),
        .rd2_gnt    (rd2_gnt),
        .rd2_valid  (rd2_valid),
        .rd2_data   (rd2_data),
        .rd2_last   (rd2_last),
        .wr_req     (wr_req),
        .wr_addr    (wr_addr),
        .wr_beats   (wr_beats),
        .wr_gnt     (wr_gnt),
        .wr_data    (wr_data),
        .wr_strb    (wr_strb),
        .wr_valid   (wr_valid),
        .wr_ready   (wr_ready),
        .wr_last    (wr_last)
    );

    // ------------------------------------------------------------ scan-out
    gfx_scanout #(
        .H_ACT  (H_ACT),
        .H_FP   (H_FP),
        .H_SYNC (H_SYNC),
        .H_BP   (H_BP),
        .V_ACT  (V_ACT),
        .V_FP   (V_FP),
        .V_SYNC (V_SYNC),
        .V_BP   (V_BP),
        .RAM_AW (8)
    ) u_scan (
        .clk        (clk),
        .rst_n      (rst_n),
        .pclk       (pclk),
        .preset_n   (preset_n),
        .fb_base    (cfg_fb_base),
        .fb_stride  (cfg_fb_stride),
        .fb_w       (cfg_fb_w),
        .fb_h       (cfg_fb_h),
        .enable     (cfg_fb_enable),
        .fb_next    (cfg_fb_next),
        .fb_seq     (cfg_fb_seq),
        .fb_commit  (cfg_fb_commit),
        .rd_req     (rd0_req),
        .rd_addr    (rd0_addr),
        .rd_beats   (rd0_beats),
        .rd_gnt     (rd0_gnt),
        .rd_valid   (rd0_valid),
        .rd_data    (rd0_data),
        .rd_last    (rd0_last),
        .scan_accepted (sc_accepted),
        .underruns  (sc_underruns),
        .shown      (sc_shown),
        .axi_errors (sc_axi_err),
        .frames     (sc_frames),
        .lines_last (sc_lines),
        .blanking   (sc_blanking),
        .first_under(sc_first_under),
        .dbg_rd_cyc_sum(sc_rd_cyc_sum),
        .dbg_rd_wait_max(sc_rd_wait_max),
        .dbg_rd_gap_max(sc_rd_gap_max),
        .dbg_pf_cnt(sc_pf_cnt),
        .dbg_pf_stall_max(sc_pf_stall_max),
        .front_now  (),
        .fetch_row_dbg (),
        .rgb        (rgb),
        .de         (de),
        .hs         (hs),
        .vs         (vs)
    );

    // ------------------------------------------------------------ memory
    gfx_mem #(
        .AXI_DW (128)
    ) u_mem (
        .clk        (clk),
        .rst_n      (rst_n),
        .rd0_req    (rd0_req),
        .rd0_addr   (rd0_addr),
        .rd0_beats  (rd0_beats),
        .rd0_gnt    (rd0_gnt),
        .rd0_valid  (rd0_valid),
        .rd0_data   (rd0_data),
        .rd0_last   (rd0_last),
        .rd1_req    (rd1_req),
        .rd1_addr   (rd1_addr),
        .rd1_beats  (rd1_beats),
        .rd1_gnt    (rd1_gnt),
        .rd1_valid  (rd1_valid),
        .rd1_data   (rd1_data),
        .rd1_last   (rd1_last),
        .rd2_req    (rd2_req),
        .rd2_addr   (rd2_addr),
        .rd2_beats  (rd2_beats),
        .rd2_gnt    (rd2_gnt),
        .rd2_valid  (rd2_valid),
        .rd2_data   (rd2_data),
        .rd2_last   (rd2_last),
        .wr_req     (wr_req),
        .wr_addr    (wr_addr),
        .wr_beats   (wr_beats),
        .wr_gnt     (wr_gnt),
        .wr_data    (wr_data),
        .wr_strb    (wr_strb),
        .wr_valid   (wr_valid),
        .wr_ready   (wr_ready),
        .wr_last    (wr_last),
        .rd_beats_cnt (),
        .wr_beats_cnt (),
        .rresp_err_cnt(),
        .bresp_err_cnt(),
        .dbg_state  (mem_dbg),
        .m_araddr   (m_araddr),
        .m_arlen    (m_arlen),
        .m_arsize   (m_arsize),
        .m_arburst  (m_arburst),
        .m_arvalid  (m_arvalid),
        .m_arready  (m_arready),
        .m_rdata    (m_rdata),
        .m_rresp    (m_rresp),
        .m_rlast    (m_rlast),
        .m_rvalid   (m_rvalid),
        .m_rready   (m_rready),
        .m_awaddr   (m_awaddr),
        .m_awlen    (m_awlen),
        .m_awsize   (m_awsize),
        .m_awburst  (m_awburst),
        .m_awvalid  (m_awvalid),
        .m_awready  (m_awready),
        .m_wdata    (m_wdata),
        .m_wstrb    (m_wstrb),
        .m_wlast    (m_wlast),
        .m_wvalid   (m_wvalid),
        .m_wready   (m_wready),
        .m_bresp    (m_bresp),
        .m_bvalid   (m_bvalid),
        .m_bready   (m_bready)
    );

    wire [3:0] core_dbg;
    wire [7:0] mem_dbg;

    assign dbg_state = {8'h0,
                        core_busy,
                        m_rready, m_rvalid,
                        m_arready, m_arvalid,
                        m_bready,  m_bvalid,
                        m_wready,  m_wvalid,
                        m_awready, m_awvalid,
                        wr_valid,
                        mem_dbg,
                        core_dbg};

endmodule

`default_nettype wire
