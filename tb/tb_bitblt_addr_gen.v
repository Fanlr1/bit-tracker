// Self-checking testbench for bitblt_addr_gen.
//
// Verifies the address recurrence, the line handshake, the independent
// src/dst strides, and the single-cycle done pulse.
`timescale 1ns / 1ps

// FAULT INJECTION (oob_addr) -- PROOF THESE ASSERTIONS CAN FAIL
//   Change: in bitblt_addr_gen.v, the oob_addr assignment was replaced by the
//           constant 32'hDEADBEEF. Reverted afterwards.
//
//   Actual output with the fault in place:
//     FAIL oob_addr/below:  got deadbeef want 00007000
//     FAIL oob_addr/above:  got deadbeef want 00009000
//     FAIL oob_addr/clears: got deadbeef want 0
//     RESULT: FAILED with 3 error(s)
//
//   All three directions fail, including "clears" -- which is the one that
//   matters most, because a stale address reads as a current one. The three
//   assertions were written as a set for that reason.

module tb_bitblt_addr_gen;

    localparam AW = 32;

    reg              clk   = 1'b0;
    reg              rst_n = 1'b0;
    reg              ce    = 1'b1;

    reg  [AW-1:0]    src_base    = 32'h0000_1000;
    reg  [AW-1:0]    dst_base    = 32'h0000_8000;
    reg  [15:0]      img_width   = 16'd8;
    reg  [15:0]      img_height  = 16'd4;
    reg  [AW-1:0]    src_stride  = 32'h0000_0020;   // 32 B/row
    reg  [AW-1:0]    dst_stride  = 32'h0000_0040;   // 64 B/row (different!)
    reg  [3:0]       bytes_per_px = 4'd4;           // 4 B/px (widened: 8 does not fit 3 bits)

    // Framebuffer bounds. The first two groups keep their destination inside
    // this window so they behave exactly as before; the last group deliberately
    // steps outside it.
    reg  [AW-1:0]    fb_start = 32'h0000_8000;
    reg  [AW-1:0]    fb_end   = 32'h0000_9000;

    reg              start = 1'b0;
    wire             busy, done, oob;
    wire [31:0]      oob_addr;

    wire [AW-1:0]    line_src_addr;
    wire [AW-1:0]    line_dst_addr;
    wire [31:0]      line_bytes;
    wire [15:0]      line_index;
    wire             line_req;
    reg              line_ack = 1'b0;

    integer errors = 0;
    integer done_pulses = 0;
    integer lines_done  = 0;
    integer errs_before = 0;

    // expected values, recomputed independently in the TB
    reg [AW-1:0] exp_src;
    reg [AW-1:0] exp_dst;

    bitblt_addr_gen #(.AW(AW)) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .ce            (ce),
        .src_base      (src_base),
        .dst_base      (dst_base),
        .img_width     (img_width),
        .img_height    (img_height),
        .src_stride    (src_stride),
        .dst_stride    (dst_stride),
        .bytes_per_px  (bytes_per_px),
        .fb_start      (fb_start),
        .fb_end        (fb_end),
        .start         (start),
        .busy          (busy),
        .done          (done),
        .oob           (oob),
        .oob_addr      (oob_addr),
        .line_src_addr (line_src_addr),
        .line_dst_addr (line_dst_addr),
        .line_bytes    (line_bytes),
        .line_index    (line_index),
        .line_req      (line_req),
        .line_ack      (line_ack)
    );

    always #5 clk = ~clk;

    // count done pulses
    always @(posedge clk) if (done) done_pulses = done_pulses + 1;

    // consume one line: check the addresses, then ack
    task consume_line;
        input [15:0] n;
        begin
            // wait for line_req
            while (!line_req) @(posedge clk);
            #1;

            exp_src = src_base + (n * src_stride);
            exp_dst = dst_base + (n * dst_stride);

            // Snapshot the error count so the PASS line below is only printed
            // when every check for this line actually passed. It used to be
            // unconditional, sitting right after the four checks -- so a log
            // could contain both "FAIL line N ..." and "PASS line N ...", and
            // grepping for PASS would report success on a failing run.
            errs_before = errors;

            if (line_src_addr !== exp_src) begin
                $display("FAIL line %0d src: got %h want %h", n, line_src_addr, exp_src);
                errors = errors + 1;
            end
            if (line_dst_addr !== exp_dst) begin
                $display("FAIL line %0d dst: got %h want %h", n, line_dst_addr, exp_dst);
                errors = errors + 1;
            end
            // Expectation computed from the specification (width * bytes per
            // pixel), not hard-coded to 32. With the literal, a DUT that
            // ignored bytes_per_px entirely and always assumed 4 would match
            // and pass.
            if (line_bytes !== ({16'd0, img_width} * {28'd0, bytes_per_px})) begin
                $display("FAIL line %0d bytes: got %0d want %0d", n, line_bytes,
                         ({16'd0, img_width} * {28'd0, bytes_per_px}));
                errors = errors + 1;
            end
            if (line_index !== n) begin
                $display("FAIL line %0d index: got %0d", n, line_index);
                errors = errors + 1;
            end
            if (errors == errs_before)
                $display("PASS line %0d: src=%h dst=%h bytes=%0d",
                         n, line_src_addr, line_dst_addr, line_bytes);
            else
                $display("      line %0d: checks FAILED (see above)", n);
            lines_done = lines_done + 1;

            // ack for one cycle
            @(posedge clk);
            line_ack <= 1'b1;
            @(posedge clk);
            line_ack <= 1'b0;
            @(posedge clk);
        end
    endtask

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_bitblt_addr_gen.vcd");
        $dumpvars(0, tb_bitblt_addr_gen);

        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- start a 4-line frame ----
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        // busy is a registered output: it rises one cycle AFTER start is sampled,
        // so give it that cycle before checking.
        @(posedge clk);
        #1;

        if (busy !== 1'b1) begin
            $display("FAIL busy not asserted after start");
            errors = errors + 1;
        end

        consume_line(16'd0);
        consume_line(16'd1);
        consume_line(16'd2);
        consume_line(16'd3);

        // ---- frame should now be done ----
        repeat (4) @(posedge clk);
        if (done_pulses == 1) $display("PASS done: exactly 1 pulse");
        else begin
            $display("FAIL done: %0d pulses, want 1", done_pulses);
            errors = errors + 1;
        end
        if (busy !== 1'b0) begin
            $display("FAIL busy still high after done");
            errors = errors + 1;
        end
        if (lines_done !== 4) begin
            $display("FAIL consumed %0d lines, want 4", lines_done);
            errors = errors + 1;
        end

        // ---- second configuration: 8 bytes per pixel ----
        // The first group ran with bytes_per_px = 4 and an expectation of 32
        // bytes per line, so a DUT that ignored bytes_per_px and always assumed
        // 4 would have matched and passed. Here the expected line size is
        // 8 px * 8 B = 64, which that DUT cannot produce. 8 also does not fit in
        // 3 bits, which is why the port was widened to 4.
        img_width    = 16'd8;
        img_height   = 16'd2;
        src_stride   = 32'h0000_0040;    // 8 px * 8 B
        dst_stride   = 32'h0000_0080;
        bytes_per_px = 4'd8;
        lines_done   = 0;
        done_pulses  = 0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        #1;
        consume_line(16'd0);
        consume_line(16'd1);
        repeat (4) @(posedge clk);
        if (done_pulses == 1) $display("PASS bpp8: done after 2 lines of 64 B");
        else begin
            $display("FAIL bpp8: %0d done pulses, want 1", done_pulses);
            errors = errors + 1;
        end

        // ---- degenerate config: zero height must finish immediately ----
        img_height = 16'd0;
        done_pulses = 0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        repeat (3) @(posedge clk);
        if (done_pulses == 1) $display("PASS empty-frame: done without any line");
        else begin
            $display("FAIL empty-frame: %0d done pulses, want 1", done_pulses);
            errors = errors + 1;
        end

        // ---- bounds checking ----
        //
        // Without this, a sprite running off the end of the framebuffer writes
        // into whatever DDR follows it. That is memory corruption, not a display
        // glitch, and the bullet-hell demo is exactly where sprites leave the
        // screen.
        //
        // Framebuffer window for these cases: [0x8000, 0x9000).
        dst_stride   = 32'h0000_0040;
        src_stride   = 32'h0000_0040;
        bytes_per_px = 4'd4;

        // (1) starts before the framebuffer
        dst_base    = 32'h0000_7000;
        img_width   = 16'd8;
        img_height  = 16'd2;
        done_pulses = 0;
        lines_done  = 0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        repeat (4) @(posedge clk);
        if (done_pulses == 1 && oob === 1'b1 && lines_done == 0) begin
            $display("PASS oob/below: refused, done asserted, oob=1, 0 lines");
            // The ADDRESS is the part a driver cannot infer. Without it,
            // debugging means guessing whether the base register, the
            // stride, or the sprite coordinates are wrong.
            if (oob_addr === dst_base)
                $display("PASS oob_addr/below: reported the refused destination");
            else begin
                $display("FAIL oob_addr/below: got %h want %h", oob_addr, dst_base);
                errors = errors + 1;
            end
        end
        else begin
            $display("FAIL oob/below: done=%0d oob=%b lines=%0d (want 1/1/0)",
                     done_pulses, oob, lines_done);
            errors = errors + 1;
        end

        // (2) starts at or past the end of the framebuffer
        dst_base    = 32'h0000_9000;
        done_pulses = 0;
        lines_done  = 0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        repeat (4) @(posedge clk);
        if (done_pulses == 1 && oob === 1'b1 && lines_done == 0) begin
            $display("PASS oob/above: refused, done asserted, oob=1, 0 lines");
            if (oob_addr === dst_base)
                $display("PASS oob_addr/above: reported the refused destination");
            else begin
                $display("FAIL oob_addr/above: got %h want %h", oob_addr, dst_base);
                errors = errors + 1;
            end
        end
        else begin
            $display("FAIL oob/above: done=%0d oob=%b lines=%0d (want 1/1/0)",
                     done_pulses, oob, lines_done);
            errors = errors + 1;
        end

        // (3) starts inside but overruns the bottom edge -- the interesting one.
        //     base 0x8F80, stride 0x40, 4 rows of 32 B:
        //       row 0: 0x8F80..0x8FA0  inside
        //       row 1: 0x8FC0..0x8FE0  inside
        //       row 2: 0x9000..          past the end -> must stop after row 1
        //     The first two rows are valid and must still be transferred; the
        //     transfer ends early rather than writing past the framebuffer.
        dst_base    = 32'h0000_8F80;
        img_width   = 16'd8;
        img_height  = 16'd4;
        done_pulses = 0;
        lines_done  = 0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        @(posedge clk);
        #1;
        consume_line(16'd0);
        consume_line(16'd1);
        repeat (4) @(posedge clk);
        if (done_pulses == 1 && oob === 1'b1 && lines_done == 2)
            $display("PASS oob/overrun: 2 valid rows transferred, then stopped with oob=1");
        else begin
            $display("FAIL oob/overrun: done=%0d oob=%b lines=%0d (want 1/1/2)",
                     done_pulses, oob, lines_done);
            errors = errors + 1;
        end

        // (4) oob must not stick across transfers: a valid transfer after a
        //     refused one has to come back clean, otherwise the flag is useless
        //     as a per-command error report.
        dst_base    = 32'h0000_8000;
        img_width   = 16'd8;
        img_height  = 16'd1;
        done_pulses = 0;
        lines_done  = 0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        @(posedge clk);
        #1;
        consume_line(16'd0);
        repeat (4) @(posedge clk);
        if (done_pulses == 1 && oob === 1'b0 && lines_done == 1) begin
            $display("PASS oob/clears: next valid transfer reports oob=0");
            // A stale address left over from the previous transfer would
            // read as if it belonged to this one. oob = 0 implies
            // oob_addr = 0, so software never sees a number that is no
            // longer about anything.
            if (oob_addr === 32'd0)
                $display("PASS oob_addr/clears: zeroed with oob");
            else begin
                $display("FAIL oob_addr/clears: got %h want 0", oob_addr);
                errors = errors + 1;
            end
        end
        else begin
            $display("FAIL oob/clears: done=%0d oob=%b lines=%0d (want 1/0/1)",
                     done_pulses, oob, lines_done);
            errors = errors + 1;
        end

        // ---- summary ----
        $display("");
        if (errors == 0) $display("PASS: all checks OK");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $finish;
    end

endmodule
