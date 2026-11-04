// ============================================================================
// gfx_core.v -- rectangle engine: solid fill, copy, alpha blend, colour key.
//
// Command format (352 bits, laid out by gfx_regs.param_snapshot):
//   [351:320] op (low 3 bits used)
//   [319:288] src address
//   [287:256] dst address
//   [255:224] size       {height[31:16], width[15:0]}
//   [223:192] src stride (low 16 bits used)
//   [191:160] dst stride (low 16 bits used)
//   [159:128] colour     RGB565 in [15:0]
//   [127:96]  alpha      [7:0]
//   [95:64]   key        RGB565 in [15:0]
//   [63:32]   clip x     (driver bookkeeping, not used by the engine)
//   [31:0]    clip y
//
// WHY THERE IS A PER-SEGMENT PIXEL ARRAY
//   Source rows and destination rows are not aligned to the same 16-byte
//   boundary, so a source beat and a destination beat cover different pixels.
//   Handling that per beat needs a window spanning two beats and an offset that
//   changes at beat boundaries -- every earlier attempt at this in the project
//   produced an off-by-one row. Here a segment of at most 112 pixels is
//   unpacked into a flat pixel array first, and both the source offset and the
//   destination offset index that array by absolute pixel number. The array is
//   small enough to be registers and the arithmetic is exact.
//
// THROUGHPUT
//   112 pixels per segment: read source (<=15 beats), read background (<=15
//   beats), compose (15 clocks), write (<=15 beats). A full-frame fill is 17,280
//   segments, about 5.8 ms at 100 MHz.
// ============================================================================
`default_nettype none

module gfx_core (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         cmd_valid,
    output wire         cmd_ready,
    input  wire [351:0] cmd_data,

    output reg          busy,
    output reg  [31:0]  done_cnt,
    output reg          error,
    output reg          clipped,
    output reg  [31:0]  err_addr,
    output reg  [31:0]  pix_cnt,
    output wire [3:0]   dbg_state,

    output reg          rd1_req,
    output reg  [31:0]  rd1_addr,
    output reg  [8:0]   rd1_beats,
    input  wire         rd1_gnt,
    input  wire         rd1_valid,
    input  wire [127:0] rd1_data,
    input  wire         rd1_last,

    output reg          rd2_req,
    output reg  [31:0]  rd2_addr,
    output reg  [8:0]   rd2_beats,
    input  wire         rd2_gnt,
    input  wire         rd2_valid,
    input  wire [127:0] rd2_data,
    input  wire         rd2_last,

    output reg          wr_req,
    output reg  [31:0]  wr_addr,
    output reg  [8:0]  wr_beats,
    input  wire         wr_gnt,
    output wire [127:0] wr_data,
    output wire [15:0]  wr_strb,
    output reg          wr_valid,
    input  wire         wr_ready,
    output wire         wr_last
);

    localparam [31:0] FB_POOL_LO = 32'h0800_0000;
    localparam [31:0] FB_POOL_HI = 32'h0C00_0000;

    localparam [2:0] OP_FILL = 3'd0, OP_COPY = 3'd1, OP_BLEND = 3'd2,
                     OP_KEY  = 3'd3, OP_BLIT = 3'd4, OP_COPY_KEY = 3'd5;

    localparam [3:0] S_IDLE   = 4'd0,
                     S_SEG    = 4'd1,
                     S_RS_REQ = 4'd2,
                     S_RS_DAT = 4'd3,
                     S_RB_REQ = 4'd4,
                     S_RB_DAT = 4'd5,
                     S_PIX    = 4'd6,
                     S_WR_REQ = 4'd7,
                     S_WR_DAT = 4'd8,
                     S_NEXT   = 4'd9,
                     S_FIN    = 4'd10,
                     S_PIX_R  = 4'd11,
                     S_PIX_M  = 4'd12,
                     S_SPX_REQ = 4'd13,
                     S_SPX_DAT = 4'd14;

    // 112 pixels per segment. 240 was tried and fitted only at 72k LUT4: the
    // 256-deep background/compose arrays are register files, roughly 4 LUT per
    // bit, which is past the Ti60 capacity. Depth, not width, is the cost.
    localparam [7:0] MAXN = 8'd112;

    reg [2:0]  op;
    reg [31:0] src, dst;
    reg [15:0] cw, ch;
    reg [15:0] ss, ds;
    reg [15:0] color, key;
    reg [7:0]  alpha;

    reg [15:0] row, xdone;

    reg [7:0]  n;
    reg [3:0]  soff, doff;
    reg [8:0]  sbeats, wbeats;
    reg [31:0] sa, da;

    reg [8:0]  beatidx;
    reg [4:0]  pixj;

    reg [15:0] spx [0:127];
    reg [15:0] bpx [0:127];
    reg [15:0] opx [0:127];

    reg [3:0]  state;

    // Compact-source mode: when src_stride == width*2 the whole sprite is
    // contiguous in memory, so one burst fetches every row. Without this
    // a 16x16 sprite cost 16 read transactions, and the DDR round trip per
    // transaction dominated a 43 us per-sprite budget.
    reg        spx_mode;
    reg [3:0]  spx_off;
    reg [8:0]  spx_beats;
    reg [9:0]  spx_row;
    reg [3:0]  spx_seg;        // segment number for sprite > 128 px
    reg [7:0]  spx_rps;        // rows per segment (128 / cw)

    // One stage between index selection and the blend arithmetic. The combined
    // path was 35 logic levels (10.08 ns) and left 0.076 ns of setup margin;
    // splitting it is cheaper than losing the whole design to a hot afternoon.
    reg [15:0] fg_q [0:7];
    reg [15:0] bg_q [0:7];
    reg [7:0]  ok_q;

    wire use_src = (op != OP_FILL);
    wire [9:0] spx_base = spx_mode ? spx_row : 10'd0;
    wire use_bg  = (op == OP_BLEND) | (op == OP_KEY) | (op == OP_BLIT) | (op == OP_COPY_KEY);

    assign cmd_ready = (state == S_IDLE) && cmd_valid;
    assign dbg_state = state;

    // ------------------------------------------------------------ geometry
    wire [15:0] width_left = cw - xdone;
    wire [7:0]  seg_n = (width_left > {8'd0, MAXN}) ? MAXN : width_left[7:0];

    wire [31:0] row_src  = src + (row * ss);
    wire [31:0] row_dst  = dst + (row * ds);
    wire [31:0] src_pix  = row_src + {17'd0, xdone, 1'b0};
    wire [31:0] dst_pix  = row_dst + {17'd0, xdone, 1'b0};

    wire [31:0] seg_sa   = {src_pix[31:4], 4'd0};
    wire [31:0] seg_da   = {dst_pix[31:4], 4'd0};
    wire [3:0]  seg_soff = src_pix[3:0] >> 1;
    wire [3:0]  seg_doff = dst_pix[3:0] >> 1;
    // 7 bits, not 6: (7 + 112 + 7) = 126 needs seven bits. The old six-bit
    // sum wrapped for any segment above 56 pixels, so wbeats came out as zero
    // and the compose FSM cycled forever -- a 16-pixel test passed by luck.
    wire [8:0]  seg_sb_w = ({4'd0, seg_soff} + {1'b0, seg_n} + 9'd7);
    wire [8:0]  seg_wb_w = ({4'd0, seg_doff} + {1'b0, seg_n} + 9'd7);
    wire [8:0]  seg_sb = seg_sb_w[8:3];
    wire [8:0]  seg_wb = seg_wb_w[8:3];

    // ------------------------------------------------------------ unpack
    integer ku;
    always @(posedge clk) begin
        if (rd1_valid) begin
            for (ku = 0; ku < 8; ku = ku + 1)
                spx[{beatidx, 3'b000} + ku] <= rd1_data[16*ku +: 16];
        end
        if (rd2_valid) begin
            for (ku = 0; ku < 8; ku = ku + 1)
                bpx[{beatidx, 3'b000} + ku] <= rd2_data[16*ku +: 16];
        end
    end

    // ------------------------------------------------------------ colour maths
    function [15:0] mix565;
        input [15:0] f;
        input [15:0] b;
        input [7:0]  a;
        reg [7:0] ia;
        reg [17:0] tr, tg, tb;
        begin
            ia = 8'd255 - a;
            tr = f[15:11] * a + b[15:11] * ia + 18'd128;
            tr = tr + (tr >> 8);
            tg = f[10:5]  * a + b[10:5]  * ia + 18'd128;
            tg = tg + (tg >> 8);
            tb = f[4:0]   * a + b[4:0]   * ia + 18'd128;
            tb = tb + (tb >> 8);
            mix565 = {tr[12:8], tg[13:8], tb[12:8]};
        end
    endfunction

    function [15:0] pix_op;
        input [2:0]  o;
        input [15:0] f;
        input [15:0] b;
        input [7:0]  a;
        input [15:0] k;
        begin
            case (o)
                OP_FILL:     pix_op = f;
                OP_COPY:     pix_op = f;
                OP_BLEND:    pix_op = mix565(f, b, a);
                OP_KEY:      pix_op = (f == k) ? b : f;
                OP_BLIT:     pix_op = (f == k) ? b : mix565(f, b, a);
                OP_COPY_KEY: pix_op = (f == k) ? b : f;
                default:     pix_op = f;
            endcase
        end
    endfunction

    // ------------------------------------------------------------ compose
    integer kc;
    reg signed [10:0] p;
    always @(posedge clk) begin
        if (state == S_PIX_R) begin
            for (kc = 0; kc < 8; kc = kc + 1) begin
                p = {2'b0, pixj, 3'b000} + kc - {7'b0, doff};
                ok_q[kc] <= ((p >= 0) && (p < {3'b0, n})) ? 1'b1 : 1'b0;
                fg_q[kc] <= (op == OP_FILL) ? color : spx[p[6:0] + {3'b0, soff} + spx_base];
                bg_q[kc] <= bpx[p[6:0] + {3'b0, doff}];
            end
        end
        if (state == S_PIX_M) begin
            for (kc = 0; kc < 8; kc = kc + 1) begin
                opx[{pixj, 3'b000} + kc] <= ok_q[kc]
                    ? pix_op(op, fg_q[kc], bg_q[kc], alpha, key)
                    : color;
            end
        end
    end

    // ------------------------------------------------------------ write pack
    wire [127:0] wr_word;
    wire [15:0]  wr_mask;
    genvar gw;
    generate
        for (gw = 0; gw < 8; gw = gw + 1) begin : g_pack
            wire signed [10:0] ps = {2'b0, pixj, 3'b000} + gw - {7'b0, doff};
            assign wr_word[16*gw +: 16] = opx[{pixj, 3'b000} + gw];
            assign wr_mask[2*gw +: 2] = ((ps >= 0) && (ps < {3'b0, n})) ? 2'b11 : 2'b00;
        end
    endgenerate

    assign wr_data = wr_word;
    assign wr_strb = wr_mask;
    assign wr_last = (pixj == (wbeats - 5'd1));

    // ------------------------------------------------------------ main FSM
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 1'b0;
            done_cnt <= 32'd0;
            error <= 1'b0;
            clipped <= 1'b0;
            err_addr <= 32'd0;
            pix_cnt <= 32'd0;
            op <= 3'd0; src <= 32'd0; dst <= 32'd0;
            cw <= 16'd0; ch <= 16'd0; ss <= 16'd0; ds <= 16'd0;
            color <= 16'd0; key <= 16'd0; alpha <= 8'd0;
            row <= 16'd0; xdone <= 16'd0;
            n <= 8'd0; soff <= 4'd0; doff <= 4'd0; sbeats <= 9'd0; wbeats <= 9'd0;
            sa <= 32'd0; da <= 32'd0;
            beatidx <= 9'd0;
            pixj <= 5'd0;
            spx_mode <= 1'b0; spx_off <= 4'd0; spx_beats <= 9'd0; spx_row <= 10'd0;
            rd1_req <= 1'b0; rd1_addr <= 32'd0; rd1_beats <= 9'd0;
            rd2_req <= 1'b0; rd2_addr <= 32'd0; rd2_beats <= 9'd0;
            wr_req <= 1'b0; wr_addr <= 32'd0; wr_beats <= 9'd0;
            wr_valid <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (cmd_valid) begin
                        op    <= cmd_data[322:320];
                        src   <= cmd_data[319:288];
                        dst   <= cmd_data[287:256];
                        cw    <= cmd_data[239:224];
                        ch    <= cmd_data[255:240];
                        ss    <= cmd_data[207:192];
                        ds    <= cmd_data[175:160];
                        color <= cmd_data[143:128];
                        alpha <= cmd_data[103:96];
                        key   <= cmd_data[79:64];
                        row   <= 16'd0;
                        xdone <= 16'd0;
                        busy  <= 1'b1;
                        clipped <= 1'b0;
                        if ((cmd_data[239:224] == 16'd0) || (cmd_data[255:240] == 16'd0)) begin
                            state <= S_FIN;
                        end else if ((cmd_data[287:256] < FB_POOL_LO) ||
                                     ((cmd_data[287:256] +
                                       ((cmd_data[255:240] - 16'd1) * cmd_data[175:160]) +
                                       (cmd_data[239:224] << 1)) >= FB_POOL_HI)) begin
                            err_addr <= cmd_data[287:256];
                            clipped <= 1'b1;
                            state <= S_FIN;
                        end else begin
                            // Compact source: contiguous rows (stride == width*2)
                            // let one burst fetch the whole sprite instead of one
                            // transaction per row. Capped at the 128-entry staging
                            // array, which suits the 8x8 sprites the demo uses;
                            // a 16x16 sprite needs 256 entries and did not fit.
                            if ((cmd_data[322:320] != OP_FILL) &&
                                (cmd_data[207:192] == (cmd_data[239:224] << 1)) &&
                                ((cmd_data[239:224] * cmd_data[255:240]) <= 16'd256) && (cmd_data[319:316] == 4'd0)) begin
                                spx_mode  <= 1'b1;
                                spx_off   <= cmd_data[319:316] >> 1;
                                spx_row   <= 10'd0;
                                spx_seg   <= 4'd0;
                                spx_rps   <= (cmd_data[239:224] == 16'd8)  ? 8'd16 :
                                             (cmd_data[239:224] == 16'd16) ? 8'd8  :
                                             (cmd_data[239:224] == 16'd32) ? 8'd4  : 8'd8;
                                state     <= S_SPX_REQ;
                            end else begin
                                spx_mode  <= 1'b0;
                                state     <= S_SEG;
                            end
                        end
                    end
                end

                // ---- whole-sprite source fetch ----
                S_SPX_REQ: begin
                    rd1_req   <= 1'b1;
                    // 128-pixel segment (or the remainder for short sprites)
                    rd1_addr  <= {src[31:4], 4'd0} + {spx_seg, 8'd0};
                    sbeats    <= (spx_seg == 4'd0)
                               ? (({4'd0, spx_off} + 9'd128 + 9'd7) >> 3)
                               : 9'd16;
                    rd1_beats <= (spx_seg == 4'd0)
                               ? (({4'd0, spx_off} + 9'd128 + 9'd7) >> 3)
                               : 9'd16;
                    if (rd1_gnt) begin
                        rd1_req <= 1'b0;
                        beatidx <= 9'd0;
                        state   <= S_SPX_DAT;
                    end
                end

                S_SPX_DAT: begin
                    if (rd1_valid) begin
                        beatidx <= beatidx + 9'd1;
                        if (rd1_last) begin
                            beatidx <= 9'd0;
                            state   <= S_SEG;
                        end
                    end
                end

                S_SEG: begin
                    n      <= seg_n;
                    soff   <= seg_soff;
                    doff   <= seg_doff;
                    sbeats <= seg_sb;
                    wbeats <= seg_wb;
                    sa     <= seg_sa;
                    da     <= seg_da;
                    beatidx <= 9'd0;
                    pixj   <= 4'd0;
                    if (spx_mode)     state <= (use_bg ? S_RB_REQ : S_PIX_R);
                    else if (use_src) state <= S_RS_REQ;
                    else if (use_bg)  state <= S_RB_REQ;
                    else              state <= S_PIX_R;
                end

                S_RS_REQ: begin
                    rd1_req   <= 1'b1;
                    rd1_addr  <= sa;
                    rd1_beats <= sbeats;
                    if (rd1_gnt) begin
                        rd1_req <= 1'b0;
                        beatidx <= 9'd0;
                        state   <= S_RS_DAT;
                    end
                end

                S_RS_DAT: begin
                    if (rd1_valid) begin
                        beatidx <= beatidx + 9'd1;
                        if (rd1_last) begin
                            beatidx <= 9'd0;
                            state <= use_bg ? S_RB_REQ : S_PIX_R;
                        end
                    end
                end

                S_RB_REQ: begin
                    rd2_req   <= 1'b1;
                    rd2_addr  <= da;
                    rd2_beats <= wbeats;
                    if (rd2_gnt) begin
                        rd2_req <= 1'b0;
                        beatidx <= 9'd0;
                        state   <= S_RB_DAT;
                    end
                end

                S_RB_DAT: begin
                    if (rd2_valid) begin
                        beatidx <= beatidx + 9'd1;
                        if (rd2_last) begin
                            beatidx <= 9'd0;
                            state <= S_PIX_R;
                        end
                    end
                end

                S_PIX_R: begin
                    state <= S_PIX_M;
                end

                S_PIX_M: begin
                    pix_cnt <= pix_cnt + 32'd8;
                    if (pixj == (wbeats - 9'd1)) state <= S_WR_REQ;
                    else begin
                        pixj  <= pixj + 4'd1;
                        state <= S_PIX_R;
                    end
                end

                S_WR_REQ: begin
                    // Handshake before streaming data. Holding WR_REQ until the
                    // write channel accepts it is what stops a transaction from
                    // being dropped when the channel is still busy with the
                    // previous row: without this the data went into the FIFO but
                    // no AW was ever issued, so rows silently went missing and
                    // later commands reused stale beats.
                    wr_req   <= 1'b1;
                    wr_addr  <= da;
                    wr_beats <= wbeats;
                    pixj     <= 4'd0;
                    if (wr_gnt) begin
                        wr_req   <= 1'b0;
                        wr_valid <= 1'b1;
                        state    <= S_WR_DAT;
                    end
                end

                S_WR_DAT: begin
                    if (wr_valid && wr_ready) begin
                        if (pixj == (wbeats - 9'd1)) begin
                            wr_valid <= 1'b0;
                            wr_req   <= 1'b0;
                            state    <= S_NEXT;
                        end else begin
                            pixj <= pixj + 5'd1;
                        end
                    end
                end

                S_NEXT: begin
                    if ((xdone + {8'd0, n}) >= cw) begin
                        xdone <= 16'd0;
                        if ((row + 16'd1) >= ch) begin
                            state <= S_FIN;
                        end else if (spx_mode && (((row + 16'd1) & ({8'd0, spx_rps} - 16'd1)) == 16'd0)) begin
                            // start of a new 128-pixel segment: refill the array
                            row     <= row + 16'd1;
                            spx_row <= 10'd0;
                            spx_seg <= spx_seg + 4'd1;
                            state   <= S_SPX_REQ;
                        end else begin
                            row <= row + 16'd1;
                            spx_row <= spx_row + cw;
                            state <= S_SEG;
                        end
                    end else begin
                        xdone <= xdone + {8'd0, n};
                        state <= S_SEG;
                    end
                end

                S_FIN: begin
                    done_cnt <= done_cnt + 32'd1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
