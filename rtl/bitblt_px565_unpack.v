// RGB565 -> ARGB8888 unpacker for the read side (docs/83).
//
// WHY THIS EXISTS
//   Measured 2026-10-15: scan-out traffic is the engine's biggest external limit.
//   Forcing it to read half of each line took a sprite from 1,218 to 754 cycles,
//   and 2048 sprites then fit in a 60 Hz frame. Halving that traffic for real
//   means a 16-bit framebuffer (2 bytes/pixel instead of 4).
//
// WHY IT IS A SEPARATE MODULE, NOT A CHANGE TO THE PIXEL ENGINE
//   bitblt_pixel_engine indexes channels as fg[c*8 +: 8] with c = 0..3 (B,G,R,A).
//   At 16 bits/pixel there are only two channels and alpha blending has nothing
//   to work with. So the pixel engine keeps DW=32 and this stage converts around
//   it -- the engine, both DMA engines and the address generator are untouched.
//
// RATE
//   One 128-bit beat carries EIGHT 16-bit pixels, while the pixel engine wants
//   FOUR 32-bit pixels per clock. A beat therefore takes two clocks to deliver,
//   which is exactly what makes the write side's 128-bit beats arrive half as
//   often -- the bandwidth saving, expressed in the data path.
//
// THE TWO HALVES
//   First clock : pixels 0..3 straight through (combinational from the beat).
//   Second clock: pixels 4..7 held in a register.
//   beat_ready stays low while the second half is still pending, so the read
//   engine simply waits one extra cycle -- it does not need to know why.
//
// ASCII only.
`timescale 1ns / 1ps

module bitblt_px565_unpack (
    input  wire          clk,
    input  wire          rst_n,

    // ---- beat side (from a read engine, 128-bit AXI beat) ----
    input  wire          beat_valid,
    output wire          beat_ready,
    input  wire [127:0]  beat_data,     // eight RGB565 pixels, little-endian within the beat

    // ---- pixel side (to the pixel engine) ----
    output reg           px_valid,
    input  wire          px_ready,
    output reg  [127:0]  px_data        // four ARGB8888 pixels
);

    // RGB565 -> ARGB8888: replicate the high bits so full scale maps to 255.
    // R5 -> R8 : {r, r[4:2]}   G6 -> G8 : {g, g[5:4]}   B5 -> B8 : {b, b[4:2]}
    function [31:0] expand;
        input [15:0] p;
        reg [4:0] r;
        reg [5:0] g;
        reg [4:0] b;
        begin
            r = p[15:11];
            g = p[10:5];
            b = p[4:0];
            expand = {8'hFF, r, r[4:2], g, g[5:4], b, b[4:2]};
        end
    endfunction

    // BYTE ORDER -- the low bits of an AXI beat are the LOWEST ADDRESS.
    // Pixel 0 therefore lives in beat_data[15:0], and it must land in
    // px_data[31:0] so that the pixel engine, the write side and the memory model
    // all agree on which pixel is which. (The first version had these two halves
    // swapped and the pixels reversed within them; every rate and order check
    // failed, while the colour conversion itself -- checked independently -- was
    // already correct.)
    //
    // First half (pixels 0..3) is the LOW 64 bits, combinational -- no register in
    // the way. Second half (pixels 4..7) is the HIGH 64 bits, held.
    wire [127:0] first_half  = { expand(beat_data[63:48]),  expand(beat_data[47:32]),
                                 expand(beat_data[31:16]), expand(beat_data[15:0]) };
    wire [127:0] second_half = { expand(beat_data[127:112]), expand(beat_data[111:96]),
                                 expand(beat_data[95:80]),   expand(beat_data[79:64]) };

    reg [127:0] hold;
    reg         second_pending;

    // A beat can be accepted only when no second half is still waiting.
    assign beat_ready = ~second_pending;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px_valid       <= 1'b0;
            px_data        <= 128'd0;
            hold           <= 128'd0;
            second_pending <= 1'b0;
        end else begin
            if (!px_valid) begin
                // Nothing presented yet: take the second half if one is pending,
                // otherwise take a fresh beat's first half.
                if (second_pending) begin
                    px_valid       <= 1'b1;
                    px_data        <= hold;
                    second_pending <= 1'b0;
                end else if (beat_valid) begin
                    px_valid       <= 1'b1;
                    px_data        <= first_half;
                    hold           <= second_half;
                    second_pending <= 1'b1;
                end
            end else if (px_ready) begin
                if (second_pending) begin
                    px_data        <= hold;          // deliver half two next cycle
                    second_pending <= 1'b0;
                end else if (beat_valid) begin
                    px_data        <= first_half;    // straight into half one
                    hold           <= second_half;
                    second_pending <= 1'b1;
                end else begin
                    px_valid <= 1'b0;
                end
            end
        end
    end

endmodule
