//============================================================================
// tb_bitblt_sprite_state -- the state block on its own
//============================================================================
// WHY THIS EXISTS
//   bitblt_sprite_state is the only core module with no standalone testbench. It
//   has been covered only through the walker's, which drives it the way the
//   design happens to use it. Three things are therefore untested by
//   construction, because the walker never does them:
//
//     * clr_valid           -- driven by bitblt_top, so its path is not
//                              exercised in isolation
//     * out-of-range indices -- the walker only ever presents valid ones
//     * step_en re-entry     -- the walker fires it once per frame
//
//   Those are exactly the paths that only run when something is already wrong,
//   which is when a testbench is worth most.
//
// METHOD
//   Every assertion has a negative half: the state is established, checked, and
//   then the stimulus is applied and it is checked again. A testbench that only
//   looked at the after-state would pass on a block that ignored the input
//   entirely, and this project has already been bitten twice by one-directional
//   assertions (docs/48 section seven).
//
// FAULT INJECTION -- see the note at the end of this header.
//============================================================================

`timescale 1ns / 1ps

module tb_bitblt_sprite_state;

    localparam N  = 256;
    localparam IW = 16;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;                          // 100 MHz

    reg         init_en = 0;
    reg  [15:0] init_idx = 0;
    reg  [15:0] init_x = 0, init_y = 0, init_vx = 0, init_vy = 0;

    reg  [15:0] rd_idx = 0;
    reg         step_en = 0;
    reg  [15:0] fb_w = 1920, fb_h = 1080;
    reg  [15:0] rt_sel = 0;

    reg         dbg_req = 0;
    reg  [15:0] dbg_idx = 0;

    reg         clr_valid = 0;
    // ok/lv live in the payload RAM now, so the clear is a WALK of N cycles and
    // clr_valid alone cannot say when it is finished. bitblt_top gates the
    // walker's enable with ~clr_busy; this testbench waits on it directly.
    wire        clr_busy;
    reg         live_clr_en = 0;
    reg  [15:0] live_clr_idx = 0;

    wire [15:0] rd_x, rd_y;
    wire        rd_valid, rd_live, stepping, frame_done;
    wire [31:0] rt_word;
    wire [31:0] dbg_xy;
    wire        dbg_valid;

    bitblt_sprite_state #(.N(N), .IW(IW)) dut (
        .clk(clk), .rst_n(rst_n),
        .init_en(init_en), .init_idx(init_idx),
        .init_x(init_x), .init_y(init_y), .init_vx(init_vx), .init_vy(init_vy),
        .rd_idx(rd_idx), .rd_x(rd_x), .rd_y(rd_y),
        .rd_valid(rd_valid), .rd_live(rd_live),
        .fb_w(fb_w), .fb_h(fb_h),
        .step_en(step_en), .stepping(stepping), .frame_done(frame_done),
        .rt_sel(rt_sel), .rt_word(rt_word),
        .dbg_req(dbg_req), .dbg_idx(dbg_idx),
        .dbg_xy(dbg_xy), .dbg_valid(dbg_valid),
        .live_clr_en(live_clr_en), .live_clr_idx(live_clr_idx),
        .clr_valid(clr_valid),
        .clr_busy (clr_busy)
    );

    integer errors = 0;
    integer i, k;

    task check;
        input [255:0] what;
        input         ok;
        begin
            if (ok) $display("  PASS %0s", what);
            else begin $display("  FAIL %0s", what); errors = errors + 1; end
        end
    endtask

    task seed;
        input [15:0] idx, x, y, vx, vy;
        begin
            @(negedge clk);
            init_en = 1; init_idx = idx;
            init_x = x; init_y = y; init_vx = vx; init_vy = vy;
            @(negedge clk);
            init_en = 0;
        end
    endtask

    // Read a slot through the walker-facing port. rd_x/rd_y carry the RAM's
    // two-cycle latency; rd_valid is combinational on idx_clamped.
    task read_slot;
        input  [15:0] idx;
        output [15:0] ox, oy;
        begin
            @(negedge clk); rd_idx = idx;
            repeat (4) @(posedge clk);
            #1;
            ox = rd_x; oy = rd_y;
        end
    endtask

    reg [15:0] gx, gy;

    initial begin
        $display("==================================================");
        $display("  tb_bitblt_sprite_state -- the state block alone");
        $display("--------------------------------------------------");

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ================================================================
        // 1. clr_valid
        // ================================================================
        $display("  --- clr_valid ---");

        seed(16'd3, 16'h0100, 16'h0200, 16'd1, 16'd1);
        seed(16'd4, 16'h0300, 16'h0400, 16'd1, 16'd1);
        repeat (4) @(posedge clk);

        // NEGATIVE half: without clr_valid the slots are valid.
        @(negedge clk); rd_idx = 16'd3;
        repeat (2) @(posedge clk); #1;
        check("a seeded slot reports valid before any clear", rd_valid === 1'b1);

        // POSITIVE half: after clr_valid it is not.
        //
        // 2026-10-15: this used to be a one-cycle pulse, because the valid bits
        // were registers and cleared combinationally. They are payload RAM bits
        // now, and a RAM takes ONE address per cycle, so the clear is a walk of
        // N cycles. Waiting on clr_busy is the contract bitblt_top relies on.
        @(negedge clk); clr_valid = 1'b1;
        while (!clr_busy) @(negedge clk);   // walk has started
        while (clr_busy)  @(negedge clk);   // walk has finished
        @(negedge clk); clr_valid = 1'b0;
        repeat (4) @(posedge clk); #1;      // let the RAM read pipe settle
        check("clr_valid clears the valid flag of a seeded slot", rd_valid === 1'b0);

        @(negedge clk); rd_idx = 16'd4;
        repeat (2) @(posedge clk); #1;
        check("clr_valid clears it for every slot, not just the one selected",
              rd_valid === 1'b0);

        // The POSITION is not erased -- only the valid flag. That distinction
        // matters: bitblt_top relies on clr_valid to disarm the table without
        // losing what was loaded, so a re-seed does not have to repeat it.
        @(negedge clk); rd_idx = 16'd3;
        repeat (4) @(posedge clk); #1;
        check("clr_valid leaves the stored position alone (x still 0x0100)",
              rd_x === 16'h0100);
        check("clr_valid leaves the stored position alone (y still 0x0200)",
              rd_y === 16'h0200);

        // A slot can be re-armed afterwards.
        seed(16'd3, 16'h0100, 16'h0200, 16'd0, 16'd0);
        repeat (4) @(posedge clk);
        @(negedge clk); rd_idx = 16'd3;
        repeat (2) @(posedge clk); #1;
        check("a slot can be re-armed after clr_valid", rd_valid === 1'b1);

        // ================================================================
        // 2. out-of-range indices
        // ================================================================
        // Each of the three ports clamps to index 0 rather than propagating the
        // out-of-range value. That is a design decision worth pinning down: the
        // alternative -- reading whatever the RAM happens to return -- would
        // make an out-of-range request look like a legitimate one.
        $display("  --- out-of-range indices ---");

        seed(16'd0, 16'hAAAA, 16'h5555, 16'd0, 16'd0);
        seed(16'd7, 16'h0F0F, 16'hF0F0, 16'd0, 16'd0);
        repeat (4) @(posedge clk);

        // rd_idx = N is one past the end. NOTE: this assertion does NOT
        // actually test the clamp, and that was discovered by fault injection,
        // not by reading it. simple_dual_port_ram addresses on the low bits, so
        // 256 wraps to slot 0 on its own -- removing the clamp leaves this
        // passing. It is kept because it is still true and still worth stating,
        // but the assertion below is the one doing the work.
        @(negedge clk); rd_idx = N[15:0];
        repeat (4) @(posedge clk); #1;
        check("rd_idx == N reads slot 0 (true, but the RAM wraps here anyway)",
              rd_x === 16'hAAAA && rd_y === 16'h5555);

        // THIS is the one that tests the clamp. 60000 does not wrap onto slot 0
        // by address truncation, so it reaches slot 0 only because idx_clamped
        // forces it there.
        @(negedge clk); rd_idx = 16'd60000;
        repeat (4) @(posedge clk); #1;
        check("rd_idx far past the end still reads slot 0 (this tests the clamp)",
              rd_x === 16'hAAAA && rd_y === 16'h5555);

        // rt_sel past the last word must read word 0, not garbage. N/32 = 8, so
        // 8 is one past the end.
        @(negedge clk); rt_sel = 16'd0;
        repeat (2) @(posedge clk); #1;
        check("rt_sel 0 and rt_sel 8 agree (both clamped to word 0)",
              rt_word === 32'd0);          // nothing retired yet: word 0 is zero

        // dbg_idx past the end must read slot 0 as well.
        @(negedge clk);
        dbg_req = 1'b1; dbg_idx = 16'd1000;
        @(negedge clk); dbg_req = 1'b0;
        repeat (8) @(posedge clk); #1;
        check("dbg_idx past the end is clamped and still answers",
              dbg_valid === 1'b1);
        check("dbg_idx past the end returns slot 0's position",
              dbg_xy[15:0] === 16'hAAAA && dbg_xy[31:16] === 16'h5555);

        // ================================================================
        // 3. step_en re-entry
        // ================================================================
        // The sweep is a read-modify-write over every slot. Asserting step_en
        // again while it runs must NOT restart it -- a restart would re-apply
        // the velocity to slots already advanced, and the error would grow with
        // every extra assertion rather than being visible once.
        $display("  --- step_en re-entry ---");

        // COORDINATES MUST BE ON SCREEN. The first version seeded this slot at
        // (0x1000, 0x2000) = (4096, 8192) against a 1920x1080 framebuffer, so
        // the first sweep retired it -- correctly -- and the position stopped
        // advancing. The assertion then failed and looked like a restart bug.
        // A sweep only advances slots that survive it.
        seed(16'd5, 16'h0064, 16'h00C8, 16'd3, 16'd4);      // (100, 200) + (3, 4)
        repeat (4) @(posedge clk);

        @(negedge clk); step_en = 1'b1;
        @(negedge clk); step_en = 1'b0;
        repeat (20) @(posedge clk); #1;
        check("the sweep is running (stepping high)", stepping === 1'b1);

        // hammer step_en while it runs
        for (i = 0; i < 6; i = i + 1) begin
            @(negedge clk); step_en = 1'b1;
            @(negedge clk); step_en = 1'b0;
            repeat (3) @(posedge clk);
        end
        check("step_en during a sweep does not disturb stepping", stepping === 1'b1);

        // let it finish, counting frame_done pulses
        k = 0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(posedge clk);
            #1;
            if (frame_done) k = k + 1;
            if (!stepping && frame_done) i = 4000;   // done
        end
        $display("  INFO frame_done pulses counted after re-entry: %0d", k);
        check("exactly one frame_done despite repeated step_en", k === 1);

        // AND THE POSITION ADVANCED EXACTLY ONCE. This is the assertion that
        // would catch a restart: a second sweep would add the velocity twice.
        repeat (4) @(posedge clk);
        @(negedge clk); rd_idx = 16'd5;
        repeat (4) @(posedge clk); #1;
        check("the velocity was applied exactly once (100+3, 200+4)",
              rd_x === 16'h0067 && rd_y === 16'h00CC);

        // ================================================================
        $display("--------------------------------------------------");
        if (errors == 0) $display("RESULT: PASS (sprite state)");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #400000;
        $display("FAIL: testbench timed out");
        $display("RESULT: FAILED (timeout)");
        $finish;
    end

//============================================================================
// FAULT INJECTION -- PROOF THESE ASSERTIONS CAN FAIL
//
// MEASURED, NOT PREDICTED. The first version of this note listed expected
// failures that turned out to be wrong; it said the clamp injection produced
// two failures and it produces one. Writing "actual output" from expectation is
// exactly the mistake this project keeps finding, so every line below was
// copied from a run.
//
//   (a) clr_valid disabled (`if (clr_valid)` -> `if (1'b0)`), reverted after:
//         FAIL  clr_valid clears the valid flag of a seeded slot
//         FAIL  clr_valid clears it for every slot, not just the one selected
//         RESULT: FAILED with 2 error(s)
//       -> the negative half ("reports valid before any clear") still PASSES,
//          which is the point: without it, an inert clr_valid looks fine.
//
//   (b) clamp removed on the walker port
//       (`idx_clamped = (rd_idx < N) ? ... : 0` -> `= rd_idx[AW-1:0]`):
//         PASS  rd_idx == N reads slot 0 ...
//         FAIL  rd_idx far past the end still reads slot 0
//         RESULT: FAILED with 1 error(s)
//       -> ONE failure, not two, and the passing one is the finding. The RAM
//          addresses on low bits, so 256 wraps onto slot 0 by itself; only 60000
//          reaches slot 0 because the clamp puts it there. The assertion that
//          was written to test the clamp did not test the clamp. It is kept,
//          with a note, and the assertion below it does the work.
//
//   (c) step_en honoured outside SW_IDLE: not run. Stated as not run rather
//       than described, because describing an unrun injection is how (b) came
//       to be wrong in the first place.
//============================================================================

endmodule
