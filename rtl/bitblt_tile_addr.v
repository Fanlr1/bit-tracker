// Tile-address generator for a tiled framebuffer.
//
// WHY THIS EXISTS (docs/82)
//   Measured on the board 2026-10-15: the same 16x16 COPY costs 89 cycles to a
//   CONTIGUOUS destination and 1109 cycles to the row-major framebuffer -- 12.46x.
//   The difference is the 32 DDR round trips a sprite pays today: one target read
//   and one write PER ROW, because row_cap forbids a burst crossing a row and the
//   rows are FB_STRIDE (8192 B) apart. A tiled framebuffer puts a whole 16x16
//   sprite inside one 1 KB block, so those 32 round trips become 2.
//
// WHAT A TILE IS
//   A 16x16 pixel block stored contiguously, 1024 B (ARGB8888). The screen is a
//   grid of TILE_COLS x TILE_ROWS tiles. Pixel (x,y) lives at:
//
//       addr = fb_base + ((y/TILE)*TILE_COLS + (x/TILE)) * TILE*TILE*4
//                      + ((y%TILE)*TILE + (x%TILE)) * 4
//
//   i.e. the tile index selects the block and the in-tile offset walks it in
//   normal raster order -- so a sprite aligned to the grid is one contiguous run.
//
// TWO PROPERTIES THE TESTBENCH PINS
//   1. A full aligned TILE x TILE sprite covers exactly 1024 consecutive bytes,
//      in raster order. That is what makes one round trip possible.
//   2. An UNALIGNED sprite crosses at most 2x2 tiles, so it costs 4 runs, not 32.
//      Both are far better than today; alignment is a bonus, not a requirement.
//
// NOTE ON TILE_SIZE: it must be a power of two, because the divide is a shift.
// 16 matches the sprite size and keeps the index arithmetic free.
//
// ASCII only.
`timescale 1ns / 1ps

module bitblt_tile_addr #(
    parameter FB_W      = 1920,          // screen width in pixels
    parameter TILE_SIZE = 16,            // power of two
    parameter PIX_BYTES = 4              // ARGB8888
) (
    input  wire [15:0]  x,
    input  wire [15:0]  y,
    input  wire [31:0]  fb_base,
    output wire [31:0]  addr
);

    localparam TS        = TILE_SIZE;
    localparam TILE_COLS = FB_W / TS;                 // 120 for 1920/16
    localparam TILE_BYTES = TS * TS * PIX_BYTES;      // 1024

    wire [15:0] tile_x   = x >> $clog2(TS);
    wire [15:0] tile_y   = y >> $clog2(TS);
    wire [15:0] inner_x  = x & (TS - 1);
    wire [15:0] inner_y  = y & (TS - 1);

    wire [31:0] tile_index = tile_y * TILE_COLS + tile_x;
    wire [31:0] inner_px   = inner_y * TS + inner_x;

    assign addr = fb_base
                + (tile_index << $clog2(TILE_BYTES))
                + (inner_px   << $clog2(PIX_BYTES));

    // Exposed for the row/column helpers the engines and the scan-out will need.
    wire [15:0] dbg_tile_x = tile_x;
    wire [15:0] dbg_tile_y = tile_y;
    wire [15:0] dbg_inner_x = inner_x;
    wire [15:0] dbg_inner_y = inner_y;

endmodule
