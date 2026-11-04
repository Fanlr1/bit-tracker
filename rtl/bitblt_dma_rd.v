// BitBlt DMA read engine -- AXI4 burst reader with streaming output.
//
// PATTERN NOTES (from D1's axi4_ctrl.v, the only readable AXI4 master example in
// the reference material -- Ddr_Write.v is a DDR controller internals module and
// memory_test/* is encrypted):
//   * AR is simple: fixed burst length, INCR.
//   * A burst may be up to 256 beats (arlen is 8-bit). A 640-pixel ARGB8888 row
//     is 2560 B = 160 beats of 128-bit, so one burst covers a normal row; wider
//     rows loop the burst engine.
//   * The last burst is shortened so the engine never reads past total_bytes.
//
// OUTPUT FIFO (2026-10-13 -- fixes a system-level deadlock)
//   This engine used to expose a SINGLE output register. rready was therefore
//   "(!dout_valid) | dout_ready", which drops the moment the consumer stalls.
//   That is fatal here, because the two read engines feed a pixel engine that
//   only consumes when BOTH have valid data. If rd_src happens to arrive first,
//   its single register fills, its rready drops, the interconnect stops
//   accepting R beats, and the DDR controller then withholds ARREADY from the
//   OTHER reader -- whose AR is still pending. Measured on hardware: the read
//   arbiter sat on channel 2 forever (ar_cnl_num stuck at 2, 7 samples) while
//   rd_dst's arvalid stayed high and arready never came.
//   A small FIFO (one burst deep) lets a whole burst be drained from the bus
//   regardless of consumer progress, so a stalled consumer can no longer block
//   the address channel of the other reader.
//
// BACK-PRESSURE (rewritten -- the first version deadlocked)
//   m_axi_rready is COMBINATIONAL and means "the output register can take a
//   beat":  (!dout_valid) | dout_ready. The earlier version registered rready and
//   cleared dout_valid in the same cycle a new beat set it, so the later
//   assignment won and a beat was swallowed; with rready already low the transfer
//   could then never finish. The receive path below only clears dout_valid when
//   no new beat is arriving, which is the standard pipeline behaviour.
`timescale 1ns / 1ps

module bitblt_dma_rd #(
    parameter AXI_DW = 128,
    parameter AXI_AW = 32,
    parameter AXI_ID = 8'h10          // distinct from the SoC's master ID
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // ---------------- command ----------------
    input  wire                 start,          // one-cycle pulse
    input  wire [AXI_AW-1:0]    base_addr,
    input  wire [31:0]          total_bytes,    // 0 = nothing to do

    // ---------------- strided multi-row mode (2026-10-14, "plan A") --------
    // One start can read MANY rows: each row is a contiguous run of row_bytes,
    // and consecutive rows are row_stride apart. row_bytes == 0, or a
    // row_bytes that covers the whole transfer, means "one contiguous run" --
    // which is exactly the old behaviour, so a caller that leaves these at 0
    // is unaffected.
    //
    // WHY (docs/72): a 16x16 sprite costs 1,966 cycles, 86% of which is a
    // per-ROW fixed cost of ~106 cycles -- one more round trip through
    // arbitration, DDR command queueing and FSM turnaround. The destination
    // rows are strided, so the caller had to start this engine once per row
    // and paid that cost 16 times. Handing it the whole rectangle instead lets
    // the next row's AR go out while the previous row's data is still
    // returning.
    //
    // SAFETY IS UNCHANGED: a burst is still issued only when the whole of it
    // fits in the FIFO, and a burst never crosses a row boundary (the beats
    // left in the row cap the burst length). So no burst can be left half
    // finished holding the R channel, which is the docs/63 deadlock.
    input  wire [31:0]          row_bytes,      // 0 = contiguous transfer
    input  wire [AXI_AW-1:0]    row_stride,     // bytes between row starts

    output reg                  busy,
    output reg                  done,           // one-cycle pulse

    // ---------------- streaming output ----------------
    // Driven by the output FIFO below (see header note "OUTPUT FIFO").
    output wire [AXI_DW-1:0]    dout,
    output wire                 dout_valid,
    input  wire                 dout_ready,
    output reg  [31:0]          beats_sent,

    // ---------------- AXI4 read master ----------------
    output wire [7:0]           m_axi_arid,
    output wire [AXI_AW-1:0]    m_axi_araddr,
    output wire [7:0]           m_axi_arlen,
    output wire [2:0]           m_axi_arsize,
    output wire [1:0]           m_axi_arburst,
    output wire                 m_axi_arlock,
    output wire [3:0]           m_axi_arcache,
    output wire [2:0]           m_axi_arprot,
    output reg                  m_axi_arvalid,
    input  wire                 m_axi_arready,
    input  wire [7:0]           m_axi_rid,
    input  wire [AXI_DW-1:0]    m_axi_rdata,
    input  wire [1:0]           m_axi_rresp,
    input  wire                 m_axi_rlast,
    input  wire                 m_axi_rvalid,
    output wire                 m_axi_rready,
    output wire [1:0]           state_o          // DEBUG 2026-10-17: fetch FSM state out
);

    // Sized to the FULL address width on purpose. Declaring this as
    // [AXI_DW/8-1:0] (16 bits) and then reading BYTES_PER_BEAT[AXI_AW-1:0]
    // selects out-of-range bits, which synthesis and simulation fill with x --
    // the address increment silently became undefined in its upper bits.
    localparam [AXI_AW-1:0]   BYTES_PER_BEAT = AXI_DW / 8;
    localparam [2:0]          AXSIZE         = 3'd4;      // 128 bit = 16 B
    // REVERTED 2026-10-14: capping this at 32 (to match the 32-entry output
    // FIFO) made things WORSE -- the application stopped producing any UART
    // output at all, so the change introduced a new failure before the old one
    // was even confirmed resolved.
    // The capacity mismatch (256-beat bursts vs a 32-entry FIFO) is still the
    // leading hypothesis for the read-side deadlock, but it has to be tested
    // one variable at a time.
    // RETEST 2026-10-14: the earlier run of this change produced ZERO UART bytes,
    // which I misread as "the change made it worse". The baseline was then
    // re-verified (57 bytes, "software fill: ...") so that zero-byte run is now
    // attributed to a flash/boot hiccup, not to this cap. Testing it properly.
    // Rationale: Axi_Mux only accepts an R beat when the routed channel asserts
    // rready; this engine can absorb at most FIFO_DEPTH beats. With 256-beat
    // bursts and a 32-entry FIFO the FIFO overflows, rready drops, the mux stops
    // taking R, and the in-order DDR controller refuses the next AR.
    // Hardware evidence: r_cnl_num stuck at 1 with BOTH readers showing rready=0.
    // 2026-10-14 (later): raised 31 -> 127 TOGETHER WITH the FIFO. The cap
    // exists only so a burst can never overflow the FIFO, so it must track the
    // FIFO depth -- raising one without the other re-creates the 2026-10-13
    // deadlock. A 16x16 ARGB sprite is 1 KB = 64 beats, so with a 128-entry
    // FIFO one sprite is now a SINGLE burst instead of five, and the AR count
    // per sprite falls from 6 to 2 (one descriptor fetch, one source read).
    // Measured motivation: ~9k cycles per sprite against 193 beats of data --
    // the cost was DDR round trips, not bandwidth.
    // 2026-10-14 (later): TRIED 127 and REVERTED. Raising the cap requires
    // raising the FIFO, and raising the FIFO required a SYNCHRONOUS-read FIFO
    // first: the old one read combinationally (dout = fifo_mem[fifo_rd]), which
    // cannot map to block RAM, so 128 entries synthesised into ~18k extra LUTs
    // and ~21k extra FFs and the build failed (docs/38 recorded this same wall).
    //
    // 2026-10-15 (step 1): that prerequisite is now in place -- the storage is
    // bitblt_fwft_fifo, a synchronous-read (BRAM-mappable) FIFO with one-word
    // read-ahead, pinned by tb_bitblt_fwft_fifo. Measured on the board at
    // 13:00: clusters 45,065 -> 33,461 and RAM10 84 -> 97, at a cost of 0.9% of
    // throughput. The synchronous-FIFO step and the depth step were kept apart
    // so their effects stayed separable.
    //
    // 2026-10-15 (step 2): depth 32 -> 128 with MAX_BURST 31 -> 127.
    // TRIED ON THE BOARD AND REVERTED -- it is 19% SLOWER:
    //   1,206.9 -> 1,437.7 cycles per sprite, ceiling 1,364 -> 1,147, and
    //   game-40fps-floor FAILED (worst frame over 25 ms).
    //
    // WHY, AND WHY IT IS NOT OBVIOUS: both readers share one R channel and a
    // burst cannot be interrupted. Lengthening the SOURCE burst to 128 beats
    // makes the DESTINATION reader wait for all of it before it can have its
    // 4-beat row, so the pixel engine -- which needs BOTH readers valid -- goes
    // hungry. Same fairness mechanism as the 2026-10-13 deadlock (docs/61/63),
    // just short of deadlocking. "Longer burst = fewer round trips = faster"
    // (docs/66 section 6) quietly assumes the round trips belong to one reader.
    //
    // The FWFT module itself is NOT implicated: it is a large area win at 0.9%
    // cost (docs/79 section 5) and it stays.
    localparam [7:0]          MAX_BURST      = 8'd31;     // 32 beats = FIFO depth

    // total beats to read = ceil(total_bytes / BYTES_PER_BEAT)
    wire [31:0] total_beats = (total_bytes + BYTES_PER_BEAT - 32'd1)
                              / BYTES_PER_BEAT;

    reg  [31:0] beats_left;      // beats still to fetch
    reg  [31:0] burst_left;      // beats left in the current burst
    reg  [AXI_AW-1:0] cur_addr;
    reg  [1:0]  state;

    // ---- strided multi-row bookkeeping (see the port note) ----------------
    // strided is a function of the command, not of the data path, so it is
    // evaluated once and then simply respected by the burst capper and the
    // row-boundary jump.
    wire        strided    = (row_bytes != 32'd0) && (row_bytes < total_bytes);
    // Beats in ONE row, rounded up: a row is not guaranteed to be a whole
    // number of 128-bit beats.
    wire [31:0] row_beats  = (row_bytes + BYTES_PER_BEAT - 32'd1) / BYTES_PER_BEAT;

    reg  [31:0]       beats_in_row;    // beats still to fetch in THIS row
    reg  [AXI_AW-1:0] next_row_addr;   // start of the row after this one

    localparam [1:0] S_IDLE  = 2'd0,
                     S_AR    = 2'd1,
                     S_RD    = 2'd2,
                     S_DONE  = 2'd3;

    // Upper bound on this burst: the remaining beats, capped at MAX_BURST.
    // The ACTUAL length is chosen further down, once the FIFO's free space is
    // known -- see "ADAPTIVE BURST LENGTH". Splitting it in two keeps every
    // identifier declared before it is used, which Questa requires (iverilog
    // tolerates forward references and that difference already cost this
    // project a full debug cycle -- see docs/62).
    wire [31:0] burst_cap = (beats_left > {24'd0, MAX_BURST} + 32'd1)
                            ? {24'd0, MAX_BURST} + 32'd1
                            : beats_left;

    // A burst must ALSO stop at the end of the current row: the next row is
    // row_stride away, not one beat away, so a burst that crossed the boundary
    // would read the wrong bytes and -- worse -- would advance cur_addr past
    // the row without the jump happening. This is the only new constraint the
    // multi-row mode adds, and it is what keeps a burst atomic.
    wire [31:0] row_cap   = (beats_in_row < burst_cap) ? beats_in_row : burst_cap;

    assign m_axi_arid    = AXI_ID;
    assign m_axi_araddr  = cur_addr;
    // m_axi_arlen is assigned below, once the adaptive burst length is known.
    assign m_axi_arsize  = AXSIZE;
    assign m_axi_arburst = 2'b01;      // INCR
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'h0;
    assign m_axi_arprot  = 3'h0;

    // ---------------------------------------------------------------
    // Output FIFO -- MUST hold a whole burst, because Axi_Mux will not accept
    // an R beat unless this engine asserts rready. Depth is 32 = MAX_BURST+1.
    // ---------------------------------------------------------------
    // 2026-10-14 (later): was 5 (32 entries). The burst cap is tied to this, so
    // a 32-entry FIFO caps a burst at 32 beats and a 1 KB sprite needs five
    // bursts -- five DDR round trips -- where one would do. Round trips, not
    // bandwidth, are the measured bottleneck.
    // BRAM cost: 128 x 128 bit = 16 Kbit, about two RAM10 blocks per reader;
    // the design currently uses 74 of 256.
    //
    // 2026-10-15: the storage moved into bitblt_fwft_fifo. It used to be a
    // COMBINATIONALLY read array right here -- "assign dout = fifo_mem[fifo_rd]"
    // -- which cannot map to block RAM. That is why the 2026-10-14 attempt to
    // deepen it to 128 entries burned 17,900 extra LUTs and had to be rolled
    // back (docs/66 section 7). The module reads ahead one word, which keeps the
    // one-word-per-cycle throughput that a plain registered read would halve;
    // its contract is pinned by tb_bitblt_fwft_fifo before it is trusted here.
    // 2026-10-15 (step 2b): DEPTH ALONE, 32 -> 128 with MAX_BURST left at 31.
    // TRIED AND REVERTED -- 14.6% SLOWER (1,206.9 -> 1,382.9 cycles per sprite,
    // ceiling 1,364 -> 1,190, game-40fps-floor FAILED).
    //
    // The hypothesis was that the destination reader's AR -> R round trip (the
    // cost bounded in-flight writes proved is NOT the write side, docs/79) could
    // be prefetched away with a deeper FIFO while leaving the source burst at 32
    // beats. It cannot. Putting step 2 (depth + burst, -19.1%) and step 2b
    // (depth only, -14.6%) together, DEPTH ITSELF is the harmful variable, and
    // the burst cap only accounts for the remaining 4.5%.
    //
    // Combined with docs/74 (unbounded in-flight writes: slow state 4/4) and
    // with the one change that DID help -- bounded in-flight writes, +0.2% --
    // the rule for this machine is: the DDR controller is in-order, the current
    // request pattern already sits at its balance point, and ANY change that
    // raises the number or depth of outstanding requests makes it slower.
    // Reducing the NUMBER of round trips is still open; raising concurrency is not.
    localparam FIFO_AW    = 5;                       // 32 entries (see MAX_BURST note)
    localparam FIFO_DEPTH = 1 << FIFO_AW;

    wire [AXI_DW-1:0] fifo_dout;
    wire              fifo_dout_valid;
    wire              fifo_full;
    wire [FIFO_AW:0]  fifo_used;
    wire              fifo_empty;

    // Accept beats while there is room -- no longer tied to consumer progress.
    wire dout_can_accept = !fifo_full;
    assign m_axi_rready  = (state == S_RD) & dout_can_accept;

    wire r_fire = m_axi_rvalid & m_axi_rready;

    bitblt_fwft_fifo #(.DW(AXI_DW), .AW(FIFO_AW)) u_fifo (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (r_fire),
        .din        (m_axi_rdata),
        .full       (fifo_full),
        .used       (fifo_used),
        .empty      (fifo_empty),
        .dout       (fifo_dout),
        .dout_valid (fifo_dout_valid),
        .dout_ready (dout_ready)
    );

    assign dout       = fifo_dout;
    assign dout_valid = fifo_dout_valid;

    // ---------------------------------------------------------------
    // BURST ADMISSION (2026-10-14 -- fixes the board deadlock)
    // ---------------------------------------------------------------
    // WHY THIS EXISTS
    //   This engine used to assert ARVALID unconditionally in S_AR, so it
    //   issued back-to-back bursts and kept the shared R channel busy for as
    //   long as it had beats left. The real DDR controller is in-order: it
    //   serves one burst at a time and will not answer the OTHER reader's AR
    //   while this one is still mid-burst. So whenever this engine's FIFO
    //   filled up (it can absorb one burst and no more) it stalled inside its
    //   burst, the R channel stayed occupied, the other reader never got data,
    //   the pixel engine -- which needs BOTH readers valid -- never consumed
    //   anything, and the FIFO never drained. Permanent deadlock.
    //
    //   Measured on hardware in docs/61 (r_cnl_num stuck, both readers' rready
    //   low) and reproduced in simulation on 2026-10-14 the moment the ordered
    //   bus was modelled. The old single-slave testbench could not show it,
    //   because each reader had its own slave and always made progress.
    //
    // THE RULE
    //   Only start a burst that fits ENTIRELY in the FIFO. A burst can then
    //   always complete without the consumer's help, so the engine always
    //   releases the R channel between bursts and the other reader gets its
    //   turn. Cost: the FIFO must drain down before a full-size burst can
    //   start, which inserts bubbles -- the price of not deadlocking.
    //
    //   The two pointers carry a wrap bit, so a plain subtraction is the
    //   occupancy and needs no wrap handling.
    // Occupancy now comes from the FIFO module. It is the ARRAY occupancy and
    // deliberately EXCLUDES the word the module holds in its output register --
    // that word has already left the array, so charging the burst budget for it
    // made every burst one beat short and the burst COUNT went up (docs/79 3.1).
    // NOTE the zero-pad width: it must be 32 - (FIFO_AW+1) = 26 for a 6-bit
    // occupancy. It has to change with FIFO_AW or it truncates silently.
    wire [31:0]      fifo_free      = FIFO_DEPTH - {26'd0, fifo_used};

    // ---------------------------------------------------------------
    // ADAPTIVE BURST LENGTH (2026-10-14)
    // ---------------------------------------------------------------
    // The first version of the admission rule was "start a burst only if the
    // WHOLE of it fits", with the length fixed at MAX_BURST. That is safe, but
    // it costs a bubble on every burst: a 32-beat burst needs 32 free entries,
    // so the FIFO must drain COMPLETELY before the next AR may go out.
    //
    // Measured on hardware (docs/64): a 16x16 sprite -- 1 KB, two bursts --
    // costs ~9.2k cycles, about 2% of the available DDR bandwidth, and the
    // density sweep showed the cost scales per SPRITE rather than per byte.
    // Waiting for a completely empty FIFO between bursts is a large part of
    // that.
    //
    // This keeps the safety property -- a burst still cannot overflow the FIFO,
    // because its length is bounded by the free space at the moment it is
    // issued -- while removing the "wait until empty" bubble: with 8 entries
    // free the engine issues an 8-beat burst instead of waiting. Short bursts
    // cost more AR overhead, so the length is still allowed to grow to
    // MAX_BURST whenever the FIFO is empty.
    //
    // burst_want == 0 means "no room yet": S_AR simply waits, which is exactly
    // what lets the other reader through (the deadlock fix).
    // A FLOOR on the burst length.
    // Without it the engine happily issues 1-beat bursts whenever the FIFO is
    // nearly full. Simulation says that is free (the slave model answers
    // immediately) and it did shave ~7% off the walk -- but every AR is a full
    // DDR round trip on hardware, and the density sweep put a sprite's cost at
    // ~9.2k cycles of which almost all is latency, not bandwidth. Trading one
    // round trip for one beat is a bad bargain there.
    //
    // 8 beats keeps the benefit that matters (never wait for a completely empty
    // FIFO) while capping the AR count at 64/8 = 8 per 16x16 sprite instead of
    // 64. If fewer than 8 entries are free the engine waits, exactly as the
    // deadlock fix requires.
    //
    // 2026-10-15: measured (docs/80) the source read costs 5.37 ARs per 16x16
    // sprite at an average of 11.9 beats each, so the floor of 8 is not what
    // sets the count -- free space is. Raising it to 16 was TRIED AND REVERTED:
    // 1,204.9 -> 1,250.0 cycles per sprite (+3.74%), ceiling 1,368 -> 1,318.
    // Waiting for more room costs more than the longer burst saves, which is
    // what this comment claimed back when 8 was chosen. 8 stays.
    wire [31:0]      burst_floor    = 32'd8;
    wire [31:0]      burst_want     = (fifo_free >= burst_floor)
                                      ? ((row_cap > fifo_free) ? fifo_free : row_cap)
                                      : 32'd0;
    wire [7:0]       arlen_now      = burst_want[7:0] - 8'd1;
    wire             fifo_can_start = (burst_want != 32'd0);
    assign m_axi_arlen = arlen_now;

    // (the FIFO's storage, pointers and read-ahead now live in bitblt_fwft_fifo)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            m_axi_arvalid<= 1'b0;
            beats_left   <= 32'd0;
            burst_left   <= 32'd0;
            cur_addr     <= {AXI_AW{1'b0}};
            beats_sent   <= 32'd0;
            beats_in_row <= 32'd0;
            next_row_addr<= {AXI_AW{1'b0}};
        end else begin
            done <= 1'b0;                       // default: pulse only

            case (state)
                // ------------------------------------------------
                S_IDLE: begin
                    m_axi_arvalid <= 1'b0;
                    if (start) begin
                        // Clear unconditionally: an empty transfer must still
                        // report beats_sent = 0 rather than a stale value.
                        beats_sent <= 32'd0;
                        if (total_beats == 32'd0) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;      // nothing to do
                        end else begin
                            busy         <= 1'b1;
                            beats_left   <= total_beats;
                            cur_addr     <= base_addr;
                            // Contiguous transfers get one "row" that spans
                            // everything, so the row-boundary branch below is
                            // never taken and the old behaviour is preserved
                            // bit for bit.
                            beats_in_row <= strided ? row_beats : total_beats;
                            next_row_addr<= base_addr + row_stride;
                            state        <= S_AR;
                        end
                    end
                end

                // ------------------------------------------------
                // issue the read address
                S_AR: begin
                    // Admission control -- see "BURST ADMISSION" above. Holding
                    // ARVALID low here is what lets the other reader through.
                    if (fifo_can_start) begin
                        m_axi_arvalid <= 1'b1;
                        if (m_axi_arvalid && m_axi_arready) begin
                            m_axi_arvalid <= 1'b0;
                            burst_left    <= burst_want;
                            state         <= S_RD;
                        end
                    end else begin
                        m_axi_arvalid <= 1'b0;
                    end
                end

                // ------------------------------------------------
                // stream the read data out
                S_RD: begin
                    if (r_fire) begin
                        // The FIFO captures m_axi_rdata itself (see the FIFO
                        // always block); nothing to store here.
                        burst_left   <= burst_left - 32'd1;
                        beats_left   <= beats_left - 32'd1;
                        beats_in_row <= beats_in_row - 32'd1;
                        beats_sent   <= beats_sent + 32'd1;

                        if (m_axi_rlast) begin
                            if (beats_left <= 32'd1) begin
                                state <= S_DONE;    // whole transfer done
                            end else if (beats_in_row <= 32'd1) begin
                                // Last beat of this row: the next burst starts
                                // at the NEXT ROW, not at the next beat. Safe
                                // precisely because the burst that just ended
                                // was capped at the row boundary, so no beat
                                // belonging to this row is being skipped.
                                cur_addr      <= next_row_addr;
                                next_row_addr <= next_row_addr + row_stride;
                                beats_in_row  <= strided ? row_beats
                                                         : (beats_left - 32'd1);
                                state         <= S_AR;
                            end else begin
                                cur_addr <= cur_addr + BYTES_PER_BEAT;
                                state    <= S_AR;   // more bursts to go
                            end
                        end else begin
                            cur_addr <= cur_addr + BYTES_PER_BEAT;
                        end
                    end
                    // Draining is handled entirely by the FIFO's read pointer;
                    // no output-register bookkeeping is needed here any more.
                end

                // ------------------------------------------------
                // Wait for the consumer to take the final beat before declaring
                // done. Clearing dout_valid unconditionally here DROPPED the last
                // beat: the two read engines do not necessarily present their
                // final beat on the same cycle, so whenever the window was
                // missed the write engine waited forever for data that had been
                // thrown away.
                S_DONE: begin
                    m_axi_arvalid <= 1'b0;
                    if (!fifo_empty) begin
                        // still holding unconsumed beats -- wait for the consumer
                    end else begin
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        state      <= S_IDLE;
                    end
                end

                // Both 2-bit encodings are defined, so this is reachable only in
                // simulation (state = X). Parking the handshake outputs low
                // costs nothing and makes undefined-state behaviour identical
                // to S_IDLE rather than leaving ARVALID asserted.
                default: begin
                    state         <= S_IDLE;
                    m_axi_arvalid <= 1'b0;
                end
            endcase
        end
    end

// DEBUG 2026-10-17: expose the FSM state (IDLE=0 AR=1 RD=2 DONE=3).
assign state_o = state;

endmodule
