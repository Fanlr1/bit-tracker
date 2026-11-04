//============================================================================
// bitblt_monitor -- on-chip assertions that software can read
//============================================================================
// WHY THIS EXISTS
//   On the board, the screen only shows whether the picture LOOKS right. There
//   is a class of fault that is invisible there and that software has no reason
//   to ask about:
//
//     * a handshake that never completes        (bus wedged)
//     * a response that is not OKAY             (a transfer silently dropped)
//     * a state machine that never finishes     (indistinguishable from "the
//                                                main loop is not running")
//     * an internal request silently discarded  (software waits forever)
//
//   None of these produce a wrong pixel. They produce a picture that is
//   occasionally, inexplicably wrong -- or one that stops.
//
//   The project already had one hardware assertion, bitblt_video_out's
//   cfg_error, and tb_bitblt_video_out carries a contract test for it. That
//   proves the approach works here; it just covered one condition.
//
// WHAT THIS MODULE IS, AND IS NOT
//   It is a READ-ONLY OBSERVER. It taps signals and drives nothing. It must
//   never introduce a handshake dependency or a delay into the paths it
//   watches -- an observer that changes the behaviour it observes is worse
//   than no observer, because it also invalidates the earlier verification.
//
//   Every condition gets TWO pieces of state:
//     sticky : latched until software clears it. A transient that happened
//              once and stopped is still worth knowing about.
//     count  : how many times. This is what separates "a glitch at power-on"
//              from "happening every frame", which is the first question
//              anyone asks and the one a lone sticky bit cannot answer.
//
//   The counter SATURATES rather than wrapping. A wrap would turn "65536
//   events" into "0 events", which reads as "nothing wrong".
//
// CLEARING
//   Sticky bits clear on a WRITE OF 1 to their bit position, not on a write of
//   0. With clear-on-zero, a register write that happens to carry zeros in the
//   wrong places would silently erase evidence, and "I cleared it" would be
//   indistinguishable from "it never fired".
//============================================================================

`timescale 1ns / 1ps

module bitblt_monitor #(
    // Cycles a valid may wait for its ready before it counts as wedged. At
    // 100 MHz this is 0.65 ms for the default -- far longer than any legitimate
    // handshake (a DDR3 access is tens of cycles, worst case low hundreds), and
    // short enough that software notices within a frame or two.
    parameter TIMEOUT = 16'd65535
) (
    input  wire         clk,
    input  wire         rst_n,

    // ---------------- observed: source read engine (S1) ----------------
    input  wire         rd0_arvalid,
    input  wire         rd0_arready,
    input  wire         rd0_rvalid,
    input  wire         rd0_rready,
    input  wire [1:0]   rd0_rresp,

    // ---------------- observed: destination read engine (S2) -----------
    input  wire         rd1_arvalid,
    input  wire         rd1_arready,
    input  wire         rd1_rvalid,
    input  wire         rd1_rready,
    input  wire [1:0]   rd1_rresp,

    // ---------------- observed: write engine (S3) ---------------------
    input  wire         wr_awvalid,
    input  wire         wr_awready,
    input  wire         wr_wvalid,
    input  wire         wr_wready,
    input  wire         wr_bvalid,
    input  wire         wr_bready,
    input  wire [1:0]   wr_bresp,

    // ---------------- observed: scan-out starvation -------------------
    // o_short_sticky, already synchronised into this clock domain by
    // system_top. One bit, so a two-flop chain there is sound.
    input  wire         scan_short,

    // ---------------- observed: sprite walker -------------------------
    input  wire         spr_busy,
    // A position read-back request that arrived while the walker held the RAM
    // read port. bitblt_top gates it away, so without this the driver waits for
    // a valid bit that will never come -- item 2's known weakness.
    input  wire         pos_req,
    input  wire         pos_req_gated,

    // ---------------- control ----------------
    // One bit per condition, in the order below. Writing 1 clears that sticky.
    input  wire [15:0]  clr_mask,
    input  wire         clr_count,       // write 1 to zero the counters

    // ---------------- readback ----------------
    // 16 sticky bits in one word; the counters are selected by index, in the
    // same shape as SPR_RT_SEL / SPR_RT_BITS and SPR_POS_IDX / SPR_POS_XY.
    output wire [15:0]  sticky_word,
    input  wire [3:0]   cnt_sel,
    output wire [31:0]  cnt_word
);

    // ---- condition indices (documented, because software needs them) ----
    localparam C_RD0_AR = 4'd0;   // source read: AR handshake wedged
    localparam C_RD0_R  = 4'd1;   // source read: R  handshake wedged
    localparam C_RD1_AR = 4'd2;
    localparam C_RD1_R  = 4'd3;
    localparam C_WR_AW  = 4'd4;
    localparam C_WR_W   = 4'd5;
    localparam C_WR_B   = 4'd6;
    localparam C_RESP   = 4'd7;   // any rresp/bresp that was not 2'b00
    localparam C_SPR_HANG = 4'd8; // walker busy for longer than any real frame
    localparam C_POS_DROP = 4'd9; // read-back request discarded by the gate
    localparam C_SHORT    = 4'd10;// scan-out starved: pixels skipped
    localparam C_MAX      = 4'd11;

    // ------------------------------------------------------------------
    // Handshake timeouts. One instance per channel, all identical: a valid
    // that is asserted while ready stays low, for longer than TIMEOUT cycles.
    // ------------------------------------------------------------------
    reg [15:0] tmo_rd0_ar, tmo_rd0_r, tmo_rd1_ar, tmo_rd1_r;
    reg [15:0] tmo_wr_aw,  tmo_wr_w,  tmo_wr_b;
    reg        hit_rd0_ar, hit_rd0_r, hit_rd1_ar, hit_rd1_r;
    reg        hit_wr_aw,  hit_wr_w,  hit_wr_b;

    // The counter resets as soon as the handshake completes, so a long series
    // of short waits never accumulates into a false timeout. Only an
    // UNINTERRUPTED wait counts.
    //
    // WRITTEN OUT SEVEN TIMES RATHER THAN FACTORED INTO A TASK. The obvious
    // version used `task automatic watch(...)` with the counter as an inout
    // argument; iverilog rejects that outright -- "automatically allocated
    // variables may not be assigned values using non-blocking assignments" --
    // because a task's automatic variables are not storage. A non-automatic
    // task would work in simulation but is a poor fit for synthesis. Seven
    // copies of four lines is the honest answer here.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmo_rd0_ar <= 16'd0; tmo_rd0_r <= 16'd0;
            tmo_rd1_ar <= 16'd0; tmo_rd1_r <= 16'd0;
            tmo_wr_aw  <= 16'd0; tmo_wr_w  <= 16'd0; tmo_wr_b <= 16'd0;
        end else begin
            if (!(rd0_arvalid && !rd0_arready)) tmo_rd0_ar <= 16'd0;
            else if (tmo_rd0_ar != TIMEOUT)     tmo_rd0_ar <= tmo_rd0_ar + 16'd1;

            if (!(rd0_rvalid && !rd0_rready))   tmo_rd0_r <= 16'd0;
            else if (tmo_rd0_r != TIMEOUT)      tmo_rd0_r <= tmo_rd0_r + 16'd1;

            if (!(rd1_arvalid && !rd1_arready)) tmo_rd1_ar <= 16'd0;
            else if (tmo_rd1_ar != TIMEOUT)     tmo_rd1_ar <= tmo_rd1_ar + 16'd1;

            if (!(rd1_rvalid && !rd1_rready))   tmo_rd1_r <= 16'd0;
            else if (tmo_rd1_r != TIMEOUT)      tmo_rd1_r <= tmo_rd1_r + 16'd1;

            if (!(wr_awvalid && !wr_awready))   tmo_wr_aw <= 16'd0;
            else if (tmo_wr_aw != TIMEOUT)      tmo_wr_aw <= tmo_wr_aw + 16'd1;

            if (!(wr_wvalid && !wr_wready))     tmo_wr_w <= 16'd0;
            else if (tmo_wr_w != TIMEOUT)       tmo_wr_w <= tmo_wr_w + 16'd1;

            if (!(wr_bvalid && !wr_bready))     tmo_wr_b <= 16'd0;
            else if (tmo_wr_b != TIMEOUT)       tmo_wr_b <= tmo_wr_b + 16'd1;
        end
    end

    // A timeout latches when the counter REACHES the limit, and stays latched
    // until the handshake finally completes. Without the clear the sticky bit
    // would fire on any wait that happened to be long, including a legitimate
    // one, which is how a diagnostic becomes noise.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_rd0_ar <= 1'b0; hit_rd0_r <= 1'b0;
            hit_rd1_ar <= 1'b0; hit_rd1_r <= 1'b0;
            hit_wr_aw  <= 1'b0; hit_wr_w  <= 1'b0; hit_wr_b <= 1'b0;
        end else begin
            if (!(rd0_arvalid && !rd0_arready)) hit_rd0_ar <= 1'b0;
            else if (tmo_rd0_ar == TIMEOUT)     hit_rd0_ar <= 1'b1;

            if (!(rd0_rvalid && !rd0_rready))   hit_rd0_r <= 1'b0;
            else if (tmo_rd0_r == TIMEOUT)      hit_rd0_r <= 1'b1;

            if (!(rd1_arvalid && !rd1_arready)) hit_rd1_ar <= 1'b0;
            else if (tmo_rd1_ar == TIMEOUT)     hit_rd1_ar <= 1'b1;

            if (!(rd1_rvalid && !rd1_rready))   hit_rd1_r <= 1'b0;
            else if (tmo_rd1_r == TIMEOUT)      hit_rd1_r <= 1'b1;

            if (!(wr_awvalid && !wr_awready))   hit_wr_aw <= 1'b0;
            else if (tmo_wr_aw == TIMEOUT)      hit_wr_aw <= 1'b1;

            if (!(wr_wvalid && !wr_wready))     hit_wr_w <= 1'b0;
            else if (tmo_wr_w == TIMEOUT)       hit_wr_w <= 1'b1;

            if (!(wr_bvalid && !wr_bready))     hit_wr_b <= 1'b0;
            else if (tmo_wr_b == TIMEOUT)       hit_wr_b <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Response errors. A response is only meaningful on the cycle its valid is
    // asserted, which is why this is edge-qualified rather than level.
    // ------------------------------------------------------------------
    // COMBINATIONAL, AND THAT IS THE FIX. The first version registered this and
    // only ever set it, so once a SLVERR had occurred resp_err stayed high
    // forever. The event detector downstream is (resp_err & ~sticky[bit]), so
    // clearing the sticky bit made the event fire again on the very next cycle
    // -- the sticky bit could never be cleared. The testbench's NEGATIVE
    // assertion caught it: an OKAY response was reported as an error.
    //
    // A response is only meaningful on the cycle its valid is asserted, so this
    // is naturally a one-cycle pulse.
    wire resp_err = (rd0_rvalid && rd0_rresp != 2'b00) ||
                    (rd1_rvalid && rd1_rresp != 2'b00) ||
                    (wr_bvalid  && wr_bresp  != 2'b00);

    // ------------------------------------------------------------------
    // Walker hang. A frame is bounded: docs/44 measured 82 cycles per 8x2
    // sprite, so even 256 sprites of 32x32 is far under a million cycles
    // (about 10 ms). Two seconds at 100 MHz is 200 million -- an order of
    // magnitude clear, so this cannot fire on a slow but working walk.
    //
    // The counter is 28 bits, which is the widest that still fits the 32-bit
    // readback alongside its index.
    // ------------------------------------------------------------------
    localparam [27:0] SPR_HANG_LIMIT = 28'd200_000_000;
    reg [27:0] spr_run;
    reg        spr_hang;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spr_run  <= 28'd0;
            spr_hang <= 1'b0;
        end else if (!spr_busy) begin
            spr_run <= 28'd0;
        end else if (spr_run == SPR_HANG_LIMIT) begin
            spr_hang <= 1'b1;
        end else begin
            spr_run <= spr_run + 28'd1;
        end
    end

    // ------------------------------------------------------------------
    // Discarded read-back requests. The request was asserted but the gate did
    // not forward it -- which happens whenever software asks while the walker
    // is running. Software gets no valid bit and no error, so it waits out its
    // whole spin budget and gives up with no idea why.
    // ------------------------------------------------------------------
    // Same mistake as resp_err above, same fix. The condition IS the event:
    // the request was asserted and the gate did not forward it.
    wire pos_drop = pos_req && !pos_req_gated;

    // Scan-out starvation, edge-detected into a single event.
    //
    // short_seen FOLLOWS the source rather than latching. The first version set
    // it on the first assertion and never cleared it, on the reasoning that the
    // upstream sticky bit never falls, so it did not matter. That made this
    // module depend on a detail of the module above it: if scan-out starvation
    // ever gains a clear path upstream, the latch here would silently stop
    // reporting every event after the first. Following the source is both
    // simpler and correct for a sticky or a pulsing input.
    //
    // The testbench assertion "starvation re-latches after the source cycles"
    // is what surfaced this. It was written expecting the event to re-fire, and
    // it was right to expect that.
    reg  short_seen;
    wire short_ev = scan_short & ~short_seen;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) short_seen <= 1'b0;
        else        short_seen <= scan_short;
    end

    // ------------------------------------------------------------------
    // Sticky bits and counters.
    // ------------------------------------------------------------------
    reg [15:0] sticky;
    reg [31:0] cnt [0:15];
    integer    i;

    // One-cycle event pulses, so the counters count EVENTS rather than cycles.
    // The & ~sticky[...] term makes each pulse fire once per clear cycle: after
    // the first event the sticky bit is set and the pulse stops, so the counter
    // records "how many times was this cleared and re-triggered" rather than
    // incrementing every cycle a condition persists. That only works if the
    // source is a genuine pulse -- see the two fixes above.
    wire ev_rd0_ar = hit_rd0_ar & ~sticky[C_RD0_AR];
    wire ev_rd0_r  = hit_rd0_r  & ~sticky[C_RD0_R];
    wire ev_rd1_ar = hit_rd1_ar & ~sticky[C_RD1_AR];
    wire ev_rd1_r  = hit_rd1_r  & ~sticky[C_RD1_R];
    wire ev_wr_aw  = hit_wr_aw  & ~sticky[C_WR_AW];
    wire ev_wr_w   = hit_wr_w   & ~sticky[C_WR_W];
    wire ev_wr_b   = hit_wr_b   & ~sticky[C_WR_B];
    wire ev_resp   = resp_err    & ~sticky[C_RESP];
    wire ev_hang   = spr_hang    & ~sticky[C_SPR_HANG];
    wire ev_drop   = pos_drop    & ~sticky[C_POS_DROP];
    wire ev_short  = short_ev    & ~sticky[C_SHORT];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sticky <= 16'd0;
            for (i = 0; i < 16; i = i + 1) cnt[i] <= 32'd0;
        end else begin
            // ---- counters: saturating, and cleared by an explicit command ----
            if (clr_count) begin
                for (i = 0; i < 16; i = i + 1) cnt[i] <= 32'd0;
            end else begin
                if (ev_rd0_ar && cnt[C_RD0_AR] != 32'hFFFF_FFFF) cnt[C_RD0_AR] <= cnt[C_RD0_AR] + 32'd1;
                if (ev_rd0_r  && cnt[C_RD0_R ] != 32'hFFFF_FFFF) cnt[C_RD0_R ] <= cnt[C_RD0_R ] + 32'd1;
                if (ev_rd1_ar && cnt[C_RD1_AR] != 32'hFFFF_FFFF) cnt[C_RD1_AR] <= cnt[C_RD1_AR] + 32'd1;
                if (ev_rd1_r  && cnt[C_RD1_R ] != 32'hFFFF_FFFF) cnt[C_RD1_R ] <= cnt[C_RD1_R ] + 32'd1;
                if (ev_wr_aw  && cnt[C_WR_AW ] != 32'hFFFF_FFFF) cnt[C_WR_AW ] <= cnt[C_WR_AW ] + 32'd1;
                if (ev_wr_w   && cnt[C_WR_W  ] != 32'hFFFF_FFFF) cnt[C_WR_W  ] <= cnt[C_WR_W  ] + 32'd1;
                if (ev_wr_b   && cnt[C_WR_B  ] != 32'hFFFF_FFFF) cnt[C_WR_B  ] <= cnt[C_WR_B  ] + 32'd1;
                if (ev_resp   && cnt[C_RESP  ] != 32'hFFFF_FFFF) cnt[C_RESP  ] <= cnt[C_RESP  ] + 32'd1;
                if (ev_hang   && cnt[C_SPR_HANG] != 32'hFFFF_FFFF) cnt[C_SPR_HANG] <= cnt[C_SPR_HANG] + 32'd1;
                if (ev_drop   && cnt[C_POS_DROP] != 32'hFFFF_FFFF) cnt[C_POS_DROP] <= cnt[C_POS_DROP] + 32'd1;
                if (ev_short  && cnt[C_SHORT   ] != 32'hFFFF_FFFF) cnt[C_SHORT   ] <= cnt[C_SHORT   ] + 32'd1;
            end

            // ---- sticky bits: set by an event, cleared by writing 1 ----
            // The new value is (old | event) & ~clr_mask, so a clear command
            // and a simultaneous event resolve in favour of the event: losing
            // evidence to a race with the clear is the worse failure.
            sticky[0]  <= (sticky[0]  | ev_rd0_ar)   & ~clr_mask[0];
            sticky[1]  <= (sticky[1]  | ev_rd0_r)    & ~clr_mask[1];
            sticky[2]  <= (sticky[2]  | ev_rd1_ar)   & ~clr_mask[2];
            sticky[3]  <= (sticky[3]  | ev_rd1_r)    & ~clr_mask[3];
            sticky[4]  <= (sticky[4]  | ev_wr_aw)    & ~clr_mask[4];
            sticky[5]  <= (sticky[5]  | ev_wr_w)     & ~clr_mask[5];
            sticky[6]  <= (sticky[6]  | ev_wr_b)     & ~clr_mask[6];
            sticky[7]  <= (sticky[7]  | ev_resp)     & ~clr_mask[7];
            sticky[8]  <= (sticky[8]  | ev_hang)     & ~clr_mask[8];
            sticky[9]  <= (sticky[9]  | ev_drop)     & ~clr_mask[9];
            sticky[10] <= (sticky[10] | ev_short)    & ~clr_mask[10];
            sticky[15:11] <= sticky[15:11] & ~clr_mask[15:11];   // reserved, clearable
        end
    end

    assign sticky_word = sticky;
    assign cnt_word    = (cnt_sel < C_MAX) ? cnt[cnt_sel] : 32'd0;

endmodule
