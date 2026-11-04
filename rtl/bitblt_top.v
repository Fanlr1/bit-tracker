// BitBlt accelerator top level.
//
// Assembles M1 (registers) + M3 (address generator) + pulse generator +
// two read engines + M4 (4-pixel-per-beat pixel engine) + write engine, per the
// wiring table in docs/12-顶层集成设计.md section 3.
//
// LAYERING
//   This module exposes THREE AXI4 master ports -- read-source, read-destination
//   and write. They are meant to land on three separate Axi_Mux slave ports so
//   the interconnect can separate the engines by AXI ID. The Axi_Mux instance
//   belongs in the system-level top next to the SoC and ddr3_top.
//
//   READ ENGINES ONLY HAVE A READ CHANNEL, so this module exposes only their
//   AR/R pins. The Axi_Mux slave port they land on still has AW/W/B pins; those
//   are tied off in the system top, not here.
//
// SIMPLIFICATION IN THIS REVISION
//   Every mode starts both read engines, including Solid Fill (whose data is
//   discarded). That keeps px_valid = src_valid & dst_valid unconditionally and
//   avoids a mode-dependent valid mux. Cost: one extra DDR read per line, taking
//   utilisation from ~13.8% to ~18.4% of the available 1.6 GB/s. Revisit only if
//   bandwidth becomes the bottleneck.
//
// LINE COMPLETION
//   A line is finished when BOTH read engines AND the write engine report done.
//   Each done is a one-cycle pulse, so they would be missed if simply ANDed --
//   the engines finish on different cycles. Flags are latched and cleared at the
//   next line start. line_ack must be a ONE-CYCLE pulse because M3 advances its
//   line counter on it; a level would skip rows, so ack_sent guards that.
`timescale 1ns / 1ps

module bitblt_top #(
    parameter AXI_DW      = 128,
    parameter AXI_AW      = 32,
    parameter DW          = 32,
    parameter PX_PER_BEAT = 4       // 128 / 32
) (
    input  wire         clk,
    input  wire         rst_n,

    // Is scan-out currently in blanking? Generated in the pixel domain inside
    // bitblt_video_out, synchronised in system_top. Read-only to software, and
    // it exists because blt_set_fb cannot comply on its own: writing FB_CFG
    // during the active region costs the first few pixels of that line and
    // offsets the framebuffer row permanently.
    input  wire         scan_blanking,

    // Scan-out starvation, synchronised in system_top. The sticky bit drives
    // the monitor; the count is exposed read-only so software can judge scale,
    // not just occurrence.
    input  wire         scan_short,
    input  wire [31:0]  scan_short_count,   // was [7:0]; 8 bits saturated at 255
    // scan-out self-proof (docs/67): active lines in the last frame, and frames
    // completed. Passed through to the register file untouched.
    input  wire [15:0]  scan_lines,
    input  wire [31:0]  scan_frames,

    // 2026-10-27: FrameSpeed-style display-health counters.
    input  wire [31:0]  scan_underruns,     // lines that started with an empty FIFO
    input  wire [31:0]  scan_shown,         // complete new frames
    input  wire [31:0]  scan_axi_err,    // RRESP != OKAY (clk domain)

    // ============================================================
    // AXI4 SLAVE -- from the Sapphire SoC at 0xE1000000 (32-bit)
    // ============================================================
    output wire         axi_interrupt,
    input  wire [7:0]   s_axi_awid,
    input  wire [AXI_AW-1:0] s_axi_awaddr,
    input  wire [7:0]   s_axi_awlen,
    input  wire [2:0]   s_axi_awsize,
    input  wire [1:0]   s_axi_awburst,
    input  wire         s_axi_awlock,
    input  wire [3:0]   s_axi_awcache,
    input  wire [2:0]   s_axi_awprot,
    input  wire [3:0]   s_axi_awqos,
    input  wire [3:0]   s_axi_awregion,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wlast,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [7:0]   s_axi_bid,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [7:0]   s_axi_arid,
    input  wire [AXI_AW-1:0] s_axi_araddr,
    input  wire [7:0]   s_axi_arlen,
    input  wire [2:0]   s_axi_arsize,
    input  wire [1:0]   s_axi_arburst,
    input  wire         s_axi_arlock,
    input  wire [3:0]   s_axi_arcache,
    input  wire [2:0]   s_axi_arprot,
    input  wire [3:0]   s_axi_arqos,
    input  wire [3:0]   s_axi_arregion,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [7:0]   s_axi_rid,
    output wire [31:0]  s_axi_rdata,           // 32-bit, matches the register file
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rlast,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,

    // DEBUG 2026-10-13: register-file read-channel state, forwarded to system_top
    // so it can be observed through the SoC GPIO (see bitblt_axi_slave.dbg_observ).
    output wire [3:0]   dbg_observ,

    // DEBUG 2026-10-17: the two read-engine FSMs. A slow-state run reads
    // dbg_observ = 0000 -- no data in either engine, no AR on the bus -- so the
    // engines are stuck INSIDE themselves rather than waiting on DDR. This says
    // where. {u_rd_src.state[1:0], u_rd_dst.state[1:0]}.
    output wire [3:0]   dbg_rd_state,

    // ============================================================
    // AXI4 MASTER 0 -- read source image      -> Axi_Mux S1 (AR/R only)
    // ============================================================
    output wire [7:0]   rd0_arid,
    output wire [AXI_AW-1:0] rd0_araddr,
    output wire [7:0]   rd0_arlen,
    output wire [2:0]   rd0_arsize,
    output wire [1:0]   rd0_arburst,
    output wire         rd0_arlock,
    output wire [3:0]   rd0_arcache,
    output wire [2:0]   rd0_arprot,
    output wire         rd0_arvalid,
    input  wire         rd0_arready,
    input  wire [7:0]   rd0_rid,
    input  wire [AXI_DW-1:0] rd0_rdata,
    input  wire [1:0]   rd0_rresp,
    input  wire         rd0_rlast,
    input  wire         rd0_rvalid,
    output wire         rd0_rready,

    // ============================================================
    // AXI4 MASTER 1 -- read destination row   -> Axi_Mux S2 (AR/R only)
    // ============================================================
    output wire [7:0]   rd1_arid,
    output wire [AXI_AW-1:0] rd1_araddr,
    output wire [7:0]   rd1_arlen,
    output wire [2:0]   rd1_arsize,
    output wire [1:0]   rd1_arburst,
    output wire         rd1_arlock,
    output wire [3:0]   rd1_arcache,
    output wire [2:0]   rd1_arprot,
    output wire         rd1_arvalid,
    input  wire         rd1_arready,
    input  wire [7:0]   rd1_rid,
    input  wire [AXI_DW-1:0] rd1_rdata,
    input  wire [1:0]   rd1_rresp,
    input  wire         rd1_rlast,
    input  wire         rd1_rvalid,
    output wire         rd1_rready,

    // ============================================================
    // AXI4 MASTER 2 -- write back             -> Axi_Mux S3 (AW/W/B only)
    // ============================================================
    output wire [7:0]   wr_awid,
    output wire [AXI_AW-1:0] wr_awaddr,
    output wire [7:0]   wr_awlen,
    output wire [2:0]   wr_awsize,
    output wire [1:0]   wr_awburst,
    output wire         wr_awlock,
    output wire [3:0]   wr_awcache,
    output wire [2:0]   wr_awprot,
    output wire         wr_awvalid,
    input  wire         wr_awready,
    output wire [AXI_DW-1:0] wr_wdata,
    output wire [AXI_DW/8-1:0] wr_wstrb,
    output wire         wr_wlast,
    output wire         wr_wvalid,
    input  wire         wr_wready,
    input  wire [7:0]   wr_bid,
    input  wire [1:0]   wr_bresp,
    input  wire         wr_bvalid,
    output wire         wr_bready,

    // ============================================================
    // status / debug
    // ============================================================
    output wire         busy,
    output wire [15:0]  cur_line,
    output wire [31:0]  dbg_beats_rd,
    output wire [31:0]  dbg_beats_wr,
    output wire         dbg_b_error,

    // ============================================================
    // scan-out configuration, straight out of the register file
    // ============================================================
    // Wired directly to system_top's video module. These come from registers
    // rather than the engine, so they are valid as soon as the SoC writes them
    // and do not depend on the engine's state machine.
    //
    // fb_base being a register is what makes double buffering real: the scan-out
    // can be pointed at the buffer that is not currently being drawn into.
    output wire [31:0]  reg_fb_base,
    output wire [15:0]  reg_fb_width,
    output wire [15:0]  reg_fb_height,
    output wire [15:0]  reg_fb_stride,
    output wire         reg_fb_enable
);

    // ---------------------------------------------------------------
    // M1 register file
    // ---------------------------------------------------------------
    wire [31:0] reg_ctrl, reg_op, reg_src_addr, reg_dst_addr, reg_width_h;
    wire [31:0] reg_src_stride, reg_dst_stride, reg_fill_color;
    wire [31:0] reg_alpha, reg_key_color, reg_frame_cnt;
    wire [3:0]  reg_bpp;
    wire        reg_start_pulse;
    wire [31:0] engine_status;
    // P4 sprite table. Internal to this module: the walker lives here and the
    // CPU reaches these over AXI, so they do not need top-level ports.
    wire [31:0] reg_spr_table;
    wire [15:0] reg_spr_count;
    wire        reg_spr_enable;

    // ---------------------------------------------------------------
    // Internal signals used by the instantiation port maps below.
    //
    // These declarations MUST come before the first instantiation.
    // Verilog declares an undeclared identifier as an implicit 1-bit wire,
    // so a signal used in a port connection before its declaration is 1 bit
    // wide at that point. iverilog tolerated it silently (only -Wall named
    // it) and Efinity appears to collect declarations first, but Questa
    // rejected the file outright with "already declared in this scope".
    // Three tools, two behaviours: that is undefined behaviour, so the
    // declarations moved up rather than being left to luck.
    // ---------------------------------------------------------------
    // These two had NO declaration at all and relied on the implicit 1-bit
    // wire. That happens to be the right width here -- st_dbg_req_gated is an
    // AND of three flags and px_in_ready is a single-bit handshake from the
    // pixel engine -- but relying on it is not the same as being correct:
    // 17 of the 19 implicitly declared signals in this file are 16 or 32 bits
    // wide and were being treated as 1 bit at the point of use.
    wire        st_dbg_req_gated;
    wire        px_in_ready;
    wire [31:0] addr_oob_addr;
    wire [15:0] st_rt_sel, st_live_clr_idx;
    wire [31:0] st_rt_word;
    wire        st_live_clr_en;
    wire [31:0] st_dbg_xy;
    wire        st_dbg_valid;
    wire        st_dbg_req;
    wire [15:0] st_dbg_idx;
    wire [15:0] mon_sticky;
    wire [31:0] mon_cnt;
    wire [15:0] mon_clr_mask;
    wire [3:0]  mon_cnt_sel;
    wire        mon_clr_count;
    wire [AXI_DW-1:0] rd_src_data, rd_dst_data;
    wire              rd_src_valid, rd_dst_valid;
    wire              rd_src_done, rd_dst_done;
    wire              rd_src_busy, rd_dst_busy;
    wire [1:0]        rd_src_state, rd_dst_state;   // DEBUG 2026-10-17: fetch FSMs
    wire [2:0]        walk_state;                    // DEBUG 2026-10-17: walk FSM

    bitblt_axi_slave #(
        .ADDR_WIDTH (AXI_AW),
        .DATA_WIDTH (32)
    ) u_regs (
        // DEBUG 2026-10-13: the slave's read-state observation is replaced by the
    // ENGINE's completion state -- that is what is blind right now. The engine
    // stops advancing lines because all_done never asserts, and we cannot tell
    // which of the three DMAs is holding it up.
    .dbg_observ     (),
        .axi_interrupt  (axi_interrupt),
        .axi_aclk       (clk),
        .axi_resetn     (rst_n),
        .axi_awid       (s_axi_awid),
        .axi_awaddr     (s_axi_awaddr),
        .axi_awlen      (s_axi_awlen),
        .axi_awsize     (s_axi_awsize),
        .axi_awburst    (s_axi_awburst),
        .axi_awlock     (s_axi_awlock),
        .axi_awcache    (s_axi_awcache),
        .axi_awprot     (s_axi_awprot),
        .axi_awqos      (s_axi_awqos),
        .axi_awregion   (s_axi_awregion),
        .axi_awvalid    (s_axi_awvalid),
        .axi_awready    (s_axi_awready),
        .axi_wdata      (s_axi_wdata),
        .axi_wstrb      (s_axi_wstrb),
        .axi_wlast      (s_axi_wlast),
        .axi_wvalid     (s_axi_wvalid),
        .axi_wready     (s_axi_wready),
        .axi_bid        (s_axi_bid),
        .axi_bresp      (s_axi_bresp),
        .axi_bvalid     (s_axi_bvalid),
        .axi_bready     (s_axi_bready),
        .axi_arid       (s_axi_arid),
        .axi_araddr     (s_axi_araddr),
        .axi_arlen      (s_axi_arlen),
        .axi_arsize     (s_axi_arsize),
        .axi_arburst    (s_axi_arburst),
        .axi_arlock     (s_axi_arlock),
        .axi_arcache    (s_axi_arcache),
        .axi_arprot     (s_axi_arprot),
        .axi_arqos      (s_axi_arqos),
        .axi_arregion   (s_axi_arregion),
        .axi_arvalid    (s_axi_arvalid),
        .axi_arready    (s_axi_arready),
        .axi_rid        (s_axi_rid),
        .axi_rdata      (s_axi_rdata),
        .axi_rresp      (s_axi_rresp),
        .axi_rlast      (s_axi_rlast),
        .axi_rvalid     (s_axi_rvalid),
        .axi_rready     (s_axi_rready),
        .reg_ctrl       (reg_ctrl),
        .reg_op         (reg_op),
        .reg_src_addr   (reg_src_addr),
        .reg_dst_addr   (reg_dst_addr),
        .reg_width_h    (reg_width_h),
        .reg_src_stride (reg_src_stride),
        .reg_dst_stride (reg_dst_stride),
        .reg_fill_color (reg_fill_color),
        .reg_alpha      (reg_alpha),
        .reg_key_color  (reg_key_color),
        .reg_frame_cnt  (reg_frame_cnt),
        .reg_bpp        (reg_bpp),
        .reg_status     (engine_status),
        .reg_start_pulse(reg_start_pulse),
        .reg_fb_base    (reg_fb_base),
        .reg_fb_width   (reg_fb_width),
        .reg_fb_height  (reg_fb_height),
        .reg_fb_stride  (reg_fb_stride),
        .reg_fb_enable  (reg_fb_enable),
        .reg_spr_table  (reg_spr_table),
        .reg_spr_count  (reg_spr_count),
        .reg_spr_enable (reg_spr_enable),
        // Reclamation loop: software reads the retired bitmap through
        // spr_rt_bits and frees slots through retire_en/idx.
        .reg_spr_rt_sel      (st_rt_sel),
        .spr_rt_bits         (st_rt_word),
        .reg_spr_retire_en   (st_live_clr_en),
        .reg_spr_retire_idx  (st_live_clr_idx),
        // Position read-back: request out, response in.
        .scan_blanking       (scan_blanking),
        // On-chip assertion monitor, read-only to software.
        .mon_sticky          (mon_sticky),
        .scan_short_count    (scan_short_count),
        .scan_lines          (scan_lines),
        .scan_frames         (scan_frames),
        .scan_underruns      (scan_underruns),
        .scan_shown          (scan_shown),
        .scan_axi_err     (scan_axi_err),
        .addr_oob_addr       (addr_oob_addr),
        .mon_cnt             (mon_cnt),
        .reg_mon_clr_mask    (mon_clr_mask),
        .reg_mon_cnt_sel     (mon_cnt_sel),
        .reg_mon_clr_count   (mon_clr_count),
        .reg_spr_pos_req     (st_dbg_req),
        .reg_spr_pos_idx     (st_dbg_idx),
        .spr_pos_xy          (st_dbg_xy),
        .spr_pos_valid       (st_dbg_valid)
    );

    // ---------------------------------------------------------------
    // M3 address generator
    // ---------------------------------------------------------------
    wire        line_req, line_ack;
    wire [1:0]  addr_state;            // DEBUG 2026-10-17: addr_gen FSM state
    wire [AXI_AW-1:0] line_src_addr, line_dst_addr;
    wire [31:0] line_bytes;
    wire [15:0] line_index;
    wire        compact_src;
    wire [31:0] src_bytes_total;
    wire        addr_busy, addr_done, addr_oob;

    // ========================================================================
    // FRAMEBUFFER POOL BOUNDS (2026-10-25) -- a real defect, not a tuning.
    // ========================================================================
    // The bounds used to follow reg_fb_base, i.e. they covered ONLY the buffer
    // currently being scanned out. But double buffering draws into the OTHER
    // buffer: the demo sets blt_set_fb(front) and then issues blits to back.
    // Every one of those writes fell outside the window and was silently
    // rejected by addr_gen oob path -- addr_oob latched, the blit did nothing,
    // and the CPU went on believing it had drawn.
    //
    // Measured on the board with the scan-out on buf[1] (0x08438000):
    //     DBG cfg fb=0x08438000 ... oob=0x083e8db8
    // 0x083e8db8 is buf[0] row 1000 -- a valid framebuffer address, rejected
    // purely because it sits below fb_base. The visible symptom is old content
    // in the rows that were skipped and current animation in the rows that
    // happened to fall inside the window.
    //
    // The bounds must cover the WHOLE POOL, not the displayed buffer.
    // FB_POOL_BASE is the constant system_top anchors buf[0] at; the pool is
    // two frames back to back.
    localparam [31:0] FB_POOL_BASE = 32'h0800_0000;
    wire [31:0] frame_bytes   = {16'd0, reg_fb_height} * {16'd0, reg_fb_stride};
    wire [31:0] fb_start_addr = FB_POOL_BASE;
    wire [31:0] fb_end_addr   = FB_POOL_BASE + (frame_bytes << 1);

    // ---------------------------------------------------------------
    // P4 sprite walker -- see bitblt_sprite_walker.v
    // ---------------------------------------------------------------
    // While the walker is running it owns the geometry inputs; the register
    // file owns them otherwise. spr_busy is high for the whole walk (not just
    // during one blit), so a register write that lands mid-walk cannot corrupt
    // a sprite that is about to be dispatched.
    //
    // NOTE: this step adds structure only. enable comes straight from the
    // register and SPR_CTL resets to 0, so reg_spr_enable is low until software
    // writes it -- the regression must pass completely unchanged, which is what
    // proves the added muxes are transparent while the walker is idle. The
    // fetch side is deliberately still tied off (see the walker instance), so
    // even with enable set the walker cannot yet issue anything.
    wire spr_busy, spr_blit_start, spr_fetch_start, spr_fetch_active;
    wire spr_clr_busy;      // the state table is mid-clear; hold the walker off
    wire [AXI_AW-1:0] spr_src, spr_dst, spr_src_stride, spr_fetch_addr;
    wire [15:0] spr_w, spr_h, spr_index;
    wire spr_done_pulse;

    // Live sprite state: position and velocity, advanced once per frame.
    wire        st_init_en, st_rd_valid, st_rd_live, st_step_en, st_frame_done;
    wire [15:0] st_init_idx, st_init_x, st_init_y, st_init_vx, st_init_vy;
    wire [15:0] st_rd_x, st_rd_y;
    // Reclamation: software selects a retired-bitmap word, reads it, and frees
    // the slots it finds. st_rt_word is the one signal flowing from the engine
    // back into the register file.
    // Software position read-back. st_dbg_req is gated below so it can never
    // fire while the walker owns the RAM read port.
    wire        st_stepping;
    // Driven by the register file: reg_spr_pos_req is a one-cycle pulse when
    // software writes SPR_POS_IDX, and reg_spr_pos_idx is the slot it named.
    // On-chip assertion monitor (bitblt_monitor.v). Read-only: it taps signals
    // and drives nothing, so it cannot change the behaviour it watches.

    // 256 slots: 64 bits each is 16 Kbit, against the 30 Kbit that the three
    // RAM10 blocks for this shape provide, so the depth increase should cost no
    // additional RAM. IW stays 16 so the walker's index ports are unchanged.
    // ---------------------------------------------------------------
    // On-chip assertion monitor -- read-only, see bitblt_monitor.v
    // ---------------------------------------------------------------
    // Every condition here is invisible on a screen and unasked-for by a
    // driver: a wedged handshake, a non-OKAY response, a walk that never
    // finishes, a read-back request silently discarded. Each gets a sticky bit
    // and a saturating counter that software can read.
    bitblt_monitor #(.TIMEOUT(16'd65535)) u_monitor (
        .clk            (clk),
        .rst_n          (rst_n),

        .rd0_arvalid    (rd0_arvalid),
        .rd0_arready    (rd0_arready),
        .rd0_rvalid     (rd0_rvalid),
        .rd0_rready     (rd0_rready),
        .rd0_rresp      (rd0_rresp),

        .rd1_arvalid    (rd1_arvalid),
        .rd1_arready    (rd1_arready),
        .rd1_rvalid     (rd1_rvalid),
        .rd1_rready     (rd1_rready),
        .rd1_rresp      (rd1_rresp),

        .wr_awvalid     (wr_awvalid),
        .wr_awready     (wr_awready),
        .wr_wvalid      (wr_wvalid),
        .wr_wready      (wr_wready),
        .wr_bvalid      (wr_bvalid),
        .wr_bready      (wr_bready),
        .wr_bresp       (wr_bresp),

        .scan_short     (scan_short),
        .spr_busy       (spr_busy),
        // The request as software issued it, and the copy that actually
        // reached the state block. When they differ, a request was discarded
        // by the idle gate -- which the driver currently cannot detect.
        .pos_req        (st_dbg_req),
        .pos_req_gated  (st_dbg_req_gated),

        .clr_mask       (mon_clr_mask),
        .clr_count      (mon_clr_count),
        .sticky_word    (mon_sticky),
        .cnt_sel        (mon_cnt_sel),
        .cnt_word       (mon_cnt)
    );

    // 2026-10-14: N was pinned to 256 HERE, which silently overrode the module
    // default -- raising the default alone changed nothing (the give-away was
    // RAM10 staying at 74 while a 4x-deeper payload RAM should have added
    // several blocks). .IW stays 16: a 10-bit index fits easily.
    // 2026-10-14: 2048 was TRIED here and reverted -- pnr failed with
    // "Not enough physical locations for Logic blocks: capacity=60800
    // usage=62373", i.e. 2.6% over. The whole increase came from u_spr_state
    // (9,072 xlr at N=1024), because ok[idx]/lv[idx] are 2048:1 combinational
    // bit selects. 2048 comes back once those move into RAM.
    //
    // NOTE the instance parameter is what counts: the module default was raised
    // on its own earlier the same day and had NO effect (docs/70; the give-away
    // was RAM10 not moving). .IW stays 16: an 11-bit index fits easily.
    // 2026-10-15: 1024 -> 2048, TOGETHER WITH two synthesis area options in
    // bitblt_system.xml (pack-luts-to-comb4=1, use-logic-for-small-mem=0).
    // The first 2048 attempt failed at 62,373 clusters against a 60,800 limit
    // (2.6% over), and the entire increase came from this module's
    // ok[idx]/lv[idx] combinational bit selects. Try the cheap lever first;
    // only rewrite the state module if the area options are not enough.
    // 2026-10-16 (8192 attack): N=4096 -> 8192. The state module is the explicit-RAM
    // version from work/opt-study/w8192 (bitmap as simple_dual_port_ram), which passes
    // tb_bitblt_sprite_state, tb_bitblt_sprite_walker and tb_bitblt_top at N=8192.
    // Level sweep costs 5 cycles/slot, so a frame tail is 40,960 cycles here.
    bitblt_sprite_state #(.N(8192), .IW(16)) u_spr_state (
        .clk        (clk),
        .rst_n      (rst_n),
        .init_en    (st_init_en),
        .init_idx   (st_init_idx),
        .init_x     (st_init_x),
        .init_y     (st_init_y),
        .init_vx    (st_init_vx),
        .init_vy    (st_init_vy),
        .rd_idx     (spr_index),
        .rd_x       (st_rd_x),
        .rd_y       (st_rd_y),
        .rd_valid   (st_rd_valid),
        .rd_live    (st_rd_live),
        // Screen bounds for automatic retirement. These are the same registers
        // the scan-out uses, so a sprite is retired against the display that is
        // actually being scanned -- including when double buffering switches
        // geometry.
        .fb_w       (reg_fb_width),
        .fb_h       (reg_fb_height),
        .step_en    (st_step_en),
        .frame_done (st_frame_done),
        // Retiring a slot is software's job, and its interface (which register
        // carries the index) belongs with the launch path. Tied off here so
        // the port exists and the walk is unchanged; nothing retires anything
        // until that register is added.
        .rt_sel       (st_rt_sel),
        .rt_word      (st_rt_word),
        // Position read-back. THE GATE IS THE POINT: the RAM has one read port,
        // and the walker drives it from cur_index continuously while it runs.
        // Letting a read-back steal an address cycle would make the walker load
        // the wrong slot's position -- a sprite would be drawn at another
        // sprite's coordinates, and nothing would report an error. So a request
        // is only forwarded when the walker is idle.
        .dbg_req      (st_dbg_req_gated),
        .dbg_idx      (st_dbg_idx),
        .dbg_xy       (st_dbg_xy),
        .dbg_valid    (st_dbg_valid),
        .stepping     (st_stepping),
        .live_clr_en  (st_live_clr_en),
        .live_clr_idx (st_live_clr_idx),
        // Clearing the enable re-arms the table, so software can hand over a
        // fresh sprite set without a reset.
        .clr_valid  (~reg_spr_enable),
        // ok now lives in the payload RAM, so the re-arm clear takes N cycles
        // instead of one. This reports it; see the walker's enable below.
        .clr_busy   (spr_clr_busy)
    );

    wire spr_owns = reg_spr_enable & spr_busy;

    wire [AXI_AW-1:0] eff_src_base   = spr_owns ? spr_src        : reg_src_addr;
    wire [AXI_AW-1:0] eff_dst_base   = spr_owns ? spr_dst        : reg_dst_addr;
    wire [15:0]       eff_img_w      = spr_owns ? spr_w          : reg_width_h[15:0];
    wire [15:0]       eff_img_h      = spr_owns ? spr_h          : reg_width_h[31:16];
    wire [AXI_AW-1:0] eff_src_stride = spr_owns ? spr_src_stride : reg_src_stride;
    wire              eff_start      = reg_start_pulse | spr_blit_start;

    bitblt_sprite_walker #(.AW(AXI_AW)) u_walker (
        .clk            (clk),
        .rst_n          (rst_n),
        .table_base     (reg_spr_table),
        .sprite_count   (reg_spr_count),
        // GATED BY THE CLEAR WALK. blt_spr_arm disarms then re-arms tens of
        // cycles later, so clr_valid (a level) is only high briefly -- but the
        // clear of the payload RAM's validity bits needs N cycles. Without
        // this gate the walker would start on a half-cleared table and draw
        // sprites from the previous set at their stale positions.
        //
        // The cost is one frame starting ~20 us late, inside a 16.67 ms budget.
        .enable         (reg_spr_enable & ~spr_clr_busy),
        .bytes_per_px   (reg_bpp),
        .dst_stride     (reg_dst_stride),
        .fb_base        (reg_fb_base),
        .fetch_start    (spr_fetch_start),
        .fetch_addr     (spr_fetch_addr),
        .fetch_bytes    (),
        // The source read engine is shared: the walker drives it between
        // blits, the P3 path drives it during one. fetch_active is the
        // arbitrator -- see the muxes on u_rd_src below.
        .fetch_busy     (rd_src_busy),
        .fetch_done     (rd_src_done),
        .fetch_data     (rd_src_data),
        .fetch_valid    (rd_src_valid & spr_fetch_active),
        .blit_start     (spr_blit_start),
        .spr_src        (spr_src),
        .spr_dst        (spr_dst),
        .spr_w          (spr_w),
        .spr_h          (spr_h),
        .spr_src_stride (spr_src_stride),
        .blit_done      (addr_done),
        .st_init_en     (st_init_en),
        .st_init_idx    (st_init_idx),
        .st_init_x      (st_init_x),
        .st_init_y      (st_init_y),
        .st_init_vx     (st_init_vx),
        .st_init_vy     (st_init_vy),
        .st_rd_x        (st_rd_x),
        .st_rd_y        (st_rd_y),
        .st_rd_valid    (st_rd_valid),
        // THE WIRE WAS DRAWN BUT NEVER PLUGGED IN (found 2026-10-08).
        //
        // st_rd_live is declared at line 366 and sprite_state drives it at line
        // 442, but the walker's input of the same name was left off this port
        // map. A dangling input reads as 0, and the walker's S_BLIT state does:
        //
        //     if (st_rd_valid && !st_rd_live) begin   // retired: issue nothing
        //
        // so with the input stuck at 0 EVERY slot looks retired and the walk
        // draws nothing at all. On a board the sprites would simply never appear.
        //
        // WHY NOTHING CAUGHT IT. tb_bitblt_sprite_walker drives st_rd_live
        // itself, so the walker behaved correctly there. tb_bitblt_top left the
        // port unconnected but only counts AXI transactions -- it never checks
        // what was drawn. The failing combination, real rd_live driving a real
        // walk, was covered by neither, and both testbenches passed every run.
        //
        // iverilog -Wall had been reporting it as "dangling input port 32
        // (st_rd_live)" since -Wall was turned on. It sat in the tracked list and
        // I had classified it as a testbench gap. It was not.
        .st_rd_live     (st_rd_live),
        .st_step_en     (st_step_en),
        .st_frame_done  (st_frame_done),
        .busy           (spr_busy),
        .state_o        (walk_state),
        .cur_index      (spr_index),
        .fetch_active   (spr_fetch_active),
        .done_pulse     (spr_done_pulse)
    );

    bitblt_addr_gen #(.AW(AXI_AW)) u_addr (
        .clk           (clk),
        .rst_n         (rst_n),
        .ce            (1'b1),
        .src_base      (eff_src_base),
        .dst_base      (eff_dst_base),
        .img_width     (eff_img_w),
        .img_height    (eff_img_h),
        .src_stride    (eff_src_stride),
        .dst_stride    (reg_dst_stride),
        .bytes_per_px  (reg_bpp),
        .fb_start      (fb_start_addr),
        .fb_end        (fb_end_addr),
        .start         (eff_start),
        .busy          (addr_busy),
        .done          (addr_done),
        .oob           (addr_oob),
        .oob_addr      (addr_oob_addr),
        .line_src_addr (line_src_addr),
        .line_dst_addr (line_dst_addr),
        .line_bytes    (line_bytes),
        .compact_src   (compact_src),
        .src_bytes_total(src_bytes_total),
        .line_index    (line_index),
        .state_o       (addr_state),
        .line_req      (line_req),
        .line_ack      (line_ack)
    );

    // ---------------------------------------------------------------
    // level -> pulse: one start pulse per line, shared by all engines
    // ---------------------------------------------------------------
    wire line_start;
    bitblt_pulse_gen u_pulse (
        .clk   (clk),
        .rst_n (rst_n),
        .level (line_req),
        .pulse (line_start)
    );

    // ========================================================================
    // LINE-START RETRIGGER (2026-10-17) -- the fix for the walker deadlock.
    //
    // line_req is a LEVEL that addr_gen holds until line_ack comes back, but
    // u_pulse only emits ONE pulse, on the rising edge. If that single pulse
    // arrives while a DMA engine is still busy (not in S_IDLE), the start is
    // simply ignored -- and because line_req stays high, the pulse generator never
    // produces another one. The transfer then deadlocks exactly as observed:
    //
    //     dma_rd never started -> no done -> no line_ack
    //       -> addr_gen parked in S_LINE (busy high, line_req high)
    //       -> addr_gen.done never pulses
    //       -> walker parked in S_RUN (32/32 histogram samples)
    //       -> spr_busy stays high -> STATUS[0] never falls -> blt_wait times out
    //
    // The monitor confirms it as C_SPR_HANG (sticky bit 8, walker busy > 200 M).
    //
    // Fix: keep re-issuing the start every 16 cycles while the request is still
    // outstanding. line_index does not advance until line_ack, so every retrigger
    // addresses the same row -- a duplicate start while an engine is already busy
    // is harmless (it is ignored, which is precisely why the retrigger is safe).
    // ========================================================================
    reg [3:0] line_retrig_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          line_retrig_cnt <= 4'd0;
        else if (!line_req || line_ack)      line_retrig_cnt <= 4'd0;
        else                                 line_retrig_cnt <= line_retrig_cnt + 4'd1;
    end
    wire line_start_retrig = (line_retrig_cnt == 4'd15);
    wire line_start_eff    = line_start | line_start_retrig;

    // ---------------------------------------------------------------
    // Source read start (P3)
    // ---------------------------------------------------------------
    // With a compact source the read engine is handed the whole rectangle, so
    // it must be started ONCE, not once per row. All the other engines still
    // start per row, unchanged.
    //
    // line_index is the row being started and is 0 exactly on the first
    // line_req of a transfer, so this needs no extra state.
    // 2026-10-17: "START ONCE" MUST BE A LATCH, NOT "line_index == 0".
    //
    // With a compact source the read engine is handed the whole rectangle and is
    // meant to start exactly once, on the first line. That was keyed on
    // line_index == 0 -- but line_index advances as soon as the FIRST line is
    // acknowledged, so if the single start pulse for line 0 is ever missed the
    // condition can never be true again and the source engine is never started at
    // all. That is exactly what the probes found:
    //
    //   addr_gen parked in S_LINE, line_req high, line_ack low   (32/32 samples)
    //   f_src = 0  while  f_dst = 1                              (32/32 samples)
    //   rd_src sits in S_IDLE, rd_dst already finished
    //   walker parked in S_RUN, monitor reports C_SPR_HANG
    //
    // A latch remembers "already started" independently of which line is current,
    // and is cleared at the beginning of every transfer, so a retrigger can still
    // deliver the start.
    reg src_started;
    reg [15:0] src_row_last;   // last line_index this read engine was started for
    // 2026-10-25: THE RETRIGGER AND THE LATCH ARE NOW CONNECTED.
    // Between 2026-10-24 and today line_start_retrig / line_start_eff were
    // DECLARED AND NEVER USED (bisect step 1 reverted the condition but left the
    // generator in place), so the slow-state defect described above was fully
    // back. That is not a hypothesis: tb_bitblt_top's P4 walk dispatched 3
    // sprites and issued ZERO source bursts, and the board shows the same shape
    // (DBG wto st=00000001, walker parked in S_RUN).
    //
    // The retrigger alone is NOT safe, which is why the earlier attempt produced
    // a 959,128-pixel copy-readback regression: line_req stays high until every
    // engine has acknowledged, so a retrigger that fires in the gap between one
    // engine finishing and line_ack arriving can start the SAME row a second
    // time, and the duplicate beats shift every pixel that follows.
    //
    // src_row_last closes that hole: a start is issued at most ONCE per
    // line_index. A lost start is recovered (the line has not been started yet,
    // so a retrigger is accepted), and a completed start cannot be repeated (the
    // row is already remembered). compact_src keeps its once-per-transfer latch
    // for the same reason it always had one.
    wire src_start = line_start_eff & (~compact_src | ~src_started)
                                    & (src_row_last != line_index);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              src_started <= 1'b0;
        else if (eff_start)      src_started <= 1'b0;          // new transfer
        else if (src_start)      src_started <= 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              src_row_last <= 16'hFFFF;
        else if (eff_start)      src_row_last <= 16'hFFFF;
        else if (src_start)      src_row_last <= line_index;
    end
    // 2026-10-17: BOTH halves are required -- each was tried alone and each alone
    // left f_src = 0 (verified on hardware).
    //   * line_start fires ONLY on the rising edge of line_req, and line_req then
    //     stays high for the whole row, so there is no second pulse to catch;
    //   * and the "start once" condition has to be a latch, not line_index == 0.
    // Retrigger supplies the pulse, the latch lets it through.
    // (src_start is defined above, next to the latch it depends on.)

    // 2026-10-17: QUANTIFY THE HANDOFF. Two attempts at this fix have failed
    // on hardware, so stop guessing about conditions and count events instead.
    // src_start_cnt counts how many times the source engine was actually asked to
    // start (saturating, never cleared -- this is a "did it ever happen" counter).
    //   * cnt = 0  with f_src = 0  => the start was never issued at all
    //   * cnt > 0  with f_src = 0  => it WAS issued and the read engine ignored it
    // which points at completely different code.
    reg [15:0] src_start_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     src_start_cnt <= 16'd0;
        else if (src_start)             src_start_cnt <= (src_start_cnt == 16'hFFFF)
                                                         ? src_start_cnt : src_start_cnt + 16'd1;
    end

    // ---------------------------------------------------------------
    // Destination read: read the WHOLE rectangle in one start (plan A)
    // ---------------------------------------------------------------
    // The source side got this treatment in P3 ("compact source") and the
    // target side never did, even though it is the side that pays for it most
    // often: a sprite's destination rows are strided, so the engine used to be
    // restarted once per row. Measured on hardware (docs/72) that restart
    // costs ~106 cycles per row no matter how little data the row carries --
    // for a 16x16 sprite, 16 x 106 = 1,693 of its 1,966 cycles, 86%.
    //
    // The read engine now takes (row_bytes, row_stride) and walks the rows
    // itself, so the AR for row N+1 is issued while row N's data is still
    // coming back and the round trip stops being exposed 16 times.
    //
    // WHEN NOT TO: a destination whose rows are already adjacent
    // (dst_stride == line_bytes) is one contiguous run and already optimal --
    // sending it through the row machinery would only add a jump per row for
    // no gain. A single-row rectangle is likewise one run. Both cases fall
    // back to exactly the old behaviour.
    wire dst_multirow = (line_bytes != 32'd0) &&
                        (eff_img_h > 16'd1) &&
                        (reg_dst_stride != line_bytes);

    wire [31:0] dst_bytes_total = dst_multirow
                                ? ({16'd0, eff_img_h} * line_bytes)
                                : line_bytes;

    // Started once, like the compact source, and for the same reason: the
    // engine is handed the whole rectangle.
    // Same defect on the target side, same fix (see src_start above).
    reg dst_started;
    reg [15:0] dst_row_last;   // last line_index this read engine was started for
    // Same pairing as src_start: retrigger supplies the pulse, the per-row latch
    // makes it fire at most once per line_index, so a recovered start cannot
    // become a duplicated one (the 959,128-pixel regression).
    wire dst_start = line_start_eff & (~dst_multirow | ~dst_started)
                                    & (dst_row_last != line_index);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              dst_started <= 1'b0;
        else if (eff_start)      dst_started <= 1'b0;
        else if (dst_start)      dst_started <= 1'b1;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              dst_row_last <= 16'hFFFF;
        else if (eff_start)      dst_row_last <= 16'hFFFF;
        else if (dst_start)      dst_row_last <= line_index;
    end
    // (dst_start is defined above, next to the latch it depends on.)

    // ==================================================================
    // COPY / FILL skip the destination read -- SOFTWARE-INITIATED ONLY
    // ==================================================================
    // pixel_engine's COPY passes the source through and FILL uses a register, so
    // neither reads in_bg: the destination read is 16.31 of 38.99 round trips
    // per sprite (41.8%, docs/80) spent on discarded data. Measured on board:
    // full-screen fill 1,313,03x -> 1,065,70x cycles/frame, 5 runs against 5.
    //
    // spr_owns IS DELIBERATELY EXCLUDED. The same change applied to the sprite
    // (walker) path produced 3 runs that all landed in the intermittent "slow
    // state" (440,002,xxx cycles/frame), while the unmodified baseline showed
    // one healthy run out of three. That is not enough evidence to call it a
    // regression (3 vs 3, ~30% chance of coincidence), but it is more than
    // enough to keep it away from a path we cannot currently measure reliably.
    // The sprite path keeps the destination read exactly as before.
    wire bg_needed       = (reg_op[2:0] > 3'd1);
    wire dst_start_g     = dst_start & bg_needed;
    wire rd_dst_done_eff = bg_needed ? rd_dst_done : 1'b1;

    // ---------------------------------------------------------------
    // two read engines
    // ---------------------------------------------------------------
    wire              rd_src_ready, rd_dst_ready;

    // ---------------------------------------------------------------
    // Shared source read engine: the walker and the P3 path take turns
    // ---------------------------------------------------------------
    // Axi_Mux has no free slave port, so a descriptor fetch borrows the source
    // read engine instead of adding a sixth master. The two are mutually
    // exclusive by construction: the walker only fetches BETWEEN blits, which
    // is exactly when the source reader is idle. spr_fetch_active is the
    // arbitrator, and these three muxes plus the valid gate in the pixel path
    // are the entire mechanism.
    wire        eff_re_start = src_start | spr_fetch_start;
    wire [AXI_AW-1:0] eff_re_base  = spr_fetch_active ? spr_fetch_addr : line_src_addr;
    wire [31:0] eff_re_bytes       = spr_fetch_active ? 32'd16        : src_bytes_total;

    bitblt_dma_rd #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW), .AXI_ID(8'h18)) u_rd_src (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (eff_re_start),
        .base_addr    (eff_re_base),
        .total_bytes  (eff_re_bytes),
        // The source side is already read as one run whenever it is compact
        // (P3), so this instance never needs the strided multi-row mode.
        .row_bytes    (32'd0),
        .row_stride   ({AXI_AW{1'b0}}),
        .busy         (rd_src_busy),
        .state_o      (rd_src_state),
        .done         (rd_src_done),
        .dout         (rd_src_data),
        .dout_valid   (rd_src_valid),
        .dout_ready   (rd_src_ready),
        .beats_sent   (dbg_beats_rd),
        .m_axi_arid   (rd0_arid),
        .m_axi_araddr (rd0_araddr),
        .m_axi_arlen  (rd0_arlen),
        .m_axi_arsize (rd0_arsize),
        .m_axi_arburst(rd0_arburst),
        .m_axi_arlock (rd0_arlock),
        .m_axi_arcache(rd0_arcache),
        .m_axi_arprot (rd0_arprot),
        .m_axi_arvalid(rd0_arvalid),
        .m_axi_arready(rd0_arready),
        .m_axi_rid    (rd0_rid),
        .m_axi_rdata  (rd0_rdata),
        .m_axi_rresp  (rd0_rresp),
        .m_axi_rlast  (rd0_rlast),
        .m_axi_rvalid (rd0_rvalid),
        .m_axi_rready (rd0_rready)
    );

    bitblt_dma_rd #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW), .AXI_ID(8'h1A)) u_rd_dst (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (dst_start_g),
        .base_addr    (line_dst_addr),
        .total_bytes  (dst_bytes_total),
        .row_bytes    (dst_multirow ? line_bytes : 32'd0),
        .row_stride   (reg_dst_stride),
        .busy         (rd_dst_busy),
        .state_o      (rd_dst_state),
        .done         (rd_dst_done),
        .dout         (rd_dst_data),
        .dout_valid   (rd_dst_valid),
        .dout_ready   (rd_dst_ready),
        .beats_sent   (),
        .m_axi_arid   (rd1_arid),
        .m_axi_araddr (rd1_araddr),
        .m_axi_arlen  (rd1_arlen),
        .m_axi_arsize (rd1_arsize),
        .m_axi_arburst(rd1_arburst),
        .m_axi_arlock (rd1_arlock),
        .m_axi_arcache(rd1_arcache),
        .m_axi_arprot (rd1_arprot),
        .m_axi_arvalid(rd1_arvalid),
        .m_axi_arready(rd1_arready),
        .m_axi_rid    (rd1_rid),
        .m_axi_rdata  (rd1_rdata),
        .m_axi_rresp  (rd1_rresp),
        .m_axi_rlast  (rd1_rlast),
        .m_axi_rvalid (rd1_rvalid),
        .m_axi_rready (rd1_rready)
    );

    // ---------------------------------------------------------------
    // M4 pixel engine (4 pixels per beat)
    // ---------------------------------------------------------------
    wire [AXI_DW-1:0]      px_data;
    wire [PX_PER_BEAT-1:0] px_be;
    wire                   px_valid, px_ready;

    // both read streams must be present before the engine works on a beat
    //
    // SPRITE FETCH GATE: while the walker is fetching a descriptor the source
    // engine is carrying that descriptor, not pixels. Without this gate the
    // pixel engine would happily blend a descriptor word into the framebuffer
    // -- silently, since a descriptor is just 16 bytes that look like data.
    // The gate is the whole reason the shared read engine is safe.
    // ==================================================================
    // 565 CONVERSION STAGE (docs/83 stage 3, docs/85)
    // ==================================================================
    // The framebuffer is RGB565 (2 B/pixel), so one 128-bit beat carries EIGHT
    // pixels, while the pixel engine works on FOUR 32-bit pixels per clock.
    // The unpackers turn one beat into two clock's worth of pixels; the packer
    // turns two of the engine's beats back into one.
    //
    // WHY EACH READER IS GATED ONLY BY ITS OWN UNPACKER
    //   The obvious-looking alternative -- gate both readers on "both unpackers
    //   can accept" -- DEADLOCKS, and was tried: the source unpacker fills up
    //   waiting for a destination pixel that cannot arrive because the
    //   destination beat is being held back by the source unpacker's fullness.
    //   The measured symptom was the engine parked mid-transfer with the density
    //   sweep issuing 0 ARs.
    //
    //   Letting the two run independent is safe because an unpacker can only
    //   ever be ONE BEAT ahead: beat_ready is low while a second half is
    //   pending. Pairing is not lost either -- the pixel engine consumes on
    //   (src_px_valid & dst_px_valid), so whichever side arrives early simply
    //   waits, and each unpacker emits its halves in order.
    wire [AXI_DW-1:0] unp_src_px, unp_dst_px;
    wire              unp_src_px_valid, unp_dst_px_valid;
    wire              unp_src_beat_ready, unp_dst_beat_ready;
    wire              unp_src_px_ready, unp_dst_px_ready;

    // The source reader also carries sprite descriptors while the walker fetches
    // one (16 bytes that look exactly like pixel data). Those must NOT be fed
    // through the 565 unpacker -- a descriptor is not eight pixels -- so the
    // unpacker's beat_valid is gated off and the beat goes straight to the
    // walker, which is what .fetch_data below already does.
    bitblt_px565_unpack u_unp_src (
        .clk        (clk),
        .rst_n      (rst_n),
        .beat_valid (rd_src_valid & ~spr_fetch_active),
        .beat_ready (unp_src_beat_ready),
        .beat_data  (rd_src_data),
        .px_valid   (unp_src_px_valid),
        .px_ready   (unp_src_px_ready),
        .px_data    (unp_src_px)
    );

    bitblt_px565_unpack u_unp_dst (
        .clk        (clk),
        .rst_n      (rst_n),
        .beat_valid (rd_dst_valid),
        .beat_ready (unp_dst_beat_ready),
        .beat_data  (rd_dst_data),
        .px_valid   (unp_dst_px_valid),
        .px_ready   (unp_dst_px_ready),
        .px_data    (unp_dst_px)
    );

    wire px_in_valid = bg_needed ? (unp_src_px_valid & unp_dst_px_valid) : unp_src_px_valid;

    // back-pressure is broadcast to both readers -- BUT IT MUST BE MUTUALLY
    // GATED, and that is not cosmetic.
    //
    // Ready used to be broadcast unconditionally:
    //     assign rd_src_ready = px_in_ready;
    //     assign rd_dst_ready = px_in_ready;
    // which is asymmetric with px_in_valid above. When one reader has data and
    // the other does not, px_in_valid is 0 so the pixel engine does NOT consume
    // the beat -- yet both readers are told the beat was taken. The data is
    // silently dropped.
    //
    // The defect was invisible because the two readers were strictly lockstep:
    // same line_start, same line_bytes, same completion, so their valids always
    // arrived together and the AND never mattered. Anything that desynchronises
    // them exposes it -- the compact-source work did exactly that, and the
    // symptom was a write engine waiting forever with din_ready low while the
    // source engine reported every beat delivered.
    //
    // Gating each ready with the OTHER reader's valid means a reader that has
    // data simply holds it until its partner catches up.
    //
    // The spr_fetch_active term lets the source engine hand its beat to the
    // walker instead: during a fetch there is no destination reader running at
    // all, so the interlock above would stall forever without it.
    assign rd_src_ready = spr_fetch_active | unp_src_beat_ready;
    assign rd_dst_ready = unp_dst_beat_ready;

    // A converted beat is consumed only when its PARTNER also has one ready, so
    // the pixel engine always sees a source and a destination pixel of the same
    // index. Without the partner term one side would run ahead by a beat.
    assign unp_src_px_ready = bg_needed ? (px_in_ready & unp_dst_px_valid) : px_in_ready;
    assign unp_dst_px_ready = bg_needed ? (px_in_ready & unp_src_px_valid) : px_in_ready;

    bitblt_pixel_engine #(
        .DW          (DW),
        .PX_PER_BEAT (PX_PER_BEAT)
    ) u_px (
        .clk             (clk),
        .rst_n           (rst_n),
        .ce              (1'b1),
        // 3 bits now: the engine also supports ADD / MUL / SCREEN blends
        .mode            (reg_op[2:0]),
        .fill_color      (reg_fill_color),
        .alpha           (reg_alpha[7:0]),
        .key_color       (reg_key_color),
        .key_use_pixel_a (1'b0),          // global alpha only, for now
        .in_valid        (px_in_valid),
        .in_ready        (px_in_ready),
        .in_fg           (unp_src_px),
        .in_bg           (unp_dst_px),
        .out_valid       (px_valid),
        .out_ready       (px_ready),
        .out_px          (px_data),
        .out_be          (px_be)
    );

    // ---------------------------------------------------------------
    // write engine
    // ---------------------------------------------------------------
    wire wr_done, wr_busy;
    wire wr_din_ready;
    wire wr_b_error;

    // 565: the pack stage assembles the write beat from TWO pixel-engine beats
    // and produces the byte strobes itself. A 16-bit pixel owns TWO byte lanes,
    // so the old "one enable bit -> four lanes" expansion (b*4 +: 4) no longer
    // describes anything; pack565 pairs the enables two at a time instead.
    wire [AXI_DW-1:0]    wr_beat_data;
    wire [AXI_DW/8-1:0]  wr_strb;
    wire                 wr_beat_valid;
    wire                 pack_px_ready;

    bitblt_px565_pack u_pack (
        .clk        (clk),
        .rst_n      (rst_n),
        .px_valid   (px_valid),
        .px_ready   (pack_px_ready),
        .px_data    (px_data),
        .px_be      (px_be),
        .beat_valid (wr_beat_valid),
        .beat_ready (wr_din_ready),
        .beat_data  (wr_beat_data),
        .beat_strb  (wr_strb)
    );

    assign px_ready = pack_px_ready;

    bitblt_dma_wr #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW), .AXI_ID(8'h1C)) u_wr (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (line_start),
        .base_addr     (line_dst_addr),
        .total_bytes   (line_bytes),
        .busy          (wr_busy),
        .done          (wr_done),
        .din           (wr_beat_data),
        .din_strb      (wr_strb),
        .din_valid     (wr_beat_valid),
        .din_ready     (wr_din_ready),
        .beats_taken   (dbg_beats_wr),
        .m_axi_awid    (wr_awid),
        .m_axi_awaddr  (wr_awaddr),
        .m_axi_awlen   (wr_awlen),
        .m_axi_awsize  (wr_awsize),
        .m_axi_awburst (wr_awburst),
        .m_axi_awlock  (wr_awlock),
        .m_axi_awcache (wr_awcache),
        .m_axi_awprot  (wr_awprot),
        .m_axi_awvalid (wr_awvalid),
        .m_axi_awready (wr_awready),
        .m_axi_wdata   (wr_wdata),
        .m_axi_wstrb   (wr_wstrb),
        .m_axi_wlast   (wr_wlast),
        .m_axi_wvalid  (wr_wvalid),
        .m_axi_wready  (wr_wready),
        .m_axi_bid     (wr_bid),
        .m_axi_bresp   (wr_bresp),
        .m_axi_bvalid  (wr_bvalid),
        .m_axi_bready  (wr_bready),
        .m_axi_b_error (wr_b_error)
    );

    // ---------------------------------------------------------------
    // line completion
    // ---------------------------------------------------------------
    reg f_src, f_dst, f_wr, ack_sent;

    // done pulses may arrive on different cycles, so OR them into latched flags
    //
    // COMPACT SOURCE (P3): the source engine is started once and runs for the
    // whole rectangle, so its done arrives only after the LAST row. Waiting for
    // it on every row would leave all_done low for rows 1..h-1, line_ack would
    // never be sent, addr_gen would wait forever and the engine would hang --
    // the same failure the comment below describes for a dropped done pulse,
    // reached from the opposite direction. So when the source is compact its
    // done is excluded from the per-row handshake.
    //
    // This is safe together with the ready interlock above: the surplus source
    // beats are held (not dropped) while the target reader finishes its row,
    // and they flow again once the next row starts.
    //
    // Coverage is still complete: busy includes rd_src_busy, so the engine
    // cannot report completion while the source is still reading.
    //
    // MULTI-ROW TARGET (plan A) -- same reasoning, second instance. When the
    // target reader is handed the whole rectangle its done arrives only after
    // the LAST row, so waiting for it here would leave all_done low for rows
    // 1..h-1 and hang the engine. It is excluded exactly the way the compact
    // source is, and it is safe for the same reason: the target's surplus
    // beats are HELD in its FIFO (dout_ready is gated by the pixel engine, and
    // the pixel engine only consumes when both readers present data), never
    // dropped, so row N still gets its data after row N-1's write finishes.
    //
    // The per-row handshake is then driven by the write engine, which is still
    // started once per row: row N's write cannot even begin until the pixel
    // engine has row N's data.
    wire all_done = (compact_src | f_src | rd_src_done) &
                    (dst_multirow | f_dst | rd_dst_done_eff) &
                    (f_wr  | wr_done);

    // line_ack MUST be a single-cycle pulse: M3 increments its line counter on
    // it, so a level would run through several rows at once.
    assign line_ack = all_done & ~ack_sent;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_src    <= 1'b0;
            f_dst    <= 1'b0;
            f_wr     <= 1'b0;
            ack_sent <= 1'b0;
        end else if (line_start) begin
            // A new line begins: clear the previous line's completion flags --
            // but still capture a done arriving on this very cycle.
            //
            // These used to be two mutually exclusive branches, so a done pulse
            // coinciding with line_start was discarded outright. Because
            // all_done = (f_src | rd_src_done) & ..., losing one leaves all_done
            // permanently low, line_ack is never sent, addr_gen waits for it
            // forever and the engine hangs.
            //
            // Assigning the done signals directly is identical to the old
            // "clear to 0" in normal operation (a done cannot legitimately
            // arrive on the cycle a new line starts) while removing any chance
            // of dropping one.
            f_src    <= rd_src_done;
            f_dst    <= rd_dst_done_eff;
            f_wr     <= wr_done;
            ack_sent <= 1'b0;
        end else begin
            if (rd_src_done) f_src <= 1'b1;
            if (rd_dst_done_eff) f_dst <= 1'b1;
            if (wr_done)     f_wr  <= 1'b1;
            if (line_ack)    ack_sent <= 1'b1;
        end
    end

    // DEBUG 2026-10-13: export the line-completion handshake instead of the
    // slave read state. Read via the SoC GPIO at 0xF8015000 (APB, so it stays
    // readable even when the AXI path is stuck):
    //   bit0 = f_src   (source reader's done latched)
    //   bit1 = f_dst   (destination reader's done latched)
    //   bit2 = f_wr    (write engine's done latched)
    //   bit3 = all_done
    // Switched to BUSY signals: the done flags were all zero, which says "not
    // even the first line finished" but cannot say WHICH engine is stuck.
    //   bit0 = rd_src_busy   bit1 = rd_dst_busy
    //   bit2 = wr_busy       bit3 = addr_busy (line scheduler)
    // Now observing the WRITE ENGINE's AXI handshake -- that is where the chain
    // stops. Axi_Mux accepts a B response only when the target channel drives
    // B_READY (M_B_Ready = |(S_B_Ready & B_Act_Cnl_List)), and bitblt_dma_wr
    // drives B_READY only while its FSM sits in S_RESP.
    //   bit0 = wr_awvalid   bit1 = wr_wvalid
    //   bit2 = wr_bvalid    bit3 = wr_bready
    // The write engine's AXI handshake turned out to be COMPLETELY IDLE, so it
    // is parked in S_WAIT waiting for din_valid. That moves the question one
    // stage upstream: who is failing to produce/consume a beat?
    //   bit0 = rd_src_valid   bit1 = rd_dst_valid
    //   bit2 = px_in_valid    bit3 = px_in_ready
    // That read 1_0_0_1: rd_src HAS data, rd_dst has NONE, consumer is ready.
    // So rd_dst itself is stuck. Its FSM waits in S_AR for arready, or in S_RD
    // for rvalid. This tells us which one.
    //   bit0 = rd1_arvalid   bit1 = rd1_arready
    //   bit2 = rd1_rvalid    bit3 = rd1_rready
    // Reverted to the PIPELINE signals so the effect of the new output FIFO is
    // directly visible: expect rd_src_valid=1 and rd_dst_valid=1 together.
    //   bit0 = rd_src_valid   bit1 = rd_dst_valid
    //   bit2 = px_in_valid    bit3 = px_in_ready
    // 2026-10-17: repurposed for the slow-state hunt. In a slow run the read
    // engines sit in S_IDLE with no ARVALID at all, so they are NOT waiting on a
    // bus handshake -- nothing has started them. That points at the walker, and
    // this is its state: {state[2:0], busy}. IDLE=0 FETCH=1 WAIT=2 BLIT=3
    // RUN=4 STEP=5 ADV=6.
    // 2026-10-17 (second repurposing): THE BUSY BITS.
    //
    // blt_wait() spins until BLT_ST_BUSY falls, bounded at 20,000,000
    // iterations. A slow run measures hw = 440 M cycles for 32 sprites, and
    // 20 M iterations at ~22 cycles each is 440 M -- so in a slow run blt_wait()
    // ALWAYS times out: the engine's done bit never falls.
    //
    // Top-level busy is addr_busy | rd_src_busy | rd_dst_busy | wr_busy |
    // spr_busy. A GPIO sample in the slow state showed the walker IDLE with
    // spr_busy low, and both read engines in S_IDLE with no ARVALID. These are
    // the remaining four -- whichever is stuck high is holding BLT_ST_BUSY up.
    //   bit0 = addr_busy   bit1 = rd_src_busy   bit2 = rd_dst_busy   bit3 = wr_busy
    // 2026-10-17 (third repurposing): THE PIXEL PATH.
    //
    // The busy bits have served their purpose: in a slow run they are LOW at the
    // moment blt_wait() gives up, yet STATUS[0] stayed high for the whole 20 M
    // spin -- so busy is toggling, the engine is retrying, not parked. What
    // matters now is whether data ever reaches the engines at all. The DDR side
    // was caught holding rvalid=1 with rready=0 (the mux refusing data), so:
    //   bit0 = rd_src_valid   bit1 = rd_dst_valid
    //   bit2 = px_in_valid    bit3 = px_in_ready
    // 2026-10-17 (fourth repurposing): BACK TO THE BUSY BITS, but now paired with
    // the read-engine FSMs in observation group 2 so both are captured in the SAME
    // timeout snapshot. The engine is stuck waiting for line_ack, which needs
    // rd_src_done & rd_dst_done_eff & wr_done; whichever producer never finishes is
    // the one whose busy bit stays high while its FSM sits still.
    //   bit0 = addr_busy   bit1 = rd_src_busy   bit2 = rd_dst_busy   bit3 = wr_busy
    // 2026-10-17 (fifth repurposing): THE ONE BUSY BIT NEVER SAMPLED.
    //
    // Top-level busy = addr_busy | rd_src_busy | rd_dst_busy | wr_busy | spr_busy,
    // and blt_wait() times out, so STATUS[0] must be high. A 32-sample histogram in
    // a slow run puts the two read engines in IDLE 31 times out of 32, and the four
    // busy bits below are all low -- leaving spr_busy as the only term that can
    // still hold busy up. It was never sampled at the timeout instant, only later,
    // by which time the walker had settled.
    //   bit3..1 = walker state (IDLE=0 FETCH=1 WAIT=2 BLIT=3 RUN=4 STEP=5 ADV=6)
    //   bit0    = spr_busy
    // 2026-10-17 (final form): THE PIXEL PATH -- what the engines actually have
    // and whether the consumer takes it. A slow run shows the AR arbiter IDLE with
    // Cnl_Search_En=0, i.e. NOBODY IS ASKING for the bus, so the wait must be
    // upstream: an engine that cannot get FIFO space never issues its AR. This is
    // the pair that says so directly.
    //   bit0 = rd_src_valid  bit1 = rd_dst_valid
    //   bit2 = px_in_valid   bit3 = px_in_ready
    // A slow run stuck in admission would show data valid (bit0/1) with the pixel
    // engine not ready (bit3 = 0), or no data at all while the engines wait.
    // 2026-10-17 (final): THE WALKER, now the prime suspect.
    //
    // The monitor's sticky word came back 0x00000100 = C_SPR_HANG: the walker has been
    // continuously busy for over 200 M cycles. That also explains why STATUS[0] never
    // falls -- busy includes spr_busy -- and it supersedes yesterday's "walker is IDLE"
    // reading, which was taken after blt_wait() had already given up.
    //
    // The pixel path agrees from the other side: 32/32 samples read 0x8 =
    // {px_in_ready=1, px_in_valid=0, rd_dst_valid=0, rd_src_valid=0} -- no data
    // anywhere, because the walker never dispatched the blits.
    //   bit3..1 = walker state (IDLE=0 FETCH=1 WAIT=2 BLIT=3 RUN=4 STEP=5 ADV=6)
    //   bit0    = spr_busy
    // 2026-10-17 (final): THE ADDR_GEN HANDOFF. The walker is parked in S_RUN
    // (32/32 histogram samples) waiting for addr_gen.done, so the question is where
    // addr_gen itself sits. Its FSM has four states: IDLE=0 LINE=1 DONE=2 GAP=3.
    // S_LINE is the one that waits for line_ack, and line_ack needs rd_src_done,
    // rd_dst_done_eff and wr_done together -- so "parked in S_LINE with line_req
    // high and line_ack low" would name the missing producer outright.
    //   bit0..1 = addr_gen state
    //   bit2    = line_req      bit3 = line_ack
    // 2026-10-17: WHICH PRODUCER NEVER FINISHES.
    // addr_gen is parked in S_LINE with line_req high and line_ack low (32/32
    // histogram samples). line_ack is gated by three per-row completion flags:
    //   all_done = (compact_src | f_src | rd_src_done)
    //            & (dst_multirow | f_dst | rd_dst_done_eff)
    //            & (f_wr | wr_done);
    // f_* are the latched, level-visible versions of those done pulses, so they
    // survive a histogram sample. Whichever one is still 0 names the engine that
    // never completed its row.
    //   bit0 = f_src   bit1 = f_dst   bit2 = f_wr   bit3 = ack_sent
    // 2026-10-17: {src asked?, f_src, f_dst, ...} to split the last unknown.
    //   bit3 = src_start_cnt != 0   (the source engine was asked to start at least once)
    //   bit2 = src_started          (the latch fired)
    //   bit1 = f_dst                (destination row completed)
    //   bit0 = f_src                (source row completed)
    // If bit3 = 0 the problem is still upstream of the read engine; if bit3 = 1 while
    // bit0 = 0, the read engine itself ignored a request it had been given.
    assign dbg_observ = {|src_start_cnt, src_started, f_dst, f_src};

    // 2026-10-17: read-engine state machines, for the slow-state hunt.
    assign dbg_rd_state = {rd_src_state, rd_dst_state};

    // ---------------------------------------------------------------
    // status back to the register file
    // ---------------------------------------------------------------
    // STATUS[2] is the error bit the driver polls. It now reports either a bad
    // write response or a rectangle that would have written outside the
    // framebuffer -- both are "the engine did not do what you asked".
    // STATUS BIT 2 USED TO CONFLATE TWO DIFFERENT THINGS.
    //
    //   wr_b_error : the B channel handshake went wrong. A real fault.
    //   addr_oob   : the operation lay entirely outside the framebuffer, so
    //                addr_gen wrote nothing. THIS IS NORMAL. A bullet flying off
    //                the screen does exactly this, every frame, by design.
    //
    // With them OR-ed together, a bullet-hell game reports a permanent error:
    // software sees bit 2 set continuously and concludes the engine is broken,
    // when all that happened is that sprites left the screen. The distinction
    // was already drawn in addr_gen's own header -- "a line that would start
    // outside [fb_start, fb_end) ends the transfer" -- it just was not carried
    // through to the status word.
    //
    // [2] is now a genuine error only. [3] reports that clipping happened, which
    // is worth counting but is not a fault. Bit 2 keeps its meaning, so existing
    // drivers see FEWER spurious errors rather than a changed one.
    // 2026-10-14 FIX -- bit 0 was addr_busy, which is ONLY the address
    // generator. The comment immediately below explains that "busy must include
    // the walker", and the wire it describes
    //     busy = addr_busy | rd_src_busy | wr_busy | spr_busy
    // was built for exactly that -- but it was never what software reads.
    // Consequence: while a sprite walk was in flight, a poll of STATUS could see
    // bit 0 low in the gaps BETWEEN sprites and conclude the engine was idle.
    //
    // Found by comparing simulation against the board: the density sweep on
    // hardware reported 256 sprites in ~10.5k cycles while simulation (whose
    // testbench watches the real busy) reported 85.5k. The board had been timing
    // register writes, not the walk.
    assign engine_status = {28'd0, addr_oob, wr_b_error, addr_done, busy};

    // busy must include the walker. Without spr_busy, software polling this
    // sees an idle engine while a whole frame of sprites is being dispatched,
    // and will happily rewrite the table mid-walk or conclude the frame is
    // done. That went unnoticed until a testbench actually waited on busy
    // through a multi-sprite frame; the three-sprite case slept a fixed number
    // of cycles and never asked.
    // rd_dst_busy joined this list with plan A (multi-row target). It used to
    // be redundant: the target reader finished within a cycle or two of the
    // write engine, so wr_busy covered it. Now it runs ahead of the writes
    // across the whole rectangle, so leaving it out would report "idle" while
    // the target reader is still draining -- and the next sprite's start
    // pulse, which arrives from the walker a few dozen cycles later, would be
    // dropped by an engine that was still in S_DONE.
    assign busy         = addr_busy | rd_src_busy | rd_dst_busy | wr_busy | spr_busy;

    // A position read-back may only proceed while the walker is idle AND the
    // frame-end sweep is not mid read-modify-write. spr_busy covers the whole
    // walk (not just one blit), and st_stepping comes from the state block.
    assign st_dbg_req_gated = st_dbg_req & ~spr_busy & ~st_stepping;
    assign cur_line     = line_index;
    assign dbg_b_error  = wr_b_error;

endmodule
