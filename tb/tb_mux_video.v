// End-to-end testbench: bitblt_video_out behind Axi_Mux.
//
// WHY THIS TB EXISTS
//   Every other testbench in this project connects a module to a hand-written
//   AXI slave BFM. None of them goes through the interconnect. That leaves the
//   single most important link in "render then display" untested: the path from
//   the video scan-out, through Axi_Mux, to memory and back.
//
//   It is also the only test that can catch an AXI ID problem. AXI permits two
//   masters to use the same ID, so nothing in the protocol or in the tools
//   complains -- the failure is read data arriving at the wrong master. That is
//   exactly the bug found in the 2026-10-06 audit (video used low nibble 0x0,
//   same as the BitBlt read engine), and exactly what this TB is built to
//   expose.
//
// HOW THE ID BUG WOULD SHOW UP HERE
//   Two masters are driven CONCURRENTLY and the slave returns deliberately
//   different data per address range:
//
//     S0 (stands in for a BitBlt engine) reads 0x0000_1000  -> 0xAAAA_xxxx
//     S4 (bitblt_video_out)              reads 0x0800_0000  -> row*1000+col
//
//   If the IDs collide, Axi_Mux cannot tell the returning beats apart and the
//   video pipeline receives 0xAAAA_xxxx (or S0 receives video pixels). Either
//   way the pixel checks below fail loudly rather than silently.
//
// TESTBENCH RULES OBSERVED (learned the hard way in this project)
//   * rdata / rlast are COMBINATIONAL with respect to the beat presented.
//     Registering them makes beat 0 look like the last one, or repeats beat 0.
//   * Stimulus changes #1 after a clock edge, never in the same timestep.
//   * Every instance connects every port it declares. Leaving ports dangling is
//     silent in iVerilog but produces vopt-2685 warnings in Questa, and it means
//     the TB is not describing the design it claims to test.
`timescale 1ns / 1ps

module tb_mux_video;

    // ---------------------------------------------------------------- clocks
    reg clk  = 1'b0;      // AXI domain, 100 MHz
    reg pclk = 1'b0;      // pixel domain, 25 MHz
    always #5  clk  = ~clk;
    always #20 pclk = ~pclk;

    reg rst_n = 1'b0;

    localparam FB_BASE = 32'h0800_0000;

    // Rows hold 2560 bytes of pixels, but the row PITCH is 4096.
    //
    // bitblt_video_out splits a line across 4 KB pages, which only works when
    // every line STARTS page-aligned -- so fb_base and fb_stride must both be
    // multiples of 4096, and the RTL raises cfg_error if either is not. With
    // the natural pitch of 640*4 = 2560 this testbench tripped that check, the
    // video module refused to start, and "AR bursts S4" stayed at 0 while S0
    // looked healthy.
    //
    // The 1536 padding bytes per row are never displayed. row = (addr -
    // FB_BASE) / FB_STRIDE below picks this up automatically.
    // The frame is deliberately tiny: 8 active lines plus 4 blanking lines, so
    // one frame is 12 lines and the ~30-line simulation window spans more than
    // two of them.
    //
    // WHY THAT MATTERS: the phase between rd_row and the scan line can only be
    // established by enabling during VERTICAL BLANKING, which is what real
    // software does. With V_ACT = 480 the testbench would have to run 525 lines
    // before vertical blanking came round, and it only runs about 30 -- so the
    // enable always landed mid-frame and the display stayed offset by however
    // many pixels the interrupted line lost.
    // 2026-10-14: FB_W was 640, which makes every line ONE burst (2560 B < 4 KB)
    // and therefore never exercises the multi-segment path. On the board the
    // scan-out runs at 1920 pixels = 7680 B per line, which bitblt_video_out
    // must split into 2 bursts (256 + 224 beats) -- and with an engine also
    // reading, the board reports AR handshakes wedged on BOTH readers and zero
    // active lines. This is the reproduction: 1920 wide, stride 8192 (must stay
    // a multiple of 4096 or the RTL raises cfg_error).
    localparam FB_W      = 1920;
    localparam FB_H      = 8;
    localparam FB_STRIDE = 8192;

    // =====================================================================
    // Master side (Axi_Mux output) -- a DDR3 stand-in
    // =====================================================================
    wire [7:0]   m_awid;
    wire [31:0]  m_awaddr;
    wire [7:0]   m_awlen;
    wire [2:0]   m_awsize;
    wire [1:0]   m_awburst;
    wire [1:0]   m_awlock;
    wire         m_awvalid;
    reg          m_awready = 1'b1;
    wire [7:0]   m_wid;
    wire [127:0] m_wdata;
    wire         m_wlast;
    wire [15:0]  m_wstrb;
    wire         m_wvalid;
    reg          m_wready = 1'b1;
    reg  [7:0]   m_bid   = 8'h0;
    reg          m_bvalid = 1'b0;
    wire         m_bready;
    wire [7:0]   m_arid;
    wire [31:0]  m_araddr;
    wire [7:0]   m_arlen;
    wire [2:0]   m_arsize;
    wire [1:0]   m_arburst;
    wire [1:0]   m_arlock;
    wire         m_arvalid;
    wire         m_arready;          // driven by the AR queue's fullness
    reg  [7:0]   m_rid    = 8'h0;
    reg  [127:0] m_rdata;
    reg          m_rlast;
    reg  [1:0]   m_rresp  = 2'b00;
    reg          m_rvalid = 1'b0;
    wire         m_rready;

    // ---- burst engine: queues AR requests and serves them in order ----
    //
    // An earlier revision kept only ONE set of cur_addr/cur_len/beat_idx. That
    // works while a single burst is in flight, but AXI permits several
    // outstanding reads and Axi_Mux issues them: when S0's AR arrived while
    // S4's 160-beat burst was still running, the second request overwrote the
    // first, beat_idx reset to 0, m_rlast fired early, and Axi_Mux concluded the
    // burst had ended. Every later beat went to the wrong master -- exactly what
    // the S0BEAT trace showed (S0 receiving rid=1e plus framebuffer pixels).
    //
    // So queue the requests and serve them in order. Throttling m_arready would
    // also stop the corruption, but it would serialise the two masters and
    // defeat the point of this testbench, which is to exercise the interconnect
    // under concurrency.
    // The storage is sized to the POINTER's wrap point, not to QD.
    //
    // q_wr / q_rd are 3-bit and therefore wrap at 8. Sizing the arrays [0:QD-1]
    // (= 4 entries) meant the fifth accepted AR wrote q_len[4], which does not
    // exist: the write was discarded and the read returned x. cur_len = x made
    // m_rlast = (beat_idx == x) = x, an x in an if-condition is false, so the
    // burst's end condition never fired -- beat_idx ran to 5644, bursting stayed
    // high, m_rvalid stayed asserted for 108170 clocks, the DUT took 6128 beats,
    // wrote 24495 pixels, filled the FIFO and stalled the scan-out.
    //
    // The initialisation loop below had the same off-by-size bug (it used QD),
    // which is why adding it changed nothing.
    localparam QD = 4;
    localparam QSLOTS = 8;              // = 2**3, the pointer wrap point
    reg [31:0] q_addr [0:QSLOTS-1];
    reg [7:0]  q_id   [0:QSLOTS-1];
    reg [7:0]  q_len  [0:QSLOTS-1];
    reg [2:0]  q_wr   = 3'd0;
    reg [2:0]  q_rd   = 3'd0;
    reg [2:0]  q_cnt  = 3'd0;

    reg [31:0]  cur_addr = 32'd0;
    reg [31:0]  beat_idx = 32'd0;
    reg         bursting = 1'b0;
    reg  [7:0]  cur_id   = 8'h0;
    reg  [7:0]  cur_len  = 8'h0;

    integer ar_seen = 0;
    integer ar_s0   = 0;      // AR bursts whose low nibble is S0's
    integer ar_s4   = 0;      // ... and S4's

    // Waveform control, set from the command line. Declared here because
    // $value$plusargs needs a module-scope variable to write into.
    integer dump_mode = 0;

    // S0 uses 8'h18 (low nibble 8), S4 uses 8'h1E (low nibble E) -- matching
    // system_top. Counting them separately proves the mux actually forwards
    // both masters rather than merging them.
    localparam S0_LOWNIB = 4'h8;
    localparam S4_LOWNIB = 4'hE;

    wire ar_fire = m_arvalid & m_arready;
    wire r_fire  = m_rvalid  & m_rready;

    // Queue occupancy must be computed as ONE expression, not two separate
    // non-blocking assignments.
    //
    // This used to be
    //     if (ar_fire)     q_cnt <= q_cnt + 1;    // push
    //     if (pop_ok)      q_cnt <= q_cnt - 1;    // pop
    // in the same always block. Verilog applies the last assignment, so on any
    // cycle where a push and a pop coincide the +1 is silently dropped and the
    // count only decrements. That is precisely the situation this testbench
    // creates on purpose -- two masters overlapping -- and the count drifts
    // low, arready rises too early, and the queue overwrites entries it has not
    // served yet.
    //
    // The symptom was the video channel receiving the BitBlt region's data,
    // which looks exactly like an Axi_Mux routing failure. It was not: it was
    // this testbench losing track of its own queue.
    // Non-empty is decided by POINTER INEQUALITY, not by the counter.
    //
    // The counter-based test (`q_cnt > 0`) is only as good as q_cnt, and q_cnt
    // was wrong: it let the model start a burst when the queue was in fact
    // empty. That burst read q_len[5], which had never been written, so
    // cur_len came out as x. m_rlast = (beat_idx == x) is x, and an x in an
    // if-condition counts as FALSE, so the burst's end condition never fired:
    // beat_idx ran to 5644 instead of stopping at 159, bursting stayed high,
    // m_rvalid stayed asserted for 108170 clocks, the DUT consumed 6128 beats,
    // wrote 24495 pixels, filled the FIFO, stalled splitting, blocked
    // need_line, and displayed 35 rows of mostly stale data.
    //
    // Depth is QD=4 and m_arready holds the queue at 4 entries, so q_wr - q_rd
    // never reaches the 3-bit wrap point and inequality is exact.
    wire q_empty = (q_wr == q_rd);
    wire ar_pop  = (!bursting && !q_empty);
    wire [2:0] q_cnt_next = q_cnt
                          + (ar_fire ? 3'd1 : 3'd0)
                          - (ar_pop  ? 3'd1 : 3'd0);

    // Belt and braces: initialise the queue storage.
    //
    // The pointer test above is the real fix, but an uninitialised array
    // element turned out to be able to propagate x into an if-condition and
    // silently disable a burst's end condition. Zeroing the storage means that
    // even if some future change lets the pointers slip again, the failure will
    // be a wrong address rather than an x that quietly removes a control path.
    integer qi;
    initial begin
        for (qi = 0; qi < QSLOTS; qi = qi + 1) begin
            q_addr[qi] = 32'd0;
            q_id[qi]   = 8'h00;
            q_len[qi]  = 8'h00;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_wr     <= 3'd0;
            q_rd     <= 3'd0;
            q_cnt    <= 3'd0;
            bursting <= 1'b0;
            beat_idx <= 32'd0;
            cur_addr <= 32'd0;
            cur_id   <= 8'h0;
            cur_len  <= 8'h0;
            m_rvalid <= 1'b0;
            ar_seen  <= 0;
            ar_s0    <= 0;
            ar_s4    <= 0;
        end else begin
            // ---- accept a new AR into the queue ----
            if (ar_fire) begin
                q_addr[q_wr] <= m_araddr;
                q_id[q_wr]   <= m_arid;
                q_len[q_wr]  <= m_arlen;
                q_wr         <= q_wr + 3'd1;

                ar_seen <= ar_seen + 1;
                if (m_arid[3:0] == S0_LOWNIB) ar_s0 <= ar_s0 + 1;
                if (m_arid[3:0] == S4_LOWNIB) ar_s4 <= ar_s4 + 1;

                if (ar_seen < 6)
                    $display("  DEBUG AR  t=%0t id=%h addr=%h len=%0d qcnt=%0d",
                             $time, m_arid, m_araddr, m_arlen, q_cnt);
            end

            // Single occupancy update; see q_cnt_next above.
            q_cnt <= q_cnt_next;

            // ---- start serving the head of the queue ----
            if (!bursting && !q_empty) begin
                cur_addr <= q_addr[q_rd];
                cur_id   <= q_id[q_rd];
                cur_len  <= q_len[q_rd];
                beat_idx <= 32'd0;
                bursting <= 1'b1;
                m_rvalid <= 1'b1;
                q_rd     <= q_rd + 3'd1;
            end
            // ---- advance the burst currently being served ----
            else if (bursting && r_fire) begin
                if (m_rlast) begin
                    if (ar_seen < 7)
                        $display("  DEBUG R-END t=%0t beats=%0d last=1", $time, beat_idx);
                    bursting <= 1'b0;
                    m_rvalid <= 1'b0;
                    beat_idx <= 32'd0;
                end else begin
                    beat_idx <= beat_idx + 32'd1;
                end
            end
        end
    end

    assign m_arready = (q_cnt < QD);

    // ---- data depends on which region was addressed ----
    function [31:0] pix;
        input [31:0] row;
        input [31:0] col;
        reg   [31:0] v;
        begin
            v   = row*1000 + col;
            pix = {8'hFF, v[23:0]};
        end
    endfunction

    // region A: the framebuffer.
    //
    // 2026-10-14: the column used to be derived from the BEAT INDEX inside the
    // current burst (base_col = b * 4). That silently assumes one line == one
    // burst, which held at FB_W = 640 (2560 B < 4 KB) and breaks at 1920: a
    // full-HD line is split into two bursts, the second burst restarts its beat
    // index at 0, and the model then handed back the START of the row for the
    // second half. The DUT dutifully displayed it, and the testbench reported
    // 627 pixel errors whose value was exactly (expected - 1024) starting at
    // h=1024 -- which looked like an RTL bug in the segment join and was not.
    //
    // The column must come from the ADDRESS: the burst's byte offset inside the
    // row, plus the beat's own offset.
    function [127:0] fb_beat;
        input [31:0] addr;
        input [31:0] b;
        reg   [31:0] row;
        reg   [31:0] base_col;
        begin
            row      = (addr - FB_BASE) / FB_STRIDE;
            base_col = ((addr - FB_BASE) % FB_STRIDE) / 4 + b * 4;
            fb_beat  = { pix(row, base_col + 3), pix(row, base_col + 2),
                         pix(row, base_col + 1), pix(row, base_col + 0) };
        end
    endfunction

    // region B: the "BitBlt" region, an unmistakable pattern
    function [127:0] aa_beat;
        input [31:0] b;
        begin
            aa_beat = { 32'hAAAA_0003 ^ b, 32'hAAAA_0002 ^ b,
                        32'hAAAA_0001 ^ b, 32'hAAAA_0000 ^ b };
        end
    endfunction

    // rdata / rlast are COMBINATIONAL w.r.t. the beat being presented
    always @(*) begin
        if (cur_addr >= FB_BASE && cur_addr < (FB_BASE + 32'h0010_0000))
            m_rdata = fb_beat(cur_addr, beat_idx);
        else
            m_rdata = aa_beat(beat_idx);
        m_rlast = (beat_idx == cur_len);
        m_rid   = cur_id;
    end

    // =====================================================================
    // S0: a minimal AR initiator standing in for a BitBlt read engine
    // =====================================================================
    reg  [7:0]  s0_arid    = 8'h18;
    reg  [31:0] s0_araddr  = 32'h0000_1000;
    reg  [7:0]  s0_arlen   = 8'h03;        // 4 beats
    reg         s0_arvalid = 1'b0;
    wire        s0_arready;
    wire [7:0]  s0_rid;
    wire [127:0] s0_rdata;
    wire        s0_rlast;
    wire [1:0]  s0_rresp;
    wire        s0_rvalid;
    reg         s0_rready  = 1'b1;

    integer s0_beats  = 0;
    integer s0_errors = 0;
    integer s0_round  = 0;      // which AR this is (0-based)
    reg [127:0] s0_first = 128'h0;

    always @(posedge clk) begin
        if (rst_n && s0_rvalid && s0_rready) begin
            if (s0_beats == 0) s0_first <= s0_rdata;

            // Log the first 8 beats verbatim. The question is whether S0 is
            // handed the video's data from the very first beat (wrong routing)
            // or only after its own 4-beat burst should have ended (over-run).
            // Those two have completely different fixes.
            if (s0_beats < 8)
                $display("  S0BEAT #%0d t=%0t rid=%h hi=%h lo=%h rlast=%b",
                         s0_beats, $time, s0_rid, s0_rdata[127:96], s0_rdata[31:0], s0_rlast);

            s0_beats <= s0_beats + 1;
            // region B data must look like 0xAAAA....  If the video pipeline's
            // pixels show up here, the IDs collided.
            // Only the FIRST burst is value-checked: the model returns data by
            // the beat index WITHIN a burst, and every S0 burst reads the same
            // address, so later bursts would compare against a running counter
            // and report false errors.
            if (s0_beats < 4 && s0_rdata[127:96] !== (32'hAAAA_0003 ^ (s0_beats)))
                s0_errors <= s0_errors + 1;
        end
    end

    // =====================================================================
    // S4: the real video scan-out, through the real Axi_Mux
    // =====================================================================
    wire [7:0]   v_arid;
    wire [31:0]  v_araddr;
    wire [7:0]   v_arlen;
    wire [2:0]   v_arsize;
    wire [1:0]   v_arburst;
    wire         v_arvalid;
    wire         v_arready;
    wire [7:0]   v_rid;
    wire [127:0] v_rdata;
    wire [1:0]   v_rresp;
    wire         v_rlast;
    wire         v_rvalid;
    wire         v_rready;

    wire [23:0]  v_rgb;
    wire         v_de, v_hs, v_vs;
    wire [15:0]  v_hcnt, v_vcnt;
    wire         v_cfg_err;

    reg  [31:0]  cfg_fb_base   = FB_BASE;
    reg  [15:0]  cfg_fb_width  = FB_W;
    reg  [15:0]  cfg_fb_height = FB_H;
    reg  [15:0]  cfg_fb_stride = FB_STRIDE;
    reg          cfg_enable    = 1'b0;

    // Enable during VERTICAL BLANKING, which is what software must do.
    //
    // With enable high from power-on the scan starts at v_cnt = 0 while the AXI
    // side is still completing its first AR handshake. The FIFO is empty for
    // the first few pixels of row 0, de stays low (it is gated by rd_valid),
    // and that row comes up short. FIFO consumption is what advances rd_row,
    // so the display then stays behind by that many pixels FOR THE WHOLE FRAME
    // -- not just row 0.
    //
    // Enabling during blanking removes the race: with V_ACT = 8 there are 4
    // blanking lines x 920 pclk = 3680 cycles before the next active line,
    // which is far more than the first AR handshake needs.
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n)               cfg_enable <= 1'b0;
        else if (v_vcnt >= 16'd8) cfg_enable <= 1'b1;      // V_ACT -> blanking
    end

    // Only start checking on the first frame that begins AFTER enable.
    //
    // The frame in progress when enable lands is inherently offset: rd_row
    // starts at 0 but that frame's row 0 was never consumed, so its data is
    // still queued. Checking from the next frame boundary onward removes that
    // once-only artefact without weakening the check -- from there the phase is
    // established exactly as it is in the real system.
    //
    // The frame boundary is taken from v_vcnt wrapping rather than from the vs
    // edge, so it does not depend on vs polarity.
    reg [15:0] v_vcnt_d = 16'd0;
    reg        armed    = 1'b0;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            v_vcnt_d <= 16'd0;
            armed    <= 1'b0;
        end else begin
            v_vcnt_d <= v_vcnt;
            if (cfg_enable && (v_vcnt_d != 16'd0) && (v_vcnt == 16'd0))
                armed <= 1'b1;
        end
    end

    bitblt_video_out #(
        // 2026-10-14: this was 640 while fb_width is now 1920. That mismatch is
        // exactly the "phase" failure the note further down describes: the
        // scan-out displayed 640 pixels per line while fetching 7680 bytes, so
        // every line started 640 pixels further into the framebuffer than the
        // display expected. H_ACT must equal fb_width.
        .H_ACT   (1920),
        .V_ACT   (8),                     // = FB_H, so rd_row wraps with the frame
        .V_FP    (1),
        .V_SYNC  (1),
        .V_BP    (2),                     // frame = 8 + 4 = 12 lines
        .FIFO_AW (11),
        .PIX565  (0),                     // ARGB8888: 4 KB page splitting is only
                                          // reachable at 8 B/pixel (docs/85)
        .AXI_ID  (8'h1E)                  // must match S4_LOWNIB above
    ) u_video (
        .clk           (clk),
        .rst_n         (rst_n),
        .pclk          (pclk),
        .fb_base       (cfg_fb_base),
        .fb_stride     (cfg_fb_stride),
        .fb_width      (cfg_fb_width),
        .fb_height     (cfg_fb_height),
        .enable        (cfg_enable),
        .m_axi_arid    (v_arid),
        .m_axi_araddr  (v_araddr),
        .m_axi_arlen   (v_arlen),
        .m_axi_arsize  (v_arsize),
        .m_axi_arburst (v_arburst),
        .m_axi_arvalid (v_arvalid),
        .m_axi_arready (v_arready),
        .m_axi_rid     (v_rid),
        .m_axi_rdata   (v_rdata),
        .m_axi_rresp   (v_rresp),
        .m_axi_rlast   (v_rlast),
        .m_axi_rvalid  (v_rvalid),
        .m_axi_rready  (v_rready),
        .rgb           (v_rgb),
        .de            (v_de),
        .hs            (v_hs),
        .vs            (v_vs),
        .h_cnt_o       (v_hcnt),
        .v_cnt_o       (v_vcnt),
        .cfg_error     (v_cfg_err)
    );

    // =====================================================================
    // The interconnect under test
    // =====================================================================
    wire        mux_s0_awready, mux_s1_awready, mux_s2_awready, mux_s3_awready;
    wire [7:0]  mux_s0_arready;
    wire        mux_s1_arready, mux_s2_arready, mux_s3_arready;

    Axi_Mux #(
    ) u_mux (
        .Sys_Clk            (clk),
        .Sys_Rst_N          (rst_n),

        // ---- S0: stand-in BitBlt read engine (read channel only) ----
        .I_S0_AW_ID         (8'h18), .I_S0_AW_ADDR (32'h0), .I_S0_AW_LEN (8'h0),
        .I_S0_AW_SIZE       (3'b100), .I_S0_AW_BURST (2'b01), .I_S0_AW_LOCK (2'b0),
        .I_S0_AW_VALID      (1'b0),  .O_S0_AW_READY (mux_s0_awready),
        .I_S0_W_ID          (8'h18), .I_S0_W_DATA (128'h0), .I_S0_W_LAST (1'b0),
        .I_S0_W_STRB        (16'h0), .I_S0_W_VALID (1'b0), .O_S0_W_READY (),
        .O_S0_B_ID          (), .O_S0_B_VALID (), .I_S0_B_READY (1'b0),
        .I_S0_AR_ID         (s0_arid),   .I_S0_AR_ADDR (s0_araddr),
        .I_S0_AR_LEN        (s0_arlen),  .I_S0_AR_SIZE (3'b100),
        .I_S0_AR_BURST      (2'b01),     .I_S0_AR_LOCK (2'b0),
        .I_S0_AR_VALID      (s0_arvalid),.O_S0_AR_READY (s0_arready),
        .O_S0_R_ID          (s0_rid),    .O_S0_R_DATA (s0_rdata),
        .O_S0_R_LAST        (s0_rlast),  .O_S0_R_RESP (s0_rresp),
        .O_S0_R_VALID       (s0_rvalid), .I_S0_R_READY (s0_rready),

        // ---- S1/S2/S3: honestly idle ----
        .I_S1_AW_ID (8'h1A), .I_S1_AW_ADDR (32'h0), .I_S1_AW_LEN (8'h0),
        .I_S1_AW_SIZE (3'b100), .I_S1_AW_BURST (2'b01), .I_S1_AW_LOCK (2'b0),
        .I_S1_AW_VALID (1'b0), .O_S1_AW_READY (mux_s1_awready),
        .I_S1_W_ID (8'h1A), .I_S1_W_DATA (128'h0), .I_S1_W_LAST (1'b0),
        .I_S1_W_STRB (16'h0), .I_S1_W_VALID (1'b0), .O_S1_W_READY (),
        .O_S1_B_ID (), .O_S1_B_VALID (), .I_S1_B_READY (1'b0),
        .I_S1_AR_ID (8'h1A), .I_S1_AR_ADDR (32'h0), .I_S1_AR_LEN (8'h0),
        .I_S1_AR_SIZE (3'b100), .I_S1_AR_BURST (2'b01), .I_S1_AR_LOCK (2'b0),
        .I_S1_AR_VALID (1'b0), .O_S1_AR_READY (mux_s1_arready),
        .O_S1_R_ID (), .O_S1_R_DATA (), .O_S1_R_LAST (), .O_S1_R_RESP (),
        .O_S1_R_VALID (), .I_S1_R_READY (1'b0),

        .I_S2_AW_ID (8'h1C), .I_S2_AW_ADDR (32'h0), .I_S2_AW_LEN (8'h0),
        .I_S2_AW_SIZE (3'b100), .I_S2_AW_BURST (2'b01), .I_S2_AW_LOCK (2'b0),
        .I_S2_AW_VALID (1'b0), .O_S2_AW_READY (mux_s2_awready),
        .I_S2_W_ID (8'h1C), .I_S2_W_DATA (128'h0), .I_S2_W_LAST (1'b0),
        .I_S2_W_STRB (16'h0), .I_S2_W_VALID (1'b0), .O_S2_W_READY (),
        .O_S2_B_ID (), .O_S2_B_VALID (), .I_S2_B_READY (1'b0),
        .I_S2_AR_ID (8'h1C), .I_S2_AR_ADDR (32'h0), .I_S2_AR_LEN (8'h0),
        .I_S2_AR_SIZE (3'b100), .I_S2_AR_BURST (2'b01), .I_S2_AR_LOCK (2'b0),
        .I_S2_AR_VALID (1'b0), .O_S2_AR_READY (mux_s2_arready),
        .O_S2_R_ID (), .O_S2_R_DATA (), .O_S2_R_LAST (), .O_S2_R_RESP (),
        .O_S2_R_VALID (), .I_S2_R_READY (1'b0),

        .I_S3_AW_ID (8'h18), .I_S3_AW_ADDR (32'h0), .I_S3_AW_LEN (8'h0),
        .I_S3_AW_SIZE (3'b100), .I_S3_AW_BURST (2'b01), .I_S3_AW_LOCK (2'b0),
        .I_S3_AW_VALID (1'b0), .O_S3_AW_READY (mux_s3_awready),
        .I_S3_W_ID (8'h18), .I_S3_W_DATA (128'h0), .I_S3_W_LAST (1'b0),
        .I_S3_W_STRB (16'h0), .I_S3_W_VALID (1'b0), .O_S3_W_READY (),
        .O_S3_B_ID (), .O_S3_B_VALID (), .I_S3_B_READY (1'b0),
        .I_S3_AR_ID (8'h18), .I_S3_AR_ADDR (32'h0), .I_S3_AR_LEN (8'h0),
        .I_S3_AR_SIZE (3'b100), .I_S3_AR_BURST (2'b01), .I_S3_AR_LOCK (2'b0),
        .I_S3_AR_VALID (1'b0), .O_S3_AR_READY (mux_s3_arready),
        .O_S3_R_ID (), .O_S3_R_DATA (), .O_S3_R_LAST (), .O_S3_R_RESP (),
        .O_S3_R_VALID (), .I_S3_R_READY (1'b0),

        // ---- S4: the video scan-out ----
        .I_S4_AW_ID (8'h1E), .I_S4_AW_ADDR (32'h0), .I_S4_AW_LEN (8'h0),
        .I_S4_AW_SIZE (3'b100), .I_S4_AW_BURST (2'b01), .I_S4_AW_LOCK (2'b0),
        .I_S4_AW_VALID (1'b0), .O_S4_AW_READY (),
        .I_S4_W_ID (8'h1E), .I_S4_W_DATA (128'h0), .I_S4_W_LAST (1'b0),
        .I_S4_W_STRB (16'h0), .I_S4_W_VALID (1'b0), .O_S4_W_READY (),
        .O_S4_B_ID (), .O_S4_B_VALID (), .I_S4_B_READY (1'b0),
        .I_S4_AR_ID    (v_arid),    .I_S4_AR_ADDR  (v_araddr),
        .I_S4_AR_LEN   (v_arlen),   .I_S4_AR_SIZE  (v_arsize),
        .I_S4_AR_BURST (v_arburst), .I_S4_AR_LOCK  (2'b00),
        .I_S4_AR_VALID (v_arvalid), .O_S4_AR_READY (v_arready),
        .O_S4_R_ID     (v_rid),     .O_S4_R_DATA   (v_rdata),
        .O_S4_R_LAST   (v_rlast),   .O_S4_R_RESP   (v_rresp),
        .O_S4_R_VALID  (v_rvalid),  .I_S4_R_READY  (v_rready),

        // ---- master side ----
        .O_M_AW_ID    (m_awid),    .O_M_AW_ADDR  (m_awaddr),
        .O_M_AW_LEN   (m_awlen),   .O_M_AW_SIZE  (m_awsize),
        .O_M_AW_BURST (m_awburst), .O_M_AW_LOCK  (m_awlock),
        .O_M_AW_VALID (m_awvalid), .I_M_AW_READY (m_awready),
        .O_M_W_ID     (m_wid),     .O_M_W_DATA   (m_wdata),
        .O_M_W_LAST   (m_wlast),   .O_M_W_STRB   (m_wstrb),
        .O_M_W_VALID  (m_wvalid),  .I_M_W_READY  (m_wready),
        .I_M_B_ID     (m_bid),     .I_M_B_VALID  (m_bvalid),
        .O_M_B_READY  (m_bready),
        .O_M_AR_ID    (m_arid),    .O_M_AR_ADDR  (m_araddr),
        .O_M_AR_LEN   (m_arlen),   .O_M_AR_SIZE  (m_arsize),
        .O_M_AR_BURST (m_arburst), .O_M_AR_LOCK  (m_arlock),
        .O_M_AR_VALID (m_arvalid), .I_M_AR_READY (m_arready),
        .I_M_R_ID     (m_rid),     .I_M_R_DATA   (m_rdata),
        .I_M_R_LAST   (m_rlast),   .I_M_R_RESP   (m_rresp),
        .I_M_R_VALID  (m_rvalid),  .O_M_R_READY  (m_rready),

        // ---- configuration: all five channels enabled ----
        .Cfg_Arb_Type (1'b1),
        .Cfg_Cnl_Mask (5'b11111),

        .O_AW_Cnl_Num (), .O_W_Cnl_Num (), .O_B_Cnl_Num (),
        .O_AR_Cnl_Num (), .O_R_Cnl_Num ()
    );

    // =====================================================================
    // Pixel checking: the video stream must be framebuffer data, not 0xAAAA
    // =====================================================================
    integer px_checks  = 0;
    integer px_errors  = 0;
    integer px_aaaa    = 0;      // pixels that look like the OTHER master's data
    integer exp_row    = 0;
    integer exp_col    = 0;
    integer rows_seen  = 0;

    // Periodic state dump. Needed to tell apart two very different failures:
    //   - v_cnt stops advancing  -> the timing generator is stuck
    //   - v_cnt advances but fifo_wcnt stays high -> the read side is not
    //     draining the FIFO, so the prefetch never asks for another line
    // Those have completely different fixes, and the pixel counts alone cannot
    // distinguish them.
    integer dbg_tick = 0;
    always @(posedge pclk) begin
        if (rst_n) begin
            dbg_tick = dbg_tick + 1;
            if ((dbg_tick % 5000) == 0)
                $display("  DBG t=%0t v=%0d h=%0d de=%b wcnt=%0d st=%0d full=%b",
                         $time, v_vcnt, v_hcnt, v_de,
                         u_video.u_fifo.wcnt_o, u_video.state,
                         u_video.fifo_full);
        end
    end

    // Watch the S4-side handshake specifically. The distinction that matters:
    //   m_rlast is produced by THIS testbench's slave
    //   v_rlast is what Axi_Mux forwards to the video module
    // Axi_Mux's read controller uses I_S4_R_LAST to decide a transaction is
    // finished, so if it forwards rvalid/rdata but not rlast, the controller
    // waits forever and never raises O_S4_AR_READY again -- which would exactly
    // explain state stuck in S_AR.
    integer s4_tick = 0;
    integer s4_data = 0;       // beats seen on the S4 read channel
    integer s4_last = 0;       // how many of them carried rlast
    integer s4_ar_ok = 0;

    // Count what actually moves through the FIFO ports.
    //
    // The reported numbers do not add up: 4 read bursts of 159 beats is 2544
    // pixels, yet 35 rows (22400 pixels) are displayed. Either the write side
    // pushes far more than was fetched, or rows advance without consuming. These
    // two counters separate those cases directly, without a waveform.
    //
    // write beats and read beats are counted on their own clocks, and the row
    // counter is sampled from the video module's own rd_row.
    integer wr_beats = 0;
    integer rd_beats = 0;
    integer max_rd_row = 0;

    // How many AXI beats the video module actually accepted (beat_accept =
    // rvalid & rready while not splitting). With a correct splitter this should
    // equal the number of pixels fetched / 4. If it matches but fifo_we is far
    // larger, the splitter is re-writing one held beat many times.
    integer beat_accepts = 0;
    integer split_starts = 0;
    reg     splitting_d = 1'b0;

    // How many times the slave model actually STARTED a burst.
    //
    // There are only 5 AR requests on the wire (4 from S4, 1 from S0), so a
    // correct model starts 5 bursts. beat_accept is 6124, which at 5 clocks per
    // beat implies roughly 12 bursts' worth of beats -- so either bursting
    // restarts, or the count comes from somewhere else. This settles it.
    integer burst_starts = 0;
    integer qrd_pulses   = 0;
    reg     bursting_d = 1'b0;
    reg [2:0] q_rd_d = 3'd0;

    // DUT-side read channel: what the VIDEO MODULE actually sees.
    //
    // Everything measured so far (burst_starts=5, rlast firing at beat_idx==159)
    // is on the TB side of Axi_Mux. Yet the DUT counts 6124 beat_accepts where
    // the TB only produced 800 beats. So compare the two sides directly:
    //   v_handshakes : v_rvalid & v_rready  -- beats the video module consumed
    //   v_lasts      : v_rlast pulses       -- how many bursts it was told ended
    // If handshakes are ~6124 but lasts are 5, Axi_Mux is presenting one beat
    // many times over; if lasts are also ~6124 the mux is inventing whole bursts.
    integer v_handshakes = 0;
    integer v_lasts      = 0;
    integer v_valids     = 0;

    // Mirror the same measurement on the TB side of the mux.
    //
    // Axi_Mux drives S4's rvalid straight from M_R_Valid (line 2162:
    // S_R_Valid = R_Act_Cnl_List & {ACN{M_R_Valid}}), so the DUT's 108166
    // rvalid-high clocks can only come from m_rvalid being high that long. But
    // burst_starts is 5 and each burst should last 800 clocks. If m_valids here
    // is also ~108166, the model leaves m_rvalid asserted between bursts.
    integer m_valids     = 0;
    integer m_handshakes = 0;
    integer tlast_pulses = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (m_rvalid) begin
                m_valids <= m_valids + 1;
                if (m_rready) m_handshakes <= m_handshakes + 1;
                if (m_rlast)  tlast_pulses <= tlast_pulses + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (v_rvalid) begin
                v_valids <= v_valids + 1;
                if (v_rready) v_handshakes <= v_handshakes + 1;
                if (v_rlast)  v_lasts <= v_lasts + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            bursting_d <= bursting;
            if (bursting && !bursting_d) burst_starts <= burst_starts + 1;
            q_rd_d <= q_rd;
            if (q_rd != q_rd_d) qrd_pulses <= qrd_pulses + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            // There is no splitter any more: one beat is accepted and stored
            // per cycle, so "a beat was accepted" is just the R handshake.
            // The old split_starts counter tracked splitting edges, which no
            // longer exist. Counting the handshake here instead keeps the
            // number meaningful.
            if (v_rvalid && v_rready) beat_accepts <= beat_accepts + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && u_video.fifo_we) wr_beats <= wr_beats + 1;
    end

    always @(posedge pclk) begin
        if (rst_n && u_video.fifo_re) rd_beats <= rd_beats + 1;
        if (u_video.rd_row > max_rd_row) max_rd_row <= u_video.rd_row;
    end

    // Declared BEFORE the always block that uses it.
    //
    // This was previously declared after the block, at the end of the probe
    // section. iverilog accepts a use-before-declaration and implicitly creates
    // the name; Questa rejects it outright:
    //     (vlog-2730) Undefined variable: 'end_win'
    //     (vlog-2388) 'end_win' already declared in this scope
    // The implicit version is a wire being assigned by blocking assignment from
    // inside a clocked block, which is not well defined -- and this testbench
    // wedges under iverilog at a fixed simulated time with no signal activity,
    // which is consistent with the simulator mis-scheduling around it in a way
    // that never terminates.
    integer end_win = 0;

    // Probe Rd_Ctrl's internal view. The question is whether the controller
    // ever recognises the burst as finished:
    //   M_R_End = M_R_Ready & M_R_Valid & M_R_Last
    // If M_R_End never pulses, the channel is never released and AR_READY stays
    // low forever -- which is what the transcript shows.
    always @(posedge clk) begin
        if (rst_n) begin
            s4_tick = s4_tick + 1;

            if (v_rvalid) begin
                s4_data = s4_data + 1;
                if (v_rlast) s4_last = s4_last + 1;
                if (s4_data <= 4 || v_rlast)
                    $display("  S4DATA t=%0t #%0d rid=%h rlast=%b rready=%b arready=%b",
                             $time, s4_data, v_rid, v_rlast, v_rready, v_arready);
            end

            if (v_arvalid && v_arready) s4_ar_ok = s4_ar_ok + 1;

            // The previous probe only logged while the video FSM sat in S_R, so
            // it stopped the instant the burst completed -- exactly when the
            // interesting part starts. Trigger on M_R_End instead and keep
            // logging for 20 clocks afterwards, so channel release is visible.
            if (u_mux.U3_Axi_Mux_Rd_Ctrl.M_R_End) begin
                $display("  END  t=%0t *** M_R_End pulses ***", $time);
                end_win = 20;
            end
            if (end_win > 0) begin
                end_win = end_win - 1;
                $display("  END  t=%0t (+%0d) M_R_End=%b R_Act=%b AR_Num=%0d S_AR_Rdy=%b S4_AR_Rdy=%b st=%0d",
                         $time, (20 - end_win),
                         u_mux.U3_Axi_Mux_Rd_Ctrl.M_R_End,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.AR_Act_Cnl_Num,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.S_AR_Ready,
                         v_arready,
                         u_video.state);
            end
        end
    end

    // Trace the AR arbiter from reset. The deadlock mechanism is now clear from
    // reading Addr_Ctrl:
    //     Act_Cnl_List only clears on M_A_End
    //     M_A_Valid = |(Act_Cnl_List & S_A_Valid)   -- only the LOCKED channel
    // so if it locks onto a channel with no request, it can never unlock. What
    // is not yet known is how it locked onto S0 in the first place, and whether
    // M_A_End ever fired for that transaction.
    // Log only on change (or on M_A_End) -- a level-sensitive probe floods the
    // transcript and buries the transition being looked for.
    reg [4:0] prev_act = 5'h00;
    reg       prev_mae = 1'b0;
    reg [4:0] prev_rlist = 5'h00;
    always @(posedge clk) begin
        if (rst_n) begin
            // R-side channel ownership. This is a DIFFERENT register from the AR
            // side's Act_Cnl_List, maintained by U3_R_Info_Process. The AR side
            // is already known to rotate correctly, yet S4's read data is being
            // delivered to S0 -- so the suspicion is that R_Act_Cnl_List never
            // moves off S0 after S0's short burst.
            if (u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_List !== prev_rlist) begin
                $display("  RLIST t=%0t R_Act=%b (hex %h) R_Num=%0d M_R_End=%b",
                         $time,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_Num,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.M_R_End);
                prev_rlist = u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_List;
            end

            if (u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Act_Cnl_List !== prev_act
                || u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.M_A_End !== prev_mae) begin
                $display("  ARB t=%0t Act=%b ActNum=%0d Chan=%b EffeVal=%b M_A_End=%b M_A_Valid=%b S4arvalid=%b",
                         $time,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Act_Cnl_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Act_Cnl_Num,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Channel_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Effe_S_Val,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.M_A_End,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.M_A_Valid,
                         v_arvalid);
                prev_act = u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Act_Cnl_List;
                prev_mae = u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.M_A_End;
            end
        end
    end

    // Probe the FIRST pixel of a row: that is where the 5-pixel shortfall
    // appears (exp_col stalls at 635, so each row drops its first 5 pixels).
    // What matters is whether the read side was simply not ready yet
    // (rd_valid low / FIFO empty) or whether rd_px starts at a non-zero phase.
    // Count how long each v_de burst actually is. A row should be H_ACT = 640
    // pclk. If the burst is longer, exp_col (which wraps at FB_W) drifts ahead
    // of h_cnt by exactly the excess -- matching the observed exp_col = 635
    // against h = 0.
    integer de_run = 0;
    integer run_no = 0;
    always @(posedge pclk) begin
        if (rst_n) begin
            if (v_de) begin
                de_run = de_run + 1;
            end else if (de_run != 0) begin
                if (run_no < 6)
                    $display("  DERUN n=%0d len=%0d  (expect %0d)", run_no, de_run, FB_W);
                run_no = run_no + 1;
                de_run = 0;
            end
        end
    end

    reg v_de_d = 1'b0;
    integer row_starts = 0;
    always @(posedge pclk) begin
        v_de_d <= v_de;
        if (rst_n && v_de && !v_de_d && row_starts < 6) begin
            $display("  ROWSTART n=%0d t=%0t v=%0d h=%0d rd_px=%0d rd_valid=%b fe=%b hold=%h",
                     row_starts, $time, v_vcnt, v_hcnt,
                     u_video.rd_px, u_video.rd_valid,
                     u_video.fifo_empty, u_video.rd_hold);
            row_starts = row_starts + 1;
        end
    end

    always @(posedge pclk) begin
        // Row 0 is skipped on purpose. At power-on the FIFO has not filled
        // yet, de is gated by rd_valid, and the first row therefore comes up a
        // few pixels short (measured: 635 instead of 640). Everything after it
        // is exactly 640, so checking from row 1 onward is aligned.
        //
        // A real frame is preceded by vertical blanking -- 45 lines at 1080p --
        // which is ample time to fill the FIFO, so this start-up artefact does
        // not exist in the system; it is an artefact of a testbench that begins
        // scanning immediately at v_cnt = 0.
        if (rst_n && v_de && armed) begin
            px_checks = px_checks + 1;

            if (v_rgb[23:16] == 8'hAA && v_rgb[15:8] == 8'hAA)
                px_aaaa = px_aaaa + 1;      // unmistakable cross-talk signature

            // Expect the pixel for the position the DUT says it is scanning,
            // not for a counter of our own.
            //
            // exp_row/exp_col were a local counter advancing once per de. That
            // is fragile: the first row is short by a few pixels while the FIFO
            // fills (de is gated by rd_valid, and at power-on the read side has
            // nothing yet), and a local counter then stays offset for the whole
            // frame -- 5 pixels of skew showed up as one error per row.
            //
            // v_vcnt/v_hcnt come from the DUT's own scan counters, so an early
            // shortfall cannot desynchronise the expectation. In the real
            // system a frame is preceded by vertical blanking (45 lines at
            // 1080p), which is ample time to fill the FIFO.
            if (v_rgb !== ((v_vcnt % 1000) * 1000 + v_hcnt) % 16777216) begin
                if (px_errors < 8)
                    $display("  PIX MISMATCH t=%0t v=%0d h=%0d got=%06h exp=%0d",
                             $time, v_vcnt, v_hcnt, v_rgb,
                             ((v_vcnt % 1000) * 1000 + v_hcnt) % 16777216);
                px_errors = px_errors + 1;
            end

            if (exp_col == FB_W - 1) begin
                exp_col = 0;
                exp_row = exp_row + 1;
                rows_seen = rows_seen + 1;
            end else begin
                exp_col = exp_col + 1;
            end
        end
    end

    // =====================================================================
    // Stimulus
    // =====================================================================
    integer i;
    integer seg;
    initial begin
        // Read the waveform setting before anything else. The return value is
        // ignored; dump_mode keeps its default of 0 when the plusarg is absent.
        dump_mode = 0;
        if ($value$plusargs("dump=%d", dump_mode)) begin end

        // VCD dumping is OFF by default, and controlled by ONE plusarg with a
        // value rather than two flags.
        //
        // The first attempt used $test$plusargs("dump") and
        // $test$plusargs("dump_late"). That does not work: $test$plusargs does a
        // PREFIX match, so "+dump_late" also satisfies "dump". Both blocks ran,
        // the first one opened the dump at time zero, and the second was ignored
        // with a warning. The result was a 13 MB waveform being written for the
        // whole run -- exactly the slowdown the change was meant to remove, but
        // now invisible because the code looked correct.
        //
        // A single valued argument has no such ambiguity:
        //     +dump=1   record from time zero
        //     +dump=2   start recording at 40 us (small file, for late failures)
        //     (absent)  no waveform at all
        if (dump_mode == 1) begin
            $dumpfile("tb_mux_video.vcd");
            $dumpvars(0, tb_mux_video);
            $display("  DUMP started at t=%0t (full run)", $time);
        end else if (dump_mode == 2) begin
            #40_000;                        // 40 us, in ns because of the timescale
            $dumpfile("tb_mux_video_late.vcd");
            $dumpvars(0, tb_mux_video);
            $display("  DUMP started at t=%0t (late window)", $time);
        end

        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // Fire S0 shortly after the video starts, so the two masters overlap.
        // Concurrency is the point: a serialised mux would hide an ID collision.
        //
        // arvalid MUST be held until arready. An earlier revision pulsed it for
        // a single clock and released it, which is an AXI protocol violation and
        // wedged the whole interconnect: Axi_Mux's AR arbiter latches onto the
        // requesting channel in S_ADDR_IDLE and only releases it on M_A_End,
        // where
        //     M_A_Valid = |(Act_Cnl_List & S_A_Valid)
        // looks only at the LOCKED channel. Dropping arvalid before the
        // handshake makes M_A_Valid fall to 0, so M_A_End never fires and
        // S_A_Ready stays stuck on channel 0 forever -- starving every other
        // master, including the video path. The video module itself never does
        // this (it sits in S_AR holding arvalid until ready), which is why S4's
        // own burst always completed fine.
        // 2026-10-14: this used to be ONE 4-beat burst. On the board the failure
        // needs the engine to be a PERSISTENT competitor -- a real sprite walker
        // issues hundreds of ARs per frame -- and a single burst is long over
        // before the scan-out presents its second. 64 bursts with a short gap is
        // what makes the two masters genuinely concurrent.
        repeat (200) @(posedge clk);
        for (s0_round = 0; s0_round < 64; s0_round = s0_round + 1) begin
            @(negedge clk); s0_arvalid = 1'b1;
            while (!s0_arready) @(posedge clk);
            @(negedge clk); s0_arvalid = 1'b0;
            repeat (20) @(posedge clk);
        end

        // Let the scanning run long enough for the two masters to be genuinely
        // concurrent and for the pixel comparison to gather a useful sample.
        // This used to be 450000 pclk = 18 ms of simulated time. Measured
        // throughput is about 40 us of simulated time per 20 s of CPU, so that
        // would have taken roughly two and a half hours -- and it was not the
        // VCD dumper doing it (turning that off changed nothing; five AXI
        // channels plus per-pixel comparison is simply expensive).
        //
        // What the test actually needs is far less:
        //   * S0's 4-beat burst must overlap S4's 159-beat burst  -> a few rows
        //   * enough pixels to catch cross-talk                    -> 20 rows is
        //     12800 samples, and the threshold below asks for 5000
        // 40000 pclk at 40 ns is 1.6 ms, about 11x cheaper.
        // Fine-grained progress, flushed after each step.
        //
        // An earlier version advanced in 10 segments of 4000 pclk and printed
        // nothing at all in 120 s -- which places the wedge inside the first
        // segment but says nothing about where. A 500-pclk step narrows it by
        // another factor of eight.
        //
        // $fflush matters more than the printing: redirected stdout is buffered,
        // and a stale log has been mistaken for a hang three times already in
        // this investigation. Flushing makes the log tell the truth.
        $display("  SEG start   t=%0t", $time);
        $fflush;

        // Phase 1: coarse, to reach the neighbourhood of the wedge (measured at
        // roughly 3000 pclk in).
        repeat (3000) @(posedge pclk);
        $display("  REACHED 3000   t=%0t", $time);
        $fflush;

        // Phase 2: fine, 50 pclk per step, so the stall lands inside one row of
        // 800 pclk. Coarse-only left it somewhere in a 500-pclk window.
        //
        // From +200 onwards, also dump the AR arbiter and the video FSM. The
        // stall was bracketed to between +200 and +250, and the existing probes
        // only fire when a signal CHANGES -- so at a stall they print nothing at
        // all, which is precisely when the state matters. These snapshots are
        // unconditional.
        for (seg = 0; seg < 100; seg = seg + 1) begin
            repeat (50) @(posedge pclk);
            $display("  +%0d   t=%0t", (seg + 1) * 50, $time);
            if (seg >= 3 && seg <= 8) begin
                $display("      AR  : Act=%b ActNum=%0d Chan=%b EffeVal=%b M_A_End=%b M_A_Valid=%b",
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Act_Cnl_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Act_Cnl_Num,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Channel_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.Effe_S_Val,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.M_A_End,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.U1_Axi_Mux_AR_Ctrl.M_A_Valid);
                $display("      R   : R_Act=%b R_Num=%0d M_R_End=%b S_AR_Rdy=%b",
                         u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_List,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.R_Act_Cnl_Num,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.M_R_End,
                         u_mux.U3_Axi_Mux_Rd_Ctrl.S_AR_Ready);
                $display("      VIDEO: state=%0d arvalid=%b arready=%b rvalid=%b rready=%b",
                         u_video.state, v_arvalid, v_arready, v_rvalid, v_rready);
                // Splitter state. rready is ~splitting, and splitting only
                // advances while fifo_we is high, which needs ~fifo_full. So
                // these three numbers decide whether the stall is ordinary
                // back-pressure (FIFO full, draining) or a deadlock (full and
                // not draining).
                $display("      BACKPRESSURE: fifo_full=%b fifo_we=%b rd_valid=%b rd_px=%0d",
                         u_video.fifo_full, u_video.fifo_we,
                         u_video.rd_valid, u_video.rd_px);
            end
            $fflush;
        end

        // Phase 3: run on to the end, sampling the video state periodically.
        //
        // The symptom is that only 4 read bursts are issued in 1.12 ms while 35
        // rows are displayed, so every row after the third replays stale FIFO
        // data. need_line requires wcnt < fb_width AND !splitting AND !cfg_bad;
        // a single snapshot cannot say which of those is failing, so sample
        // across the whole run instead.
        // 2026-10-14: was 10 x 2000 pclk = 20000 cycles = 0.8 ms, which at
        // H_ACT=1920 is barely ONE frame (12 lines x 2200 = 26400 pclk), so the
        // sample never reached the 5000-pixel threshold and the run FAILed for
        // lack of data rather than for a defect. 30 x 2000 = 2.4 ms is two+
        // frames.
        for (seg = 0; seg < 30; seg = seg + 1) begin
            repeat (2000) @(posedge pclk);
            $display("  T3 %0d/10  t=%0t  state=%0d fifo_full=%b rd_valid=%b rd_px=%0d",
                     seg + 1, $time, u_video.state, u_video.fifo_full,
                     u_video.rd_valid, u_video.rd_px);
            $display("       wcnt=%0d need_line=%b cfg_bad=%b rd_row=%0d fifo_empty=%b fifo_full=%b",
                     u_video.fifo_wcnt, u_video.need_line, u_video.cfg_bad,
                     u_video.rd_row, u_video.fifo_empty, u_video.fifo_full);
            // 2026-10-14: verify the self-proof counters THEMSELVES. On the board
            // they read "lines=0, frames=2200", which is arithmetically
            // impossible for a real 2200x1125 frame (one frame per 2.475M pclk,
            // so frames should advance by 1 in a 16.67 ms window). Either the
            // scan-out is broken or the counters are -- and the simulator is
            // where those two can be told apart.
            $display("       self-proof: o_lines_last=%0d (want V_ACT=%0d)  o_frames=%0d  h_cnt=%0d v_cnt=%0d H_TOTAL=%0d",
                     u_video.o_lines_last, 8, u_video.o_frames,
                     u_video.h_cnt, u_video.v_cnt, 2200);
            $fflush;
        end
        $display("  REACHED end   t=%0t", $time);
        $fflush;

        $display("");
        $display("==================================================");
        $display("  pixels checked   = %0d", px_checks);
        $display("  pixel errors     = %0d", px_errors);
        $display("  rows seen        = %0d", rows_seen);
        $display("  AR bursts total  = %0d", ar_seen);
        $display("  AR bursts S0     = %0d", ar_s0);
        $display("  AR bursts S4     = %0d", ar_s4);
        $display("  S0 beats         = %0d", s0_beats);
        $display("  S0 data errors   = %0d", s0_errors);
        $display("  pixels that look like 0xAAAA (cross-talk) = %0d", px_aaaa);
        $display("--------------------------------------------------");
        $display("  FIFO write beats (fifo_we pulses) = %0d", wr_beats);
        $display("  FIFO read  beats (fifo_re pulses) = %0d", rd_beats);
        $display("  max rd_row reached                = %0d", max_rd_row);
        $display("  pixels fetched by AXI (S4 x 160 x 4) = %0d", ar_s4 * 640);
        $display("  AXI beats accepted (beat_accept)   = %0d", beat_accepts);
        $display("  splitter cycles entered            = %0d", split_starts);
        $display("  slave burst starts                 = %0d", burst_starts);
        $display("  q_rd advances                      = %0d", qrd_pulses);
        $display("--------------------------------------------------");
        $display("  DUT side: v_rvalid high clocks     = %0d", v_valids);
        $display("  DUT side: v_rvalid&v_rready (beats)= %0d", v_handshakes);
        $display("  DUT side: v_rlast pulses           = %0d", v_lasts);
        $display("--------------------------------------------------");
        $display("  TB  side: m_rvalid high clocks     = %0d", m_valids);
        $display("  TB  side: m_rvalid&m_rready (beats)= %0d", m_handshakes);
        $display("  TB  side: m_rlast pulses           = %0d", tlast_pulses);
        $display("==================================================");

        // 5000 rather than 10000: the run was shortened above, and requiring a
        // sample larger than the run can produce would fail the test for the
        // wrong reason. 5000 pixels is ~8 rows of scanning -- still far more
        // than needed to see a routing error, which shows up in the first row.
        if (px_errors == 0 && s0_errors == 0 && px_aaaa == 0 &&
            px_checks > 5000 && ar_s0 > 0 && ar_s4 > 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");

        $finish;
    end

    initial begin
        #25_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

    // The per-clock burst trace that located the bug has been removed.
    //
    // It printed m_rvalid/m_rready/bursting/beat_idx/cur_len/q_cnt/q_rd/q_wr for
    // 400 clocks starting at t=64.4 us, and that is what showed cur_len = x on
    // the fifth burst. The root cause is fixed (the queue arrays were sized
    // [0:QD-1] = 4 while q_wr/q_rd are 3-bit and wrap at 8, so the fifth AR
    // wrote q_len[4], which does not exist), so the trace is no longer needed
    // and only slows the run.
    //
    // To reinstate it: a separate initial block (NOT fork/join_none, which is
    // SystemVerilog and this testbench compiles -g2005), waiting `repeat (6400)
    // @(posedge clk)` -- not `while ($time < 64000000)`, which silently never
    // exited under iverilog -- with its own loop variable so it cannot collide
    // with the stimulus block's `seg`.
    //
    // The occupancy counters above are kept: they are cheap and they state, in
    // the summary, whether the two sides of the mux agree.

endmodule
