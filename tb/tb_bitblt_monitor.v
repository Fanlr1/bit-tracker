//============================================================================
// tb_bitblt_monitor -- the on-chip assertion monitor
//============================================================================
// WHAT IS BEING TESTED
//   Ten conditions, each with a sticky bit and a saturating counter. The point
//   of this testbench is not that the counters count; it is that each condition
//   can be told apart from its absence. Every assertion below therefore has a
//   NEGATIVE half: the sticky bit must be CLEAR before the stimulus, and SET
//   after it. A test that only checked "it goes high" would pass on a bit
//   hardwired to 1, which is exactly the failure mode that made the scan-status
//   assertions need both states earlier in this project.
//
// TWO FINDINGS, AND THE SECOND IS WHY THIS TESTBENCH EXISTS
//
// 1. THE NEGATIVE ASSERTIONS CAUGHT A REAL DESIGN BUG.
//    The first version registered resp_err and pos_drop and only ever SET them,
//    so once a fault had occurred the intermediate signal stayed high forever.
//    The event detector downstream is (source & ~sticky[bit]), so clearing the
//    sticky bit made the event fire again on the very next cycle -- the bit
//    could never be cleared. On hardware that reads as "this error is still
//    happening" when it happened once, which sends diagnosis the wrong way.
//
//    Caught by:
//      FAIL an OKAY response does not set sticky[7]
//      FAIL a forwarded request does not set sticky[9]
//    Both fixed by making those two signals combinational one-cycle events.
//    A testbench that only checked "it goes high on a fault" would have passed.
//
// 2. FAULT INJECTION (sticky[0] forced to 1'b1 in bitblt_monitor.v, then
//    reverted):
//      FAIL sticky is clear before any stimulus
//      FAIL healthy handshakes do not set the sticky bit
//      FAIL repeated short waits do not accumulate into a timeout
//      FAIL the counter for that condition is 1
//      FAIL clr_mask bit 0 clears sticky[0]
//      FAIL a second wedge raises the count to 2
//      RESULT: FAILED with 6 error(s)
//    The first three are NEGATIVE assertions, and that is the point: a monitor
//    that reports everything as broken is exactly as useless as one that
//    reports nothing.
//
// WHAT IS NOT COVERED, STATED PLAINLY
//   The walker-hang limit is 200 million cycles (about 2 seconds) and the
//   counters saturate at 2^32. Neither can be reached in a simulation of this
//   size, so only their NEGATIVE direction is asserted here: a normal walk must
//   not trip the hang bit, and clr_count must genuinely zero a counter. The
//   positive directions rest on the limits being compile-time constants
//   compared against counters -- which is structurally simple, but has not been
//   observed end to end.
//============================================================================

`timescale 1ns / 1ps

module tb_bitblt_monitor;

    // Small timeout so the test finishes quickly. The real default is 65535;
    // nothing in the logic depends on the value except how long it waits.
    localparam TIMEOUT = 16'd4;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg rd0_arvalid = 0, rd0_arready = 1, rd0_rvalid = 0, rd0_rready = 1;
    reg [1:0] rd0_rresp = 2'b00;
    reg rd1_arvalid = 0, rd1_arready = 1, rd1_rvalid = 0, rd1_rready = 1;
    reg [1:0] rd1_rresp = 2'b00;
    reg wr_awvalid = 0, wr_awready = 1, wr_wvalid = 0, wr_wready = 1;
    reg wr_bvalid = 0, wr_bready = 1;
    reg [1:0] wr_bresp = 2'b00;
    reg spr_busy = 0;
    // A NEW INPUT LEFT UNCONNECTED IS Z, WHICH BECOMES X, WHICH PROPAGATES.
    // This was not connected when it was added and the first two assertions
    // failed with sticky[10] unknown -- because a floating input in simulation
    // is not zero, while in synthesis it is. The two would have disagreed, and
    // the simulation side would have been the wrong one.
    reg scan_short = 0;
    reg pos_req = 0, pos_req_gated = 0;

    reg [15:0] clr_mask = 0;
    reg        clr_count = 0;
    reg [3:0]  cnt_sel = 0;

    wire [15:0] sticky;
    wire [31:0] cnt;

    bitblt_monitor #(.TIMEOUT(TIMEOUT)) dut (
        .clk(clk), .rst_n(rst_n),
        .rd0_arvalid(rd0_arvalid), .rd0_arready(rd0_arready),
        .rd0_rvalid(rd0_rvalid),   .rd0_rready(rd0_rready), .rd0_rresp(rd0_rresp),
        .rd1_arvalid(rd1_arvalid), .rd1_arready(rd1_arready),
        .rd1_rvalid(rd1_rvalid),   .rd1_rready(rd1_rready), .rd1_rresp(rd1_rresp),
        .wr_awvalid(wr_awvalid),   .wr_awready(wr_awready),
        .wr_wvalid(wr_wvalid),     .wr_wready(wr_wready),
        .wr_bvalid(wr_bvalid),     .wr_bready(wr_bready),   .wr_bresp(wr_bresp),
        .scan_short(scan_short),
        .spr_busy(spr_busy),
        .pos_req(pos_req), .pos_req_gated(pos_req_gated),
        .clr_mask(clr_mask), .clr_count(clr_count),
        .sticky_word(sticky), .cnt_sel(cnt_sel), .cnt_word(cnt)
    );

    integer errors = 0;
    integer i;

    task check;
        input [255:0] what;
        input         ok;
        begin
            if (ok) $display("  PASS %0s", what);
            else begin $display("  FAIL %0s", what); errors = errors + 1; end
        end
    endtask

    // Hold a valid high with ready low for N cycles, then release.
    task wedge;
        output done;
        begin
            repeat (TIMEOUT + 3) @(posedge clk);
            done = 1'b1;
        end
    endtask

    initial begin
        $display("==================================================");
        $display("  tb_bitblt_monitor -- on-chip assertions");
        $display("--------------------------------------------------");

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---- 1. NEGATIVE: nothing has happened yet ----------------------
        check("sticky is clear before any stimulus", sticky === 16'd0);
        cnt_sel = 4'd0; #1;
        check("counter 0 starts at zero", cnt === 32'd0);

        // ---- 2. a normal handshake must NOT fire -------------------------
        // This is the half that a "goes high" test would miss: an observer that
        // flags healthy traffic is worse than none, because its output gets
        // ignored.
        for (i = 0; i < 20; i = i + 1) begin
            @(negedge clk); rd0_arvalid = 1;
            @(negedge clk); rd0_arready = 1;
            @(negedge clk); rd0_arvalid = 0;
        end
        check("healthy handshakes do not set the sticky bit", sticky[0] === 1'b0);

        // ---- 3. SHORT waits must not accumulate --------------------------
        // The counter resets when the handshake completes, so a long run of
        // short waits is not a timeout. Without that reset this would fire.
        for (i = 0; i < 30; i = i + 1) begin
            @(negedge clk); rd0_arvalid = 1; rd0_arready = 0;
            @(negedge clk); rd0_arvalid = 1; rd0_arready = 0;   // 2 cycles < TIMEOUT
            @(negedge clk); rd0_arready = 1;
            @(negedge clk); rd0_arvalid = 0;
        end
        check("repeated short waits do not accumulate into a timeout",
              sticky[0] === 1'b0);

        // ---- 4. POSITIVE: a real wedge sets bit 0 and counts ------------
        @(negedge clk); rd0_arvalid = 1; rd0_arready = 0;
        repeat (TIMEOUT + 4) @(posedge clk);
        #1;
        check("a wedged AR handshake sets sticky[0]", sticky[0] === 1'b1);
        cnt_sel = 4'd0; #1;
        check("and the counter for that condition is 1", cnt === 32'd1);

        // ---- 5. the sticky bit stays set after the handshake completes ---
        // A transient that has already passed is still evidence. If the bit
        // cleared itself, a fault that happens once per boot would be invisible
        // by the time software looks.
        @(negedge clk); rd0_arready = 1;
        @(negedge clk); rd0_arvalid = 0;
        repeat (4) @(posedge clk);
        check("sticky[0] survives the handshake completing", sticky[0] === 1'b1);

        // ---- 6. write-1-to-clear ----------------------------------------
        @(negedge clk); clr_mask = 16'h0001;
        @(negedge clk); clr_mask = 16'd0;
        repeat (2) @(posedge clk); #1;
        check("clr_mask bit 0 clears sticky[0]", sticky[0] === 1'b0);
        check("clearing bit 0 leaves the others alone", sticky[15:1] === 15'd0);

        // ---- 7. a second event increments rather than re-latching --------
        // With the bit already cleared, the same fault again must raise the
        // count to 2. If the count were tied to the sticky bit it would stay 1.
        @(negedge clk); rd0_arvalid = 1; rd0_arready = 0;
        repeat (TIMEOUT + 4) @(posedge clk); #1;
        cnt_sel = 4'd0; #1;
        check("a second wedge raises the count to 2", cnt === 32'd2);

        @(negedge clk); rd0_arready = 1; rd0_arvalid = 0;
        @(negedge clk); clr_mask = 16'h0001;
        @(negedge clk); clr_mask = 16'd0;

        // ---- 8. every other channel also fires ---------------------------
        // One channel is tested in detail above; the rest must at least be
        // shown to work, or a copy-paste error in one of the seven would go
        // unnoticed.
        //
        // 2026-10-07: this section only covered rd1 AR and wr W, which left
        // four of the eleven conditions asserted nowhere at all -- rd0 R,
        // rd1 R, wr AW and wr B. A monitor is only worth having if each of its
        // bits is known to fire; an untested bit is indistinguishable from a
        // bit that was never connected. All four are now driven.
        @(negedge clk); rd0_rvalid = 1; rd0_rready = 0;
        repeat (TIMEOUT + 4) @(posedge clk); #1;
        check("rd0 R wedge sets sticky[1]", sticky[1] === 1'b1);
        @(negedge clk); rd0_rready = 1; rd0_rvalid = 0;

        @(negedge clk); rd1_arvalid = 1; rd1_arready = 0;
        repeat (TIMEOUT + 4) @(posedge clk); #1;
        check("rd1 AR wedge sets sticky[2]", sticky[2] === 1'b1);
        @(negedge clk); rd1_arready = 1; rd1_arvalid = 0;

        @(negedge clk); rd1_rvalid = 1; rd1_rready = 0;
        repeat (TIMEOUT + 4) @(posedge clk); #1;
        check("rd1 R wedge sets sticky[3]", sticky[3] === 1'b1);
        @(negedge clk); rd1_rready = 1; rd1_rvalid = 0;

        @(negedge clk); wr_awvalid = 1; wr_awready = 0;
        repeat (TIMEOUT + 4) @(posedge clk); #1;
        check("wr AW wedge sets sticky[4]", sticky[4] === 1'b1);
        @(negedge clk); wr_awready = 1; wr_awvalid = 0;

        @(negedge clk); wr_wvalid = 1; wr_wready = 0;
        repeat (TIMEOUT + 4) @(posedge clk); #1;
        check("wr W wedge sets sticky[5]", sticky[5] === 1'b1);
        @(negedge clk); wr_wready = 1; wr_wvalid = 0;

        @(negedge clk); wr_bvalid = 1; wr_bready = 0;
        repeat (TIMEOUT + 4) @(posedge clk); #1;
        check("wr B wedge sets sticky[6]", sticky[6] === 1'b1);
        @(negedge clk); wr_bready = 1; wr_bvalid = 0;

        // (the "all eleven" summary moved to section 14, at the end -- it was
        //  here first and failed, because bits 7..10 have not fired yet)

        // ---- 9. a non-OKAY response -------------------------------
        @(negedge clk); rd0_rvalid = 1; rd0_rresp = 2'b10;   // SLVERR
        @(negedge clk); rd0_rvalid = 0; rd0_rresp = 2'b00;
        repeat (2) @(posedge clk); #1;
        check("a SLVERR sets sticky[7]", sticky[7] === 1'b1);

        // and an OKAY response must not
        @(negedge clk); clr_mask = 16'h0080;
        @(negedge clk); clr_mask = 16'd0;
        repeat (2) @(posedge clk);
        @(negedge clk); rd0_rvalid = 1; rd0_rresp = 2'b00;
        @(negedge clk); rd0_rvalid = 0;
        repeat (2) @(posedge clk); #1;
        check("an OKAY response does not set sticky[7]", sticky[7] === 1'b0);

        // ---- 10. walker hang --------------------------------------------
        @(negedge clk); spr_busy = 1;
        repeat (6) @(posedge clk); #1;
        check("a short walk does NOT set the hang bit (needs 200M cycles)",
              sticky[8] === 1'b0);
        @(negedge clk); spr_busy = 0;
        // The 2-second limit cannot be reached in a simulation of this size, so
        // what is asserted here is only the negative direction: a normal walk
        // must not trip it. The positive direction is covered by the fact that
        // the limit is a compile-time constant compared against a counter --
        // stated plainly rather than pretended.

        // ---- 11. discarded read-back request ---------------------------
        @(negedge clk); pos_req = 1; pos_req_gated = 0;   // gate swallowed it
        @(negedge clk); pos_req = 0;
        repeat (2) @(posedge clk); #1;
        check("a discarded read-back request sets sticky[9]", sticky[9] === 1'b1);

        @(negedge clk); clr_mask = 16'h0200;
        @(negedge clk); clr_mask = 16'd0;
        repeat (2) @(posedge clk);
        @(negedge clk); pos_req = 1; pos_req_gated = 1;   // forwarded normally
        @(negedge clk); pos_req = 0;
        repeat (2) @(posedge clk); #1;
        check("a forwarded request does not set sticky[9]", sticky[9] === 1'b0);

        // ---- 12. counters saturate ---------------------------------------
        // Cannot be driven to 2^32 here either; what is checked is that a
        // cleared counter restarts from zero rather than latching.
        @(negedge clk); clr_count = 1;
        @(negedge clk); clr_count = 0;
        repeat (2) @(posedge clk);
        cnt_sel = 4'd0; #1;
        check("clr_count zeroes the counters", cnt === 32'd0);

        // ---- 13. scan-out starvation (bit 10) ---------------------------
        // Both directions again, for the same reason as everywhere else: a bit
        // that is stuck high and a bit that works are indistinguishable from
        // one assertion.
        scan_short = 1'b0;
        repeat (2) @(posedge clk); #1;
        check("starvation bit clear when scan-out is fed", sticky[10] === 1'b0);

        @(negedge clk); scan_short = 1'b1;
        repeat (2) @(posedge clk); #1;
        check("starvation sets sticky[10]", sticky[10] === 1'b1);

        @(negedge clk); clr_mask = 16'h0400;      // 1 << 10
        @(negedge clk); clr_mask = 16'd0;
        repeat (2) @(posedge clk); #1;
        check("sticky[10] can be cleared", sticky[10] === 1'b0);
        // The upstream sticky bit stays high once set, so the edge detector
        // inside the monitor must not re-fire just because the bit is still
        // asserted -- otherwise this would be the un-clearable bug again.
        repeat (4) @(posedge clk); #1;
        check("sticky[10] does NOT re-latch while the source stays high",
              sticky[10] === 1'b0);

        // and after the source drops and returns, it fires once more
        @(negedge clk); scan_short = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk); scan_short = 1'b1;
        repeat (2) @(posedge clk); #1;
        check("starvation re-latches after the source cycles", sticky[10] === 1'b1);

        // ---- 14. coverage note -------------------------------------------
        // Bits 0..7, 9 and 10 each have their own assertion above, and each of
        // those names ONE bit and ONE specific handshake -- so a bit wired to
        // the wrong detector fails its own check rather than hiding behind a
        // summary.
        //
        // BIT 8 IS NOT DRIVEN, and cannot be. It needs 200 million cycles of
        // continuous spr_busy, i.e. two seconds at 100 MHz; this simulation
        // reaches about 3.1 ms. Section 10 asserts its negative direction only.
        //
        // A SUMMARY ASSERTION HERE WAS TRIED AND REMOVED. Two versions failed:
        //   * "all eleven set" -- bits 7..10 were not driven yet at that point
        //   * "every reachable bit set" -- still wrong, because the clr_mask and
        //     OKAY-response tests earlier deliberately CLEAR bits 0 and 7, so
        //     by the end they are legitimately zero. Checking the final value
        //     cannot answer "was each bit ever driven".
        // Per-bit assertions already answer that, which is the reason they are
        // written per-bit. Recorded so it is not attempted a third time.

        $display("--------------------------------------------------");
        if (errors == 0) $display("RESULT: PASS (on-chip assertion monitor)");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $display("==================================================");
        $finish;
    end

    initial begin
        #600000;
        $display("FAIL: testbench timed out");
        $display("RESULT: FAILED (timeout)");
        $finish;
    end

endmodule
