// ============================================================================
// gfx_regs.v -- AXI4-Lite register file + command FIFO for the GFX engine.
//
// WHY THIS REPLACES bitblt_axi_slave
//   The old slave had three inherited quirks: read and write were mutually
//   exclusive (one 4-state FSM), AW and W had to arrive in the same cycle, and
//   rvalid was combinationally gated by rready (which violates AXI). None of
//   those are needed. This implementation has independent AW/W and AR/R
//   handshakes and never gates a VALID with a READY.
//
// COMMAND FIFO
//   A write to CTRL with bit0 set snapshots all ten parameter registers into a
//   320-bit FIFO entry. Software can therefore issue command N+1 while command
//   N is still running, which is what removes the per-command CPU poll that
//   made the old engine slow on this board.
//
// REGISTER MAP (byte offsets, 32-bit words)
//   00 ID          RO   0x47465801  "GFX" v1
//   04 CTRL        WO   [0] START  [1] IRQ_EN  [2] SOFT_RST
//   08 STATUS      RO   [0] BUSY [1] DONE [2] ERROR [3] CLIPPED [4] FIFO_FULL
//                       [15:8] FIFO level
//   0C OP          RW   [2:0] operation code
//   10 SRC_ADDR    RW
//   14 DST_ADDR    RW
//   18 SIZE        RW   [15:0] width  [31:16] height
//   1C SRC_STRIDE  RW   bytes per source row
//   20 DST_STRIDE  RW   bytes per destination row
//   24 COLOR       RW   RGB565
//   28 ALPHA       RW   [7:0]
//   2C KEY         RW   RGB565 transparent colour
//   30 CLIP_X      RW   [15:0] x0  [31:16] x1 (exclusive)
//   34 CLIP_Y      RW   [15:0] y0  [31:16] y1 (exclusive)
//   38 DONE_CNT    RO
//   3C ERR_ADDR    RO
//   40 FB_BASE     RW   front framebuffer base
//   44 FB_STRIDE   RW   bytes per display line (4 KiB aligned)
//   48 FB_SIZE     RW   [15:0] width [31:16] height
//   4C FB_CFG      RW   [0] enable
//   50 FB_NEXT     RW   next framebuffer base
//   54 FB_SEQ      RW   next framebuffer sequence number
//   58 FB_COMMIT   WO   write 1 -> queue the page flip
//   5C FB_ACCEPTED RO   sequence number the scan-out has accepted
//   60 SCAN_STATUS RO   [0] blanking
//   64 SCAN_UNDER  RO
//   68 SCAN_SHOWN  RO
//   6C SCAN_AXIERR RO
//   70 SCAN_FRAMES RO
//   74 SCAN_LINES  RO
//   78 SPR_TABLE   RW   (reserved for the batch sprite path)
//   7C SPR_CTL     RW   (reserved)
//   80 SPR_DONE    RO   (reserved)
//   84 PIX_CNT     RO
//   88 DBG         RO
// ============================================================================
`default_nettype none

module gfx_regs #(
    parameter FIFO_DEPTH = 8,
    parameter [31:0] ID_VALUE = 32'h4746_5801,
    parameter [15:0] DEF_W = 16'd1920,
    parameter [15:0] DEF_H = 16'd1080
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---------------- AXI4-Lite slave ----------------
    input  wire [7:0]   s_awaddr,
    input  wire         s_awvalid,
    output wire         s_awready,
    input  wire [31:0]  s_wdata,
    input  wire [3:0]   s_wstrb,
    input  wire         s_wvalid,
    output wire         s_wready,
    output wire [1:0]   s_bresp,
    output wire         s_bvalid,
    input  wire         s_bready,
    input  wire [7:0]   s_araddr,
    input  wire         s_arvalid,
    output wire         s_arready,
    output wire [31:0]  s_rdata,
    output wire [1:0]   s_rresp,
    output wire         s_rlast,
    output wire         s_rvalid,
    input  wire         s_rready,

    output wire         irq,

    // ---------------- command FIFO -> gfx_core ----------------
    output wire         cmd_valid,
    input  wire         cmd_ready,
    output wire [351:0] cmd_data,
    output wire [4:0]   cmd_level,

    // ---------------- engine status in ----------------
    input  wire         core_busy,
    input  wire [31:0]  core_done_cnt,
    input  wire         core_error,
    input  wire         core_clipped,
    input  wire [31:0]  core_err_addr,
    input  wire [31:0]  core_pix_cnt,

    // ---------------- scan-out configuration ----------------
    output wire [31:0]  cfg_fb_base,
    output wire [15:0]  cfg_fb_stride,
    output wire [15:0]  cfg_fb_w,
    output wire [15:0]  cfg_fb_h,
    output wire         cfg_fb_enable,
    output wire [31:0]  cfg_fb_next,
    output wire [31:0]  cfg_fb_seq,
    output reg          cfg_fb_commit,      // one-cycle pulse
    input  wire [31:0]  scan_accepted,
    input  wire [31:0]  scan_underruns,
    input  wire [31:0]  scan_shown,
    input  wire [31:0]  scan_axi_err,
    input  wire [31:0]  scan_frames,
    input  wire [15:0]  scan_lines,
    input  wire         scan_blanking,
    input  wire [10:0]  scan_first_under,
    input  wire [15:0]  scan_rd_wait_max,
    input  wire [15:0]  scan_rd_gap_max,
    input  wire [15:0]  scan_pf_cnt,
    input  wire [15:0]  scan_pf_stall_max,
    input  wire [31:0]  scan_rd_cyc_sum,

    input  wire [31:0]  dbg_in
);

    // ---------------------------------------------------------------- offsets
    localparam [7:0] R_ID       = 8'h00;
    localparam [7:0] R_CTRL     = 8'h04;
    localparam [7:0] R_STATUS   = 8'h08;
    localparam [7:0] R_OP       = 8'h0C;
    localparam [7:0] R_SRC      = 8'h10;
    localparam [7:0] R_DST      = 8'h14;
    localparam [7:0] R_SIZE     = 8'h18;
    localparam [7:0] R_SS       = 8'h1C;
    localparam [7:0] R_DS       = 8'h20;
    localparam [7:0] R_COLOR    = 8'h24;
    localparam [7:0] R_ALPHA    = 8'h28;
    localparam [7:0] R_KEY      = 8'h2C;
    localparam [7:0] R_CX       = 8'h30;
    localparam [7:0] R_CY       = 8'h34;
    localparam [7:0] R_DONE     = 8'h38;
    localparam [7:0] R_ERRADDR  = 8'h3C;
    localparam [7:0] R_FBBASE   = 8'h40;
    localparam [7:0] R_FBSTRIDE = 8'h44;
    localparam [7:0] R_FBSIZE   = 8'h48;
    localparam [7:0] R_FBCFG    = 8'h4C;
    localparam [7:0] R_FBNEXT   = 8'h50;
    localparam [7:0] R_FBSEQ    = 8'h54;
    localparam [7:0] R_FBCOMMIT = 8'h58;
    localparam [7:0] R_FBACCEPT = 8'h5C;
    localparam [7:0] R_SCANST   = 8'h60;
    localparam [7:0] R_UNDER    = 8'h64;
    localparam [7:0] R_SHOWN    = 8'h68;
    localparam [7:0] R_AXIERR   = 8'h6C;
    localparam [7:0] R_FRAMES   = 8'h70;
    localparam [7:0] R_LINES    = 8'h74;
    localparam [7:0] R_SPRTAB   = 8'h78;
    localparam [7:0] R_SPRCTL   = 8'h7C;
    localparam [7:0] R_SPRDONE  = 8'h80;
    localparam [7:0] R_PIXCNT   = 8'h84;
    localparam [7:0] R_DBG      = 8'h88;
    localparam [7:0] R_FUROW    = 8'h8C;
    localparam [7:0] R_DBG3     = 8'h94;
    localparam [7:0] R_DBG4     = 8'h98;   // total cycles spent in line reads, last frame
    localparam [7:0] R_DBG2     = 8'h90;   // [31:16] read-wait max, [15:0] burst-gap max

    // ---------------------------------------------------------------- state
    reg [31:0] cfg_op;
    reg [31:0] cfg_src;
    reg [31:0] cfg_dst;
    reg [31:0] cfg_size;
    reg [31:0] cfg_ss;
    reg [31:0] cfg_ds;
    reg [31:0] cfg_color;
    reg [31:0] cfg_alpha;
    reg [31:0] cfg_key;
    reg [31:0] cfg_cx;
    reg [31:0] cfg_cy;

    reg [31:0] reg_fb_base;
    reg [31:0] reg_fb_stride;
    reg [31:0] reg_fb_size;
    reg        reg_fb_enable;
    reg [31:0] reg_fb_next;
    reg [31:0] reg_fb_seq;
    reg [31:0] reg_sp_tab;
    reg [31:0] reg_sp_ctl;

    reg        irq_en;
    reg        irq_pend;
    reg [31:0] done_seen;

    // ---------------------------------------------------------------- write FSM
    reg        aw_have;
    reg [7:0]  aw_addr;
    reg        w_have;
    reg [31:0] w_data;
    reg [3:0]  w_strb;
    reg        bvalid_r;

    wire aw_hs = s_awvalid & s_awready;
    wire w_hs  = s_wvalid  & s_wready;
    wire wr_fire = aw_have & w_have & ~bvalid_r;

    assign s_awready = ~aw_have;
    assign s_wready  = ~w_have;
    assign s_bvalid  = bvalid_r;
    assign s_bresp   = 2'b00;

    // ---------------------------------------------------------------- read FSM
    reg        r_have;
    reg [7:0]  r_addr;
    wire ar_hs = s_arvalid & s_arready;
    wire r_hs  = s_rvalid & s_rready;

    assign s_arready = ~r_have;
    assign s_rvalid  = r_have;
    assign s_rlast   = r_have;   // every register read is exactly one beat
    assign s_rresp   = 2'b00;

    // ---------------------------------------------------------------- command FIFO
    reg [351:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [4:0]   fifo_wp;
    reg [4:0]   fifo_rp;
    wire [4:0]  fifo_level = fifo_wp - fifo_rp;
    wire        fifo_full  = (fifo_level == FIFO_DEPTH[4:0]);
    wire        fifo_empty = (fifo_level == 5'd0);

    assign cmd_valid = ~fifo_empty;
    assign cmd_data  = fifo_mem[fifo_rp[2:0]];
    assign cmd_level = fifo_level;

    wire pop_fire = cmd_valid & cmd_ready;

    // Snapshot of all command parameters, taken when START is written.
    // 11 fields x 32 bits = 352. Order matters: gfx_core slices this vector.
    wire [351:0] param_snapshot = {
        cfg_op, cfg_src, cfg_dst, cfg_size, cfg_ss,
        cfg_ds, cfg_color, cfg_alpha, cfg_key, cfg_cx, cfg_cy
    };

    // ---------------------------------------------------------------- CFG outs
    assign cfg_fb_base   = reg_fb_base;
    assign cfg_fb_stride = reg_fb_stride[15:0];
    assign cfg_fb_w      = reg_fb_size[15:0];
    assign cfg_fb_h      = reg_fb_size[31:16];
    assign cfg_fb_enable = reg_fb_enable;
    assign cfg_fb_next   = reg_fb_next;
    assign cfg_fb_seq    = reg_fb_seq;

    assign irq = irq_en & irq_pend;

    // ---------------------------------------------------------------- status
    wire        busy     = core_busy | ~fifo_empty;
    wire        done_bit = (core_done_cnt != 32'd0);
    wire [31:0] status_word = {16'd0,
                               fifo_level,
                               3'd0,
                               fifo_full,
                               core_clipped,
                               core_error,
                               done_bit,
                               busy};

    // ---------------------------------------------------------------- read mux
    reg [31:0] rdata_r;
    always @(*) begin
        case (r_addr)
            R_ID:       rdata_r = ID_VALUE;
            R_CTRL:     rdata_r = {30'd0, irq_en, 1'b0};
            R_STATUS:   rdata_r = status_word;
            R_OP:       rdata_r = cfg_op;
            R_SRC:      rdata_r = cfg_src;
            R_DST:      rdata_r = cfg_dst;
            R_SIZE:     rdata_r = cfg_size;
            R_SS:       rdata_r = cfg_ss;
            R_DS:       rdata_r = cfg_ds;
            R_COLOR:    rdata_r = cfg_color;
            R_ALPHA:    rdata_r = cfg_alpha;
            R_KEY:      rdata_r = cfg_key;
            R_CX:       rdata_r = cfg_cx;
            R_CY:       rdata_r = cfg_cy;
            R_DONE:     rdata_r = core_done_cnt;
            R_ERRADDR:  rdata_r = core_err_addr;
            R_FBBASE:   rdata_r = reg_fb_base;
            R_FBSTRIDE: rdata_r = reg_fb_stride;
            R_FBSIZE:   rdata_r = reg_fb_size;
            R_FBCFG:    rdata_r = {31'd0, reg_fb_enable};
            R_FBNEXT:   rdata_r = reg_fb_next;
            R_FBSEQ:    rdata_r = reg_fb_seq;
            R_FBCOMMIT: rdata_r = 32'd0;
            R_FBACCEPT: rdata_r = scan_accepted;
            R_SCANST:   rdata_r = {31'd0, scan_blanking};
            R_UNDER:    rdata_r = scan_underruns;
            R_SHOWN:    rdata_r = scan_shown;
            R_AXIERR:   rdata_r = scan_axi_err;
            R_FRAMES:   rdata_r = scan_frames;
            R_LINES:    rdata_r = {16'd0, scan_lines};
            R_SPRTAB:   rdata_r = reg_sp_tab;
            R_SPRCTL:   rdata_r = reg_sp_ctl;
            R_SPRDONE:  rdata_r = 32'd0;
            R_PIXCNT:   rdata_r = core_pix_cnt;
            R_DBG:      rdata_r = dbg_in;
            R_FUROW:    rdata_r = {21'd0, scan_first_under};
            R_DBG2:     rdata_r = {scan_rd_wait_max, scan_rd_gap_max};
            R_DBG3:     rdata_r = {scan_pf_cnt, scan_pf_stall_max};
            R_DBG4:     rdata_r = scan_rd_cyc_sum;
            default:    rdata_r = 32'hDEAD_BEEF;
        endcase
    end
    assign s_rdata = rdata_r;

    // ---------------------------------------------------------------- write side effects
    // A 32-bit store is the only access size the driver uses, so a partial
    // strobe is treated as "write the whole word". Software never sends one;
    // this keeps the logic small without pretending to support byte writes.
    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_op    <= 32'd0;
            cfg_src   <= 32'd0;
            cfg_dst   <= 32'd0;
            cfg_size  <= 32'd0;
            cfg_ss    <= 32'd0;
            cfg_ds    <= 32'd0;
            cfg_color <= 32'd0;
            cfg_alpha <= 32'd0;
            cfg_key   <= 32'd0;
            cfg_cx    <= {DEF_W[15:0], 16'd0};
            cfg_cy    <= {DEF_H[15:0], 16'd0};
            reg_fb_base   <= 32'h0800_0000;
            reg_fb_stride <= 32'd4096;
            reg_fb_size   <= {DEF_H[15:0], DEF_W[15:0]};
            reg_fb_enable <= 1'b0;
            reg_fb_next   <= 32'h0800_0000;
            reg_fb_seq    <= 32'd0;
            reg_sp_tab    <= 32'd0;
            reg_sp_ctl    <= 32'd0;
            irq_en        <= 1'b0;
            cfg_fb_commit <= 1'b0;
            fifo_wp       <= 5'd0;
            fifo_rp       <= 5'd0;
        end else begin
            cfg_fb_commit <= 1'b0;

            if (wr_fire) begin
                case (aw_addr)
                    R_CTRL: begin
                        irq_en <= w_data[1];
                        if (w_data[0] && !fifo_full) begin
                            fifo_mem[fifo_wp[2:0]] <= param_snapshot;
                            fifo_wp <= fifo_wp + 5'd1;
                        end
                    end
                    R_OP:       cfg_op    <= w_data;
                    R_SRC:      cfg_src   <= w_data;
                    R_DST:      cfg_dst   <= w_data;
                    R_SIZE:     cfg_size  <= w_data;
                    R_SS:       cfg_ss    <= w_data;
                    R_DS:       cfg_ds    <= w_data;
                    R_COLOR:    cfg_color <= w_data;
                    R_ALPHA:    cfg_alpha <= w_data;
                    R_KEY:      cfg_key   <= w_data;
                    R_CX:       cfg_cx    <= w_data;
                    R_CY:       cfg_cy    <= w_data;
                    R_FBBASE:   reg_fb_base   <= w_data;
                    R_FBSTRIDE: reg_fb_stride <= w_data;
                    R_FBSIZE:   reg_fb_size   <= w_data;
                    R_FBCFG:    reg_fb_enable <= w_data[0];
                    R_FBNEXT:   reg_fb_next   <= w_data;
                    R_FBSEQ:    reg_fb_seq    <= w_data;
                    R_FBCOMMIT: cfg_fb_commit <= w_data[0];
                    R_SPRTAB:   reg_sp_tab    <= w_data;
                    R_SPRCTL:   reg_sp_ctl    <= w_data;
                    default:    ;
                endcase
            end

            if (pop_fire) fifo_rp <= fifo_rp + 5'd1;
        end
    end

    // ---------------------------------------------------------------- bus FSM registers
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_have  <= 1'b0;
            aw_addr  <= 8'd0;
            w_have   <= 1'b0;
            w_data   <= 32'd0;
            w_strb   <= 4'd0;
            bvalid_r <= 1'b0;
            r_have   <= 1'b0;
            r_addr   <= 8'd0;
        end else begin
            if (aw_hs) begin aw_have <= 1'b1; aw_addr <= s_awaddr; end
            if (w_hs)  begin w_have  <= 1'b1; w_data  <= s_wdata; w_strb <= s_wstrb; end
            if (wr_fire) begin
                aw_have  <= 1'b0;
                w_have   <= 1'b0;
                bvalid_r <= 1'b1;
            end
            if (bvalid_r && s_bready) bvalid_r <= 1'b0;

            if (ar_hs) begin r_have <= 1'b1; r_addr <= s_araddr; end
            if (r_hs)  begin r_have <= 1'b0; end
        end
    end

    // ---------------------------------------------------------------- interrupt
    // DONE_CNT is a free-running counter in the core. Any change is a completion,
    // so a single edge-detect produces one interrupt per finished command without
    // a separate pulse wire crossing the module boundary.
    always @(posedge clk) begin
        if (!rst_n) begin
            done_seen <= 32'd0;
            irq_pend  <= 1'b0;
        end else begin
            done_seen <= core_done_cnt;
            if (core_done_cnt != done_seen) irq_pend <= 1'b1;
            if (r_hs && (r_addr == R_STATUS)) irq_pend <= 1'b0;
        end
    end

endmodule

`default_nettype wire
