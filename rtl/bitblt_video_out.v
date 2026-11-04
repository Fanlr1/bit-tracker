// BitBlt video scan-out: reads the framebuffer over AXI4 and drives RGB + syncs.
//
// ============================================================================
// ARCHITECTURE
// ============================================================================
//
//   pixel domain (pclk, 25 MHz)              AXI domain (clk, 100 MHz)
//   ---------------------------              ------------------------
//     h_cnt / v_cnt  (free running)
//          |
//          | de_raw
//          v
//     [FWFT FIFO 24b x 2048]  <-----------  128->24 split  <---- AXI4 read
//          |                                       ^                ^
//          | o_rdata valid BEFORE i_re             |                |
//          v                                       |          [line FSM]
//     rgb / de / hs / vs                            |                |
//                                                   |        o_wcnt (level)
//                                                   |                |
//                                          px_in_line / rd_row counters
//
// ============================================================================
// THREE DESIGN DECISIONS WORTH STATING
// ============================================================================
//
// (1) FWFT FIFO INSTEAD OF A COMPENSATED READ
//     The previous revision used OUTPUT_REG="TRUE", so o_rdata became valid one
//     cycle AFTER i_re, and it tried to compensate with fifo_re = de | de_d. That
//     fudge never aligned, because the consumer (color_bar_rgb) also registers
//     its output -- the result was a fixed pixel offset.
//     Here OUTPUT_REG="FALSE" (first-word fall-through): o_rdata is already
//     valid when de is asserted, and rgb is a direct wire. No delay to tune.
//
//     Note on COMPATIBILITY: "X" and "A" FORCE OUTPUT_REG to "FALSE" internally
//     (dual_clock_fifo.v lines 86 and 161). "E" passes the user value through
//     (line 123). So "E" + "FALSE" is the combination that actually does what it
//     says; picking "X" for safety would silently ignore the parameter.
//
// (2) LINE NUMBER DERIVED FROM PIXELS WRITTEN -- NO CLOCK-DOMAIN HANDSHAKE
//     The pixel side knows which line it displays; the AXI side must know which
//     line to fetch. Passing v_cnt across would need a synchroniser or a small
//     async FIFO.
//     Instead the AXI side counts the pixels it has written and advances rd_row
//     when a line's worth has gone by. The two sides cannot drift because the
//     count IS the shared state. Division is avoided by carrying px_in_line and
//     incrementing rd_row on wrap.
//
// (3) PREFETCH THRESHOLD TAKEN FROM THE FIFO ITSELF
//     need_line compares the FIFO's own o_wcnt against one line of pixels.
//     A separate credit counter is easy to get subtly out of step with real
//     occupancy; reading o_wcnt cannot be.
//
// ============================================================================
// THROUGHPUT (why holding rready low during the split is harmless)
// ============================================================================
//   A line costs ~fb_width clk cycles of AXI time (4 clk per beat, 4 px/beat).
//   A line of display lasts H_TOTAL pixels x 4 clk/pixel = 4*H_TOTAL clk.
//   With fb_width=640, H_TOTAL=800: 640 cycles of work per 3200 available,
//   about 20% utilisation. The back-pressure costs nothing.
//
// ============================================================================
// TIMING (CEA-861 640x480@60)
// ============================================================================
//   H: fp 16, sync 96, active 640, bp 48  -> 800
//   V: fp 10, sync  2, active 480, bp 33  -> 525
`timescale 1ns / 1ps

module bitblt_video_out #(
    // ------------------------------------------------------------------
    // Display timing. DEFAULTS ARE 1920x1080@60 (CEA-861), because that is
    // what the product runs. Testbenches override them explicitly -- keeping
    // 640x480 in the existing tests rather than rewriting their pixel-exact
    // expectations.
    //
    //   148.5 MHz pixel clock = 2200 * 1125 * 60
    //   H: 1920 active + 88 front porch + 44 sync + 148 back porch = 2200
    //   V: 1080 active +  4 front porch +  5 sync +  36 back porch = 1125
    // ------------------------------------------------------------------
    parameter H_ACT   = 1920,
    parameter H_FP    = 88,
    parameter H_SYNC  = 44,
    parameter H_BP    = 148,
    parameter V_ACT   = 1080,
    parameter V_FP    = 4,
    parameter V_SYNC  = 5,
    parameter V_BP    = 36,
    parameter FIFO_AW = 12,           // 4096 pixels -- one 1920-pixel line plus margin
                                      // Was 11 (2048): enough for 640-wide, but a 1920
                                      // line needs 1920 entries and 2048 would leave only
                                      // 128 of slack. Each extra AW bit costs 5 RAM10
                                      // blocks (4096x24 instead of 2048x24).
    parameter AXI_ID  = 8'h20,        // distinct from the three BitBlt engines

    // ------------------------------------------------------------------
    // PIX565 -- framebuffer pixel format
    // ------------------------------------------------------------------
    //   1 : RGB565, 2 B/pixel. One 128-bit beat carries EIGHT pixels, so a FIFO
    //       entry spans eight pixels and is consumed over two pixel clocks.
    //       This is the product configuration (docs/85): halving the bytes the
    //       scan-out pulls per line is what lets 2048 sprites fit in 60 Hz.
    //   0 : the original ARGB8888 path -- four 24-bit pixels per 96-bit entry.
    //
    // Both are kept because the 4 KB page-splitting logic below is only ever
    // EXERCISED at 8 B/pixel: a 1920-pixel line is 7680 B and must be issued as
    // two bursts, while at 2 B/pixel it is 3840 B and fits one page. The two
    // testbenches that exist specifically to protect that splitting
    // (tb_video_split, tb_mux_video) therefore instantiate PIX565 = 0.
    parameter PIX565  = 1
) (
    input  wire         clk,          // AXI domain
    input  wire         rst_n,
    input  wire         pclk,         // pixel domain

    // ---------------- configuration (AXI domain) ----------------
    input  wire [31:0]  fb_base,
    input  wire [15:0]  fb_stride,    // bytes per line
    input  wire [15:0]  fb_width,     // pixels per line
    input  wire [15:0]  fb_height,    // lines per frame
    input  wire         enable,

    // ---------------- AXI4 read master ----------------
    output wire [7:0]   m_axi_arid,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [7:0]   m_axi_rid,
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    // ---------------- video out ----------------
    output wire [23:0]  rgb,
    output wire         de,
    output wire         hs,
    output wire         vs,
    output wire [15:0]  h_cnt_o,
    output wire [15:0]  v_cnt_o,
    // 2026-10-25: the row the AXI side is fetching, exported for observation.
    // The picture keeps showing old content in fixed screen regions, and rd_row
    // is the only signal that says WHICH framebuffer row is being read. Comparing
    // it against the visible row is the direct test for a row-mapping fault.
    output wire [15:0]  rd_row_o,
    // Blanking, in the PIXEL domain, derived from the same expression that
    // gates de. Exported so software can learn when it is safe to write
    // FB_CFG -- see the note in blt_set_fb: enabling scan-out during the
    // active region costs the first few pixels of that line and offsets the
    // framebuffer row permanently, because rd_row and the scan line wrap at
    // the same rate.
    //
    // It is deliberately ONE BIT computed inside this module rather than
    // h_cnt_o/v_cnt_o exported so the caller can compare them: fb_width and
    // fb_height come from registers in the clk domain, so a comparison made
    // outside would add a 16-bit clock-domain crossing on top of this one-bit
    // crossing -- and would do it without a synchroniser, which is how this
    // design already reads fb_width inside the pixel domain.
    output wire         o_blanking,

    // ---------------- scan-out starvation ----------------
    // de_raw says "this pixel is inside the active region"; de adds "and the
    // read FIFO actually had it". When the first is true and the second is not,
    // the display is being starved -- pixels are being skipped. The picture
    // simply has a short or missing line, and NOTHING anywhere reports it.
    //
    // The contract this mirrors is tb_bitblt_video_out's: it fails when fewer
    // than 95% of the expected lines appear. Counting CYCLES rather than lines
    // is deliberate -- cycles give software a ratio immediately, without having
    // to wait for a line boundary to find out that something is wrong.
    //
    // Both outputs are in the PIXEL domain. o_short_count is 32 bits and must be
    // read with a stable-sample synchroniser, not a plain two-flop one: a
    // multi-bit value crossing on independent flops can be read mid-change and
    // produce a number that was never true. o_short_sticky is one bit, so two
    // flops are genuinely enough for it.
    //
    // 2026-10-14: was 8 bits, which saturated at 255 and made the board report
    // "starved for 255 cycles (saturated -- a floor, not a total)" every run.
    // At 148.5 MHz that is under 2 microseconds: the real figure could have been
    // 1.7 us or most of a frame, so the counter measured nothing useful exactly
    // when it mattered. 32 bits will not wrap at this clock.
    output wire         o_short_sticky,
    output wire [31:0]  o_short_count,

    // ---- 2026-10-14: self-proof for "is it really 1080p60?" ----
    // o_lines_last = the number of ACTIVE LINES this scan-out produced in the
    // previous frame. It should read 1080 every frame; less means a short frame.
    // This is the measurement an oscilloscope CANNOT make: the H and V counters
    // free-run, so a missing pixel does not perturb the VSYNC period at all --
    // only an in-fabric count can see it.
    //
    // o_frames increments once per frame. Software samples it twice across a
    // known cycle gap to obtain the real refresh rate, so 59.94 Hz is verified
    // on hardware instead of inferred from the timing constants.
    output wire [15:0]  o_lines_last,
    output wire [31:0]  o_frames,

    // ---- observability (2026-10-27) ----
    // The same three numbers FrameSpeed exposes. Without them a bad picture can
    // only be described by eye ("it tears"), which is why every attempt so far
    // ended in a guess.
    output wire [31:0]  o_underruns,    // lines whose data was not ready at x=0
    output wire [31:0]  o_shown,        // complete new frames (no underrun)
    output wire [31:0]  o_axi_errors,   // RRESP != OKAY

    output wire         cfg_error
);

    // 2026-10-14: the trailing numbers used to read 800 and 525 -- the 640x480
    // timing these constants were born with. The values have been 1080p60 for a
    // long time (2200 x 1125 @ 148.5 MHz = 59.94 Hz) but the comment was never
    // updated, so anyone reading it would conclude the design still scans out
    // 480p. That is the same class of stale comment that cost a debug cycle in
    // docs/62; comments that contradict the code are worse than no comment.
    localparam H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;   // 2200 (1080p60)
    localparam V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP;   // 1125

    // ========================================================================
    // 1. Video timing, pixel domain
    // ========================================================================
    //
    // Reset synchroniser for the pixel clock domain.
    //
    // rst_n is asynchronous to pclk, and until now it drove pclk-domain
    // registers directly (h_cnt/v_cnt and the FIFO read side). Asynchronous
    // assertion is fine, but asynchronous RELEASE is not: if rst_n goes high
    // close to a pclk edge, some flip-flops leave reset on one edge and others
    // on the next, so the counters can start from inconsistent values. That
    // shows up as an occasional garbled picture after a cold power-up that
    // disappears after a warm reset -- the hardest kind of fault to reproduce.
    //
    // Two flops shift in a constant 1, so the release is aligned to pclk.
    // Assertion stays asynchronous, which is what we want.
    reg [1:0] rst_sync_p;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) rst_sync_p <= 2'b00;
        else        rst_sync_p <= {rst_sync_p[0], 1'b1};
    end
    wire rst_n_pclk = rst_sync_p[1];

    reg [12:0] h_cnt, v_cnt;

    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) begin
            h_cnt <= 13'd0;
            v_cnt <= 13'd0;
        end else if (h_cnt == H_TOTAL - 1) begin
            h_cnt <= 13'd0;
            if (v_cnt == V_TOTAL - 1) v_cnt <= 13'd0;
            else                      v_cnt <= v_cnt + 13'd1;
        end else begin
            h_cnt <= h_cnt + 13'd1;
        end
    end

    wire h_active = (h_cnt < H_ACT);
    wire v_active = (v_cnt < V_ACT);
    wire de_raw   = h_active & v_active;

    // Syncs are active low (CEA-861) and are deliberately independent of data
    // availability, so a FIFO underrun can never damage the sync timing itself.
    assign hs = ~((h_cnt >= H_ACT + H_FP) && (h_cnt < H_ACT + H_FP + H_SYNC));
    assign vs = ~((v_cnt >= V_ACT + V_FP) && (v_cnt < V_ACT + V_FP + V_SYNC));

    assign h_cnt_o = {3'b000, h_cnt};
    assign v_cnt_o = {3'b000, v_cnt};

    // ========================================================================
    // 2. Beat to FIFO -- one beat, one write
    // ========================================================================
    // The FIFO holds FOUR pixels per entry (96 bits = 4 x 24-bit RGB), so an
    // entire 128-bit AXI beat is stored in a single cycle. There is no
    // splitter any more, and therefore no hold / split_cnt / splitting state.
    //
    // WHY THIS REPLACED A SPLITTER
    //   The previous version held each beat in a register and wrote it out
    //   one pixel per cycle, holding rready low meanwhile:
    //       cycle 0  accept beat
    //       cycles 1-4  write 4 pixels
    //     => 5 cycles per beat => 0.8 pixels/clk => 80 M pixels/s at 100 MHz.
    //   That is enough for 640x480 (25 M pixels/s) but NOT for 1080p60, which
    //   needs 148.5 M. Measured: at pclk = 142.9 MHz only 89 of 148 lines were
    //   driven -- de is gated by ~fifo_empty, so the missing lines simply never
    //   appeared, with errors = 0. See docs/41.
    //
    //   Writing the whole beat at once gives 4 pixels/clk = 400 M pixels/s.
    //
    // Pixel n occupies bits [n*32 +: 32] of the beat = {A,R,G,B}; the low 24
    // bits are RGB. fb_width is checked to be a multiple of 4, so a line is
    // always a whole number of entries and no entry ever spans two lines.
    localparam RW  = PIX565 ? 128 : 96;                        // bits per entry
    localparam RPB = PIX565 ? 3 : 2;                           // rd_px counter width
    localparam FAW = PIX565 ? (FIFO_AW - 3) : (FIFO_AW - 2);   // FIFO address width

    // 888: the four 24-bit pixels form a 96-bit word that must be RIGHT-aligned
    // inside the 128-bit container, so slicing [RW-1:0] yields them unchanged.
    //
    // A first version padded on the RIGHT -- {pixels, 32'd0} -- which is 160
    // bits, so the top pixel was silently shifted out of the 128-bit wire and
    // every colour came out wrong. tb_video_split could NOT see it (it only
    // checks AR address/length shapes); tb_mux_video, which checks pixels, could.
    wire [95:0]  beat888 = { m_axi_rdata[119:96], m_axi_rdata[87:64],
                             m_axi_rdata[55:32],  m_axi_rdata[23:0] };
    wire [RW-1:0] beat_rgb = PIX565 ? m_axi_rdata[127:0] : {32'd0, beat888};

    // ========================================================================
    // 3. FWFT FIFO -- rdata valid BEFORE i_re
    // ========================================================================
    // Swapped from the vendor dual_clock_fifo_wrapper to async_fifo_gray.
    //
    // The vendor wrapper's o_empty and o_full are combinational assigns that
    // include their own handshake inputs (dual_clock_fifo.v lines 471 and 353),
    // so feeding them back into fifo_we / fifo_re closes a loop. Under iverilog
    // that wedged the simulation at t=130.6 us with no signal activity and no
    // time advance; under Questa it reported "Iteration limit 10000000 reached".
    // Four attempts to work around it by delaying or substituting individual
    // signals all failed.
    //
    // async_fifo_gray registers full and empty, so the same feedback topology
    // converges -- verified by tb_async_fifo_gray test 8, which drives we/re
    // combinationally from wfull/rempty and completes (Questa: Iteration: 1).
    //
    // LATENCY DIFFERS AND THAT IS NOT COSMETIC. The vendor part presents rdata
    // one read clock AFTER re despite OUTPUT_REG="FALSE"; the new one presents
    // it in the same cycle (measured in tb_async_fifo_gray test 9). So de is no
    // longer delayed -- de_d1 is gone. Getting this wrong misaligns every pixel,
    // which is precisely what defeated four earlier attempts.
    wire [RW-1:0]      fifo_rdata;      // one entry: 8x16-bit or 4x24-bit
    wire               fifo_empty, fifo_full;
    wire [FAW:0]       fifo_wcnt;       // entry count, AW+1 bits -- MUST match wcnt_o
                                        // or a FULL FIFO reads as EMPTY and burst
                                        // admission deadlocks (docs/76 comment)

    // Write side: one beat, one entry. rready is simply the inverse of full,
    // so the AXI side can stream back-to-back beats.
    wire fifo_we = m_axi_rvalid & m_axi_rready & ~fifo_full;

    // Declared explicitly rather than left implicit. It is used in the port map
    // below and only assigned at line ~341, so without this Verilog creates an
    // implicit 1-bit wire at the point of use. It IS 1 bit, so this one happened
    // to be correct -- but bitblt_top.v had seventeen where that was not true
    // (16- and 32-bit signals used as 1 bit), which is why -Wall now treats
    // implicit declarations as fatal. See run-regression.ps1 and docs/45.
    wire fifo_re;

    async_fifo_gray #(
        .DW (RW),                       // 128b: eight 16-bit; 96b: four 24-bit
        .AW (FAW)                       // either way 2**FAW entries = 2**FIFO_AW pixels
    ) u_fifo (
        // write side runs on the AXI clock and uses the AXI reset
        .wclk     (clk),
        .wrst_n   (rst_n),
        .we       (fifo_we),
        .wdata    (beat_rgb),
        .wfull    (fifo_full),

        // read side runs on the pixel clock and uses its synchronised reset
        .rclk     (pclk),
        .rrst_n   (rst_n_pclk),
        .re       (fifo_re),
        .rdata    (fifo_rdata),
        .rempty   (fifo_empty),

        .wcnt_o   (fifo_wcnt),
        .wbin_o   (),
        .rbin_o   ()
    );

    // 3b. Read side -- one entry per four pixels
    // ========================================================================
    // An entry holds four pixels and the display consumes one pixel per pclk,
    // so a new entry is needed every fourth cycle.
    //
    // THE RAM READ IS REGISTERED, SO THE FETCH STARTS TWO CYCLES EARLY.
    //   async_fifo_gray stores entries in simple_dual_port_ram, whose read is
    //   `if (re) r_rdata_1P <= ram[raddr]` -- rdata appears the cycle AFTER re,
    //   even with OUTPUT_REG="FALSE" (docs/38). Asserting re on the cycle the
    //   data is wanted returns the previous entry, and the very first fetch
    //   returns x.
    //
    //   rd_px 2: assert fifo_re          (fetch group N+1)
    //   rd_px 3: rdata valid -> rd_hold  (still emitting group N, pixel 3)
    //   rd_px 0: emit rd_hold[23:0]      (group N+1, pixel 0)
    //   rd_px 1: emit rd_hold[55:32]
    //   rd_px 2: emit rd_hold[87:64]
    //   rd_px 3: emit rd_hold[119:96]    and start the next fetch
    //
    // rd_valid means "rd_hold holds a usable group". It is cleared when a new
    // group is needed but the FIFO is empty, so a starved FIFO drives de LOW
    // instead of repeating stale pixels. That is what lets the testbench's
    // line-count assertion detect a supply shortfall -- without it, a starved
    // scan-out looks identical to a healthy one.
    reg [RPB-1:0] rd_px;            // 0..7 at 128b, 0..3 at 96b
    reg [RW-1:0]  rd_hold;
    reg        rd_valid;

    // The fetch condition has two cases, and BOTH are needed:
    //   ~rd_valid & ~prefetch_d  -- start-up, or recovery after a starvation
    //   de_raw & rd_px == 2      -- steady state, two cycles before use
    //
    // The ~prefetch_d term is NOT optional. rd_valid only rises one cycle
    // after prefetch_d, and prefetch_d lags prefetch by one, so during the
    // start-up window ~rd_valid stays high for TWO cycles and the read would
    // be issued twice. The second read (group N+1) then lands in rd_hold on
    // top of group N, which has emitted only its first pixel -- producing
    // 0,5,6,7,8,... instead of 0,1,2,3,4,...
    //
    // Without the first term the logic deadlocks instead: rd_px cannot advance
    // until rd_valid is set, and rd_valid cannot be set without a fetch.
    //
    // prefetch_d is DECLARED BEFORE IT IS USED, two lines above where it used to
    // sit. That single-line ordering produced the third instance of this defect
    // class in this project, and the one that settled how to find them:
    //
    //   iverilog, default   : silent
    //   iverilog -Wall      : SILENT TOO. It reported the nineteen scalar signals
    //                         in bitblt_top.v but said nothing about this scalar
    //                         reg, nor about five arrays in
    //                         tb_bitblt_sprite_walker.v. The -Wall check added
    //                         earlier is therefore NOT a reliable detector for
    //                         this class -- it caught one instance and missed
    //                         another.
    //   Questa              : "Undefined variable: 'prefetch_d'" plus "already
    //                         declared in this scope". Every time.
    //
    // The only dependable way to find these is to run Questa. work\cross_sim.py
    // does that for all 22 testbenches and derives the file lists itself.
    reg  prefetch_d;
    // start the fetch 2 (96b entry) or 6 (128b) cycles before the group is used
    wire need_group = (~rd_valid & ~prefetch_d)
                    | (de_raw & (rd_px == (PIX565 ? 3'd6 : 2'd2)));
    wire prefetch   = need_group & ~fifo_empty;

    // 2026-10-25: fifo_re is declared above (line ~334); it is ASSIGNED further
    // down because the drain logic needs fifo_wcnt.

    // ========================================================================
    // 2026-10-25: DRAIN DISABLED -- it threw away the next frame's row 0
    // ========================================================================
    // The drain existed to discard pixels fetched for the previous frame after
    // a realign. With rd_row derived from v_cnt there is no realign left to
    // repair -- and keeping the drain is actively harmful: it holds fifo_re
    // high during vertical blanking, which is exactly when the NEXT frame's row
    // 0 is being fetched. Those row 0 entries arrived while the drain was
    // still eating everything, so the first displayed line of every frame was
    // wrong again.
    //
    // Evidence (all three testbenches drive this module):
    //   tb_bitblt_video_out : 95,994 mismatching pixels
    //   tb_video_split      : first AR at base+stride instead of base
    //   tb_mux_video        : row 0 only 1,913 of 1,920 pixels driven
    // Turning the drain off and asking for row 0 first fixes all three.
    wire drain = 1'b0;

    // ========================================================================
    // 2026-10-27 ★ ROW-LEVEL PRESENTATION (anti-judder)
    // ========================================================================
    // de used to be gated per PIXEL by FIFO emptiness, so a starve in the middle
    // of a line produced half a picture and half black -- the horizontal banding
    // on the panel. FrameSpeed does the opposite (fs_scanout.v): decide at x==0
    // whether the whole line is presentable and hold that decision for the full
    // line ("a late line is black for its whole duration, never shifted pixels").
    reg        row_ok;
    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk)                row_ok <= 1'b0;
        else if (de_raw && (h_cnt == 13'd0)) row_ok <= ~fifo_empty;
    end

    assign fifo_re = prefetch;

    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) begin
            rd_px      <= {RPB{1'b0}};
            rd_hold    <= {RW{1'b0}};
            rd_valid   <= 1'b0;
            prefetch_d <= 1'b0;
        end else begin
            prefetch_d <= prefetch;

            // data arrives one cycle after the read was issued
            if (prefetch_d)
                rd_hold <= fifo_rdata;

            if (prefetch_d)
                rd_valid <= 1'b1;
            else if (need_group & fifo_empty)
                rd_valid <= 1'b0;      // starved: stop claiming a valid pixel

            // RESET THE PHASE ONLY IN VERTICAL BLANKING -- not every line.
            //
            // A row is exactly fb_width pixels = a whole number of four-pixel
            // groups, so rd_px ends a row on 3 and the next row naturally
            // continues at 0. The group for the next row has already been
            // fetched (need_group fires at rd_px == 2, so the fetch lands while
            // rd_px == 3 still reads the old group).
            //
            // Doing this per LINE instead of per FRAME is wrong and was tried:
            // resetting on every !de_raw lets a single stray de_raw-low cycle
            // mid-row rewind rd_px, which repeats one group and drops another.
            // tb_bitblt_video_out showed exactly that -- output ran
            // ...632,633,632,633,634... and lost 638/639, i.e. a permanent
            // 2-pixel skew.
            //
            // Vertical blanking is the right scope: it is where a frame begins,
            // and it is the only place the phase ever needs forcing.
            if (!v_active)
                rd_px <= {RPB{1'b0}};
            else if (rd_valid)
                rd_px <= rd_px + 1'b1;
        end
    end

    // de is COMBINATIONAL: it must be asserted in the same cycle as the pixel
    // it describes. rd_hold already carries the one-cycle RAM latency.
    //
    // SLICES ARE 24 BITS APART, NOT 32. beat_rgb packs four pixels into 96
    // bits by DROPPING each pixel's alpha byte, so pixel n lives at
    // [n*24 +: 24]. Using 32-bit strides here reads across two neighbouring
    // pixels: at rd_px=1 it returned {0x06,0x0000} = 0x060000 = 393216
    // instead of 1.
    // 2026-10-27: whole line present or absent as one unit (see row_ok).
    assign de  = de_raw & rd_valid & row_ok;

    // Timing blanking only -- NOT de. de additionally depends on the FIFO being
    // fed (rd_valid), so it goes low whenever supply falls behind. That is a
    // starvation indicator, and reporting it as "blanking" would make software
    // think it may reconfigure scan-out precisely when the display is starved.
    // 2026-10-24 FIX: o_blanking must mean VERTICAL blanking, not "no pixel
    // this cycle". It used to be ~de_raw, and de_raw is false in HORIZONTAL
    // blanking too (de_raw = h_active & v_active), so software polling
    // blt_scan_blanking() -- which the driver documents as "wait for the
    // vertical blanking before flipping fb_base" -- was satisfied at the first
    // inter-line gap it saw. Every blt_set_fb then landed mid-frame and tore
    // the picture once per flip, which is the flicker seen on the board.
    //
    // de_raw stays the right source for de and for the starvation counter:
    // those are per-pixel questions. Only the blanking flag is per-line.
    // 2026-10-24: RESTORED to the intended vertical-blanking meaning.
    //
    // The experiment that set this back to ~de_raw was there to find out whether
    // the vblank fix is what wedged the animation at f=4. It is not the cause of
    // that wedge -- and it IS the cause of a serious defect: ~de_raw is also true
    // during HORIZONTAL blanking, so blt_scan_wait_blanking() (documented as
    // "wait for the vertical blanking before flipping fb_base") was satisfied at
    // the first inter-line gap, and every blt_set_fb landed mid-frame. That is
    // what a realign build measured as 959,128 mismatching pixels in
    // copy-readback: the flip tore the frame while the copy-back was reading it.
    //
    // de_raw stays the right source for de and for the starvation counter -- those
    // are per-pixel questions. Only the blanking flag is per-line.
    assign o_blanking = ~v_active;

    // ---- starvation, counted in the pixel domain ----
    // Saturating: a wrap would turn "256 bad cycles" into "0 bad cycles", which
    // reads as "nothing wrong". The sticky bit carries the fact; the count
    // carries the scale, and saturating keeps the scale honest at the top end.
    wire pixel_short = de_raw & ~de;

    reg        short_sticky;
    reg [31:0] short_count;      // was [7:0]; see the port note above

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            short_sticky <= 1'b0;
            short_count  <= 32'd0;
        end else begin
            if (pixel_short) begin
                short_sticky <= 1'b1;
                if (short_count != 32'hFFFF_FFFF) short_count <= short_count + 32'd1;
            end
        end
    end

    assign o_short_sticky = short_sticky;
    assign o_short_count  = short_count;

    // ---- frame accounting (2026-10-14) ----
    // A line counts once its last active pixel is reached (h_cnt == H_ACT-1)
    // while v_active: i.e. a line that really was inside the active region.
    // v_cnt == V_TOTAL-1 is the final cycle of the frame, at which point
    // lines_now holds this frame's total -- it is latched into lines_last so
    // software reads a STABLE number (the live one is rewritten every line).
    reg [15:0] lines_now;
    reg [15:0] lines_last;
    reg [31:0] frames_out;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            lines_now  <= 16'd0;
            lines_last <= 16'd0;
            frames_out <= 32'd0;
        end else begin
            if (h_active && v_active && (h_cnt == H_ACT - 1))
                lines_now <= lines_now + 16'd1;

            // 2026-10-14 FIX -- this used to test "v_cnt == V_TOTAL-1" as a
            // LEVEL, which is true for a whole LINE (H_TOTAL cycles), not for
            // one cycle. So frames_out incremented once per pclk for a full
            // line, reporting ~2200 frames per frame, and lines_last latched
            // lines_now one cycle after clearing it, so the active-line count
            // always read 0.
            //
            // Both board readings -- "active lines = 0" and "frames in 1666691
            // cycles: 2200" -- were THIS bug, not the scan-out.
            //
            // The frame boundary is the single cycle where BOTH counters hold
            // their last value.
            if ((v_cnt == V_TOTAL - 1) && (h_cnt == H_TOTAL - 1)) begin
                lines_last <= lines_now;
                lines_now  <= 16'd0;
                frames_out <= frames_out + 32'd1;
            end
        end
    end

    // ========================================================================
    // OBSERVABILITY COUNTERS (2026-10-27)
    // ========================================================================
    // underruns : a line began (x==0, active video) with an EMPTY FIFO. That row
    //             is guaranteed to be short, which is what the panel shows as a
    //             horizontal band or a partial line.
    // shown     : frames whose every active line started with data available.
    //             scans - shown is therefore the number of damaged frames.
    // axi_errors: RRESP != OKAY on an accepted beat.
    // All three are free-running saturating counters cleared only by reset.
    reg [31:0] underrun_cnt;
    reg [31:0] shown_cnt;
    reg [31:0] axi_err_cnt;
    reg        frame_clean;
    wire       line_first = v_active && (h_cnt == 16'd0);

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            underrun_cnt <= 32'd0;
            shown_cnt    <= 32'd0;
            frame_clean  <= 1'b1;
        end else begin
            if (line_first && fifo_empty) begin
                underrun_cnt <= underrun_cnt + 32'd1;
                frame_clean  <= 1'b0;
            end
            if ((v_cnt == V_TOTAL - 1) && (h_cnt == H_TOTAL - 1)) begin
                if (frame_clean) shown_cnt <= shown_cnt + 32'd1;
                frame_clean <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) axi_err_cnt <= 32'd0;
        else if (m_axi_rvalid && m_axi_rready && (m_axi_rresp != 2'b00))
            axi_err_cnt <= axi_err_cnt + 32'd1;
    end

    assign o_underruns  = underrun_cnt;
    assign o_shown      = shown_cnt;
    assign o_axi_errors = axi_err_cnt;

    assign o_lines_last = lines_last;
    assign o_frames     = frames_out;
    wire [15:0] px565 = rd_hold[{rd_px, 4'b0000} +: 16];
    wire [23:0] rgb565 = { px565[15:11], px565[15:13],      // R5 -> R8 (replicate high)
                           px565[10:5],  px565[10:9],       // G6 -> G8
                           px565[4:0],   px565[4:2] };      // B5 -> B8
    wire [23:0] rgb888 = (rd_px == 2'd0) ? rd_hold[23:0]  :
                         (rd_px == 2'd1) ? rd_hold[47:24] :
                         (rd_px == 2'd2) ? rd_hold[71:48] :
                                           rd_hold[95:72];
    assign rgb = PIX565 ? rgb565 : rgb888;

    // ========================================================================
    // 4. Write side bookkeeping
    // ========================================================================
    // Back-pressure is now just "FIFO full": there is no splitter to serialise,
    // so a beat is accepted and stored in the same cycle. rready high therefore
    // means a beat really is consumed.
    assign m_axi_rready = ~fifo_full;

    // ------------------------------------------------------------------
    // 3c. LINE-PHASE REALIGNMENT AT EVERY VERTICAL BLANKING (2026-10-24)
    // ------------------------------------------------------------------
    // rd_row / px_in_line advance ONLY when a beat is written; they never look
    // at where the scan is. So any starvation shifts the framebuffer row
    // against the screen row PERMANENTLY (bitblt.h documents this), and the
    // shift accumulates.
    //
    // Measured on the board: a locator bar painted at framebuffer y=0..7 was
    // first seen along the top edge and later about half way down the panel,
    // and the whole picture appeared to flicker as the offset kept moving.
    // Realigning both counters at the start of every vertical blanking removes
    // the accumulated error once per frame.
    //
    // v_active is in the pixel-clock domain and the counters are in the AXI
    // clock domain, so the edge is detected in pclk and crossed on two flops.
    reg v_act_d;
    always @(posedge pclk or negedge rst_n_pclk) begin
        if (!rst_n_pclk) v_act_d <= 1'b0;
        else             v_act_d <= v_active;
    end
    // v_active synchronised into the AXI clock domain, for the row-counter hold.
    reg v_act_s1, v_act_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_act_s1 <= 1'b0;
            v_act_s2 <= 1'b0;
        end else begin
            v_act_s1 <= v_active;
            v_act_s2 <= v_act_s1;
        end
    end

    // 2026-10-25: THE REALIGN PULSE WAS TOO NARROW TO CROSS DOMAINS.
    // vblank_p is one pclk wide. pclk is 148.5 MHz (6.7 ns) while clk is 100 MHz
    // (10 ns), so the pulse frequently fell between clk edges and vb_s1 never saw
    // it. The realign then fired only on the frames where it happened to be
    // caught -- which is exactly the 'rd_row reads 3 at the frame boundary'
    // measurement: the counter ran on for a few rows before a later attempt stuck.
    //
    // Deriving the edge here, from the already-synchronised LEVEL, gives a pulse
    // that is one clk wide and therefore always visible in this domain.
    wire vb_edge = v_act_s1 & ~v_act_s2;   // 1 clk wide, rising edge of blanking
    wire vblank_p = v_act_d & ~v_active;   // one pclk wide, once per frame

    reg vb_s1, vb_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vb_s1 <= 1'b0;
            vb_s2 <= 1'b0;
        end else begin
            vb_s1 <= vblank_p;
            vb_s2 <= vb_s1;
        end
    end

    // ========================================================================
    // 2026-10-25 REFACTOR: THE ROW NUMBER COMES FROM THE SCAN, NOT FROM BEATS.
    // ========================================================================
    // The old scheme counted written beats and advanced rd_row when a line had
    // gone by. Its documented premise -- "the two sides cannot drift because the
    // count IS the shared state" -- only holds while the FIFO never empties. Every
    // starvation stopped the count while the pixel side kept consuming, so the
    // framebuffer row and the screen row separated and never rejoined.
    //
    // v_cnt already knows which line is on screen. Carrying it across on two
    // flops and fetching one row ahead removes the inference entirely: whatever
    // the FIFO does, rd_row is always a function of where the scan actually is.
    reg [12:0] vc_s1, vc_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vc_s1 <= 13'd0;
            vc_s2 <= 13'd0;
        end else begin
            vc_s1 <= v_cnt;
            vc_s2 <= vc_s1;
        end
    end

    // Fetch one line ahead, wrapping inside the ACTIVE area only -- blanking rows
    // are never displayed so there is nothing to fetch for them.
    wire [12:0] row_ahead = (vc_s2 + 13'd1 >= V_ACT) ? 13'd0 : (vc_s2 + 13'd1);

    // 2026-10-25 FIX: THE FIRST REQUEST MUST BE ROW 0.
    // "One line ahead" is right in steady state, but on the very first frame
    // nothing has been fetched yet: vc_s2 starts at 0, so row_ahead is 1 and
    // row 0 is not asked for until the first vertical blanking. The FIFO then
    // began with row 1, and every pixel of the first frame sat one row away
    // from where the scan put it. Measured before this fix:
    //   tb_bitblt_video_out : 95,994 mismatching pixels
    //   tb_video_split      : first AR at base+stride instead of base
    //
    // fetched_row resets to 16'hFFFF -- a row that never exists -- so the very
    // first need_line_req asks for row 0. From then on the sequence is
    // 0,1,...,V_ACT-1,0,1,... which is exactly the order the pixel side
    // consumes out of the FIFO. Declared BEFORE rd_row_sel because Questa
    // rejects a forward reference and iverilog silently tolerates one (docs/62).
    reg  [15:0] fetched_row;
    wire [12:0] rd_row_sel = (fetched_row == 16'hFFFF) ? 13'd0 : row_ahead;
    wire [15:0] rd_row     = {3'b000, rd_row_sel};
    assign rd_row_o = rd_row;

    // One request per row: need_line stays high until the read FSM has been
    // handed this row, and arvalid itself is held until arready (AXI rule), so a
    // refused request simply keeps asking.
    //
    // 2026-10-25 FIX: fetched_row is updated when the AR IS ACCEPTED, not when
    // the request merely becomes visible. The first version updated it on
    // need_line_req itself, which cleared the "needs this row" condition one
    // cycle after the FSM left S_IDLE -- so rd_row advanced to the NEXT row
    // while arvalid was still waiting for arready, and m_axi_araddr (a live
    // function of rd_row) put the wrong address on the bus. Every burst was
    // exactly one row late; that IS the 95,994-pixel mismatch, and it is also
    // why the first AR appeared at base+stride in tb_video_split.
    //
    // The row is latched into row_req on the cycle the FSM is launched and used
    // by the address, so the address cannot move under a pending handshake.
    reg  [12:0] row_req;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                                 row_req <= 13'd0;
        else if (need_line_req && state == S_IDLE)  row_req <= rd_row_sel;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fetched_row <= 16'hFFFF;
        else if (state == S_AR && arvalid_r && m_axi_arready)
            fetched_row <= {3'b000, row_req};
    end
    wire need_line_req = enable & (fetched_row != rd_row);

    // ========================================================================
    // 4b. Prefetch decision, taken straight from the FIFO's own level
    // ========================================================================
    // fifo_wcnt counts ENTRIES now, and one entry is four pixels, so it is
    // shifted left by 2 before being compared with fb_width (pixels).
    //
    // fifo_wcnt is FIFO_AW-2 bits wide, i.e. FIFO_AW-1 bits; it is zero
    // extended to 16 bits first. Getting this pad wrong is not harmless: too
    // few bits and a full FIFO reads low, so need_line keeps requesting data
    // that will not fit.
    wire [15:0] wcnt16    = {{(17-FIFO_AW){1'b0}}, fifo_wcnt};
    wire [15:0] wpix16    = PIX565 ? {wcnt16[12:0], 3'b00}    // entries * 8 = pixels
                                  : {wcnt16[13:0], 2'b00};    // entries * 4 = pixels
    // 2026-10-25 REFACTOR: request per ROW, not "less than a line in the FIFO".
    // The FIFO-level test asked for data whenever the level dropped, re-issuing an
    // address already fetched. need_line_req compares the row the scan needs
    // against the row already handed to the read FSM.
    wire        need_line = need_line_req;

    // ---------------------------------------------------------------
    // BURST ADMISSION (2026-10-14 -- same disease as docs/63, other patient)
    // ---------------------------------------------------------------
    // m_axi_rready is ~fifo_full, so a burst that does not fit ENTIRELY in the
    // FIFO can have rready pulled mid-burst. AXI forbids that from completing:
    // the master stops accepting, the slave still owes beats, and the read FSM
    // parks in S_R forever. Measured in tb_mux_video at 1920 pixels wide:
    //   state=2 (S_R)  fifo_full=1  wcnt=512  need_line=0
    // -- the FSM waiting in S_R with a full FIFO, which it can never leave.
    //
    // need_line is NOT the guard: it only asks for "less than one line" of
    // pixels (480 entries at fb_width=1920), while one SEGMENT is 256 entries
    // and the FIFO holds 512. So the old rule could start a 256-entry segment
    // with as few as 32 entries free.
    //
    // The rule is the same one the BitBlt read engine had to adopt: only start
    // a burst that fits. The length is bounded by the free space at the moment
    // it is issued, so a burst can always complete without the consumer's help.
    // fifo_free / seg_fits are defined BELOW, after seg_beats exists -- Questa
    // rejects a forward reference and iverilog silently tolerates one, and that
    // difference has already cost this project three debug cycles (docs/62).

    // ========================================================================
    // 5. AXI4 read FSM -- ONE LINE, POSSIBLY SPLIT ACROSS 4 KB PAGES
    // ========================================================================
    // A full-HD line is 1920 pixels = 7680 bytes, which is LARGER than one
    // 4 KB page, so a single burst can never carry it: AXI4 forbids a burst
    // from crossing a 4 KB boundary, arlen is only 8 bits (256 beats = 4096
    // bytes at 16 bytes/beat), and the DDR3 controller does not split a
    // crossing burst (docs/40).
    //
    // So a line is issued as ceil(line_bytes / 4096) bursts, each at most one
    // page long. The address and length of the CURRENT burst are pure
    // functions of seg_idx, not running accumulators -- that keeps them valid
    // in the same cycle seg_idx changes, with no "when does the sum update"
    // question.
    //
    // This relies on the line start being page-aligned, which holds when BOTH
    // fb_base and fb_stride are multiples of 4096. Both conditions are checked
    // below rather than assumed; a misaligned stride would make the first
    // burst shorter than a page and the arithmetic here wrong.
    //
    //   1920 px -> total_beats 480 -> segment 0: 256 beats (4096 B)
    //                                 segment 1: 224 beats (3584 B)
    localparam S_IDLE = 2'd0,
               S_AR   = 2'd1,
               S_R    = 2'd2;

    reg [1:0]  state;
    reg        arvalid_r;
    // 2026-10-27: 3 -> 5 bits. The segment is now 16 beats (256 B) instead of
    // 256 beats (4 KB), so a 1920-pixel line needs ceil(480/16) = 30 segments.
    reg [4:0]  seg_idx;          // 0-based; 5 bits = up to 32 segments

    wire [15:0] total_beats = fb_width >> (PIX565 ? 3 : 2);   // beats in the whole line
    // 2026-10-27 ★ BURST GRANULARITY IS THE SLOW-STATE ROOT.
    // Axi_Mux hands the R channel to one master until rlast:
    //     M_R_End = M_R_Ready & M_R_Valid & M_R_Last;
    // With a 256-beat segment the scan-out therefore OWNS the R channel for 256
    // consecutive cycles, twice per line (2 x 256 = 512 of the ~1,481 cycles a
    // 1080p line takes = ~35% of the time). Every engine read has to queue
    // behind that, which is what turned a ~10-cycle read into ~58,000 cycles.
    //
    // The reference implementation (FrameSpeed-Engine, fs_scanout.v) issues
    // FIXED 16-beat bursts and re-arbitrates after every rlast; its arbiter
    // header says it outright: "Scanout requests only 320 words per line,
    // leaving idle time for blitter". 16 beats here = 256 bytes = a quarter of
    // the old segment, so a line becomes 30 bursts and the channel is released
    // every 16 cycles instead of every 256.
    // 2026-10-27 (v2): 16 -> 64 beats (1 KB). 16 was measured to be TOO SMALL:
    // each segment costs an AR handshake, and tb showed segments arriving
    // millions of cycles apart once the line had 30 of them -- the read could
    // not keep up with the scan and rows were skipped. 64 beats is the
    // compromise: 8 segments per 1080p line (vs 2 at 4 KB, 30 at 256 B), R
    // channel occupancy per burst drops 4x, AR count rises only 4x.
    localparam [15:0] SEG_BEATS = 16'd64;
    wire [15:0] seg_start   = {11'd0, seg_idx} * SEG_BEATS; // first beat of this segment
    wire [15:0] seg_beats   = (total_beats > seg_start + SEG_BEATS)
                              ? SEG_BEATS
                              : (total_beats - seg_start);
    wire        last_seg    = (seg_start + seg_beats) >= total_beats;

    // ---- burst admission (see the long note further up) ----
    // Declared HERE because seg_beats is only defined here; every user (S_IDLE,
    // S_AR) is further down the file.
    localparam [16:0] FIFO_ENTRIES = 17'd1 << FAW;
    wire [16:0] fifo_free = FIFO_ENTRIES - {1'b0, wcnt16};
    wire        seg_fits  = (fifo_free >= {1'b0, seg_beats});

    assign m_axi_arid    = AXI_ID;
    // row_req, NOT rd_row: the row must be the one latched when this burst was
    // admitted, not whatever the scan has advanced to by the time arready comes.
    assign m_axi_araddr  = fb_base + ({3'b000, row_req} * fb_stride) + (seg_idx * 32'd1024);
    assign m_axi_arlen   = seg_beats[7:0] - 8'd1;         // beats - 1, max 255
    assign m_axi_arsize  = 3'b100;                        // 16 bytes = 128 bit
    assign m_axi_arburst = 2'b01;                         // INCR
    assign m_axi_arvalid = arvalid_r;

    // ---------------------------------------------------------------
    // Configuration sanity
    // ---------------------------------------------------------------
    // Each burst fetches seg_beats beats of four 32-bit pixels, while rd_row
    // advances once fb_width pixels have been pushed into the FIFO. Those two
    // only agree if the segments exactly tile the line, which needs the
    // alignment described above.
    //
    // The earlier revision could not split at all, and rejected any fb_width
    // whose beat count exceeded 256. Splitting removes that limit; what
    // remains is the alignment requirement and the 8-segment ceiling.
    wire [15:0] beats_w = fb_width >> (PIX565 ? 3 : 2);
    wire cfg_bad = (fb_width[1:0] != 2'd0)        // must be a multiple of 4 pixels
                || (beats_w == 16'd0)             // degenerate
                || (fb_stride[11:0] != 12'd0)     // stride must be page-aligned
                || (fb_base[11:0]   != 12'd0)     // so must the framebuffer base
                || (beats_w > 16'd8192);          // 32 segments x 256 beats (64-beat segs use 8)

    assign cfg_error = cfg_bad;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            arvalid_r <= 1'b0;
            seg_idx   <= 5'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    // rready is high whenever the FIFO is not full, so the
                    // only reason to wait is a full FIFO (or a bad config).
                    if (need_line && !cfg_bad && seg_fits) begin
                        seg_idx   <= 5'd0;
                        arvalid_r <= 1'b1;
                        state     <= S_AR;
                    end
                end

                S_AR: begin
                    // ONCE ARVALID IS UP IT MUST STAY UP UNTIL ARREADY.
                    //
                    // Axi_Mux's AR arbiter latches onto the requesting channel
                    // in S_ADDR_IDLE and releases it only on M_A_End, where
                    //     M_A_Valid = |(Act_Cnl_List & S_A_Valid)
                    // inspects ONLY the locked channel. Dropping arvalid before
                    // the handshake makes M_A_Valid fall, M_A_End never fires,
                    // and S_A_Ready stays stuck on that channel forever --
                    // starving every other master, the BitBlt engines included.
                    // That is exactly the "rd0/rd1 AR handshake wedged" the
                    // board reports.
                    //
                    // Consequence for the admission rule: it may gate the START
                    // of a request, never abort one already presented. The first
                    // version of this guard did abort it (an "else arvalid_r <=
                    // 1'b0" arm) and would have introduced the very deadlock it
                    // was meant to prevent.
                    if (arvalid_r) begin
                        if (m_axi_arready) begin
                            arvalid_r <= 1'b0;
                            state     <= S_R;
                        end
                    end else if (seg_fits) begin
                        arvalid_r <= 1'b1;
                    end
                end

                S_R: begin
                    // rlast terminates one SEGMENT, not the line.
                    if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                        if (last_seg) begin
                            state <= S_IDLE;      // whole line done
                        end else begin
                            seg_idx   <= seg_idx + 5'd1;
                            arvalid_r <= 1'b1;    // next page of the same line
                            state     <= S_AR;
                        end
                    end
                end

                // Never leave ARVALID asserted from an undefined state. Without
                // this the read request could stay on the bus indefinitely and
                // the FIFO would drain with nothing refilling it.
                default: begin
                    state     <= S_IDLE;
                    arvalid_r <= 1'b0;
                end
            endcase
        end
    end

endmodule
