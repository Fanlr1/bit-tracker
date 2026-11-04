//============================================================================
// bitblt_sprite_walker -- P4 traversal engine
//============================================================================
// Walks a sprite descriptor table and drives the existing BitBlt datapath once
// per sprite. The CPU writes the table base and the count, sets the enable bit,
// and then does nothing until the whole frame is drawn.
//
// WHAT THIS IS NOT (yet): it does not update sprite state. Position, velocity
// and lifetime are the "maintenance" half of P4 and are not implemented here.
// The descriptor has a spare flags word reserved for them. This module only
// reads, dispatches, and advances -- which is the prerequisite for everything
// else, because state you cannot sequence is state you cannot update.
//
// ---------------------------------------------------------------------------
// DESCRIPTOR FORMAT -- 16 bytes, one 128-bit beat
// ---------------------------------------------------------------------------
//   +0   src_addr        [31:0]      sprite image address in memory
//   +4   dst_y | dst_x   [31:16][15:0]
//   +8   height | width  [31:16][15:0]
//   +12  flags | alpha   [31:16][15:0]   reserved for P4 state work
//
// Sixteen bytes is deliberate, not incidental: bitblt_dma_rd emits 128-bit
// beats, so one fetch yields exactly one whole descriptor. Anything larger
// would need reassembly across beats and a byte counter to go with it.
//
// ---------------------------------------------------------------------------
// WHY THE SOURCE READ ENGINE IS SHARED
// ---------------------------------------------------------------------------
// Axi_Mux has five slave ports and all five are taken (SoC, source read,
// destination read, write, scan-out). Adding a sixth would mean touching
// Axi_Mux's X5 macro, its arbitration, and forty-odd port mappings in
// system_top -- an interconnect change to support a feature that fits
// comfortably in the gaps.
//
// And there ARE gaps: this engine is only active BETWEEN blits, which is
// exactly when the source read engine is idle. So the two are mutually
// exclusive by construction. fetch_start is therefore wired to the same
// dma_rd.start that the source read uses, and the datapath routes the returned
// beat to whichever of the two asked for it.
//
// The one hazard this creates is worth stating: if a fetch overlapped a blit,
// both would fight for one read engine. The state machine prevents it by never
// asserting fetch_start while S_RUN, and blit_start is only ever a one-cycle
// pulse. The testbench asserts the non-overlap directly rather than trusting
// the state machine to be obvious.
//============================================================================

`timescale 1ns / 1ps

module bitblt_sprite_walker #(
    parameter AW  = 32,
    parameter DW  = 128
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---------------- configuration (from the register file) ----------------
    input  wire [AW-1:0]    table_base,      // IDX_SPR_TABLE
    input  wire [15:0]      sprite_count,    // IDX_SPR_CTL[15:0]
    input  wire             enable,          // IDX_SPR_CTL[16]
    input  wire [3:0]       bytes_per_px,

    // Framebuffer geometry, shared by every sprite in the table -- the
    // destination address is computed from these plus the descriptor's x/y.
    input  wire [AW-1:0]    dst_stride,
    input  wire [AW-1:0]    fb_base,

    // ---------------- descriptor fetch (shares the source read engine) ------
    output reg              fetch_start,     // one-cycle pulse
    output reg  [AW-1:0]    fetch_addr,
    output wire [31:0]      fetch_bytes,     // always one descriptor
    input  wire             fetch_busy,
    input  wire             fetch_done,
    input  wire [DW-1:0]    fetch_data,
    input  wire             fetch_valid,

    // ---------------- BitBlt dispatch ----------------
    output reg              blit_start,      // one-cycle pulse
    output reg  [AW-1:0]    spr_src,
    output reg  [AW-1:0]    spr_dst,
    output reg  [15:0]      spr_w,
    output reg  [15:0]      spr_h,
    output reg  [AW-1:0]    spr_src_stride,  // width * bytes_per_px, computed
    input  wire             blit_done,

    // ---------------- live sprite state (position + velocity) --------------
    // The walker draws from HERE, not from the descriptor's x/y, once a slot
    // has been seeded. On the first visit it seeds the slot from the
    // descriptor and uses that; afterwards it uses the live value, which is
    // what stops a sprite snapping back to its table position every frame.
    output reg              st_init_en,
    output wire [15:0]      st_init_idx,
    output reg  [15:0]      st_init_x,
    output reg  [15:0]      st_init_y,
    output reg  [15:0]      st_init_vx,
    output reg  [15:0]      st_init_vy,
    input  wire [15:0]      st_rd_x,
    input  wire [15:0]      st_rd_y,
    input  wire             st_rd_valid,
    input  wire             st_rd_live,
    output reg              st_step_en,
    input  wire             st_frame_done,

    // ---------------- status ----------------
    output reg              busy,
    output reg  [15:0]      cur_index,
    output reg              fetch_active,    // high while the fetch owns the RE
    output reg              done_pulse,      // one cycle when the frame is drawn
    output wire [2:0]       state_o          // DEBUG 2026-10-17: FSM state out
);

    localparam [2:0] S_IDLE  = 3'd0,
                     S_FETCH = 3'd1,
                     S_WAIT  = 3'd2,
                     S_BLIT  = 3'd3,
                     S_RUN   = 3'd4,
                     S_STEP  = 3'd5,
                     S_ADV   = 3'd6;   // shared "next slot" tail

    reg [2:0] state;

    // The state array is indexed by the sprite being walked, and one index
    // serves both the read and the seed.
    assign st_init_idx = cur_index;

    // enable is a LEVEL, so starting on the level alone would restart the walk
    // the instant it finished: S_IDLE sees enable still high, resets cur_index
    // and goes again, forever. That is not a cosmetic loop -- busy never
    // releases, software never learns the frame is done, and the traversal
    // keeps competing with scan-out for the one DDR3.
    //
    // Rising-edge only: one walk per enable assertion. Software draws a frame
    // by clearing then setting the bit, which is also what makes "frame
    // complete" observable.
    reg enable_d;
    wire enable_rise = enable & ~enable_d;

    // One descriptor is exactly one beat.
    assign fetch_bytes = 32'd16;

    // Descriptor fields, latched from the fetched beat.
    reg [31:0] d_src;
    reg [15:0] d_dst_x, d_dst_y;
    reg [15:0] d_w, d_h;
    reg [15:0] d_vx, d_vy;

    // Byte offsets within the descriptor.
    localparam [3:0] OFF_SRC = 4'd0,
                     OFF_DST = 4'd4,
                     OFF_WH  = 4'd8;

    // Reconstruct the destination address from x/y and the framebuffer stride.
    // Both come from the port list: dst_stride is shared by every sprite in a
    // table because they all land in the same framebuffer.

    wire [AW-1:0] desc_addr = table_base + ({16'd0, cur_index} << 4);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            blit_start   <= 1'b0;
            fetch_start  <= 1'b0;
            fetch_addr   <= {AW{1'b0}};
            fetch_active <= 1'b0;
            cur_index    <= 16'd0;
            done_pulse   <= 1'b0;
            d_src        <= 32'd0;
            d_dst_x      <= 16'd0;
            d_dst_y      <= 16'd0;
            d_w          <= 16'd0;
            d_h          <= 16'd0;
            spr_src      <= {AW{1'b0}};
            spr_dst      <= {AW{1'b0}};
            spr_w        <= 16'd0;
            spr_h        <= 16'd0;
            spr_src_stride <= {AW{1'b0}};
            st_init_en     <= 1'b0;
            st_init_x      <= 16'd0;
            st_init_y      <= 16'd0;
            st_init_vx     <= 16'd0;
            st_init_vy     <= 16'd0;
            st_step_en     <= 1'b0;
        end else begin
            blit_start  <= 1'b0;             // defaults: pulses only
            fetch_start <= 1'b0;
            done_pulse  <= 1'b0;
            st_init_en  <= 1'b0;
            st_step_en  <= 1'b0;
            enable_d    <= enable;           // for the rising-edge detect

            case (state)
                // ------------------------------------------------
                S_IDLE: begin
                    busy         <= 1'b0;
                    fetch_active <= 1'b0;
                    if (enable_rise && sprite_count != 16'd0) begin
                        busy      <= 1'b1;
                        cur_index <= 16'd0;
                        state     <= S_FETCH;
                    end
                end

                // ------------------------------------------------
                S_FETCH: begin
                    fetch_addr   <= desc_addr;
                    fetch_start  <= 1'b1;
                    fetch_active <= 1'b1;
                    state        <= S_WAIT;
                end

                // ------------------------------------------------
                // collect the beat. dma_rd presents one beat per valid pulse,
                // and a descriptor is one beat, so a single latch is enough.
                S_WAIT: begin
                    if (fetch_valid) begin
                        d_src   <= fetch_data[31:0];
                        d_dst_x <= fetch_data[47:32];
                        d_dst_y <= fetch_data[63:48];
                        d_w     <= fetch_data[79:64];
                        d_h     <= fetch_data[95:80];
                        // The fourth word was reserved as flags|alpha and now
                        // carries vx|vy. Same layout as x|y, so the unpacking
                        // reads the same way.
                        d_vx    <= fetch_data[111:96];
                        d_vy    <= fetch_data[127:112];
                    end
                    if (fetch_done) begin
                        fetch_active <= 1'b0;
                        state        <= S_BLIT;
                    end
                end

                // ------------------------------------------------
                // Three-way dispatch. Both skip conditions matter:
                //
                //   seeded && !live  -> retired, draw nothing
                //   !seeded          -> freshly launched, draw AND seed
                //   seeded && live   -> in flight, draw from live state
                //
                // Testing !st_rd_live ALONE is a cold-start deadlock: a new
                // slot has live=0 precisely because nothing has seeded it yet,
                // and live is only ever set BY seeding. So every slot would be
                // skipped, nothing would ever be seeded, and the walk would
                // draw zero sprites -- which is exactly what the testbench
                // caught (19 failures) before this was fixed here.
                //
                // A dead slot must also not stall the walk: skipping cannot go
                // through S_RUN, because that state waits for blit_done and no
                // blit was issued. Both paths converge on S_ADV.
                S_BLIT: begin
                    if (st_rd_valid && !st_rd_live) begin
                        // retired slot: issue nothing, move on
                        state <= S_ADV;
                    end else begin
                        spr_src <= d_src;
                        spr_w   <= d_w;
                        spr_h   <= d_h;
                        // A sprite is stored compactly by definition, so the
                        // source stride is just one row of pixels. This is what
                        // lets every dispatched blit take P3's merged path.
                        spr_src_stride <= {16'd0, d_w} * {28'd0, bytes_per_px};

                        // WHERE to draw from: live state if this slot has been
                        // seeded, otherwise the descriptor -- and in that case
                        // seed it now, so the next frame starts from the live
                        // value.
                        if (st_rd_valid) begin
                            spr_dst <= fb_base + ({16'd0, st_rd_y} * dst_stride)
                                              + ({16'd0, st_rd_x} * {28'd0, bytes_per_px});
                        end else begin
                            st_init_en <= 1'b1;
                            st_init_x  <= d_dst_x;
                            st_init_y  <= d_dst_y;
                            st_init_vx <= d_vx;
                            st_init_vy <= d_vy;
                            spr_dst <= fb_base + ({16'd0, d_dst_y} * dst_stride)
                                              + ({16'd0, d_dst_x} * {28'd0, bytes_per_px});
                        end

                        blit_start <= 1'b1;
                        state      <= S_RUN;
                    end
                end

                // ------------------------------------------------
                S_RUN: begin
                    // addr_gen pulses done even when the sprite is entirely
                    // off-screen (oob path commits to S_DONE), so a sprite that
                    // is clipped away cannot wedge the walk.
                    if (blit_done) state <= S_ADV;
                end

                // ------------------------------------------------
                // shared tail: advance to the next slot, or finish the frame
                S_ADV: begin
                    if (cur_index + 16'd1 >= sprite_count) begin
                        // Every sprite visited. The frame is NOT finished yet:
                        // the positions still have to advance, and the next
                        // walk must not start into a half-updated array.
                        // S_STEP waits for the sweep.
                        st_step_en <= 1'b1;
                        state      <= S_STEP;
                    end else begin
                        cur_index <= cur_index + 16'd1;
                        state     <= S_FETCH;
                    end
                end

                // ------------------------------------------------
                // the state array sweeps one slot per cycle, so this takes N
                // cycles. busy stays high throughout -- from the caller's point
                // of view the frame is not done until the positions are.
                S_STEP: begin
                    busy <= 1'b1;
                    if (st_frame_done) begin
                        busy       <= 1'b0;
                        done_pulse <= 1'b1;
                        state      <= S_IDLE;
                    end
                end

                default: begin
                    // All five encodings are defined, so this is simulation-only.
                    // Parking in IDLE (and dropping the request) is safer than
                    // leaving fetch_start asserted at an unknown state.
                    state        <= S_IDLE;
                    fetch_start  <= 1'b0;
                    blit_start   <= 1'b0;
                    fetch_active <= 1'b0;
                    busy         <= 1'b0;
                end
            endcase
        end
    end

// DEBUG 2026-10-17: expose the walk FSM state (IDLE=0 FETCH=1 WAIT=2 BLIT=3 RUN=4 STEP=5 ADV=6).
assign state_o = state;

endmodule
