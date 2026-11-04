//============================================================================
// bitblt_sprite_state -- per-sprite position and velocity, on chip
//============================================================================
// The "maintenance" half of P4. The traversal engine draws each sprite from
// the position held HERE, and at the end of every frame this block advances
// that position by the velocity. The CPU writes the table once and then does
// nothing until it wants to change something.
//
// ---------------------------------------------------------------------------
// WHY THE STATE IS NOT IN MEMORY
// ---------------------------------------------------------------------------
// The obvious design puts position in the descriptor table and has the walker
// read-modify-write it each frame. Two things kill it:
//
//   1. The walker borrows the SOURCE READ engine. There is no write path at
//      all -- writing back would mean borrowing the write engine too, a second
//      mutual-exclusion problem on top of the first.
//   2. Bandwidth. This design shares one 1600 MB/s DDR3 with scan-out, which
//      already takes 594 MB/s at 1080p60. Read-modify-write for a few hundred
//      sprites per frame is exactly the wrong thing to spend it on.
//
// ---------------------------------------------------------------------------
// STORAGE: RAM for the payload, registers for the validity bits
// ---------------------------------------------------------------------------
//   x/y/vx/vy  ->  simple_dual_port_ram, 64 bits per slot, one slot per read
//   valid      ->  a plain register array
//
// The split is deliberate. simple_dual_port_ram has a 2-cycle read latency
// (OUTPUT_REG defaults to "TRUE"), and rd_valid is needed COMBINATIONALLY in
// the cycle the walker decides where to draw. Putting it in RAM would force a
// read two cycles early and couple the walker's state machine to this block's
// pipeline. A few hundred flip-flops are cheap; that coupling is not.
//
// rd_x/rd_y have the same 2-cycle latency, but they do NOT need to be
// combinational: rd_idx is wired to the walker's cur_index, which is settled
// well before S_BLIT, and the intervening descriptor fetch takes far longer
// than two cycles. So the position is simply there by the time it is used.
//
// re is tied high, always. r_rdata_2P updates unconditionally in the macro, so
// gating re would shift the pipeline under us rather than save power.
//
// ---------------------------------------------------------------------------
// THE FRAME-END SWEEP IS NOT PIPELINED, ON PURPOSE
// ---------------------------------------------------------------------------
// Advancing a slot in RAM is read-modify-write: present the address, wait two
// cycles, add, write back. Three cycles per slot, so 256 slots take 768 cycles
// -- 7.7 us out of a 16.7 ms frame. A pipelined version would overlap read and
// write and take a third of that, at the cost of a second index, a valid/ready
// handshake and a much harder thing to reason about. It is not worth 5 us.
//
// During the sweep the walker is parked in S_STEP and not reading, so the RAM
// read port is free to be driven by the sweep instead of rd_idx.
//============================================================================

`timescale 1ns / 1ps

module bitblt_sprite_state #(
    // 2026-10-14: 256 -> 1024 -> 2048 slots.
    // Every width that depends on this is DERIVED -- $clog2(N) for the payload
    // RAM address, $clog2(N/32) for the retired-bitmap word index -- so only
    // this parameter moves here; the software side moves BLT_SPR_MAX and
    // BLT_SPR_WORDS with it.
    //
    // GAME_MAX_SPRITES deliberately does NOT follow it any more. That constant
    // sizes the game's own arrays, and the application runs from 124 KB of
    // BRAM: the 1024-slot version already costs ~14 KB of .bss, so 2048 would
    // plausibly fail to link. And it would buy nothing -- 2048 sprites need
    // <= 813 cycles each to fit a 60 Hz frame, against ~1200 measured.
    //
    // Cost from 1024: payload RAM 2048 x 64 bit = 128 Kbit (~14 RAM10 blocks;
    // the design used 77 of 256), and ok/lv/rt grow from 1024 to 2048 bits each
    // (+3072 FFs total).
    // 2026-10-14: 2048 was tried and reverted -- see the note in bitblt_top.v.
    // At N=2048 this module alone needed ~23k xlr against ~9k at N=1024, and
    // the device ran out (62,373 clusters for 60,800 locations).
    parameter N  = 8192,       // slots; must be a power of two (RAM depth)
                               // 2026-10-16: raised from 2048 so the density sweep can
                               // MEASURE the frame-budget ceiling instead of extrapolating it
    parameter IW = 16          // external index width
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---------------- initialise one sprite (from a fetched descriptor) -----
    input  wire             init_en,
    input  wire [IW-1:0]    init_idx,
    input  wire [15:0]      init_x,
    input  wire [15:0]      init_y,
    input  wire [15:0]      init_vx,
    input  wire [15:0]      init_vy,

    // ---------------- read the current position (for dispatch) -------------
    input  wire [IW-1:0]    rd_idx,
    output wire [15:0]      rd_x,
    output wire [15:0]      rd_y,
    output wire             rd_valid,

    // ---------------- advance every sprite by its velocity -----------------
    input  wire             step_en,
    output reg              stepping,
    output reg              frame_done,

    // ---------------- screen bounds, for automatic retirement ---------------
    // The sweep already reads every slot, so testing the NEW position against
    // these costs one comparator and two adders that are already there. That
    // is why retirement lives here rather than in a separate pass: software
    // cannot do it, because the positions live on chip with no read-back path,
    // and recomputing them in software would be duplicate work on the one
    // thing this block exists to avoid duplicating.
    //
    // In pixels, matching the x/y stored per slot.
    input  wire [15:0]      fb_w,
    input  wire [15:0]      fb_h,

    // ---------------- clear all validity (re-arm for a fresh table) --------
    input  wire             clr_valid,
    // High while the clear walk is still zeroing slots. ok now lives in the
    // payload RAM, so clearing it takes N cycles instead of one; bitblt_top
    // gates the walker's enable with ~clr_busy so the table cannot be walked
    // while it is still being cleared.
    output wire             clr_busy,

    // ---------------- liveness: software retires a slot -------------------
    // Two bits per slot, and the distinction matters:
    //   seeded : the payload holds this slot's live state (was it ever drawn?)
    //   live   : draw it this frame
    //
    // A slot that has flown off screen is live=0, seeded=1. Reusing it for a
    // new bullet must clear BOTH, or the new one inherits the old position --
    // which looks like "new bullets appear where the last one died".
    //
    // There is no "set live" port: seeding happens exactly once, when a freshly
    // launched sprite is first walked, and at that instant it is by definition
    // alive. So init_en sets live as well as seeded, and the only thing
    // software has to say is "this one is dead".
    input  wire             live_clr_en,
    input  wire [IW-1:0]    live_clr_idx,

    // Whether this slot is alive. Combinational, like rd_valid, for the same
    // reason: the walker decides whether to dispatch on the cycle it reads it.
    output wire             rd_live,

    // ---------------- retired-slot bitmap, read back by software -----------
    // Retirement is detected HERE (the positions live on chip) but reclamation
    // must be decided by SOFTWARE (it knows when a new bullet needs a slot).
    // Those two facts are separated by missing information, not by logic, so
    // the only fix is to publish it: rt[i] is set when a sprite leaves the
    // screen, and software reads this window to find free slots.
    //
    // Without it a slot is used once and lost -- 256 bullets and the game
    // stops, which is exactly the failure this whole item exists to prevent.
    //
    // One 32-bit word at a time rather than 256 bits of ports: software loops
    // over (N/32) indices, which is eight reads for 256 slots.
    input  wire [IW-1:0]    rt_sel,     // which 32-bit word to expose
    output wire [31:0]      rt_word,

    // ---------------- position read-back (request / response) --------------
    // rt_word above can be read COMBINATIONALLY because the retired bitmap is a
    // register array. The positions are not: they live in Block RAM, which has
    // a two-cycle read latency. So this port cannot work the same way, and a
    // driver that writes an index and immediately reads the data would get the
    // PREVIOUS slot's coordinates -- a failure that looks like the engine
    // reporting stale positions rather than like a timing mistake.
    //
    // Hence a request/response pair. Pulsing dbg_req starts one read of dbg_idx;
    // two cycles later dbg_xy holds {y,x} and dbg_valid goes high. Software
    // polls dbg_valid rather than assuming.
    //
    // The caller must NOT pulse dbg_req while the walker is running: the RAM has
    // a single read port, and stealing an address cycle makes the walker read
    // the wrong slot's position. bitblt_top gates this with ~spr_busy.
    input  wire             dbg_req,
    input  wire [IW-1:0]    dbg_idx,
    output reg  [31:0]      dbg_xy,      // [15:0] = x, [31:16] = y
    output reg              dbg_valid
);

    localparam AW = $clog2(N);

    // ================= payload RAM =================
    // Layout in one 66-bit word: { lv, ok, vy, vx, y, x }
    //
    // WHY ok/lv LIVE HERE (2026-10-15). They used to be plain registers with
    // COMBINATIONAL bit selects:
    //     assign rd_valid = ok[idx_clamped];
    //     assign rd_live  = lv[idx_clamped];
    // At N=2048 each of those is a 2048:1 mux tree, and between them they cost
    // ~1,366 LUTs -- which is what pushed the 2048-slot build 2.6% over the
    // device (62,373 clusters against 60,800) and then, after two synthesis
    // area options, still 0.35% over (61,015).
    //
    // Moving them into the payload word removes those trees entirely, and costs
    // nothing in timing: the payload read is ALREADY two cycles deep, and the
    // walker's cur_index is settled long before S_BLIT needs the value (it
    // waits out a descriptor fetch in between). rd_valid/rd_live simply come
    // out of the same read instead of a mux.
    //
    // The width is 66, not 34: x/y/vx/vy are deliberately left at 16 bits.
    // Narrowing them would save RAM (which is not the constraint -- 86 of 256
    // RAM10 in use) while introducing three separate semantic hazards: vx/vy
    // are SIGNED speeds that currently rely on 16-bit wrap-around, and an
    // 11-bit x would wrap into the visible screen instead of off it.
    wire [65:0]     ram_rdata;
    reg  [65:0]     ram_wdata;
    reg  [AW-1:0]   ram_waddr;
    reg             ram_we;
    reg  [AW-1:0]   ram_raddr;

    wire [AW-1:0]   idx_clamped = (rd_idx < N) ? rd_idx[AW-1:0] : {AW{1'b0}};

    // ---- software position read-back state ----
    // Declared here, ahead of the read-address mux below, because the mux reads
    // dbg_act and dbg_addr. One declaration only: an earlier version had a wire
    // here and a reg further down, which iverilog rejects.
    reg             dbg_act;
    reg [1:0]       dbg_lat;
    reg [AW-1:0]    dbg_addr;

    // Three users of the single RAM read port, in priority order:
    //   stepping  -- the frame-end sweep, which is mid read-modify-write
    //   dbg_act   -- a software read-back in flight
    //   otherwise -- the walker, whose rd_idx is always driven by cur_index
    //
    // The sweep wins because it is a read-modify-write: interrupting it would
    // corrupt a slot. The read-back sits above the walker because bitblt_top
    // guarantees it is only requested while the walker is idle.
    wire [AW-1:0]   swp_addr;
    always @(*) begin
        if (clr_act)        ram_raddr = clr_cnt[AW-1:0];  // clear walk: read the slot
        else if (stepping)  ram_raddr = swp_addr;
        else if (dbg_act)   ram_raddr = dbg_addr;
        else                ram_raddr = idx_clamped;
    end

    simple_dual_port_ram #(
        .DATA_WIDTH (66),
        .ADDR_WIDTH (AW),
        .OUTPUT_REG ("TRUE")
    ) u_ram (
        .wdata (ram_wdata),
        .waddr (ram_waddr),
        .raddr (ram_raddr),
        .we    (ram_we),
        .wclk  (clk),
        .re    (1'b1),              // always: see header note
        .rclk  (clk),
        .rdata (ram_rdata)
    );

    // rd_x/rd_y carry the RAM's 2-cycle latency. That is fine: cur_index is
    // settled long before S_BLIT needs the value.
    assign rd_x = ram_rdata[15:0];
    assign rd_y = ram_rdata[31:16];

    // Two more fields of the SAME word -- see the layout note above. These are
    // no longer combinational; they carry the RAM's 2-cycle latency, which is
    // exactly the latency rd_x/rd_y already had.

    // ================= validity + liveness bits (registers) =================
    // Registers, not RAM: rd_valid and rd_live are both needed combinationally
    // in the cycle the walker picks a destination, and the RAM has a 2-cycle
    // read latency. A few hundred flip-flops are cheaper than that coupling.
    // WHY ok STAYS A REGISTER BUT lv DOES NOT (2026-10-15)
    //   Both were plain registers with combinational bit selects, and at N=2048
    //   each select is a 2048:1 mux tree; together they were ~1,366 LUTs, which
    //   is what pushed the 2048-slot build over the device.
    //
    //   lv moves into the payload word. Nothing needs to CLEAR it in a hurry:
    //   lv is only ever consulted when ok=1 (the walker branches on rd_valid
    //   first), so clearing ok -- one bit per slot, done in a single cycle --
    //   makes every lv irrelevant at once.
    //
    //   ok stays a register precisely because clr_valid must keep working as a
    //   one-cycle clear. clr_valid is ~reg_spr_enable, a LEVEL that goes high on
    //   every blt_spr_arm (which disarms then re-arms, tens of cycles apart); a
    //   RAM clear would need N=2048 cycles and would never finish between
    //   frames. The testbench pins this contract: it pulses clr_valid for one
    //   cycle and expects rd_valid low immediately.
    //
    //   rt also stays a register: software reads it a 32-bit WORD at a time
    //   (rt[{rt_wsel,5'b0} +: 32]), which a RAM would turn into 32 single-bit
    //   reads.
    // BOTH ok and lv are payload bits now (65 and 64). ok moved in on
    // 2026-10-15: it was 2,048 flops plus a 2048:1 combinational select, and
    // moving lv alone showed that such a move saves far more than the select
    // tree itself (61,015 -> 54,824 clusters, about 9x the estimate).
    //
    // The one obstacle was clr_valid, which MUST clear the whole table: it is
    // ~reg_spr_enable, a level that goes high on every blt_spr_arm (disarm then
    // re-arm, tens of cycles apart), and a RAM writes one address per cycle.
    // The answer is clr_busy: the clear runs over N cycles, and bitblt_top
    // holds the walker off until it finishes. The walker simply starts ~20 us
    // later in that frame, out of a 16.67 ms budget.
    // ------------------------------------------------------------------
    // RETIRED BITMAP -- stored as N/32 WORDS of 32 bits (2026-10-16, docs/86 s.12)
    // ------------------------------------------------------------------
    // It used to be one flat N-bit register: rt[k] <= ... for six different
    // writers, a single-cycle "clear every bit" (a for-loop over all N), and a
    // combinatorial 32-bit read mux. Every one of those costs logic proportional
    // to N, and at N=8192 that came to ~30,000 LUTs -- more than the device has
    // (62896 used vs 60800 available, which is what made 8192 unsynthesisable).
    //
    // Storing it as WORDS fixes the same semantics with far less logic:
    //   * a single-bit write now decodes 32 ways inside ONE word (N/32 word
    //     select lines instead of N bit-select lines);
    //   * the clear-everything term is shared by the 32 flops of a word
    //     instead of being replicated per bit;
    //   * the read is already a whole word, so the mux disappears entirely
    //     (rt_word = rt_words[rt_wsel] -- no barrel shift).
    // Read latency is unchanged (still combinatorial), which matters: software
    // polls this bitmap between frames.
    // ★ syn_ramstyle is REQUIRED here. Left to itself the synthesiser folds this
    // array to a constant: it sees a read-modify-write of the same array, argues
    // that what it reads is therefore always zero, and optimises away the writes
    // too -- reported as "Optimizing into logic zero initialized read-only memory
    // block 'rt_words'". That reasoning is wrong for real hardware (the RAM holds
    // whatever previous writes put there), and it hides the whole point of the
    // RMW engine. The attribute forces a real memory.
    // ★ The bitmap is an EXPLICIT simple_dual_port_ram (instantiated at the end of
    // this section, where every wire it needs is already declared). As a plain reg
    // array the synthesiser folded it to a constant -- it sees a read-modify-write
    // of the same array, argues that what it reads is therefore always zero, and
    // deletes the writes with it ("Optimizing into logic zero initialized read-only
    // memory block 'rt_words'"). (* syn_ramstyle *) and (* syn_ram_style="block" *)
    // were both ignored. An instance removes the judgement call.
    wire [31:0]   rt_rd_data;   // driven by u_rt_ram below


    assign rd_valid = ram_rdata[65];       // ok, rides the payload's 2-cycle read
    assign rd_live  = ram_rdata[64];       // lv, same

    // ---- clear walk -------------------------------------------------------
    // clr_valid is a LEVEL that stays high for as long as the walker is
    // disabled, so the walk must run ONCE per disable instead of restarting
    // every cycle: it stops at N-1, and only a return to clr_valid=0 rewinds
    // the counter for next time.
    // READ-MODIFY-WRITE, not "write zero": clr_valid is defined to clear the
    // VALIDITY only. bitblt_top relies on that -- it disarms the table without
    // losing what was loaded -- and tb_bitblt_sprite_state pins it with two
    // checks ("leaves the stored position alone"). A whole-word write of zero
    // passed the first eight checks and failed exactly those two.
    localparam [1:0] CL_IDLE = 2'd0,
                     CL_RD   = 2'd1,   // address on the RAM port
                     CL_WR   = 2'd2;   // data valid, write it back
    reg  [1:0] clr_st;
    reg  [1:0] clr_lat;
    reg        clr_act;
    reg [AW:0] clr_cnt;
    assign clr_busy = clr_act;

    // Expose one 32-bit slice of the retired bitmap. Software walks
    // rt_sel = 0 .. N/32-1. Anything past the array reads as zero so a
    // software loop with a slightly wrong bound sees "nothing retired"
    // rather than aliasing onto a real word.
    //
    // The index is narrowed EXPLICITLY to $clog2(N/32) bits before it touches
    // the array. Leaving it 16 bits wide cost 1493 LUTs: the synthesizer could
    // not tell that only N/32 values are reachable, so it built a 256-way
    // 32-bit mux instead of an 8-way one. The range check above is what makes
    // the narrowing safe -- it has already forced anything out of range to 0.
    localparam RW = $clog2(N/32);
    wire [IW-1:0] rt_safe = (rt_sel < (N/32)) ? rt_sel : {IW{1'b0}};
    wire [RW-1:0] rt_wsel = rt_safe[RW-1:0];
    // ★ REGISTERED READ (2026-10-16, docs/86 s.19). With the write side freed of
    // its asynchronous reset, the synthesiser's remaining objection was
    // "read port is not synchronous" -- it will not put this array in block RAM
    // or LUTRAM while the read is combinatorial, and its fallback (logic memory
    // with an async read) costs MORE than the FF+decoder it replaced: measured
    // 16,930 -> 20,529 LUTs in u_spr_state. One output register fixes it.
    //
    // Software is unaffected: it writes BLT_SPR_RT (the word index), waits for
    // the AXI round trip, then reads BLT_SPR_RT_WORD -- two MMIO accesses that
    // already cost far more than one cycle of core_clk.
    // The array has ONE read port and the RMW engine owns it while it is busy,
    // so the software-visible word simply HOLDS its previous value during an
    // update. Software polls this bitmap between frames; a few cycles of staleness
    // around a retire/clear is invisible to it.
    reg [31:0] rt_word_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rt_word_r <= 32'd0;
        else if ((rt_st == RT_IDLE) && !rt_clr_all)
            rt_word_r <= rt_rd_data;   // registered output of u_rt_ram
    end
    assign rt_word = rt_word_r;



    // ================= frame-end sweep =================
    localparam [1:0] SW_IDLE = 2'd0,
                     SW_RD   = 2'd1,   // address presented, RAM latency running
                     SW_WAIT = 2'd2,   // data valid here, write it back
                     SW_NEXT = 2'd3;

    reg [1:0]       sw_state;
// ==================================================================
    reg [AW-1:0]    swp;
    // Explicit countdown rather than inferring the latency from how many
    // states happen to sit between address and data. Getting this wrong by one
    // reads the PREVIOUS slot's velocity, which presents as "every sprite
    // moves like the one before it" -- a symptom that points nowhere near the
    // cause. OUTPUT_REG="TRUE" means two cycles: addr -> r_rdata_1P -> r_rdata_2P.
    reg [1:0]       sw_lat;
    reg [15:0]      sw_x, sw_y, sw_vx, sw_vy;

    assign swp_addr = swp;
    // RMW WRITE PATH (2026-10-16, docs/86 s.18/19)
    // ==================================================================
    // The bitmap is written ONE BIT at a time (seed-clear, reclaim-clear,
    // retire-set, clear-all). Measured cost of that: 19,184 LUTs at 4096 slots
    // (ablation C) and ~35,000 at 8192 -- because block RAM accepts whole-word
    // writes only, so the synthesiser fell back to one flip-flop plus one LUT of
    // decode PER BIT. That fallback is what made 8192 overflow pnr.
    //
    // So every bit write becomes a read-modify-write of the containing WORD:
    //   IDLE -> RD (address presented, registered data comes back)
    //        -> WR (modified word written back)  -> IDLE
    // Three cycles per update, and updates happen at most a few dozen times per
    // frame (once per sprite seeded/retired/reclaimed) against a 1.6M-cycle
    // frame -- the throughput cost is nil.
    //
    // Software's read port is unaffected: it still sees a registered read, and
    // while the RMW engine is busy the read simply holds its previous value
    // (software polls between frames).
    localparam [1:0] RT_IDLE = 2'd0,
                     RT_RD   = 2'd1,   // first latency cycle
                     RT_RD2  = 2'd3,   // second: data valid
                     RT_WR   = 2'd2;

    reg  [1:0]     rt_st;
    reg  [AW-1:0]  rt_idx_r;      // slot whose bit is being changed
    reg            rt_val_r;      // 1 = set (retire), 0 = clear
    reg  [31:0]    rt_word_rd;    // word read back from the array
    reg            rt_clr_all;    // clear-all sweep active
    reg            rt_clr_seen;   // clr_valid delayed, to launch the sweep ONCE
    reg            rt_pwr_done;   // power-on clear issued (see below)
    reg  [AW-6:0]  rt_clr_word;   // its word counter

    // --- write requests, in priority order ---
    // Retire = the sweep found this sprite off screen (see SW_WAIT below).
    // This is the ONLY place a bit is SET; everything else clears one.
    // ★ GATED ON sw_lat == 0 (2026-10-16, docs/86 s.23). The sweep walks slots
    // with an explicit latency countdown (sw_lat) because simple_dual_port_ram
    // has a two-cycle read latency; ram_rdata is only THIS slot's data once the
    // countdown reaches zero. Sampling earlier -- which the old inline condition
    // did, since it sat at the top of the SW_WAIT case -- decides retirement
    // from the PREVIOUS slot's coordinates. Trace: at swp=0 the word still read
    // x=630 (the stale value) at lat=2, while the real data (x=0, on screen)
    // only arrived at lat=1. That falsely retired slot 0.
    wire rt_req_retire = (sw_state == SW_WAIT) && (sw_lat == 2'd0) &&
                         ((ram_rdata[15:0] + ram_rdata[47:32] > fb_w) ||
                          (ram_rdata[31:16] + ram_rdata[63:48] > fb_h));
    wire rt_req_seed   = init_en   & (init_idx < N);               // seed: clear
    wire rt_req_recl   = live_clr_en & (live_clr_idx < N);         // reclaim: clear
    wire rt_req_any    = rt_req_retire | rt_req_seed | rt_req_recl;
    // ★ PRIORITY: software-initiated requests first (reclaim, then seed), the
    // sweep's retire last. The retire request is true for the whole SW_WAIT of a
    // slot, so with retire on top it starved the reclaim request outright -- the
    // walker testbench caught it as "rt[3] still set after reclaim". Sweep
    // retires are idempotent and can wait a few cycles; software cannot.
    wire [AW-1:0] rt_req_idx = rt_req_recl ? live_clr_idx[AW-1:0]
                             : rt_req_seed ? init_idx[AW-1:0]
                                           : swp;
    // Only a retire SETS a bit; the other two clear one. So the value to write is
    // 1 exactly when the selected request is the retire.
    wire rt_req_val = !(rt_req_recl | rt_req_seed);

    // --- the array's single read port: RMW engine first, software read otherwise ---
    // Presented in the IDLE cycle itself (rt_req_idx is combinatorial) so the
    // macro's two-cycle latency lands exactly on RT_RD2, where the data is
    // captured. Presenting it in RT_RD would shift everything one cycle late and
    // read the PREVIOUS word.
    wire [AW-6:0] rt_rd_addr = rt_clr_all         ? rt_clr_word
                             : (rt_st == RT_IDLE) ? (rt_req_any ? rt_req_idx[AW-1:5]
                                                                : rt_wsel[AW-6:0])
                                                  : rt_idx_r[AW-1:5];


    // --- the array's single write port: whole words only ---
    wire [31:0] rt_bit_mask = 32'd1 << rt_idx_r[4:0];
    wire [31:0] rt_wdata    = rt_clr_all ? 32'd0
                          : rt_val_r    ? (rt_word_rd |  rt_bit_mask)
                                        : (rt_word_rd & ~rt_bit_mask);
    wire        rt_we       = (rt_st == RT_WR);   // whole-word write, both paths

    // ------------------------------------------------------------------
    // the bitmap memory itself: one write port, one read port
    // ------------------------------------------------------------------
    wire [AW-6:0] rt_waddr = rt_clr_all ? rt_clr_word : rt_idx_r[AW-1:5];
    simple_dual_port_ram #(
        .DATA_WIDTH (32),
        .ADDR_WIDTH (AW-5),
        .OUTPUT_REG ("TRUE")
    ) u_rt_ram (
        .wdata (rt_wdata),
        .waddr (rt_waddr),
        .raddr (rt_rd_addr),
        .we    (rt_we),
        .wclk  (clk),
        .re    (1'b1),
        .rclk  (clk),
        .rdata (rt_rd_data)
    );

    // ★ ONE always block, one reset branch -- the first version of this engine
    // put the array write in a second, PARALLEL "if (rst_n)" section inside the
    // same always block. That is legal Verilog, but the synthesiser did not
    // accept the array write from it: it reported "'rt_words' ... Optimizing
    // into logic zero initialized read-only memory block", i.e. it decided the
    // array was never written and folded it to a constant. Keeping every
    // assignment inside a single if/else with one reset branch fixes that.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rt_st       <= RT_IDLE;
            rt_idx_r    <= {AW{1'b0}};
            rt_val_r    <= 1'b0;
            rt_word_rd  <= 32'd0;
            rt_clr_all  <= 1'b0;
            rt_clr_word <= {(AW-5){1'b0}};
            rt_clr_seen <= 1'b0;
            rt_pwr_done <= 1'b0;
        end else begin
            // ---- the array's single write port: WHOLE WORDS ONLY ----
            // (the write goes to u_rt_ram's waddr/wdata ports, driven below)

            // ---- clear-all: ONE sweep per assertion of clr_valid ----
            // clr_valid is a level (high the whole time the walker is disabled),
            // so re-arming on the level would restart the sweep forever and hold
            // the shared read port hostage.
            // ★ POWER-ON CLEAR. The array has no initial block any more (it would
            // forbid RAM mapping) and no asynchronous reset write either (same
            // reason), so something must put it into a known state. This does it
            // with a single whole-word sweep right after reset release, i.e. with
            // ordinary synchronous word writes -- which is exactly what block RAM
            // accepts. Without it a testbench that ties clr_valid low (the walker
            // test does) would read-modify-write on X forever.
            rt_clr_seen <= clr_valid;
            if (!rt_pwr_done) begin
                rt_clr_all  <= 1'b1;
                rt_pwr_done <= 1'b1;
            end else if (clr_valid && !rt_clr_seen && !rt_clr_all && (rt_st == RT_IDLE)) begin
                rt_clr_all <= 1'b1;
            end

            // ---- state machine ----
            case (rt_st)
                RT_IDLE: begin
                    if (rt_clr_all) begin
                        rt_st <= RT_RD;
                    end else if (rt_req_any) begin
                        rt_idx_r <= rt_req_idx;
                        rt_val_r <= rt_req_val;
                        rt_st    <= RT_RD;
                    end
                end
                RT_RD: begin
                    rt_st <= RT_RD2;
                end
                RT_RD2: begin
                    rt_word_rd <= rt_rd_data;   // data valid now
                    rt_st      <= RT_WR;
                end
                RT_WR: begin
                    if (rt_clr_all) begin
                        if (rt_clr_word == (N/32)-1) begin
                            rt_clr_all  <= 1'b0;
                            rt_clr_word <= {(AW-5){1'b0}};
                            rt_st       <= RT_IDLE;
                        end else begin
                            rt_clr_word <= rt_clr_word + 1'b1;
                            rt_st       <= RT_RD;      // next word of the sweep
                        end
                    end else begin
                        rt_st <= RT_IDLE;
                    end
                end
                default: rt_st <= RT_IDLE;
            endcase
        end
    end


    integer k;
    // ★ NO initial BLOCK HERE (removed 2026-10-16, docs/86 s.18).
    //
    // It used to zero rt_words at elaboration time. That is the ONE thing that
    // stopped the synthesiser from putting this array in block RAM -- it
    // reported "Mapping into logic memory block 'rt_words' (8192 bits)
    // because it has async writer", and "logic memory" meant one flip-flop
    // plus one LUT of write decode PER BIT: measured at 16,600 LUTs for 4096
    // slots (2 LUTs per stored bit) and ~35,600 at 8192 -- which is exactly the
    // overflow that pnr hit (65,497 clusters vs 60,800).
    //
    // Nothing is lost by removing it:
    //   * the Efinix memory powers up zeroed in hardware;
    //   * the synchronous reset below already clears every word;
    //   * clr_valid (high while the walker is disabled, which includes
    //     power-on) writes every slot clean before the first frame.
    // The array is still written one BIT at a time (six write points), so the
    // synthesiser may choose LUTRAM rather than a block RAM -- either way it
    // stops building a flip-flop-plus-decoder per bit.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stepping   <= 1'b0;
            frame_done <= 1'b0;
            sw_state   <= SW_IDLE;
            swp        <= {AW{1'b0}};
            ram_we     <= 1'b0;
            ram_waddr  <= {AW{1'b0}};
            ram_wdata  <= 66'd0;
            dbg_act    <= 1'b0;
            dbg_lat    <= 2'd0;
            dbg_addr   <= {AW{1'b0}};
            dbg_xy     <= 32'd0;
            dbg_valid  <= 1'b0;
            clr_act    <= 1'b0;
            clr_cnt    <= {(AW+1){1'b0}};
            clr_st     <= CL_IDLE;
            clr_lat    <= 2'd0;
            // ★ rt_words is NOT cleared here (removed 2026-10-16, docs/86 s.19).
            // This branch is the "async writer" the synthesiser kept complaining
            // about: an asynchronous reset (negedge rst_n) writing the array is
            // enough to forbid block-RAM/LUTRAM mapping, and the fallback costs
            // one flip-flop PLUS one LUT of write decode per stored bit --
            // measured 16,600 LUTs for 4096 slots and ~35,600 at 8192, which is
            // exactly what made pnr overflow (65,497 clusters vs 60,800).
            //
            // Clearing it here is redundant anyway: clr_valid is high while the
            // walker is disabled, which INCLUDES power-on (see the note at the
            // clear walk below), so every word is written clean before the first
            // frame ever looks at it. ok and lv ride the payload RAM, which is
            // not cleared here either, for the same reason.
        end else begin
            frame_done <= 1'b0;
            ram_we     <= 1'b0;          // pulse only

            // ---- seed one slot ----
            // The payload write goes straight to RAM; the bits are set here so
            // rd_valid/rd_live turn on immediately rather than 2 cycles later.
            // rt is CLEARED: a slot being launched into is by definition not
            // retired, and leaving a stale rt set would make software see a
            // free slot that is actually in use.
            if (init_en && (init_idx < N)) begin
                ram_we    <= 1'b1;
                ram_waddr <= init_idx[AW-1:0];
                // One write carries everything: the two validity bits ride in
                // the top of the same word, so there is no second write and no
                // read-modify-write on this path.
                ram_wdata <= {1'b1, 1'b1, init_vy, init_vx, init_y, init_x};
                // rt bit cleared by the RMW engine (rt_req_seed)
            end

            // ---- reclaim a slot (software) ----
            // Clears all three. This is the ONLY way a slot becomes free
            // again: software read rt, saw this one retired, and is reusing it.
            if (live_clr_en && (live_clr_idx < N)) begin
                // The slot is being freed, so its whole payload goes to zero --
                // no read needed. ok=0 is what tells the walker "never seeded,
                // draw it and seed it from the descriptor"; lv=0 stops it being
                // drawn meanwhile.
                ram_we    <= 1'b1;
                ram_waddr <= live_clr_idx[AW-1:0];
                ram_wdata <= 66'd0;
                // rt bit cleared by the RMW engine (rt_req_recl)
            end

            // ---- software position read-back ----
            // Start on a request, then count out the RAM's two-cycle latency
            // before latching. The countdown is explicit for the same reason
            // the sweep's is: inferring it from how many states happen to sit
            // between address and data gets it wrong by one, and reading one
            // cycle early returns the PREVIOUS slot's coordinates.
            if (dbg_req) begin
                dbg_act   <= 1'b1;
                dbg_lat   <= 2'd2;
                dbg_addr  <= (dbg_idx < N) ? dbg_idx[AW-1:0] : {AW{1'b0}};
                dbg_valid <= 1'b0;
            end else if (dbg_act) begin
                if (dbg_lat != 2'd0) begin
                    dbg_lat <= dbg_lat - 2'd1;
                end else begin
                    dbg_xy    <= {ram_rdata[31:16], ram_rdata[15:0]};
                    dbg_valid <= 1'b1;
                    dbg_act   <= 1'b0;
                end
            end

            // ---- clear all ----
            // rt is one bit per slot and still clears in a single cycle.
            // Clear-all is now a word sweep through the RMW engine: it writes
            // N/32 whole words of zero (3 cycles each) instead of N individual
            // bits. clr_busy stays high for both, and bitblt_top already holds
            // the walker off until it falls.
            // ---- clear walk: read-modify-write, N slots ----
            // clr_busy rides clr_act and bitblt_top holds the walker off until
            // it falls. clr_valid being a LEVEL is why the walk runs once per
            // disable: it ends with clr_cnt at N-1, which does not satisfy the
            // "start" condition below, and only a return to clr_valid=0 rewinds
            // the counter for next time.
            case (clr_st)
                CL_IDLE: begin
                    clr_act <= 1'b0;
                    if (!clr_valid) begin
                        clr_cnt <= {(AW+1){1'b0}};
                    end else if (clr_cnt == {(AW+1){1'b0}}) begin
                        clr_act <= 1'b1;
                        clr_st  <= CL_RD;
                    end
                end

                CL_RD: begin
                    // address is on the RAM port (see the read-address mux)
                    clr_lat <= 2'd2;
                    clr_st  <= CL_WR;
                end

                CL_WR: begin
                    if (clr_lat != 2'd0) begin
                        clr_lat <= clr_lat - 2'd1;
                    end else begin
                        ram_we    <= 1'b1;
                        ram_waddr <= clr_cnt[AW-1:0];
                        ram_wdata <= { 1'b0,               // ok  cleared
                                       1'b0,               // lv  cleared
                                       ram_rdata[63:48],   // vy  KEPT
                                       ram_rdata[47:32],   // vx  KEPT
                                       ram_rdata[31:16],   // y   KEPT
                                       ram_rdata[15:0] };  // x   KEPT
                        if (clr_cnt == N - 1) begin
                            clr_act <= 1'b0;
                            clr_st  <= CL_IDLE;
                        end else begin
                            clr_cnt <= clr_cnt + 1'b1;
                            clr_st  <= CL_RD;
                        end
                    end
                end

                default: clr_st <= CL_IDLE;
            endcase

            // ---- frame-end sweep: read-modify-write, 3 cycles per slot ----
            case (sw_state)
                SW_IDLE: begin
                    stepping <= 1'b0;
                    if (step_en) begin
                        stepping <= 1'b1;
                        swp      <= {AW{1'b0}};
                        sw_state <= SW_RD;
                    end
                end

                // address is on the RAM port; its 2-cycle latency is running
                SW_RD: begin
                    sw_lat   <= 2'd2;
                    sw_state <= SW_WAIT;
                end

                // wait out the RAM latency, THEN latch and add. Only seeded
                // slots move: an unseeded one has no velocity, and advancing
                // it would invent motion.
                SW_WAIT: begin
                    if (sw_lat != 2'd0) begin
                        sw_lat <= sw_lat - 2'd1;
                    end else begin
                        // ok is bit 65 of the word this slot's read returned.
                        if (ram_rdata[65]) begin
                            // ---- automatic retirement ----
                            // Test the position the sprite is ABOUT to move to,
                            // not where it is now: a bullet leaving the screen
                            // this frame should stop being drawn this frame.
                            //
                            // ONLY lv is cleared here, NOT ok. Clearing ok as
                            // well looked equivalent and was wrong: ok=0 is
                            // what tells the walker "this slot was never
                            // seeded, so draw it and seed it from the
                            // descriptor". A retired slot would then be
                            // re-seeded and drawn again on the very next
                            // frame -- the testbench caught exactly that, with
                            // frame 2 dispatching 4 blits instead of 3.
                            //
                            // So the two events clear differently:
                            //   retired (off screen) : lv only  -> skip, but the
                            //                          slot is still occupied
                            //   live_clr (software)  : lv AND ok -> slot free,
                            //                          next launch re-seeds
                            if ((ram_rdata[15:0] + ram_rdata[47:32] > fb_w) ||
                                (ram_rdata[31:16] + ram_rdata[63:48] > fb_h)) begin
                                // Retired: clear lv, KEEP ok (see the long note
                                // above), and write the word back -- lv can no
                                // longer be cleared with a single bit assignment.
                                ram_we    <= 1'b1;
                                ram_waddr <= swp;
                                ram_wdata <= { 1'b1,                // ok: KEPT -- see the note above
                                               1'b0,                // lv: cleared
                                               ram_rdata[63:48],    // vy
                                               ram_rdata[47:32],    // vx
                                               ram_rdata[31:16],    // y
                                               ram_rdata[15:0] };   // x
                                // rt bit SET by the RMW engine (rt_req_retire, driven by rt_pub)
                            end else begin
                                ram_we    <= 1'b1;
                                ram_waddr <= swp;
                                ram_wdata <= { 1'b1,                              // ok: unchanged (it is 1 here)
                                               ram_rdata[64],                     // lv: unchanged
                                               ram_rdata[63:48],                  // vy: unchanged
                                               ram_rdata[47:32],                  // vx: unchanged
                                               ram_rdata[31:16] + ram_rdata[63:48], // y += vy
                                               ram_rdata[15:0]  + ram_rdata[47:32]  // x += vx
                                             };
                            end
                        end
                        sw_state <= SW_NEXT;
                    end
                end

                SW_NEXT: begin
                    if (swp == N - 1) begin
                        stepping   <= 1'b0;
                        frame_done <= 1'b1;
                        sw_state   <= SW_IDLE;
                    end else begin
                        swp      <= swp + 1'b1;
                        sw_state <= SW_RD;
                    end
                end

                default: sw_state <= SW_IDLE;
            endcase
        end
    end

endmodule
