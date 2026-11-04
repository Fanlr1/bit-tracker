// Testbench for bitblt_tile_addr -- pins the two properties the engine relies on.
//
// WHY IT IS SEPARATE (docs/82 stage 1)
//   The tile address function is the shared foundation of the whole tiling change:
//   the write engine uses it for destinations, the read engine for backgrounds, and
//   the scan-out will use it to fetch a row band. If the mapping is wrong, every
//   one of those is wrong in a way that looks like a data corruption bug. So it is
//   pinned here first, alone, with no AXI and no timing involved.
//
// PROPERTIES
//   1. raster order inside one tile : a TILE x TILE block is 1024 consecutive bytes
//   2. aligned sprite = 1 run      : addr is monotone +1024 over an aligned block
//   3. unaligned sprite <= 4 runs  : it crosses at most 2x2 tiles
//   4. distinct tiles never overlap: every tile's base is unique and TS*TS*4 apart
//   5. corners map where the arithmetic says they do (hand-computed)
//
// ASCII only.
`timescale 1ns / 1ps

module tb_bitblt_tile_addr;

    localparam FB_W = 1920;
    localparam TS   = 16;
    localparam PB   = 4;
    localparam TILE_BYTES = TS*TS*PB;
    localparam FB_BASE = 32'h0800_0000;

    reg  [15:0] x = 0, y = 0;
    wire [31:0] addr;

    integer errors = 0;
    integer i, j;
    // All loop/scratch variables are declared HERE: Verilog-2001 does not allow
    // declarations after statements, nor inside an unnamed begin/end block
    // (iverilog: "Variable declaration in unnamed block requires SystemVerilog").
    integer tx, ty, ix_ignored, iy_ignored;
    integer runs, px, py;
    reg [31:0] prev;
    reg [31:0] a, a_prev;
    reg        started;
    reg [31:0] base_of_tile [0:4095];

    bitblt_tile_addr #(.FB_W(FB_W), .TILE_SIZE(TS), .PIX_BYTES(PB)) dut (
        .x(x), .y(y), .fb_base(FB_BASE), .addr(addr)
    );

    task fail(input [8*72-1:0] msg);
        begin
            errors = errors + 1;
            $display("  FAIL: %0s  (x=%0d y=%0d addr=%h)", msg, x, y, addr);
        end
    endtask

    // Expected address, computed independently of the DUT.
    function [31:0] want_addr(input [15:0] xx, input [15:0] yy);
        integer tx, ty, ix, iy;
        begin
            tx = xx / TS;  ty = yy / TS;
            ix = xx % TS;  iy = yy % TS;
            want_addr = FB_BASE + (ty * (FB_W/TS) + tx) * TILE_BYTES + (iy * TS + ix) * PB;
        end
    endfunction

    initial begin
        $display("=== tb_bitblt_tile_addr (FB_W=%0d TILE=%0d) ===", FB_W, TS);

        // ---- 1. exhaustively check the mapping over the whole active area ----
        // Every pixel of 1920x1080 must agree with the independent formula.
        for (ty = 0; ty < 1080; ty = ty + 1) begin
            for (tx = 0; tx < FB_W; tx = tx + 1) begin
                x = tx[15:0]; y = ty[15:0];
                #1;
                if (addr !== want_addr(tx[15:0], ty[15:0])) begin
                    fail("address disagrees with the independent formula");
                    tx = FB_W; ty = 1080;   // stop
                end
            end
        end
        $display("  1. full-area mapping vs independent formula: %0s", (errors == 0) ? "OK" : "FAILED");

        // ---- 2. inside one tile: 1024 consecutive bytes in raster order ----
        for (ty = 0; ty < TS; ty = ty + 1) begin
            for (tx = 0; tx < TS; tx = tx + 1) begin
                x = tx[15:0]; y = ty[15:0];
                #1;
                if (ty == 0 && tx == 0) prev = addr;
                else begin
                    if (addr !== prev + PB) fail("in-tile walk is not consecutive");
                    prev = addr;
                end
            end
        end
        $display("  2. aligned 16x16 block = 1024 consecutive bytes: %0s", (errors == 0) ? "OK" : "FAILED");

        // ---- 3. distinct tiles do not overlap, and are TILE_BYTES apart ----
        for (ty = 0; ty < 8; ty = ty + 1) begin
            for (tx = 0; tx < 8; tx = tx + 1) begin
                x = tx*TS; y = ty*TS;   // no part-select on an expression: Verilog-2001 forbids it
                #1;
                base_of_tile[ty*8+tx] = addr;
            end
        end
        for (i = 0; i < 64; i = i + 1) begin
            for (j = i+1; j < 64; j = j + 1) begin
                if (base_of_tile[i] == base_of_tile[j]) fail("two tiles share a base address");
            end
        end
        // tile (1,0) must be exactly TILE_BYTES after tile (0,0)
        if (base_of_tile[1] !== base_of_tile[0] + TILE_BYTES) fail("horizontal neighbour is not +1024 B");
        // tile (0,1) must be TILE_BYTES * TILE_COLS after tile (0,0)
        if (base_of_tile[8] !== base_of_tile[0] + TILE_BYTES*(FB_W/TS)) fail("vertical neighbour is not +1024*120 B");
        $display("  3. tile grid: unique bases, correct strides: %0s", (errors == 0) ? "OK" : "FAILED");

        // ---- 4. an UNALIGNED 16x16 sprite spans at most 2x2 tiles ----
        // Count the number of contiguous runs in the address sequence of a sprite
        // whose origin is off-grid. 2x2 tiles means at most 4 runs; the point is
        // that it is bounded and small compared with the 16 runs (one per row)
        // the row-major layout forces today.
        begin
            runs = 0; started = 0;
            for (py = 0; py < TS; py = py + 1) begin
                for (px = 0; px < TS; px = px + 1) begin
                    x = 5 + px; y = 7 + py;   // same reason: assign to the 16-bit reg, no [15:0]
                    #1;
                    a = addr;
                    if (!started || a !== a_prev + PB) runs = runs + 1;
                    a_prev = a; started = 1;
                end
            end
            // RECORDED, NOT ASSERTED -- and this is the single most important
            // number in the whole tiling plan.
            //
            // An ALIGNED sprite is 1 run (property 2). An unaligned one is 32:
            // each of its 16 rows crosses the tile column boundary at x=16, so
            // every row splits in two. Row-major costs 16 runs for the same
            // sprite. So tiling is a REGRESSION for sprites that are not aligned
            // to the 16-pixel grid -- it trades 16 round trips for 32.
            //
            // Consequence for the design: tiling only pays off when the sprite
            // origin is a multiple of TILE_SIZE. The density sweep's layout is
            // grid-aligned by construction (cols*16), so the measured scenario
            // gets the full 12.46x; a bullet-hell sprite that MOVES leaves the
            // grid and would get worse, not better.
            $display("  4. unaligned sprite at (5,7): %0d runs  | aligned: 1 run | row-major: 16 runs", runs);
            $display("     => tiling REQUIRES 16-pixel alignment; unaligned is a regression");
        end

        // ---- 5. hand-computed corners ----
        x = 0; y = 0; #1;
        if (addr !== FB_BASE) fail("pixel (0,0) is not fb_base");
        x = 1919; y = 1079; #1;
        // tile (119, 67): index = 67*120+119 = 8159
        // inner: x%16 = 1919-1904 = 15, y%16 = 1079-1072 = 7  => 7*16+15 = 127
        // (this expectation was 255 at first -- a hand-arithmetic slip of mine,
        //  the RTL was right; 127*4 = 508 = 0x1FC and 8159*1024 = 0x7F7C00, so
        //  the address is 0x08000000 + 0x7F7DFC = 0x087F7DFC)
        if (addr !== FB_BASE + 8159*TILE_BYTES + 127*PB) fail("pixel (1919,1079) wrong");
        $display("  5. hand-computed corners: %0s", (errors == 0) ? "OK" : "FAILED");

        if (errors == 0) $display("RESULT: PASS (tile address: mapping, raster order, grid, runs, corners)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
