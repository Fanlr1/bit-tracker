// ARGB8888 -> RGB565 packer for the write side (docs/83).
//
// Mirror of bitblt_px565_unpack: the pixel engine produces FOUR 32-bit pixels per
// clock, and a 128-bit write beat carries EIGHT 16-bit pixels, so two pixel-engine
// clocks make one beat. That is the same halving the read side sees, and it is the
// whole point: half the write beats for the same picture.
//
// WHY THE PARTIAL-WRITE ENABLES STILL WORK
//   The engine emits out_be, one bit per pixel, because MODE_KEY skips pixels. In
//   the 16-bit format a pixel owns TWO bytes, so its two wstrb bits are set or
//   cleared together. That pairing happens here; bitblt_dma_wr is untouched (it
//   passes din_strb straight through to m_axi_wstrb).
//
// HALF-BEAT BOOKKEEPING
//   beat_valid is asserted only when both halves are present, so the write engine
//   never sees a partial beat. px_ready goes low for the one clock in between,
//   which is the back-pressure the pixel engine already understands.
//
// ASCII only.
`timescale 1ns / 1ps

module bitblt_px565_pack (
    input  wire          clk,
    input  wire          rst_n,

    // ---- pixel side (from the pixel engine) ----
    input  wire          px_valid,
    output wire          px_ready,
    input  wire [127:0]  px_data,       // four ARGB8888 pixels
    input  wire [3:0]    px_be,         // one write-enable bit per pixel

    // ---- beat side (to a write engine) ----
    output reg           beat_valid,
    input  wire          beat_ready,
    output reg  [127:0]  beat_data,
    output reg  [15:0]   beat_strb      // two bits per pixel (16-bit pixels)
);

    // ARGB8888 -> RGB565. Alpha is dropped: the framebuffer holds composited,
    // opaque pixels, and the pixel engine always reads the background back as
    // fully opaque, so nothing downstream needs it.
    function [15:0] pack565;
        input [31:0] p;
        begin
            pack565 = {p[23:19], p[15:10], p[7:3]};
        end
    endfunction

    // BYTE ORDER: pixel 0 is the lowest-address pixel, so it must occupy the LOW
    // 16 bits of the 64-bit half-beat, and its two write-enable bits are the LOW
    // two of the byte enables. A 16-bit pixel owns TWO bytes, so the enables pair
    // two-at-a-time -- not four. (The first version packaged only two pixels into
    // a 64-bit half and grouped the enables four bits at a time; both were wrong.)
    wire [63:0] half_lo = { pack565(px_data[127:96]), pack565(px_data[95:64]),
                            pack565(px_data[63:32]),  pack565(px_data[31:0]) };
    wire [7:0]  be_lo   = { px_be[3], px_be[3], px_be[2], px_be[2],
                            px_be[1], px_be[1], px_be[0], px_be[0] };

    reg [63:0] hold_data;
    reg [7:0]  hold_be;
    reg        hold_valid;

    // px_ready -- may a pixel-engine beat be taken this cycle?
    //   no first half held : yes. A first half is just latched, so it needs no
    //                        room anywhere.
    //   first half held    : only while no assembled beat is still waiting.
    //                        Otherwise the second half would overwrite the beat
    //                        that has not been handed over yet.
    assign px_ready = ~hold_valid | ~beat_valid;

    // WHY beat_valid IS LEVEL, NOT A ONE-CYCLE PULSE (docs/85)
    //   The write engine's din_ready is LOW while it sits in S_WAIT -- it is
    //   waiting for din_valid before it will even raise wvalid (see
    //   bitblt_dma_wr.v S_WAIT). A beat offered as a one-cycle pulse during that
    //   window is therefore NOT taken: the pulse ends, the data is gone, and the
    //   engine waits forever for a beat that was already discarded. Measured
    //   both ways: pulse -> the write engine parked with beats_left=1/din_ready=0
    //   and 0 write bursts; gating the pulse on beat_ready instead -> deadlock,
    //   because the engine will not raise din_ready until it has seen din_valid.
    //   Holding the beat until beat_ready is the only shape that satisfies both.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_valid <= 1'b0;
            beat_data  <= 128'd0;
            beat_strb  <= 16'd0;
            hold_data  <= 64'd0;
            hold_be    <= 8'd0;
            hold_valid <= 1'b0;
        end else begin
            // Retire the assembled beat ONLY on a real handshake.
            if (beat_valid && beat_ready) beat_valid <= 1'b0;

            if (px_valid && px_ready) begin
                if (!hold_valid) begin
                    // First half arrives; keep it and wait for the second.
                    hold_data  <= half_lo;
                    hold_be    <= be_lo;
                    hold_valid <= 1'b1;
                end else begin
                    // Second half arrives: assemble one beat. The first half is
                    // the LOW 64 bits (lowest addresses), the second is HIGH.
                    beat_data  <= { half_lo, hold_data };
                    beat_strb  <= { be_lo,   hold_be  };
                    beat_valid <= 1'b1;
                    hold_valid <= 1'b0;
                end
            end
        end
    end

endmodule
