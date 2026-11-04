// Testbench for bitblt_fwft_fifo -- the synchronous-read FIFO that will replace
// the combinationally read array inside the DMA read engines.
//
// WHY IT IS A SEPARATE TESTBENCH (docs/66 section 7)
//   The FIFO sits directly on the consumer handshake, and that handshake is the
//   site of the 2026-10-13 system deadlock (docs/61/63). Replacing the array is
//   therefore not a local edit: get the read-ahead wrong and it either halving
//   throughput or drops/duplicates a word, and neither shows up as a syntax
//   error. So the contract is pinned down here first, on the bare module, with
//   no AXI and no pixel engine in the way.
//
// CONTRACT UNDER TEST
//   1. throughput    : with data available and the consumer always ready, one
//                      word per clock leaves, indefinitely.
//   2. no loss       : every word written comes out exactly once, in order.
//   3. no duplication: never twice.
//   4. full boundary : full accounts for the word held in the output register,
//                      so writing DEPTH words then one more cannot overflow and
//                      cannot corrupt an unconsumed word.
//   5. empty boundary: dout_valid is low when empty, and a pop while empty does
//                      not move anything or invent data.
//   6. back-pressure : holding dout_ready low preserves the word (no silent
//                      overwrite by the read-ahead).
//
// ASCII only.
`timescale 1ns / 1ps

module tb_bitblt_fwft_fifo;

    localparam DW    = 128;
    localparam AW    = 5;
    localparam DEPTH = 1 << AW;

    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    reg              rst_n = 1'b0;
    reg              wr_en = 1'b0;
    reg  [DW-1:0]    din = {DW{1'b0}};
    wire             full;
    wire [AW:0]      used;
    wire             empty;
    wire [DW-1:0]    dout;
    wire             dout_valid;
    reg              dout_ready = 1'b0;

    integer errors = 0;
    integer i;
    reg [DW-1:0] expect_val;
    // Diagnostic: count how many writes the DUT actually ACCEPTED, so a
    // testbench that assumes "wr_en && !full means it went in" can be checked
    // against the DUT's own view.
    integer wr_acc = 0;
    always @(posedge clk) if (rst_n && wr_en && !full) wr_acc = wr_acc + 1;

    bitblt_fwft_fifo #(.DW(DW), .AW(AW)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (wr_en),
        .din        (din),
        .full       (full),
        .used       (used),
        .empty      (empty),
        .dout       (dout),
        .dout_valid (dout_valid),
        .dout_ready (dout_ready)
    );

    task fail(input [8*64-1:0] msg);
        begin
            errors = errors + 1;
            $display("  FAIL: %0s  (t=%0t)", msg, $time);
        end
    endtask

    // Wait up to n cycles for dout_valid to rise. Returns the number of cycles.
    task wait_valid(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                if (dout_valid) k = n;
                else @(negedge clk);
            end
        end
    endtask

    // Drain anything left over before the next test starts.
    // WHY: the tests share one DUT instance, and a word still sitting in the
    // output register at the end of one test is handed to the NEXT test as its
    // first read -- which showed up as a whole-sequence mismatch in test_stress
    // with "dut: wr_ptr=38 rd_ptr=38 out_valid=1". Isolating the tests is the
    // fix; the DUT was behaving correctly.
    task flush;
        integer g;
        begin
            g = 0;
            dout_ready = 1'b1;
            while (!empty && g < 400) begin
                @(negedge clk);
                g = g + 1;
            end
            dout_ready = 1'b0;
            @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Test 1: one word in, one word out, no self-inflicted delay
    // ------------------------------------------------------------------
    task test_single;
        begin
            $display("test_single");
            @(negedge clk); wr_en = 1'b1; din = 128'hDEADBEEF;
            @(negedge clk); wr_en = 1'b0;
            wait_valid(4);
            if (!dout_valid)      fail("test_single: word never appeared");
            else if (dout !== 128'hDEADBEEF) fail("test_single: wrong value");
            // pop it
            @(negedge clk); dout_ready = 1'b1;
            @(negedge clk); dout_ready = 1'b0;
            @(negedge clk);
            if (dout_valid) fail("test_single: still valid after pop");
        end
    endtask

    // ------------------------------------------------------------------
    // Test 2: fill, check full (including the word in the output register),
    //         then stream DEPTH words out and measure the throughput.
    // ------------------------------------------------------------------
    task test_fill_and_throughput;
        integer consumed;
        integer start_cycle;
        begin
            $display("test_fill_and_throughput");
            flush;
            // Fill without any consumer activity.
            // The usable capacity is DEPTH + 1 words -- the array PLUS the word
            // the FWFT output register holds -- so this does not assume a count.
            // It writes until the DUT says full and then drains exactly as many
            // as the DUT accepted.
            wr_acc = 0;
            // din = i (NOT i[DW-1:0]): slicing a 32-bit integer with a 128-bit
            // range reads out of bounds and yields X in the upper 96 bits, which
            // then travels through the FIFO and looks like a DUT failure.
            for (i = 0; i < DEPTH + 8; i = i + 1) begin
                @(negedge clk);
                wr_en = 1'b1;
                din   = i;
            end
            @(negedge clk); wr_en = 1'b0;
            @(negedge clk);

            if (!full) fail("test_fill: full not asserted after DEPTH+4 writes");
            if (used !== DEPTH[AW:0]) begin
                fail("test_fill: used != DEPTH when full");
                $display("    used=%0d want %0d", used, DEPTH);
            end
            if (empty) fail("test_fill: empty asserted while full");

            // Now consume everything as fast as the FIFO can go.
            // ORDER MATTERS: check dout first, THEN assert ready for the word
            // just checked. Asserting ready before looking samples the NEXT word
            // and reports a one-cycle error that is not in the DUT.
            consumed    = 0;
            start_cycle = 0;
            dout_ready  = 1'b0;
            expect_val  = {DW{1'b0}};
            while (consumed < wr_acc && start_cycle < 4*DEPTH + 16) begin
                @(negedge clk);
                if (dout_valid) begin
                    if (dout !== expect_val) begin
                        fail("test_fill: value out of order / truncated");
                        $display("    got %h want %h at index %0d", dout, expect_val, consumed);
                    end
                    consumed   = consumed + 1;
                    expect_val = expect_val + 1'b1;
                    dout_ready = 1'b1;
                end else begin
                    dout_ready = 1'b0;
                end
                start_cycle = start_cycle + 1;
            end
            @(negedge clk); dout_ready = 1'b0;
            if (consumed < wr_acc) begin
                fail("test_fill: drain never finished");
                $display("    drained %0d of %0d", consumed, wr_acc);
            end
            $display("    drained %0d words in %0d cycles (ideal %0d)", consumed, start_cycle, wr_acc);
            if (consumed != wr_acc) fail("test_fill: wrong number of words drained");
            // one word per cycle: allow the extra cycle for the last pop
            if (start_cycle > wr_acc + 2)
                fail("test_fill: throughput worse than one word per cycle");

            if (full) fail("test_fill: full still asserted when empty");
            if (!empty) fail("test_fill: empty not asserted after draining everything");
            if (used !== {(AW+1){1'b0}}) fail("test_fill: used nonzero when empty");
        end
    endtask

    // ------------------------------------------------------------------
    // Test 3: empty boundary
    // ------------------------------------------------------------------
    task test_empty;
        begin
            $display("test_empty");
            flush;
            if (dout_valid) fail("test_empty: valid while empty");
            @(negedge clk); dout_ready = 1'b1;   // pop while empty
            @(negedge clk); dout_ready = 1'b0;
            @(negedge clk);
            if (dout_valid) fail("test_empty: pop while empty invented data");
        end
    endtask

    // ------------------------------------------------------------------
    // Test 4: back-pressure -- hold the consumer off and make sure the word
    //         in the output register is not overwritten by the read-ahead.
    // ------------------------------------------------------------------
    task test_backpressure;
        integer k;
        begin
            $display("test_backpressure");
            flush;
            // put four words in
            for (k = 0; k < 4; k = k + 1) begin
                @(negedge clk); wr_en = 1'b1; din = 128'h1000 + k;
            end
            @(negedge clk); wr_en = 1'b0;
            wait_valid(4);
            if (dout !== 128'h1000) fail("test_backpressure: first word wrong");
            // stall the consumer for a while; dout must not change
            for (k = 0; k < 8; k = k + 1) begin
                @(negedge clk);
                if (!dout_valid) fail("test_backpressure: valid dropped while stalled");
                else if (dout !== 128'h1000) fail("test_backpressure: word overwritten while stalled");
            end
            // now drain and check the rest -- check first, then consume
            for (k = 0; k < 4; k = k + 1) begin
                @(negedge clk);
                if (!dout_valid) begin
                    fail("test_backpressure: lost a word during drain");
                end else if (dout !== (128'h1000 + k)) begin
                    fail("test_backpressure: order/duplication error during drain");
                    $display("    k=%0d got %h want %h", k, dout, 128'h1000 + k);
                end
                dout_ready = 1'b1;
            end
            @(negedge clk); dout_ready = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Test 5: interleaved write/read stress -- 400 words through a 32-deep
    //         FIFO with the consumer pausing pseudo-randomly.
    // ------------------------------------------------------------------
    task test_stress;
        integer w, r, guard;
        reg [31:0] lfsr;
        reg [DW-1:0] wv, rv;
        begin
            $display("test_stress");
            flush;
            w = 0; r = 0; lfsr = 32'hACE1_2345;
            wv = {DW{1'b0}}; rv = {DW{1'b0}};
            wr_acc = 0;
            guard = 0;
            while (r < 400 && guard < 20000) begin
                guard = guard + 1;
                lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                @(negedge clk);
                // write when the FIFO says there is room
                if ((w < 400) && !full && lfsr[0]) begin
                    wr_en = 1'b1; din = wv; w = w + 1; wv = wv + 1'b1;
                end else begin
                    wr_en = 1'b0;
                end
                // consume with a pseudo-random ready. ready is sampled at the
                // NEXT posedge, so checking dout here is checking the word that
                // is about to be consumed -- correct.
                dout_ready = lfsr[3];
                if (dout_valid && dout_ready) begin
                    if (dout !== rv) begin
                        fail("test_stress: value mismatch");
                        $display("    got %h want %h", dout, rv);
                        $display("    tb: w=%0d r=%0d wr_acc=%0d | dut: used=%0d full=%b empty=%b",
                                 w, r, wr_acc, used, full, empty);
                        $display("    dut: wr_ptr=%0d rd_ptr=%0d out_valid=%b dout_valid=%b ready=%b",
                                 dut.wr_ptr, dut.rd_ptr, dut.out_valid, dout_valid, dout_ready);
                        if (errors > 3) begin
                            $display("    (stopping after 4 errors)");
                            r = 400; guard = 999999;
                        end
                    end
                    r = r + 1; rv = rv + 1'b1;
                end
            end
            dout_ready = 1'b0; wr_en = 1'b0;
            // drain the rest: check first, then consume (see test_fill)
            guard = 0;
            while (r < 400 && guard < 2000) begin
                guard = guard + 1;
                @(negedge clk);
                if (dout_valid) begin
                    if (dout !== rv) begin
                        fail("test_stress: mismatch during final drain");
                        $display("    got %h want %h", dout, rv);
                    end
                    r = r + 1; rv = rv + 1'b1;
                    dout_ready = 1'b1;
                end else begin
                    dout_ready = 1'b0;
                end
            end
            @(negedge clk); dout_ready = 1'b0;
            $display("    stress counters: tb_wrote=%0d dut_accepted=%0d tb_read=%0d", w, wr_acc, r);
            if (w != wr_acc)
                fail("test_stress: DUT accepted fewer writes than the tb issued");
            if (r != 400) begin
                fail("test_stress: did not get all 400 words out");
                $display("    drained %0d of 400", r);
            end
        end
    endtask

    // ------------------------------------------------------------------
    initial begin
        $display("=== tb_bitblt_fwft_fifo (DW=%0d AW=%0d depth=%0d) ===", DW, AW, DEPTH);
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        test_single;
        test_empty;
        test_fill_and_throughput;
        test_backpressure;
        test_stress;

        repeat (4) @(negedge clk);
        if (errors == 0) $display("RESULT: PASS (fwft fifo: throughput, loss, duplication, boundaries)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
