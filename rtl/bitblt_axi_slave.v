// BitBlt AXI4 slave -- register file + command interface for the 2D accelerator.
//
// STRUCTURE follows Efinix's official `axi4_slave.v`
//   (ports match soc.v:487-526 exactly, so it drops straight onto the Sapphire
//    SoC AXI4 slave port at 0xE1000000)
// WHAT CHANGED
//   The official template backs its 4 KB window with a dual-port BRAM. A BitBlt
//   engine needs a handful of control registers instead, so the RAM is replaced
//   by a 16-word register bank (only 12 words are used).
//
// ⚠️ INHERITED QUIRKS (kept deliberately -- the official design is proven against
//    the VexRiscv AXI master, and "fixing" them risks breaking that):
//   1. READ AND WRITE ARE MUTUALLY EXCLUSIVE (single 4-state FSM).
//   2. AW AND W MUST BE VALID IN THE SAME CYCLE (see awreadyReg below).
//   3. axi_rvalid is combinationally gated by axi_rready, which violates the AXI
//      spec. It works with this SoC; do not copy the pattern elsewhere.
//
// REGISTER MAP (word offsets, base 0xE1000000)
//   0x00 CTRL         [0] start (self-clearing pulse) [1] irq_en [2] soft_reset
//   0x04 STATUS       [0] busy [1] done [2] error [3] clipped
//                     -- READ ONLY, driven by engine
//                     [2] is a genuine fault (bad B handshake).
//                     [3] means the operation lay wholly outside the
//                     framebuffer, which is NORMAL -- a sprite leaving the
//                     screen does it every frame. They were OR-ed together
//                     once, which made a bullet-hell game look permanently broken.
//   0x08 OP           0=COPY 1=FILL 2=ALPHA 3=KEYING 4=ADD 5=MUL 6=SCREEN
//   0x0C SRC_ADDR     source base address in DDR3
//   0x10 DST_ADDR     destination base address (framebuffer)
//   0x14 WIDTH_H      [15:0] width  [31:16] height
//   0x18 SRC_STRIDE   source row stride in bytes
//   0x1C DST_STRIDE   destination row stride in bytes
//   0x20 FILL_COLOR   ARGB8888 colour for Solid Fill
//   0x24 ALPHA        global alpha 0..255
//   0x28 KEY_COLOR    transparent colour for Color Keying
//   0x2C FRAME_CNT    completed frame counter (written by engine)
//   0x30 BPP          bytes per pixel (1/2/4/8), reset default 4 = ARGB8888
//   0x34 FB_BASE      scan-out framebuffer base address
//   0x38 FB_SIZE_H    [15:0] width  [31:16] height
//   0x3C FB_CFG       [15:0] stride (bytes/line)  [16] enable
//
//   The three FB_ registers were added so the video scan-out can be pointed at
//   either buffer at runtime. Before this, bitblt_video_out had fb_base tied to
//   a constant in system_top, which meant double buffering could only ever draw
//   into one of the two buffers. Their reset values reproduce those old
//   constants exactly, so existing behaviour is unchanged if nothing writes
//   them.
`timescale 1ns / 1ps

module bitblt_axi_slave #(
    parameter ADDR_WIDTH = 32,
    // DATA_WIDTH is honoured only by the port declarations above. merge_bytes
    // and rdata_mux are written for 32 bits and 4 strobe bytes, so any other
    // value will either fail to elaborate or silently truncate. Treat it as
    // fixed at 32 rather than as a real parameter.
    parameter DATA_WIDTH = 32
) (
    // ---------------- AXI4 slave ----------------
    output wire                     axi_interrupt,
    input  wire                     axi_aclk,
    input  wire                     axi_resetn,

    // AW
    input  wire [7:0]               axi_awid,
    input  wire [ADDR_WIDTH-1:0]    axi_awaddr,
    input  wire [7:0]               axi_awlen,
    input  wire [2:0]               axi_awsize,
    input  wire [1:0]               axi_awburst,
    input  wire                     axi_awlock,
    input  wire [3:0]               axi_awcache,
    input  wire [2:0]               axi_awprot,
    input  wire [3:0]               axi_awqos,
    input  wire [3:0]               axi_awregion,
    input  wire                     axi_awvalid,
    output wire                     axi_awready,
    // W
    input  wire [DATA_WIDTH-1:0]    axi_wdata,
    input  wire [(DATA_WIDTH/8)-1:0] axi_wstrb,
    input  wire                     axi_wlast,
    input  wire                     axi_wvalid,
    output wire                     axi_wready,
    // B
    output wire [7:0]               axi_bid,
    output wire [1:0]               axi_bresp,
    output wire                     axi_bvalid,
    input  wire                     axi_bready,
    // AR
    input  wire [7:0]               axi_arid,
    input  wire [ADDR_WIDTH-1:0]    axi_araddr,
    input  wire [7:0]               axi_arlen,
    input  wire [2:0]               axi_arsize,
    input  wire [1:0]               axi_arburst,
    input  wire                     axi_arlock,
    input  wire [3:0]               axi_arcache,
    input  wire [2:0]               axi_arprot,
    input  wire [3:0]               axi_arqos,
    input  wire [3:0]               axi_arregion,
    input  wire                     axi_arvalid,
    output wire                     axi_arready,
    // R
    output wire [7:0]               axi_rid,
    output wire [DATA_WIDTH-1:0]    axi_rdata,
    output wire [1:0]               axi_rresp,
    output wire                     axi_rlast,
    output wire                     axi_rvalid,
    input  wire                     axi_rready,

    // DEBUG 2026-10-13: read-channel state exported to the SoC GPIO so it can be
    // observed without performing a read on this slave port.
    //   bit0 = rvalidReg    bit1 = arreadyReg
    //   bit2 = axi_rvalid   bit3 = busRead (RD state)
    output wire [3:0]               dbg_observ,

    // ---------------- engine-facing register interface ----------------
    output wire [31:0]              reg_ctrl,
    output wire [31:0]              reg_op,
    output wire [31:0]              reg_src_addr,
    output wire [31:0]              reg_dst_addr,
    output wire [31:0]              reg_width_h,
    output wire [31:0]              reg_src_stride,
    output wire [31:0]              reg_dst_stride,
    output wire [31:0]              reg_fill_color,
    output wire [31:0]              reg_alpha,
    output wire [31:0]              reg_key_color,
    output wire [31:0]              reg_frame_cnt,
    output wire [3:0]               reg_bpp,           // bytes per pixel
    // -------- scan-out configuration (see IDX_FB_* above) --------
    // Unpacked here so bitblt_video_out can use natural-width ports and stay
    // unaware of how the register file packs them.
    output wire [31:0]              reg_fb_base,
    output wire [15:0]              reg_fb_width,
    output wire [15:0]              reg_fb_height,
    output wire [15:0]              reg_fb_stride,
    output wire                     reg_fb_enable,
    // -------- P4 sprite table (consumed by bitblt_sprite_walker) --------
    // These stay internal to bitblt_top: the walker is instantiated there, and
    // the CPU reaches these through AXI, so system_top has no reason to see
    // them. Unpacked rather than exposing SPR_CTL whole, for the same reason
    // the FB registers are unpacked -- the consumer should not need to know
    // how the register file packs its bits.
    output wire [31:0]              reg_spr_table,
    output wire [15:0]              reg_spr_count,
    output wire                     reg_spr_enable,
    // -------- retired-slot bitmap window (P4 reclamation) --------
    // spr_rt_bits is an INPUT: the bitmap lives with the sprite state, and
    // this is how software reads it back. Everything else in this file flows
    // outward, so this one is worth flagging.
    output wire [15:0]              reg_spr_rt_sel,
    input  wire [31:0]              spr_rt_bits,
    // One-cycle pulse plus the slot index: free that slot for reuse.
    output wire                     reg_spr_retire_en,
    output wire [15:0]              reg_spr_retire_idx,
    // -------- scan-out status --------
    input  wire                     scan_blanking,     // clk domain, synchronised
    // -------- on-chip assertion monitor --------
    input  wire [31:0]              scan_short_count,  // was [7:0] -- docs/64
    input  wire [15:0]              scan_lines,        // active lines, last frame
    input  wire [31:0]              scan_frames,       // frames completed
    // 2026-10-27: display-health counters, read at 0x80/0x84/0x88.
    input  wire [31:0]              scan_underruns,    // lines with no data at x=0
    input  wire [31:0]              scan_shown,        // complete new frames
    input  wire [31:0]              scan_axi_err,   // RRESP != OKAY
    input  wire [31:0]              addr_oob_addr,
    input  wire [15:0]              mon_sticky,
    input  wire [31:0]              mon_cnt,
    output wire [15:0]              reg_mon_clr_mask,
    output wire [3:0]               reg_mon_cnt_sel,
    output wire                     reg_mon_clr_count,
    // -------- position read-back --------
    output wire                     reg_spr_pos_req,   // one-cycle pulse on write
    output wire [15:0]              reg_spr_pos_idx,
    input  wire [31:0]              spr_pos_xy,        // {y, x} from the state block
    input  wire                     spr_pos_valid,
    input  wire [31:0]              reg_status,        // driven by the engine
    output wire                     reg_start_pulse    // one-cycle pulse on CTRL[0] write
);

    // ---------------------------------------------------------------
    // Register indices (word offset within the 64-byte window)
    // ---------------------------------------------------------------
    // Register index is now 5 bits (address bits [6:2]) so that 32 registers
    // are decodable. The original 16 filled 0x00..0x3C exactly, leaving no room
    // for the sprite-table interface P4 needs. Widening by one address bit
    // cannot disturb the existing 16: every one of them has bit 6 clear, so
    // their indices are unchanged.
    localparam [4:0] IDX_CTRL       = 5'h00,
                     IDX_STATUS     = 5'h01,   // read-only
                     IDX_OP         = 5'h02,
                     IDX_SRC_ADDR   = 5'h03,
                     IDX_DST_ADDR   = 5'h04,
                     IDX_WIDTH_H    = 5'h05,
                     IDX_SRC_STRIDE = 5'h06,
                     IDX_DST_STRIDE = 5'h07,
                     IDX_FILL_COLOR = 5'h08,
                     IDX_ALPHA      = 5'h09,
                     IDX_KEY_COLOR  = 5'h0A,
                     IDX_FRAME_CNT  = 5'h0B,
                     IDX_BPP        = 5'h0C,   // 0x30, bytes per pixel
                     // ---- scan-out configuration (added for the video path) ----
                     // Five values are needed but only three index slots were
                     // left, so they are packed the same way IDX_WIDTH_H already
                     // packs a pair of 16-bit values. Reusing the existing
                     // convention is less error-prone than inventing a new layout,
                     // and it avoids widening the index from [5:2] to [6:2] --
                     // which would have touched every register's decode logic.
                     IDX_FB_BASE    = 5'h0D,   // 0x34
                     IDX_FB_SIZE_H  = 5'h0E,   // 0x38  [15:0] width  [31:16] height
                     IDX_FB_CFG     = 5'h0F,   // 0x3C  [15:0] stride [16] enable

                     // ---------------------------------------------------------
                     // P4 sprite-table interface.
                     //
                     // SCOPE, STATED PLAINLY: these two registers are the
                     // INTERFACE ONLY. Nothing consumes them yet -- there is no
                     // descriptor reader and no traversal engine, so writing
                     // them changes no behaviour. They exist so the register
                     // map stops being the blocker, and they are covered by a
                     // testbench that proves they read back and that adding
                     // them did not disturb any of the existing 16.
                     //
                     // What P4 still needs: a descriptor reader (the sprite
                     // table fetched over AXI), state storage (position,
                     // velocity, lifetime per sprite), and a traversal engine
                     // that walks the table and drives the existing BitBlt
                     // datapath once per sprite.
                     // ---------------------------------------------------------
                     IDX_SPR_TABLE  = 5'h10,   // 0x40  sprite descriptor table base
                     IDX_SPR_CTL    = 5'h11,   // 0x44  [15:0] count  [16] enable
                     // -------- slot reclamation (P4) --------
                     // Retirement is detected in hardware, but only software
                     // knows when a new bullet needs a slot, so the two are
                     // bridged by a readable bitmap plus a free-a-slot command.
                     IDX_SPR_RT_SEL = 5'h12,   // 0x48  write: which 32-bit word
                     IDX_SPR_RT_BITS= 5'h13,   // 0x4C  read:  that word
                     IDX_SPR_RETIRE = 5'h14,   // 0x50  write index -> free that slot
                     // -------- position read-back (P4 item #2) --------
                     // Request/response rather than a plain read: positions live
                     // in Block RAM with a two-cycle latency, so a driver that
                     // writes the index and reads the data on the next access
                     // would get the PREVIOUS slot's coordinates. Poll VALID.
                     IDX_SPR_POS_IDX = 5'h15,  // 0x54  write: which slot to read
                     IDX_SPR_POS_XY  = 5'h16,  // 0x58  read:  [15:0]=x [31:16]=y
                     // -------- scan-out status (P4 item #3) --------
                     // Read-only. One bit, because the pixel-domain signal was
                     // synchronised as one bit: exposing a line number would
                     // have meant a multi-bit CDC (Gray code or a handshake)
                     // for information software does not need.
                     IDX_SCAN_STATUS = 5'h17,  // 0x5C  read: [0] = blanking
                     // -------- on-chip assertion monitor --------
                     // Read-only observation of conditions a screen cannot show.
                     // Index + data rather than one register per condition.
                     IDX_MON_STICKY  = 5'h18,  // 0x60  read: 16 sticky bits
                                              //       write: 1 to CLEAR that bit
                     IDX_MON_CNT_SEL = 5'h19,  // 0x64  which counter to read
                     IDX_MON_CNT     = 5'h1A,  // 0x68  read: that counter
                     IDX_MON_CTL     = 5'h1B,  // 0x6C  write 1 -> zero all counters
                     // -------- scan-out starvation --------
                     // How many pixel-clock cycles the display was starved for.
                     // Read-only; it lives in the pixel domain and reaches here
                     // through a stable-sample synchroniser.
                     IDX_SHORT_CNT   = 5'h1C,  // 0x70  read: saturated cycle count
                     // -------- where a transfer was refused --------
                     // 0x04 STATUS bit 3 says a transfer was clipped or wholly
                     // outside the framebuffer. This says WHERE. Without it,
                     // debugging means guessing whether the base register, the
                     // stride, or the sprite coordinates are wrong.
                     IDX_OOB_ADDR    = 5'h1D,  // 0x74  read: destination address refused
                     // -------- scan-out self-proof (2026-10-14) --------
                     // Read-only. These answer "is it really 1080p60?" on
                     // hardware, with no instrument: the line count proves each
                     // frame really carried V_ACT active lines, and sampling the
                     // frame counter twice across a known cycle gap gives the
                     // real refresh rate. Nothing else in this design looks at
                     // the video output -- which is how a 307 Hz scan-out
                     // survived until docs/67.
                     IDX_SCAN_FRAMES = 5'h1E,  // 0x78  read: frames completed
                     IDX_SCAN_LINES  = 5'h1F;  // 0x7C  read: active lines, last frame
                     // 0x54 read: [0] = valid. Poll it before reading POS_XY: positions
                     // come out of Block RAM with a two-cycle latency, so a read that
                     // follows the write immediately returns the PREVIOUS coordinates.

    // ---------------------------------------------------------------
    // AXI state machine (verbatim structure from the official template)
    // ---------------------------------------------------------------
    localparam [1:0] IDLE    = 2'h0,
                     WR      = 2'h1,
                     WR_RESP = 2'h2,
                     RD      = 2'h3;

    reg  [1:0] busState, busNext;
    reg        awreadyReg, arreadyReg;
    wire       busReady, busWrite, busWriteResp, busRead;
    // FIX 2026-10-14 (Questa forward reference): wr_go was declared 18 lines
    // BELOW the FSM that reads it, and rd_got/rvalid_r 79 lines below the
    // ARREADY expression that reads them. iverilog tolerates a forward
    // reference, Questa does not -- so the file compiled on the board flow and
    // was REJECTED by vlog, which is why no simulation ever covered the RTL
    // that is currently in the bitstream. Declared here, before any use.
    wire       wr_go   = axi_awvalid && axi_wvalid && busReady;
    reg        rd_got;
    reg        rvalid_r;

    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) busState <= IDLE;
        else             busState <= busNext;
    end

    always @(*) begin
        busNext = busState;
        case (busState)
            // MINIMAL READ 2026-10-13: reads no longer use this FSM at all, so it
            // must not look at axi_arready any more -- that signal is now
            // unconditionally high when idle, which would send the FSM into RD
            // forever and starve writes.
            // FIX 2026-10-13 (burst): a multi-beat write arrives as AW+W(first
            // beat) in one cycle with wlast=0. Staying in IDLE would have
            // ACCEPTED the AW (wr_go asserted awready) yet left no state to
            // receive the remaining W beats --> permanent deadlock. Every probe
            // today used single-beat writes, so this never showed up; the
            // engine's DMA writes are bursts.
            IDLE:    busNext = wr_go ? (axi_wlast ? WR_RESP : WR) : IDLE;
            WR:      busNext = axi_wlast   ? WR_RESP : WR;
            WR_RESP: busNext = axi_bready  ? IDLE : WR_RESP;
            RD:      busNext = axi_rlast   ? IDLE : RD;
            default: busNext = IDLE;
        endcase
    end

    assign busReady     = (busState == IDLE);
    assign busWrite     = (busState == WR);
    assign busWriteResp = (busState == WR_RESP);
    assign busRead      = (busState == RD);

    // ---------------- AW ----------------
    // FIX CANDIDATE A (2026-10-13, judged by tb/bridge_sim): the real SoC bridge
    // (BmbToAxi4SharedBridge) holds AW and W valid for exactly ONE cycle, and
    // awreadyReg is a register -- so READY always lands one cycle too late and
    // the handshake is missed forever. Accept AW and W in the SAME cycle.
    assign axi_awready = wr_go;

    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) awreadyReg <= 1'b0;
        // NOTE: requires AW and W valid together (see header warning #2)
        else if (wr_go)                                 awreadyReg <= 1'b1;
        else                                            awreadyReg <= 1'b0;
    end

    reg [7:0]               awidReg;
    reg [ADDR_WIDTH-1:0]    awaddrReg;
    // Register index: word offset within the 128-byte window (32 registers).
    // Declared here, above everything that consumes it -- Questa rejects a
    // forward reference that iverilog accepts, and the cross-simulator run
    // caught exactly that when this block sat further down the file.
    // On the single-cycle handshake the address must be decoded combinationally
    // from the live AWADDR -- awaddrReg is only updated on the following clock.
    wire [ADDR_WIDTH-1:0] wr_addr_now = wr_go ? axi_awaddr : awaddrReg;
    wire [4:0] wr_idx    = wr_addr_now[6:2];
    // ---------------------------------------------------------------
    // Write error detection -- added because the previous behaviour was to
    // accept anything. A write aimed at a register with no write path hit a
    // bare `;` and vanished without a word; it now raises SLVERR on the B
    // channel so software finds out.
    //
    // WHAT IS *NOT* CHECKED, and why. An earlier version also refused writes
    // with bits above the register window set, to catch a stray pointer
    // aliasing onto the control registers. That cannot be done here: the
    // slave sees the FULL address including the 0xE1000000 base, so every
    // legal write has those bits set. The first assertion pair caught exactly
    // that -- "legal write answered 10, want 00". Aliasing above the window is
    // the SoC's address decoding business, not this block's.
    //
    // The cost of what IS checked: any pre-existing stray write to a read-only
    // register in a driver will start failing loudly. That is the point --
    // silent acceptance is why such a write could sit there unnoticed.
    // ---------------------------------------------------------------
    wire wr_ro = (wr_idx == IDX_SPR_RT_BITS)  |   // 0x4C read: retired bitmap word
                 (wr_idx == IDX_SPR_POS_XY)   |   // 0x58 read: x and y
                 (wr_idx == IDX_SCAN_STATUS)  |   // 0x5C read: blanking flag
                 (wr_idx == IDX_MON_CNT)      |   // 0x68 read: selected counter
                 (wr_idx == IDX_SHORT_CNT)    |   // 0x70 read: starvation count
                 (wr_idx == IDX_OOB_ADDR)     |   // 0x74 read: refused address
                 (wr_idx == IDX_STATUS);          // 0x01 read-only status
    wire wr_bad = wr_ro;

    reg [7:0]               awlenReg;
    reg [2:0]               awsizeReg;
    reg [1:0]               awburstReg;
    reg                     awlockReg;
    reg [3:0]               awcacheReg;
    reg [2:0]               awprotReg;
    reg [3:0]               awqosReg;
    reg [3:0]               awregionReg;

    // Address is captured on every AW handshake. Only single-beat accesses are
    // used for registers, so no burst address increment is implemented here --
    // the engine's bulk data path goes through its own AXI4 master (M5),
    // not through this control window.
    //
    // Capture on the AW handshake, not merely on AWVALID being high.
    // axi_awready = awreadyReg & axi_awvalid, so the condition below reduces to
    // awvalid & awreadyReg -- the cycle the address is actually accepted.
    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            awidReg     <= 8'd0;
            awaddrReg   <= {ADDR_WIDTH{1'b0}};
            awlenReg    <= 8'd0;
            awsizeReg   <= 3'd0;
            awburstReg  <= 2'd0;
            awlockReg   <= 1'b0;
            awcacheReg  <= 4'd0;
            awprotReg   <= 3'd0;
            awqosReg    <= 4'd0;
            awregionReg <= 4'd0;
        end else if (axi_awvalid && axi_awready) begin
            awidReg     <= axi_awid;
            awaddrReg   <= axi_awaddr;
            awlenReg    <= axi_awlen;
            awsizeReg   <= axi_awsize;
            awburstReg  <= axi_awburst;
            awlockReg   <= axi_awlock;
            awcacheReg  <= axi_awcache;
            awprotReg   <= axi_awprot;
            awqosReg    <= axi_awqos;
            awregionReg <= axi_awregion;
        end
    end

    // ---------------- W ----------------
    assign axi_wready = busWrite || wr_go;

    // ---------------- B ----------------
    reg [7:0] bidReg;
    reg [1:0] brespReg;
    reg       bvalidReg;

    assign axi_bid    = bidReg;
    assign axi_bresp  = brespReg;
    assign axi_bvalid = bvalidReg;

    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            bidReg    <= 8'd0;
            brespReg  <= 2'b00;
            bvalidReg <= 1'b0;
        end else if (bvalidReg && axi_bready) begin
            // FIX CANDIDATE B (2026-10-13): the SoC bridge latches its R/B
            // response-channel selector on ANY cycle BVALID is high. Holding
            // BVALID the extra cycle produced by the busState-based clear left
            // that selector stuck on "write", after which RREADY could never
            // rise again. Drop BVALID on the cycle it is accepted.
            bvalidReg <= 1'b0;
        end else if (busWriteResp) begin
            bidReg    <= awidReg;
            brespReg  <= wr_bad ? 2'b10 : 2'b00;
            bvalidReg <= 1'b1;
        end
    end

    // ---------------- AR ----------------
    // MINIMAL READ 2026-10-13: accept any AR unconditionally while no read is in
    // flight. Every previous variant gated ARREADY on ARVALID, on the shared FSM's
    // busReady, or on a handshake-clear register; none of them made the SoC's
    // bridge issue a read that ever completed.
    assign axi_arready = !rd_got && !rvalid_r;

    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) arreadyReg <= 1'b0;
        else if (axi_arvalid && busReady) arreadyReg <= 1'b1;
        else                              arreadyReg <= 1'b0;
    end

    reg [7:0]               aridReg;
    reg [ADDR_WIDTH-1:0]    araddrReg;
    reg [7:0]               arlenReg;
    reg [2:0]               arsizeReg;
    reg [1:0]               arburstReg;
    reg                     arlockReg;
    reg [3:0]               arcacheReg;
    reg [2:0]               arprotReg;
    reg [3:0]               arqosReg;
    reg [3:0]               arregionReg;

    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            aridReg     <= 8'd0;
            araddrReg   <= {ADDR_WIDTH{1'b0}};
            arlenReg    <= 8'd0;
            arsizeReg   <= 3'd0;
            arburstReg  <= 2'd0;
            arlockReg   <= 1'b0;
            arcacheReg  <= 4'd0;
            arprotReg   <= 3'd0;
            arqosReg    <= 4'd0;
            arregionReg <= 4'd0;
        // 2026-10-14 FIX -- AR fields must be captured ON THE HANDSHAKE, not
        // whenever ARVALID happens to be high.
        //
        // The old condition was a bare "axi_arvalid", so the moment a master
        // presented its SECOND AR (arvalid high, arready still low because the
        // first read was in flight) the address register was overwritten and
        // the FIRST read returned the SECOND address's data. tb_bitblt_axi_slave
        // has a case for exactly this -- read BPP (0x30) then FB_BASE (0x34),
        // expect 0x00000004 first -- and it failed with 0x08000000.
        //
        // AXIS DOES NOT PERMIT the old behaviour anyway: a slave must not sample
        // its payload outside the handshake.
        end else if (axi_arvalid && axi_arready) begin
            aridReg     <= axi_arid;
            araddrReg   <= axi_araddr;
            arlenReg    <= axi_arlen;
            arsizeReg   <= axi_arsize;
            arburstReg  <= axi_arburst;
            arlockReg   <= axi_arlock;
            arcacheReg  <= axi_arcache;
            arprotReg   <= axi_arprot;
            arqosReg    <= axi_arqos;
            arregionReg <= axi_arregion;
        end
    end

    // ---------------- R ----------------
    reg  [7:0]  ridReg;
    reg  [1:0]  rrespReg;
    wire        rvalidReg;
    reg         rvalidReg2;
    reg  [7:0]  rdataCnt;

    reg  [31:0] rdata_mux;

    assign axi_rid    = ridReg;
    assign axi_rresp  = rrespReg;
    // MINIMAL READ 2026-10-13: driven by the self-contained channel below.
    assign axi_rvalid = rvalid_r;
    assign axi_rlast  = rvalid_r;      // register reads are single-beat
    assign axi_rdata  = rdata_mux;

    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            ridReg   <= 8'd0;
            rrespReg <= 2'b00;
        end else if (busRead) begin
            ridReg   <= aridReg;
            rrespReg <= 2'b00;
        end else begin
            ridReg   <= 8'd0;
            rrespReg <= 2'b00;
        end
    end

    // ---- MINIMAL READ CHANNEL 2026-10-13 ------------------------------------
    // Self-contained: RVALID is a register that does not depend on RREADY (it is
    // cleared by the handshake instead), so no combination of peer behaviour can
    // keep it from ever rising. Data is decoded from the address latched at the
    // AR handshake.
    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            rd_got   <= 1'b0;
            rvalid_r <= 1'b0;
        end else begin
            if (axi_arvalid && axi_arready) rd_got   <= 1'b1;
            if (rd_got)                     rvalid_r <= 1'b1;
            if (rvalid_r && axi_rready) begin
                rvalid_r <= 1'b0;
                rd_got   <= 1'b0;
            end
        end
    end

    assign rvalidReg = busRead && axi_rready;

    // Exported read-channel state (see the dbg_observ port).
    assign dbg_observ = {busRead, axi_rvalid, arreadyReg, rvalidReg};

    // rvalidReg2 feeds axi_rvalid, so without a reset the master would observe
    // an X on RVALID in simulation while the FPGA would see 0. That difference
    // between simulated and actual power-up state is exactly the kind of split
    // that makes a design pass in simulation and misbehave on hardware.
    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) rvalidReg2 <= 1'b0;
        else             rvalidReg2 <= rvalidReg;
    end

    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) rdataCnt <= 8'd0;
        else if (busRead && rvalidReg2) rdataCnt <= rdataCnt + 8'd1;
        else if (busRead && !rvalidReg2) rdataCnt <= rdataCnt;
        else                             rdataCnt <= 8'd0;
    end

    // ===============================================================
    // CUSTOM LOGIC -- register bank replaces the template's 4 KB BRAM
    // ===============================================================

    // byte-granular write merge (AXI allows per-byte strobes)
    function [31:0] merge_bytes;
        input [31:0] old_val;
        input [31:0] new_val;
        input [3:0]  strb;
        begin
            merge_bytes[7:0]   = strb[0] ? new_val[7:0]   : old_val[7:0];
            merge_bytes[15:8]  = strb[1] ? new_val[15:8]  : old_val[15:8];
            merge_bytes[23:16] = strb[2] ? new_val[23:16] : old_val[23:16];
            merge_bytes[31:24] = strb[3] ? new_val[31:24] : old_val[31:24];
        end
    endfunction

    reg [31:0] r_ctrl, r_op, r_src_addr, r_dst_addr, r_width_h;
    reg [31:0] r_src_stride, r_dst_stride, r_fill_color, r_alpha, r_key_color, r_frame_cnt;
    reg [31:0] r_bpp;
    reg [31:0] r_fb_base, r_fb_size_h, r_fb_cfg;
    // P4 interface registers. Deliberately NOT brought out to the top level
    // yet: nothing consumes them, and an unconnected output would only add
    // unused ports. They are readable and writable, which is what the
    // testbench checks.
    reg [31:0] r_spr_table, r_spr_ctl;
    // Retired-slot bitmap selector, and a one-shot "free this slot" pulse.
    reg [31:0] r_spr_rt_sel;
    reg [31:0] r_spr_retire;
    reg [31:0] r_spr_pos_idx;
    reg [31:0] r_mon_cnt_sel;

    // Decoding uses only the low address bits (word offset within the 128-byte
    // register window, 32 registers). Bits above are ignored, so an address
    // sharing the same low bits aliases onto the same registers. That is the
    // SoC's decoding, not this block's -- but a write to a READ-ONLY register
    // is now refused with SLVERR rather than silently dropped.
    // Gate on wvalid as well as the FSM state: the write is only a real
    // handshake when both wready (= busWrite) and wvalid are high.
    wire       wr_strobe = (busWrite & axi_wvalid) | wr_go;


    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) begin
            r_ctrl       <= 32'h0;
            r_op         <= 32'h0;
            r_src_addr   <= 32'h0;
            r_dst_addr   <= 32'h0;
            r_width_h    <= 32'h0;
            r_src_stride <= 32'h0;
            r_dst_stride <= 32'h0;
            r_fill_color <= 32'h0;
            r_alpha      <= 32'hFF;      // default: fully opaque
            r_key_color  <= 32'hFF00FF;  // default: magenta key
            r_frame_cnt  <= 32'h0;
            r_bpp        <= 32'h4;       // default: 4 bytes/pixel (ARGB8888)
            // Scan-out defaults reproduce the constants that used to be wired
            // into system_top, so a design that never touches these registers
            // behaves exactly as it did before this change.
            r_fb_base    <= 32'h0800_0000;
            r_fb_size_h  <= 32'h0438_0780;   // height 1080 (0x438), width 1920 (0x780)
            // Was 32'h01E0_0280 (480x640) -- the bring-up geometry. The driver
            // overwrites this before enabling scan-out, so the stale value only
            // mattered for the window between reset and that write; but it is the
            // same class of leftover as the top-level instantiation, and it made
            // "what resolution is this design?" answerable two ways.
            // stride 2560, enable = 1 (bit 16). The enable bit must reset to 1:
            // system_top used to tie this input to a constant 1'b1, and the whole
            // point of these reset values is that behaviour is unchanged for a
            // design that never touches the new registers. Resetting it to 0
            // would silently give a blank screen after this change.
            r_fb_cfg     <= 32'h0001_0A00;
            // Sprite table defaults: disabled, empty. Reset to 0 means a design
            // that never touches these registers behaves exactly as before.
            r_spr_table  <= 32'h0;
            r_spr_ctl    <= 32'h0;
            r_spr_rt_sel <= 32'h0;
            r_spr_retire <= 32'h0;
            r_spr_pos_idx <= 32'h0;
            r_mon_cnt_sel <= 32'h0;
        end else if (wr_strobe) begin
            case (wr_idx)
                IDX_CTRL:       r_ctrl       <= merge_bytes(r_ctrl,       axi_wdata, axi_wstrb);
                IDX_OP:         r_op         <= merge_bytes(r_op,         axi_wdata, axi_wstrb);
                IDX_SRC_ADDR:   r_src_addr   <= merge_bytes(r_src_addr,   axi_wdata, axi_wstrb);
                IDX_DST_ADDR:   r_dst_addr   <= merge_bytes(r_dst_addr,   axi_wdata, axi_wstrb);
                IDX_WIDTH_H:    r_width_h    <= merge_bytes(r_width_h,    axi_wdata, axi_wstrb);
                IDX_SRC_STRIDE: r_src_stride <= merge_bytes(r_src_stride, axi_wdata, axi_wstrb);
                IDX_DST_STRIDE: r_dst_stride <= merge_bytes(r_dst_stride, axi_wdata, axi_wstrb);
                IDX_FILL_COLOR: r_fill_color <= merge_bytes(r_fill_color, axi_wdata, axi_wstrb);
                IDX_ALPHA:      r_alpha      <= merge_bytes(r_alpha,      axi_wdata, axi_wstrb);
                IDX_KEY_COLOR:  r_key_color  <= merge_bytes(r_key_color,  axi_wdata, axi_wstrb);
                IDX_FRAME_CNT:  r_frame_cnt  <= merge_bytes(r_frame_cnt,  axi_wdata, axi_wstrb);
                IDX_BPP:        r_bpp        <= merge_bytes(r_bpp,        axi_wdata, axi_wstrb);
                IDX_FB_BASE:    r_fb_base    <= merge_bytes(r_fb_base,    axi_wdata, axi_wstrb);
                IDX_FB_SIZE_H:  r_fb_size_h  <= merge_bytes(r_fb_size_h,  axi_wdata, axi_wstrb);
                IDX_FB_CFG:     r_fb_cfg     <= merge_bytes(r_fb_cfg,     axi_wdata, axi_wstrb);
                IDX_SPR_TABLE:  r_spr_table  <= merge_bytes(r_spr_table,  axi_wdata, axi_wstrb);
                IDX_SPR_CTL:    r_spr_ctl    <= merge_bytes(r_spr_ctl,    axi_wdata, axi_wstrb);
                IDX_SPR_RT_SEL: r_spr_rt_sel <= merge_bytes(r_spr_rt_sel, axi_wdata, axi_wstrb);
                IDX_SPR_RETIRE: r_spr_retire <= merge_bytes(r_spr_retire, axi_wdata, axi_wstrb);
                IDX_SPR_POS_IDX: r_spr_pos_idx <= merge_bytes(r_spr_pos_idx, axi_wdata, axi_wstrb);
                IDX_MON_CNT_SEL: r_mon_cnt_sel <= merge_bytes(r_mon_cnt_sel, axi_wdata, axi_wstrb);
                IDX_STATUS:     ;            // read-only; SLVERR raised above
                default:        ;            // no write path; SLVERR raised above
            endcase
        end
    end

    // Read mux
    always @(*) begin
        // 2026-10-27: 0x80.. are the display-health counters. They live in the
        // upper half of the 256-byte window so that none of the existing 32
        // indices move -- software that already reads 0x00..0x7C is unaffected.
        if (araddrReg[7]) begin
            case (araddrReg[6:2])
                5'h00: rdata_mux = scan_underruns;
                5'h01: rdata_mux = scan_shown;
                5'h02: rdata_mux = scan_axi_err;
                default: rdata_mux = 32'd0;
            endcase
        end else case (araddrReg[6:2])
            IDX_CTRL:       rdata_mux = r_ctrl;
            IDX_STATUS:     rdata_mux = reg_status;
            IDX_OP:         rdata_mux = r_op;
            IDX_SRC_ADDR:   rdata_mux = r_src_addr;
            IDX_DST_ADDR:   rdata_mux = r_dst_addr;
            IDX_WIDTH_H:    rdata_mux = r_width_h;
            IDX_SRC_STRIDE: rdata_mux = r_src_stride;
            IDX_DST_STRIDE: rdata_mux = r_dst_stride;
            IDX_FILL_COLOR: rdata_mux = r_fill_color;
            IDX_ALPHA:      rdata_mux = r_alpha;
            IDX_KEY_COLOR:  rdata_mux = r_key_color;
            IDX_FRAME_CNT:  rdata_mux = r_frame_cnt;
            IDX_BPP:        rdata_mux = r_bpp;
            IDX_FB_BASE:    rdata_mux = r_fb_base;
            IDX_FB_SIZE_H:  rdata_mux = r_fb_size_h;
            IDX_FB_CFG:     rdata_mux = r_fb_cfg;
            IDX_SPR_TABLE:  rdata_mux = r_spr_table;
            IDX_SPR_CTL:    rdata_mux = r_spr_ctl;
            IDX_SPR_RT_SEL: rdata_mux = r_spr_rt_sel;
            // The retired bitmap itself lives beside the sprite state, not
            // here, so it arrives as an input. This is the one signal in the
            // design that flows from the engine back INTO the register file.
            IDX_SPR_RT_BITS:rdata_mux = spr_rt_bits;
            IDX_SPR_RETIRE: rdata_mux = r_spr_retire;
            // VALID LIVES HERE, NOT IN POS_XY. POS_XY's 32 bits are fully
            // used by x and y, so a concatenation that also carried valid
            // would be 33 bits wide and silently drop it on assignment to the
            // 32-bit read mux -- software would then poll a bit that never
            // changes. Reading POS_IDX back reports whether the last request
            // has landed.
            IDX_SPR_POS_IDX: rdata_mux = {31'b0, spr_pos_valid};
            IDX_SPR_POS_XY:  rdata_mux = spr_pos_xy[31:0];
            // Read-only status. Software polls bit 0 and writes FB_CFG once it
            // reads 1.
            IDX_SCAN_STATUS: rdata_mux = {31'b0, scan_blanking};
            IDX_MON_STICKY:  rdata_mux = {16'b0, mon_sticky};
            IDX_MON_CNT_SEL: rdata_mux = r_mon_cnt_sel;
            IDX_MON_CNT:     rdata_mux = mon_cnt;
            IDX_SHORT_CNT:   rdata_mux = scan_short_count;   // full 32 bits now
            IDX_SCAN_FRAMES: rdata_mux = scan_frames;
            IDX_SCAN_LINES:  rdata_mux = {16'b0, scan_lines};
            IDX_OOB_ADDR:    rdata_mux = addr_oob_addr;
            default:        rdata_mux = 32'h0;
        endcase
    end

    // start pulse: asserted for one cycle when CTRL[0] is written with a 1
    reg start_pulse_r;
    always @(posedge axi_aclk or negedge axi_resetn) begin
        if (!axi_resetn) start_pulse_r <= 1'b0;
        else             start_pulse_r <= wr_strobe && (wr_idx == IDX_CTRL)
                                       && axi_wstrb[0] && axi_wdata[0];
    end

    // Interrupt: driven by the engine (reg_status[1] = done) when enabled
    assign axi_interrupt = r_ctrl[1] & reg_status[1];

    // Engine-facing outputs
    assign reg_ctrl       = r_ctrl;
    assign reg_op         = r_op;
    assign reg_src_addr   = r_src_addr;
    assign reg_dst_addr   = r_dst_addr;
    assign reg_width_h    = r_width_h;
    assign reg_src_stride = r_src_stride;
    assign reg_dst_stride = r_dst_stride;
    assign reg_fill_color = r_fill_color;
    assign reg_alpha      = r_alpha;
    assign reg_key_color  = r_key_color;
    assign reg_frame_cnt  = r_frame_cnt;
    assign reg_bpp        = r_bpp[3:0];
    assign reg_start_pulse = start_pulse_r;

    // Scan-out configuration, unpacked for the video module. Keeping the packing
    // on this side means bitblt_video_out keeps its natural port list (a 32-bit
    // base, a 16-bit stride, and so on) rather than having to know about the
    // register layout.
    assign reg_fb_base   = r_fb_base;
    assign reg_fb_width  = r_fb_size_h[15:0];
    assign reg_fb_height = r_fb_size_h[31:16];
    assign reg_fb_stride = r_fb_cfg[15:0];
    assign reg_fb_enable = r_fb_cfg[16];

    assign reg_spr_table  = r_spr_table;
    assign reg_spr_count  = r_spr_ctl[15:0];
    assign reg_spr_enable = r_spr_ctl[16];

    assign reg_spr_rt_sel     = r_spr_rt_sel[15:0];
    assign reg_spr_retire_idx = r_spr_retire[15:0];

    // A write to SPR_RETIRE is the command itself, so the enable is a write
    // strobe rather than a stored bit. Storing it would mean software had to
    // clear it afterwards, and forgetting to would free the same slot every
    // cycle forever -- silently recycling a slot that is in use.
    assign reg_spr_retire_en  = wr_strobe && (wr_idx == IDX_SPR_RETIRE);

    // Writing the sticky word IS the clear command: the byte lanes that carry a
    // 1 clear those bits. Clear-on-write-of-1, not write-of-0, so that "I
    // cleared it" cannot be confused with "the write happened to carry zeros".
    assign reg_mon_clr_mask   = (wr_strobe && (wr_idx == IDX_MON_STICKY))
                              ? axi_wdata[15:0] : 16'd0;
    assign reg_mon_cnt_sel    = r_mon_cnt_sel[3:0];
    assign reg_mon_clr_count  = wr_strobe && (wr_idx == IDX_MON_CTL);
    // A write to POS_IDX is the request; the state block latches the result and
    // raises spr_pos_valid two cycles later.
    assign reg_spr_pos_req    = wr_strobe && (wr_idx == IDX_SPR_POS_IDX);
    assign reg_spr_pos_idx    = r_spr_pos_idx[15:0];

endmodule
