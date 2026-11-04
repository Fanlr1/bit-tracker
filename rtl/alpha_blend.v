// Alpha blending core using the Titanium DSP48 primitive.
// out = (fg * alpha + bg * (255 - alpha)) / 255   (approximated by >>8 for now)
//
// The DSP48 does M = A*B then P = M + C in one block:
//   A = alpha      (19-bit)
//   B = fg         (18-bit)
//   C = bg*(255-alpha)  (18-bit)
`timescale 1ns / 1ps

module alpha_blend #(
    parameter WIDTH = 8
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             ce,
    input  wire [WIDTH-1:0] fg,
    input  wire [WIDTH-1:0] bg,
    input  wire [WIDTH-1:0] alpha,   // 0 = full background, 255 = full foreground
    output wire [WIDTH-1:0] out
);

    localparam integer DW = 48;

    // background contribution: bg * (255 - alpha)  -> up to 16 bits
    wire [15:0] bg_term = bg * (8'd255 - alpha);

    (* keep *) wire [DW-1:0] dsp_p;

    EFX_DSP48 #(
        .MODE      ("NORMAL"),
        .A_REG     (1),
        .B_REG     (1),
        .C_REG     (1),
        .P_REG     (1),
        .OP_REG    (0),
        .SIGNED    (0),
        .M_SEL     ("P"),
        .N_SEL     ("C")
    ) u_dsp48 (
        .A        ({11'b0, alpha}),      // 19-bit
        .B        ({10'b0, fg}),         // 18-bit
        .C        ({2'b0, bg_term}),     // 18-bit
        .CASCIN   (48'b0),
        .OP       (2'b00),
        // IMPORTANT: inside EFX_DSP48 the shift amount is taken from C[15:0].
        // Pulling SHIFT_ENA low keeps the shifter at 0, so C can serve purely
        // as the adder input. Leaving it high makes C corrupt the result.
        .SHIFT_ENA(1'b0),
        .CLK      (clk),
        .CE       (ce),
        .RST      (~rst_n),
        .O        (dsp_p),
        .CASCOUT  (),
        .OVFL     ()
    );

    // Divide by 255, not by 256.
    //
    // This used to be `out = dsp_p[15:8]`, i.e. a shift by 8. That is not the
    // same function: for x = fg*255 + bg*0 the true result is fg, while >>8
    // gives fg-1 for every fg >= 1. Across x in [0, 65025] the two disagree on
    // 49.8% of values, always by exactly 1 and always in the dark direction.
    //
    // (x + 1 + (x>>8)) >> 8 is exact over that range -- the same identity
    // bitblt_pixel_engine already uses. Checked at the boundaries:
    //   x=254  -> (254+1+0)>>8   = 0    = 254/255
    //   x=255  -> (255+1+0)>>8   = 1    = 255/255
    //   x=510  -> (510+1+1)>>8   = 2    = 510/255
    //   x=65025-> (65025+1+254)>>8 = 255 = 65025/255
    // The upper bound is fg*255 + bg*0 <= 255*255 = 65025, so 18 bits suffice.
    wire [17:0] sum18   = dsp_p[17:0];
    wire [17:0] rounded = sum18 + 18'd1 + {10'd0, sum18[17:8]};

    assign out = rounded[15:8];

endmodule
