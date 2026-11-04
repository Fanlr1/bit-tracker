// BitBlt address generator -- produces a PER-LINE address sequence.
//
// WHY PER-LINE AND NOT PER-PIXEL
//   The competition explicitly requires burst transfers to keep memory bandwidth
//   up. A burst is naturally one image row, so this module hands the DMA one
//   (source address, destination address, byte count) triple per row. Emitting a
//   per-pixel address stream instead would force a separate AXI transaction per
//   pixel and waste most of the available bandwidth.
//
// ADDRESS RECURRENCE
//   line N source = src_base + N * src_stride
//   line N dest   = dst_base + N * dst_stride
//   The two strides are independent because source images are often tightly
//   packed while the framebuffer is not (or vice versa).
//
// HANDSHAKE
//   line_req is asserted when a line is ready and stays asserted until the DMA
//   answers with a one-cycle line_ack. The counters only advance on that ack, so
//   the DMA can take as long as it needs.
//
// BOUNDS CHECKING
//   Without it, a sprite that extends past the end of the framebuffer writes
//   into whatever DDR follows it. That is not a display glitch, it is memory
//   corruption, and the competition's bullet-hell demo is exactly the workload
//   where sprites run off the edge.
//
//   Two levels of protection:
//     * here, each line's destination address is checked before it is issued.
//       A line that would start outside [fb_start, fb_end) ends the transfer
//       early instead of writing. This truncates a rectangle that overruns the
//       end of the framebuffer.
//     * horizontal overrun cannot be fixed here, because a line is one burst --
//       splitting it would cost the burst efficiency the competition asks for.
//       The driver clips in X before issuing the command; this module guarantees
//       the Y direction cannot run away.
//
//   fb_start / fb_end come from the FB_BASE and FB_SIZE_H/FB_CFG registers, so
//   the bound follows the active framebuffer automatically when double buffering
//   switches buffers.
`timescale 1ns / 1ps

module bitblt_addr_gen #(
    parameter AW = 32
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             ce,

    // ---------------- configuration (driven by M1's registers) ----------------
    input  wire [AW-1:0]    src_base,
    input  wire [AW-1:0]    dst_base,
    input  wire [15:0]      img_width,
    input  wire [15:0]      img_height,
    input  wire [AW-1:0]    src_stride,
    input  wire [AW-1:0]    dst_stride,
    input  wire [3:0]       bytes_per_px,    // 1 / 2 / 4 / 8

    // ---------------- framebuffer bounds ----------------
    input  wire [AW-1:0]    fb_start,
    input  wire [AW-1:0]    fb_end,          // one past the last valid byte

    // ---------------- control ----------------
    input  wire             start,           // one-cycle pulse
    output reg              busy,
    output reg              done,            // one-cycle pulse
    output reg              oob,             // sticky until the next start
    // WHERE the transfer was refused, in destination-address terms. The flag
    // alone says something went wrong; without the address, software has to
    // guess whether the framebuffer base is wrong, the stride is wrong, or the
    // sprite really was off-screen. Two different refusals set this:
    //   * the whole rectangle starts outside [fb_start, fb_end) -> dst_base
    //   * the next row would start outside it                -> that row's base
    // Cleared on every start alongside oob, for the same reason.
    output reg  [AW-1:0]    oob_addr,

    // ---------------- per-line interface to the DMA (M5) ----------------
    output reg  [AW-1:0]    line_src_addr,
    output reg  [AW-1:0]    line_dst_addr,
    output reg  [31:0]      line_bytes,      // img_width * bytes_per_px
    output wire             compact_src,     // src rows adjacent in memory
    output wire [31:0]      src_bytes_total, // whole rectangle when compact
    output reg  [15:0]      line_index,
    output reg              line_req,        // held high until line_ack
    input  wire             line_ack,        // one-cycle pulse from the DMA
    output wire [1:0]       state_o          // DEBUG 2026-10-17: FSM state out
);

    localparam [1:0] S_IDLE = 2'd0,
                     S_LINE = 2'd1,
                     S_DONE = 2'd2,
                     S_GAP  = 2'd3;   // one cycle with line_req LOW, so the next
                                      // line produces a fresh rising edge

    reg [1:0] state;

    // width * bytes_per_px, computed combinationally from the config inputs
    wire [31:0] bytes_this_line = {16'd0, img_width} * {28'd0, bytes_per_px};

    // are there any pixels at all?
    wire frame_empty = (img_width == 16'd0) || (img_height == 16'd0);

    // ---------------------------------------------------------------
    // Compact source detection (P3)
    // ---------------------------------------------------------------
    // When src_stride is exactly one row of pixels, consecutive rows are
    // adjacent in memory, so the whole rectangle can be described to the read
    // engine as ONE transfer instead of one per row.
    //
    // WHY: every transfer costs a fixed ~8 cycles of AR handshake and state
    // machine turnaround. On a 160-beat row that is 5%, invisible. On the
    // 4-beat rows of a 16x16 sprite it is 50%. Measured across sprite sizes
    // (tb_bitblt_burst_eff):
    //     16x16   eff 33% -> 88%   2.66x
    //     64x64   eff 66% -> 98%   1.47x
    //    640x640  eff 95% -> 98%   1.03x
    //
    // The target side is not compact in the common case (a sprite goes into a
    // strided framebuffer), so only the source gets this.
    //
    // NOTE: describing the whole rectangle does NOT make the read engine run
    // away. It stalls whenever the pixel engine is not ready, and the pixel
    // engine only consumes when BOTH readers present data. The extra rows
    // therefore wait inside the source engine until the per-row target reader
    // catches up -- which is the pipelining we want. That only holds because
    // rd_src_ready is now gated by rd_dst_valid; before that fix the surplus
    // beats were dropped silently.
    assign compact_src = (src_stride == bytes_this_line) && !frame_empty;

    // Bytes the source engine should fetch in one go.
    assign src_bytes_total = compact_src
                           ? ({16'd0, img_height} * bytes_this_line)
                           : bytes_this_line;

    // Would a line fit entirely inside the framebuffer?
    //
    // Written as plain wire expressions rather than a function. The first
    // version used `function automatic line_fits` with a local `reg` inside it.
    // That passed in the unit testbench, where fb_start/fb_end are constants,
    // but failed in the end-to-end testbench, where they are register values
    // that change at runtime. Rather than depend on how a given tool treats
    // `automatic` locals, the sum is written out explicitly -- a few LUTs, and
    // the question disappears.
    //
    // The sum is AW+1 bits so a line wrapping past 2^AW is caught instead of
    // appearing to fit.
    wire [AW:0] first_line_end = {1'b0, dst_base} + {1'b0, bytes_this_line};
    wire        first_line_ok  = (dst_base >= fb_start) &&
                                 (first_line_end <= {1'b0, fb_end});

    wire [AW-1:0] next_dst_base = line_dst_addr + dst_stride;
    wire [AW:0]   next_line_end = {1'b0, next_dst_base} + {1'b0, bytes_this_line};
    wire          next_line_ok  = (next_dst_base >= fb_start) &&
                                  (next_line_end <= {1'b0, fb_end});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            busy           <= 1'b0;
            done           <= 1'b0;
            oob            <= 1'b0;
            line_req       <= 1'b0;
            line_src_addr  <= {AW{1'b0}};
            line_dst_addr  <= {AW{1'b0}};
            line_bytes     <= 32'd0;
            line_index     <= 16'd0;
        end else if (ce) begin
            done <= 1'b0;                     // default: pulse only

            case (state)
                // ------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        // Sticky for this transfer: cleared on every start so a
                        // previous out-of-bounds run cannot make a later, valid
                        // one look failed.
                        oob <= ~first_line_ok;
                        // Kept consistent with oob rather than merely written on
                        // refusal: if a later valid transfer left the previous
                        // address sitting there, software reading it would get a
                        // stale number that looks current. oob = 0 now means
                        // oob_addr = 0.
                        oob_addr <= first_line_ok ? {AW{1'b0}} : dst_base;

                        if (frame_empty || !first_line_ok) begin
                            // Nothing to transfer, or the rectangle starts
                            // outside the framebuffer. Finish immediately and
                            // emit done, so the driver does not spin waiting for
                            // a completion that will never come. The oob flag
                            // tells it why nothing was drawn.
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            busy          <= 1'b1;
                            line_index    <= 16'd0;
                            line_src_addr <= src_base;
                            line_dst_addr <= dst_base;
                            line_bytes    <= bytes_this_line;
                            line_req      <= 1'b1;
                            state         <= S_LINE;
                        end
                    end
                end

                // ------------------------------------------------
                // wait for the DMA to finish the current line
                S_LINE: begin
                    if (line_ack) begin
                        line_req <= 1'b0;
                        if (line_index + 16'd1 >= img_height) begin
                            state <= S_DONE;      // last line: finish
                        end else if (!next_line_ok) begin
                            // The next row would begin outside the framebuffer.
                            // Stop here rather than write past the end of it.
                            // This truncates a rectangle that overruns the
                            // bottom edge; the rows already drawn are correct.
                            oob      <= 1'b1;
                            oob_addr <= line_dst_addr + dst_stride;
                            state    <= S_DONE;
                        end else begin
                            line_index    <= line_index + 16'd1;
                            line_src_addr <= line_src_addr + src_stride;
                            line_dst_addr <= line_dst_addr + dst_stride;
                            // Drop line_req for one cycle before raising it
                            // again. Setting it in the same cycle as the clear
                            // left it permanently high, so the edge detector
                            // downstream never fired again and only the first
                            // row was ever processed.
                            state         <= S_GAP;
                        end
                    end
                end

                // ------------------------------------------------
                // line_req held LOW for exactly one cycle -> the next
                // assertion is guaranteed to be a clean rising edge
                S_GAP: begin
                    line_req <= 1'b1;
                    state    <= S_LINE;
                end

                // ------------------------------------------------
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                // line_req is held high until line_ack, so an undefined state
                // that leaves it asserted makes the scheduler above keep
                // issuing line starts forever. Drop the request along with the
                // state. (state is 2 bits and all four encodings are defined,
                // so this is reachable only in simulation; the cost is nil.)
                default: begin
                    state    <= S_IDLE;
                    line_req <= 1'b0;
                    busy     <= 1'b0;
                end
            endcase
        end
    end

// DEBUG 2026-10-17: expose the FSM state (IDLE=0 LINE=1 DONE=2 GAP=3).
assign state_o = state;

endmodule
