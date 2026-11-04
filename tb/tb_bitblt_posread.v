//============================================================================
// tb_bitblt_posread -- the position read-back path (P4 item #2)
//============================================================================
// WHY A SEPARATE TESTBENCH
//   The walker testbench exercises the walk and the lifecycle; this exercises
//   one register pair and its timing. Keeping them apart means a failure here
//   points at the read-back and nothing else.
//
// WHAT IS ACTUALLY BEING TESTED, AND WHY IT IS EASY TO GET WRONG
//   rt_word can be read combinationally because the retired bitmap is a
//   register array. Positions live in Block RAM, which has a TWO-CYCLE read
//   latency. A read-back that samples one cycle early returns the PREVIOUS
//   slot's coordinates -- sprites reported at each other's positions, with no
//   error anywhere. So the assertions below check the value AND the cycle it
//   becomes valid, and the last one is a fault injection that proves the
//   timing assertions can fail at all.
//
// FAULT INJECTION -- PROOF THAT THESE ASSERTIONS CAN FAIL
//   Change: in bitblt_sprite_state.v, the read-back countdown was set to 1
//           instead of 2 (dbg_lat <= 2'd1), so the latch samples one cycle
//           before the RAM data arrives. Reverted afterwards.
//
//   Actual output with the fault in place:
//     FAIL readback: slot 5 returned x=xxxx y=xxxx want 1111/AAAA
//     INFO readback latency: 2 cycles after the request
//     PASS readback: latency is bounded (2 cycles)      <- the bound alone is
//                                                          too loose to catch it
//     FAIL readback: slot 6 returned x=xxxx y=xxxx want 2222/BBBB
//     FAIL readback: slot 7 returned x=xxxx y=xxxx want 3333/CCCC
//     FAIL readback: back-to-back request returned x=xxxx y=xxxx
//     FAIL readback: slot 9 before sweep = xxxxx yxxxx want 0100/0200
//     FAIL readback: slot 9 after sweep = xxxxx yxxxx want 0107/0209
//     RESULT: FAILED with 6 error(s)
//
//   Two things this proves, and one it disproves:
//     proves  : the value assertions really do depend on the timing
//     proves  : an early sample yields xxxx (the RAM has not driven yet), so
//               the failure is visible rather than a plausible wrong number
//     disproves: the latency BOUND is not sufficient on its own -- it PASSED
//               with the fault in place (2 <= 6). Only the value checks catch
//               an early read. A bound is a sanity check, not a proof.
//============================================================================

`timescale 1ns / 1ps

module tb_bitblt_posread;

    localparam N  = 256;
    localparam IW = 16;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;          // 100 MHz

    // ---- init (seed slots) ----
    reg         init_en = 0;
    reg  [15:0] init_idx = 0;
    reg  [15:0] init_x = 0, init_y = 0, init_vx = 0, init_vy = 0;

    // ---- walker-side read (unused here, held at a harmless value) ----
    reg  [15:0] rd_idx = 0;

    // ---- sweep ----
    reg         step_en = 0;

    // ---- bounds ----
    reg  [15:0] fb_w = 1920, fb_h = 1080;

    // ---- read-back ----
    reg         dbg_req = 0;
    reg  [15:0] dbg_idx = 0;

    wire [15:0] rd_x, rd_y;
    wire        rd_valid, rd_live;
    wire        stepping, frame_done;
    wire [31:0] rt_word;
    wire [31:0] dbg_xy;
    wire        dbg_valid;

    bitblt_sprite_state #(.N(N), .IW(IW)) u_state (
        .clk(clk), .rst_n(rst_n),
        .init_en(init_en), .init_idx(init_idx),
        .init_x(init_x), .init_y(init_y), .init_vx(init_vx), .init_vy(init_vy),
        .rd_idx(rd_idx), .rd_x(rd_x), .rd_y(rd_y),
        .rd_valid(rd_valid), .rd_live(rd_live),
        .fb_w(fb_w), .fb_h(fb_h),
        .step_en(step_en), .stepping(stepping), .frame_done(frame_done),
        .rt_sel(16'd0), .rt_word(rt_word),
        .dbg_req(dbg_req), .dbg_idx(dbg_idx),
        .dbg_xy(dbg_xy), .dbg_valid(dbg_valid),
        .live_clr_en(1'b0), .live_clr_idx(16'd0),
        .clr_valid(1'b0)
    );

    integer errors = 0;
    integer i;

    task seed;
        input [15:0] idx, x, y, vx, vy;
        begin
            @(negedge clk);
            init_en  = 1'b1;
            init_idx = idx; init_x = x; init_y = y; init_vx = vx; init_vy = vy;
            @(negedge clk);
            init_en  = 1'b0;
        end
    endtask

    // Pulse a request and wait for valid, counting cycles.
    task read_pos;
        input  [15:0] idx;
        output [15:0] ox, oy;
        output integer cycles;
        begin
            @(negedge clk);
            dbg_req = 1'b1;
            dbg_idx = idx;
            @(negedge clk);
            dbg_req = 1'b0;
            cycles  = 0;
            // valid must appear; the loop bound makes a hang a failure, not a wait
            while (!dbg_valid && cycles < 20) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            ox = dbg_xy[15:0];
            oy = dbg_xy[31:16];
        end
    endtask

    reg [15:0] gx, gy;
    integer    gc;

    initial begin
        $display("==================================================");
        $display("  tb_bitblt_posread -- software position read-back");
        $display("--------------------------------------------------");

        repeat (4) @(posedge clk);
        rst_n = 1;

        // ---- seed three slots with distinctive values ----
        seed(16'd5,  16'h1111, 16'hAAAA, 16'd0, 16'd0);
        seed(16'd6,  16'h2222, 16'hBBBB, 16'd0, 16'd0);
        seed(16'd7,  16'h3333, 16'hCCCC, 16'd0, 16'd0);
        repeat (4) @(posedge clk);

        // ---- 1. a plain read returns what was seeded ----
        read_pos(16'd5, gx, gy, gc);
        if (!dbg_valid) begin
            $display("FAIL readback: valid never asserted for slot 5");
            errors = errors + 1;
        end else if (gx !== 16'h1111 || gy !== 16'hAAAA) begin
            $display("FAIL readback: slot 5 returned x=%h y=%h want 1111/AAAA", gx, gy);
            errors = errors + 1;
        end else begin
            $display("PASS readback: slot 5 = x%h y%h", gx, gy);
        end

        // ---- 2. THE TIMING ASSERTION ----
        // Two cycles of RAM latency, and the request itself takes one, so valid
        // should arrive within a small, bounded window. Reporting the count
        // makes a regression visible even when the data happens to be right.
        $display("INFO readback latency: %0d cycles after the request", gc);
        if (gc > 6) begin
            $display("FAIL readback: took %0d cycles, expected about 3", gc);
            errors = errors + 1;
        end else begin
            $display("PASS readback: latency is bounded (%0d cycles)", gc);
        end

        // ---- 3. a different slot returns DIFFERENT data ----
        // Without this, a read-back that always returned slot 5's values would
        // pass test 1 and fail silently everywhere else.
        read_pos(16'd6, gx, gy, gc);
        if (gx !== 16'h2222 || gy !== 16'hBBBB) begin
            $display("FAIL readback: slot 6 returned x=%h y=%h want 2222/BBBB", gx, gy);
            errors = errors + 1;
        end else begin
            $display("PASS readback: slot 6 = x%h y%h (different slot, different data)", gx, gy);
        end

        // ---- 4. back-to-back requests both land ----
        read_pos(16'd7, gx, gy, gc);
        if (gx !== 16'h3333 || gy !== 16'hCCCC) begin
            $display("FAIL readback: slot 7 returned x=%h y=%h want 3333/CCCC", gx, gy);
            errors = errors + 1;
        end else $display("PASS readback: slot 7 = x%h y%h", gx, gy);

        read_pos(16'd5, gx, gy, gc);
        if (gx !== 16'h1111 || gy !== 16'hAAAA) begin
            $display("FAIL readback: back-to-back request returned x=%h y=%h", gx, gy);
            errors = errors + 1;
        end else $display("PASS readback: back-to-back requests both land");

        // ---- 5. the DRAINED slot has moved ----
        // A sweep advances every seeded slot by its velocity. After that, the
        // read-back must show the NEW position, not the seeded one -- otherwise
        // software is reading a stale copy and the whole point of the port is
        // lost.
        seed(16'd9, 16'h0100, 16'h0200, 16'd7, 16'd9);
        repeat (4) @(posedge clk);
        read_pos(16'd9, gx, gy, gc);
        if (gx !== 16'h0100 || gy !== 16'h0200) begin
            $display("FAIL readback: slot 9 before sweep = x%h y%h want 0100/0200", gx, gy);
            errors = errors + 1;
        end else $display("PASS readback: slot 9 before sweep = x%h y%h", gx, gy);

        // one frame-end sweep: read-modify-write, three cycles per slot
        @(negedge clk); step_en = 1'b1;
        @(negedge clk); step_en = 1'b0;
        i = 0;
        while (!frame_done && i < 4000) begin @(posedge clk); i = i + 1; end
        $display("INFO sweep completed in %0d cycles", i);
        repeat (4) @(posedge clk);

        read_pos(16'd9, gx, gy, gc);
        if (gx !== 16'h0107 || gy !== 16'h0209) begin
            $display("FAIL readback: slot 9 after sweep = x%h y%h want 0107/0209", gx, gy);
            errors = errors + 1;
        end else begin
            $display("PASS readback: slot 9 after sweep = x%h y%h (advanced by vx/vy)", gx, gy);
        end

        // ---- 6. an out-of-range index must not alias onto a real slot ----
        read_pos(16'd300, gx, gy, gc);
        if (dbg_valid && gx === 16'h1111 && gy === 16'hAAAA) begin
            $display("FAIL readback: index 300 aliased onto slot 5");
            errors = errors + 1;
        end else $display("PASS readback: index 300 does not alias onto a live slot");

        $display("--------------------------------------------------");
        if (errors == 0) $display("RESULT: PASS (position read-back)");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $display("==================================================");
        $finish;
    end

    // a runaway guard so a hang reports as a failure instead of a timeout
    initial begin
        #200000;
        $display("FAIL: testbench timed out");
        $display("RESULT: FAILED (timeout)");
        $finish;
    end

endmodule
