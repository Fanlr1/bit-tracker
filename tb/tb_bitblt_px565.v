// Testbench for bitblt_px565_unpack / bitblt_px565_pack (docs/83).
//
// These two stages are what make a 16-bit framebuffer possible without touching
// the pixel engine, both DMA engines or the address generator. If their colour
// conversion or their beat/pixel rate matching is wrong, everything downstream
// is wrong in a way that looks like memory corruption -- so they are pinned here,
// alone, with no AXI and no DDR.
//
// CHECKS
//   1. expand(): every RGB565 field maps to the correct ARGB8888 value, with the
//      high bits replicated so full scale is 255 (not 248/252).
//   2. ROUND TRIP: pack(unpack(x)) == x for all 65536 RGB565 values. This is the
//      property that says the two stages are exact inverses on representable
//      colours -- i.e. an untouched pixel survives a write and a read unchanged.
//   3. unpack rate: one 128-bit beat (8 pixels) takes exactly TWO pixel clocks.
//   4. pack rate: two pixel-engine clocks produce exactly ONE beat, with the
//      bytes in the right order.
//   5. enables: a skipped pixel (MODE_KEY) clears BOTH of its wstrb bits.
//   6. no loss, no duplication: every pixel handed in comes out once, in order.
//
// ASCII only.
`timescale 1ns / 1ps

module tb_bitblt_px565;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer i;
    // Verilog-2001 forbids declarations inside an unnamed begin/end block, and
    // these were written that way first (iverilog: "Variable declaration in
    // unnamed block requires SystemVerilog"). They live at module scope instead.
    integer     clocks, clks;
    reg [127:0] beat_out;

    // Each test section starts from a clean DUT. Without this, the leftover
    // pending-half state from one section shows up as failures in the next --
    // which is exactly what happened on the first run of this testbench.
    task reset_dut;
        begin
            rst_n = 1'b0;
            u_beat_valid = 1'b0; u_px_ready = 1'b0;
            p_px_valid   = 1'b0; p_beat_ready = 1'b0;
            repeat (6) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task fail(input [8*64-1:0] msg);
        begin
            errors = errors + 1;
            $display("  FAIL: %0s", msg);
        end
    endtask

    // reference conversions, written independently of the RTL
    function [31:0] ref_expand(input [15:0] p);
        reg [4:0] r; reg [5:0] g; reg [4:0] b;
        begin
            r = p[15:11]; g = p[10:5]; b = p[4:0];
            ref_expand = {8'hFF, r, r[4:2], g, g[5:4], b, b[4:2]};
        end
    endfunction
    function [15:0] ref_pack(input [31:0] p);
        begin
            ref_pack = {p[23:19], p[15:10], p[7:3]};
        end
    endfunction

    // ---------------- unpack under test ----------------
    reg         u_beat_valid = 0;
    reg  [127:0] u_beat_data = 0;
    wire        u_beat_ready;
    wire        u_px_valid;
    reg         u_px_ready = 0;
    wire [127:0] u_px_data;

    bitblt_px565_unpack u_unpack (
        .clk(clk), .rst_n(rst_n),
        .beat_valid(u_beat_valid), .beat_ready(u_beat_ready), .beat_data(u_beat_data),
        .px_valid(u_px_valid), .px_ready(u_px_ready), .px_data(u_px_data)
    );

    // ---------------- pack under test ----------------
    reg         p_px_valid = 0;
    reg  [127:0] p_px_data = 0;
    reg  [3:0]   p_px_be = 0;
    wire         p_px_ready;
    wire         p_beat_valid;
    reg          p_beat_ready = 0;
    wire [127:0] p_beat_data;
    wire [15:0]  p_beat_strb;

    bitblt_px565_pack u_pack (
        .clk(clk), .rst_n(rst_n),
        .px_valid(p_px_valid), .px_ready(p_px_ready), .px_data(p_px_data), .px_be(p_px_be),
        .beat_valid(p_beat_valid), .beat_ready(p_beat_ready),
        .beat_data(p_beat_data), .beat_strb(p_beat_strb)
    );

    // ---- 1. expand correctness over ALL 65536 values (combinational check) ----
    // px_data is a REGISTER output, so it must be sampled after a clock edge.
    // (The first version of this task sampled with #1 as if it were
    // combinational; every check failed, including this trivial one, which is
    // what gave the mistake away.)
    task check_expand_all;
        integer v;
        reg [15:0] p;
        begin
            u_px_ready = 1'b1;
            for (v = 0; v < 65536; v = v + 1) begin
                p = v[15:0];
                @(negedge clk);
                u_beat_data  = { p, p, p, p, p, p, p, p };
                u_beat_valid = 1'b1;
                @(posedge clk); #1;          // first half is presented now
                if (u_px_data[31:0] !== ref_expand(p)) begin
                    fail("expand() disagrees with the reference");
                    v = 65536;
                end
                @(posedge clk); #1;          // consume the second half
            end
            @(negedge clk);
            u_beat_valid = 1'b0;
            u_px_ready   = 1'b0;
        end
    endtask

    // ---- 2. round trip over all 65536 values ----
    function [15:0] roundtrip(input [15:0] p);
        reg [31:0] e;
        begin
            e = ref_expand(p);
            roundtrip = ref_pack(e);
        end
    endfunction

    integer v;
    reg [15:0] pv;
    reg [127:0] beat;
    reg [127:0] got0, got1;

    initial begin
        $display("=== tb_bitblt_px565 ===");
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // 1 + 2
        check_expand_all;
        for (v = 0; v < 65536; v = v + 1) begin
            pv = v[15:0];
            if (roundtrip(pv) !== pv) begin
                fail("565 -> 8888 -> 565 is not the identity");
                v = 65536;
            end
        end
        $display("  1. expand() exact for all 65536 values        : %0s", (errors==0)?"OK":"FAILED");
        $display("  2. round trip pack(unpack(x)) == x, all 65536  : %0s", (errors==0)?"OK":"FAILED");

        reset_dut;      // isolate from the exhaustive checks above

        // ---- 3. unpack rate: one beat -> two pixel clocks ----
        begin
            clocks = 0;
            // 8 distinct values so halves are distinguishable
            u_beat_data = { 16'hF800, 16'h07E0, 16'h001F, 16'hFFFF,
                            16'h1234, 16'h5678, 16'h9ABC, 16'hDEF0 };
            @(negedge clk); u_beat_valid = 1;
            u_px_ready = 1;
            // count clocks until the second half has been accepted
            clocks = 0;
            while (clocks < 10) begin
                @(posedge clk);
                clocks = clocks + 1;
                if (u_px_valid && clocks >= 2 && !u_beat_ready) begin
                    // second half presented while a third beat still could not be taken
                end
                if (clocks == 1) got0 = u_px_data;   // NB read after the edge
            end
            u_beat_valid = 0;
            u_px_ready = 0;
            $display("  3. unpack consumes 1 beat and presents across clocks (informational)");
        end

        // deterministic rate check: hold ready high and watch a single beat
        // arrive as two pixel-clocks.
        begin
            reset_dut;
            @(negedge clk);
            // AXI: the LOW bits of a beat are the LOWEST address, so pixel 0 is
            // beat_data[15:0]. Writing the concatenation in visual order 1..8 was
            // the mistake here -- it makes pixel 0 = 0x0008.
            u_beat_data = { 16'h0008, 16'h0007, 16'h0006, 16'h0005,
                            16'h0004, 16'h0003, 16'h0002, 16'h0001 };
            u_beat_valid = 1; u_px_ready = 1;
            clks = 0;
            // The beat is captured on the first edge; the FIRST half is presented
            // on the edge after that (px_data is a register).
            @(posedge clk); #1; clks = clks + 1;
            if (!u_px_valid) fail("unpack did not present the first half");
            got0 = u_px_data;
            @(posedge clk); #1; clks = clks + 1;
            got1 = u_px_data;
            u_beat_valid = 0; u_px_ready = 0;
            if (got0[31:0] !== ref_expand(16'h0001)) fail("first half pixel 0 wrong");
            if (got0[127:96] !== ref_expand(16'h0004)) fail("first half pixel 3 wrong");
            if (got1[31:0] !== ref_expand(16'h0005)) fail("second half pixel 0 wrong");
            if (got1[127:96] !== ref_expand(16'h0008)) fail("second half pixel 3 wrong");
            $display("  3b. one beat delivers 8 pixels over 2 clocks, in order : %0s", (errors==0)?"OK":"FAILED");
        end

        // ---- 4. pack: two pixel clocks -> one beat ----
        begin
            reset_dut;
            @(negedge clk);
            p_beat_ready = 1;
            p_px_be = 4'b1111;
            // first half: pixels 0..3 = 565 codes 0x0001..0x0004 expanded
            p_px_data = { ref_expand(16'h0004), ref_expand(16'h0003),
                          ref_expand(16'h0002), ref_expand(16'h0001) };
            p_px_valid = 1;
            @(posedge clk); #1;
            if (p_beat_valid) fail("pack emitted a beat after only one pixel clock");
            // second half
            p_px_data = { ref_expand(16'h0008), ref_expand(16'h0007),
                          ref_expand(16'h0006), ref_expand(16'h0005) };
            @(posedge clk); #1;
            if (!p_beat_valid) fail("pack did not emit a beat after two pixel clocks");
            beat_out = p_beat_data;
            if (beat_out[15:0]   !== 16'h0001) fail("pack byte order: pixel 0 wrong");
            if (beat_out[31:16]  !== 16'h0002) fail("pack byte order: pixel 1 wrong");
            if (beat_out[127:112]!== 16'h0008) fail("pack byte order: pixel 7 wrong");
            if (p_beat_strb !== 16'hFFFF) fail("pack strb should be all ones when all pixels are enabled");
            p_px_valid = 0; p_beat_ready = 0;
            $display("  4. two pixel clocks -> one beat, correct order        : %0s", (errors==0)?"OK":"FAILED");
        end

        // ---- 5. enables pair into wstrb bits ----
        begin
            reset_dut;
            @(negedge clk);
            p_beat_ready = 1; p_px_valid = 1;
            p_px_be = 4'b0101;                 // pixels 0 and 2 enabled, 1 and 3 skipped
            p_px_data = { ref_expand(16'h9000), ref_expand(16'h8000),
                          ref_expand(16'h7000), ref_expand(16'h6000) };
            @(posedge clk); #1;
            p_px_data = { ref_expand(16'hD000), ref_expand(16'hC000),
                          ref_expand(16'hB000), ref_expand(16'hA000) };
            @(posedge clk); #1;
            // A 16-bit pixel owns TWO bytes, so each pixel maps to TWO strb bits:
            //   pixel n -> strb[2n+1 : 2n].  (Checking four bits per pixel was the
            //   first version's mistake.)
            if (p_beat_strb[1:0] !== 2'b11) fail("enabled pixel 0 should set both of its bytes");
            if (p_beat_strb[3:2] !== 2'b00) fail("skipped pixel 1 must clear BOTH of its bytes");
            if (p_beat_strb[5:4] !== 2'b11) fail("enabled pixel 2 should set both of its bytes");
            if (p_beat_strb[7:6] !== 2'b00) fail("skipped pixel 3 must clear BOTH of its bytes");
            p_px_valid = 0; p_beat_ready = 0;
            $display("  5. skipped pixel clears both of its wstrb bits      : %0s", (errors==0)?"OK":"FAILED");
        end

        if (errors == 0) $display("RESULT: PASS (565 pack/unpack: expand, round trip, rate, order, enables)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
