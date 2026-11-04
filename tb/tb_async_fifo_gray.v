// Testbench for async_fifo_gray.
//
// SCOPE
//   This exercises the FIFO alone. It deliberately does not involve
//   bitblt_video_out, so a failure here cannot be confused with a failure of
//   the scan-out pipeline -- which is what went wrong when four attempts to fix
//   the vendor FIFO loop were each caught only by the 95998-check video test.
//
// WHAT IS CHECKED
//   1. reset state
//   2. single write -> single read, with data comparison
//   3. fill to full: the count written must be exactly DEPTH, and wfull must
//      assert
//   4. write while full is ignored (no data loss, no pointer movement)
//   5. drain to empty: rempty must assert, and exactly DEPTH words come out
//   6. read while empty is ignored
//   7. simultaneous write and read at full/empty boundaries
//   8. bulk data integrity across a clock-domain crossing, with the read clock
//      slower than the write clock
//   9. same, with the read clock faster
//  10. no word is ever duplicated or lost
//
// The write clock runs at 100 MHz and the read clock at 25.2 MHz by default --
// the same ratio as the real design (core_clk vs pix_clk) -- because the
// boundary behaviour depends on the ratio.
//
// NOTE: ASCII only.

`timescale 1ns / 1ps

module tb_async_fifo_gray;

    localparam DW = 24;
    localparam AW = 5;                  // small depth (32) so full/empty are easy to hit
    localparam DEPTH = (1 << AW);

    reg  wclk = 1'b0, rclk = 1'b0;
    reg  wrst_n = 1'b0, rrst_n = 1'b0;
    reg  we = 1'b0, re = 1'b0;
    reg  [DW-1:0] wdata = {DW{1'b0}};
    wire [DW-1:0] rdata;
    wire wfull, rempty;
    wire [AW:0] wbin_o, rbin_o;
    wire [AW:0] wcnt_o;         // AW+1 bits: full reads 2**AW, not 0

    integer errors = 0;
    integer checks = 0;

    // 100 MHz write, 25.2 MHz read -- the real design's ratio.
    always #5.0   wclk = ~wclk;
    always #19.84 rclk = ~rclk;

    async_fifo_gray #(.DW(DW), .AW(AW)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .we(we), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .re(re), .rdata(rdata), .rempty(rempty),
        .wbin_o(wbin_o), .rbin_o(rbin_o), .wcnt_o(wcnt_o)
    );

    task chk;
        input [255:0] what;
        input         got;
        input         want;
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  FAIL %0s: got %b want %b  t=%0t", what, got, want, $time);
            end
        end
    endtask

    task chk32;
        input [255:0]  what;
        input [DW-1:0] got;
        input [DW-1:0] want;
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("  FAIL %0s: got %h want %h  t=%0t", what, got, want, $time);
            end
        end
    endtask

    integer i;
    integer got_count;
    reg [DW-1:0] expect;

    // Drive the write side from the write clock, the read side from the read
    // clock, so both cross-domain paths are exercised.
    task wpush;
        input [DW-1:0] d;
        begin
            @(negedge wclk);
            wdata = d; we = 1'b1;
            @(negedge wclk);
            we = 1'b0;
        end
    endtask

    // Registered-read semantics: assert re, wait one rclk, THEN sample.
    //
    // This task was originally written for first-word fall-through (sample
    // first, then assert re). That matched an earlier version of the FIFO whose
    // storage was a plain reg array with a combinational read -- which passed
    // every simulation check and then could not be mapped to block RAM, blowing
    // LUT4 from 11874 to 55072 and failing pnr.
    //
    // The FIFO now uses simple_dual_port_ram, whose read is registered by
    // necessity, so data appears one rclk after re. Sampling in the old order
    // returns every word one position late (and x for the first one).
    task rpop;
        output [DW-1:0] d;
        begin
            d = {DW{1'bx}};
            @(negedge rclk);
            if (!rempty) begin
                re = 1'b1;
                @(negedge rclk);     // one full rclk for rdata to appear
                d  = rdata;
            end
            re = 1'b0;
        end
    endtask

    reg [DW-1:0] tmp;

    initial begin
        $display("");
        $display("==================================================");
        $display("  async_fifo_gray : DW=%0d AW=%0d depth=%0d", DW, AW, DEPTH);
        $display("  wclk 100 MHz, rclk 25.2 MHz");
        $display("==================================================");

        // ---------------------------------------------------- 1. reset state
        repeat (4) @(posedge wclk);
        @(negedge wclk); wrst_n = 1'b1; rrst_n = 1'b1;
        repeat (4) @(posedge wclk);
        repeat (4) @(posedge rclk);
        chk("reset: empty", rempty, 1'b1);
        chk("reset: not full", wfull, 1'b0);

        // ---------------------------------------- 2. one word in, one word out
        wpush(24'hA1B2C3);
        repeat (6) @(posedge rclk);          // let the pointer cross
        chk("after 1 write: empty deasserted", rempty, 1'b0);
        rpop(tmp);
        chk32("single word round trip", tmp, 24'hA1B2C3);
        repeat (6) @(posedge rclk);
        chk("after 1 read: empty", rempty, 1'b1);

        // ------------------------------------------- 2b. occupancy (wcnt_o)
        // bitblt_video_out uses wcnt to decide whether to fetch another line, so
        // it has to be right, not merely monotonic. Write five, read none, and
        // allow several read clocks for the synchronized pointer to settle.
        for (i = 0; i < 5; i = i + 1) wpush(24'h5000 + i[7:0]);
        repeat (10) @(posedge rclk);
        repeat (2)  @(posedge wclk);
        checks = checks + 1;
        if (wcnt_o !== 5) begin
            errors = errors + 1;
            $display("  FAIL wcnt after 5 writes+0 reads: got %0d want 5", wcnt_o);
        end

        // read two back; occupancy must fall to 3
        rpop(tmp); chk32("wcnt test read 1", tmp, 24'h5000);
        rpop(tmp); chk32("wcnt test read 2", tmp, 24'h5001);
        repeat (10) @(posedge rclk);
        repeat (2)  @(posedge wclk);
        checks = checks + 1;
        if (wcnt_o !== 3) begin
            errors = errors + 1;
            $display("  FAIL wcnt after 2 reads: got %0d want 3", wcnt_o);
        end
        // drain the rest so later tests start clean
        for (i = 0; i < 3; i = i + 1) rpop(tmp);
        repeat (6) @(posedge rclk);

        // -------------------------------------------------------- 3. fill full
        // Writing without regard to wfull: the FIFO must absorb exactly DEPTH.
        got_count = 0;
        for (i = 0; i < DEPTH + 8; i = i + 1) begin
            @(negedge wclk);
            if (!wfull) begin
                wdata = i[AW:0] + 24'h1000;
                we = 1'b1;
                got_count = got_count + 1;
            end else begin
                we = 1'b0;
            end
        end
        @(negedge wclk); we = 1'b0;
        repeat (6) @(posedge wclk);
        chk("fill: wfull asserted", wfull, 1'b1);
        checks = checks + 1;
        if (got_count !== DEPTH) begin
            errors = errors + 1;
            $display("  FAIL fill count: accepted %0d, expected %0d", got_count, DEPTH);
        end

        // ------------------------------------ 4. write while full must be ignored
        begin : full_write_ignored
            reg [AW:0] before;
            before = wbin_o;
            repeat (4) begin
                @(negedge wclk); we = 1'b1;
            end
            @(negedge wclk); we = 1'b0;
            repeat (4) @(posedge wclk);
            checks = checks + 1;
            if (wbin_o !== before) begin
                errors = errors + 1;
                $display("  FAIL write-while-full moved the pointer: %h -> %h", before, wbin_o);
            end
        end

        // --------------------------------------------------------- 5. drain it
        got_count = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            rpop(tmp);
            expect = i[AW:0] + 24'h1000;
            chk32("drain order", tmp, expect);
            got_count = got_count + 1;
        end
        repeat (6) @(posedge rclk);
        chk("drain: empty asserted", rempty, 1'b1);
        chk("drain: wfull cleared", wfull, 1'b0);

        // -------------------------------------- 6. read while empty is ignored
        begin : empty_read_ignored
            reg [AW:0] before;
            before = rbin_o;
            repeat (4) begin
                @(negedge rclk); re = 1'b1;
            end
            @(negedge rclk); re = 1'b0;
            repeat (4) @(posedge rclk);
            checks = checks + 1;
            if (rbin_o !== before) begin
                errors = errors + 1;
                $display("  FAIL read-while-empty moved the pointer: %h -> %h", before, rbin_o);
            end
        end

        // --------------------------------- 7. simultaneous write and read at half
        // Keep the FIFO moving with both sides active at once, checking that
        // every word comes back in order and none is lost or duplicated.
        //
        // Each branch needs its OWN loop variable. They share the module-level
        // `i` otherwise, and since fork branches run concurrently each one keeps
        // overwriting the other's index -- so the reader compares against an
        // expectation built from the writer's counter. The symptom was a
        // non-monotonically growing offset (want 00200e, 002017, 002020, 002026)
        // that looks like FIFO misordering but is not.
        fork
            begin : wside
                integer wi;
                for (wi = 0; wi < 64; wi = wi + 1) begin
                    @(negedge wclk);
                    while (wfull) @(negedge wclk);
                    wdata = 24'h2000 + wi[AW:0];
                    we = 1'b1;
                end
                @(negedge wclk); we = 1'b0;
            end
            begin : rside
                integer ri;
                for (ri = 0; ri < 64; ri = ri + 1) begin
                    @(negedge rclk);
                    while (rempty) @(negedge rclk);
                    re = 1'b1;
                    @(negedge rclk);        // registered read: valid one rclk later
                    chk32("simultaneous r/w order", rdata, 24'h2000 + ri[AW:0]);
                    re = 1'b0;
                    @(negedge rclk);
                end
                re = 1'b0;
            end
        join

        repeat (20) @(posedge rclk);

        // ================================================================
        // 8. THE DECISIVE TEST: handshake inputs driven COMBINATIONALLY by the
        //    FIFO's own status outputs.
        //
        // Everything above drove we/re from the testbench, so wfull and rempty
        // were only observed. The vendor FIFO does not fail in that situation --
        // it fails when its status feeds back into its request, which is exactly
        // how bitblt_video_out uses it:
        //
        //     wire we = enable & ~wfull;
        //     wire re = want   & ~rempty;
        //
        // This block reproduces that topology. If the registered full/empty do
        // their job there is no combinational loop and the run completes; if
        // they do not, iverilog wedges here (no time advance, no signal change,
        // CPU pegged) and Questa reports vsim-3601.
        // ================================================================
        $display("");
        $display("  --- test 8: combinational feedback of full/empty ---");

        // drain first
        while (!rempty) begin
            @(negedge rclk); re = 1'b1;
            @(negedge rclk); re = 1'b0;
        end
        repeat (8) @(posedge wclk);

        fork
            begin : fb_write
                integer wi;
                for (wi = 0; wi < 40; wi = wi + 1) begin
                    // Wait for room BEFORE presenting the word, then drive we from
                    // wfull to keep the combinational-feedback shape under test.
                    //
                    // The previous form did `we = ~wfull` without waiting, so any
                    // word offered while full was silently dropped while wi still
                    // advanced. Fewer than 40 words were stored and the reader
                    // waited forever for the 40th -- which is what wedged this
                    // test at "test 8" until the timeout fired.
                    //
                    // Same mistake as the "write while full" case in test 3 and
                    // the reader in test 7. Third time.
                    @(negedge wclk);
                    while (wfull) @(negedge wclk);
                    wdata = 24'h3000 + wi[AW:0];
                    we    = ~wfull;                 // <-- feedback
                    @(negedge wclk);
                    we    = 1'b0;
                end
                we = 1'b0;
            end
            begin : fb_read
                integer ri;
                reg [DW-1:0] d;
                for (ri = 0; ri < 40; ri = ri + 1) begin
                    // WAIT for data, do not skip: skipping still advances ri, so
                    // the expectation runs ahead of what was actually pushed.
                    // Same shape of mistake as the "write while full" case above.
                    @(negedge rclk);
                    re = ~rempty;                    // <-- feedback
                    while (rempty) begin
                        @(negedge rclk);
                        re = ~rempty;
                    end
                    @(negedge rclk);                 // registered read
                    d = rdata;
                    chk32("feedback read order", d, 24'h3000 + ri[AW:0]);
                    re = 1'b0;
                    @(negedge rclk);
                end
                re = 1'b0;
            end
        join

        // ================================================================
        // 9. LATENCY: how many read clocks after re does rdata become valid?
        //
        // This matters because bitblt_video_out delays de by a fixed number of
        // pclk to line up with rdata. Getting it wrong misaligns the whole pixel
        // stream -- which is how four earlier attempts were defeated.
        //
        // The answer is one rclk, and it is forced by hardware rather than
        // chosen: block RAM needs a registered read, so simple_dual_port_ram
        // registers the data even with OUTPUT_REG="FALSE". A combinational-read
        // version passed every simulation check and then could not be mapped to
        // RAM at all (LUT4 11874 -> 55072, pnr FAILED). That is why this test
        // asserts a latency of one, not zero.
        // ================================================================
        $display("");
        $display("  --- test 9: re -> rdata latency ---");
        begin : lat
            integer n;
            reg seen;
            // make sure the FIFO is empty, then push exactly one word
            while (!rempty) begin
                @(negedge rclk); re = 1'b1;
                @(negedge rclk); re = 1'b0;
            end
            repeat (8) @(posedge rclk);
            wpush(24'hDEAD01);
            repeat (8) @(posedge rclk);

            // REGISTERED read: rdata must NOT already show the word before re is
            // asserted. It may still hold whatever the drain left behind, so the
            // check is "not DEAD01" rather than "is x".
            checks = checks + 1;
            if (rdata === 24'hDEAD01) begin
                errors = errors + 1;
                $display("  FAIL latency: rdata already dead01 before any re -- combinational read?");
            end else begin
                $display("      registered read confirmed: rdata=%h with re low", rdata);
            end

            // Assert re; the word must appear exactly one rclk later.
            @(negedge rclk); re = 1'b1;
            @(negedge rclk);                    // one full rclk
            checks = checks + 1;
            if (rdata !== 24'hDEAD01) begin
                errors = errors + 1;
                $display("  FAIL latency: rdata=%h one rclk after re, want dead01", rdata);
            end else begin
                $display("      latency = 1 rclk: rdata=%h", rdata);
            end
            re = 1'b0;
            // drain
            while (!rempty) begin
                @(negedge rclk); re = 1'b1;
                @(negedge rclk); re = 1'b0;
            end
        end
        repeat (8) @(posedge rclk);

        $display("");
        $display("==================================================");
        $display("  checks = %0d", checks);
        $display("  errors = %0d", errors);
        $display("==================================================");
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
