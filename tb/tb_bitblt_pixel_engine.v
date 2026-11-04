// Self-checking testbench for bitblt_pixel_engine -- SINGLE PIXEL mode.
// PX_PER_BEAT = 1, so this exercises exactly the same behaviour as the original
// version; only the port rename (out_we -> out_be[0]) changed.
//
// Covers all four modes plus the alpha corner cases (0 / 255 / midpoint),
// per-pixel alpha, and the colour-key hit/miss decision.
`timescale 1ns / 1ps

module tb_bitblt_pixel_engine;

    localparam DW = 32;

    localparam [2:0] MODE_COPY   = 3'd0,
                     MODE_FILL   = 3'd1,
                     MODE_ALPHA  = 3'd2,
                     MODE_KEY    = 3'd3,
                     MODE_ADD    = 3'd4,
                     MODE_MUL    = 3'd5,
                     MODE_SCREEN = 3'd6;

    reg              clk   = 1'b0;
    reg              rst_n = 1'b0;
    reg              ce    = 1'b1;

    reg [2:0] mode  = MODE_COPY;
    reg  [DW-1:0]    fill_color = 32'h0;
    reg  [7:0]       alpha = 8'd255;
    reg  [DW-1:0]    key_color = 32'h0;
    reg              key_use_pixel_a = 1'b0;

    reg              in_valid = 1'b0;
    wire             in_ready;
    reg  [DW-1:0]    in_fg = 32'h0;
    reg  [DW-1:0]    in_bg = 32'h0;

    wire             out_valid;
    reg              out_ready = 1'b1;
    wire [DW-1:0]    out_px;
    wire [0:0]       out_be;          // PX_PER_BEAT = 1

    integer errors = 0;

    bitblt_pixel_engine #(.DW(DW), .PX_PER_BEAT(1)) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .ce              (ce),
        .mode            (mode),
        .fill_color      (fill_color),
        .alpha           (alpha),
        .key_color       (key_color),
        .key_use_pixel_a (key_use_pixel_a),
        .in_valid        (in_valid),
        .in_ready        (in_ready),
        .in_fg           (in_fg),
        .in_bg           (in_bg),
        .out_valid       (out_valid),
        .out_ready       (out_ready),
        .out_px          (out_px),
        .out_be          (out_be)
    );

    always #5 clk = ~clk;      // 100 MHz

    task do_pixel;
        input [DW-1:0]   fg;
        input [DW-1:0]   bg;
        input [DW-1:0]   exp_px;
        input            exp_be;
        input [255:0]    name;
        begin
            in_fg    = fg;
            in_bg    = bg;
            in_valid = 1'b1;
            @(posedge clk);
            #1;
            in_valid = 1'b0;

            while (!out_valid) begin
                @(posedge clk);
                #1;
            end

            if (out_px !== exp_px) begin
                $display("FAIL %0s: got px=%h want %h", name, out_px, exp_px);
                errors = errors + 1;
            end else if (out_be[0] !== exp_be) begin
                $display("FAIL %0s: got be=%b want %b", name, out_be[0], exp_be);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: px=%h be=%b", name, out_px, out_be[0]);
            end

            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        $dumpfile("tb_bitblt_pixel_engine.vcd");
        $dumpvars(0, tb_bitblt_pixel_engine);

        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;

        // ---------------- MODE_COPY ----------------
        mode = MODE_COPY;
        do_pixel(32'hAABBCCDD, 32'h11223344, 32'hAABBCCDD, 1'b1, "copy/passthru");

        // ---------------- MODE_FILL ----------------
        mode       = MODE_FILL;
        fill_color = 32'hFF00FF00;
        do_pixel(32'hAABBCCDD, 32'h11223344, 32'hFF00FF00, 1'b1, "fill/solid");

        // ---------------- MODE_ALPHA ----------------
        mode  = MODE_ALPHA;
        alpha = 8'd255;                                   // pure foreground
        do_pixel(32'hFFC86400, 32'hFF0A0A0A, 32'hFFC86400, 1'b1, "alpha/a=255");

        alpha = 8'd0;                                     // pure background
        do_pixel(32'hFFC86400, 32'hFF0A0A0A, 32'hFF0A0A0A, 1'b1, "alpha/a=0");

        alpha = 8'd128;                                   // midpoint
        do_pixel(32'hFFC86400, 32'hFF000000, 32'hFF643200, 1'b1, "alpha/midpoint");

        // per-pixel alpha from the A channel
        key_use_pixel_a = 1'b1;
        alpha           = 8'd255;                         // must be ignored
        do_pixel(32'h80C86400, 32'hFF000000, 32'h80643200, 1'b1, "alpha/pixel-A");
        key_use_pixel_a = 1'b0;

        // ---------------- MODE_KEY ----------------
        mode      = MODE_KEY;
        key_color = 32'hFFFF00FF;                         // magenta key

        do_pixel(32'hFF00FF00, 32'h11223344, 32'hFF00FF00, 1'b1, "key/miss-writes");
        do_pixel(32'hFFFF00FF, 32'h11223344, 32'hFFFF00FF, 1'b0, "key/hit-skips");

        // ---------------- MODE_ADD: min(fg + bg, 255) ----------------
        // Expected values are computed by hand from the specification, NOT from
        // the implementation -- a test whose expectations come from the DUT
        // cannot fail, which is exactly the trap documented in docs/20.
        mode = MODE_ADD;
        // R 0x40+0x30=0x70, G 0x80+0x50=0xD0, B 0xC0+0x90=0x150 saturates to 0xFF
        do_pixel(32'hFF4080C0, 32'hFF305090, 32'hFF70D0FF, 1'b1, "add/saturates-B");
        // all zero stays zero
        do_pixel(32'hFF000000, 32'hFF000000, 32'hFF000000, 1'b1, "add/black+black");
        // both saturated stays saturated
        do_pixel(32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF, 1'b1, "add/saturates-all");
        // exactly 255 does NOT saturate (boundary: 0x7F + 0x80 = 0xFF)
        do_pixel(32'hFF7F7F7F, 32'hFF808080, 32'hFFFFFFFF, 1'b1, "add/exact-255");

        // ---------------- MODE_MUL: fg * bg / 255 ----------------
        // q = (x + 1 + (x>>8)) >> 8, exact over [0, 65025]
        mode = MODE_MUL;
        // 128*128 = 16384 -> (16384+1+64)>>8 = 64 = 0x40
        do_pixel(32'hFF808080, 32'hFF808080, 32'hFF404040, 1'b1, "mul/midpoint");
        // 255*255 = 65025 -> (65025+1+254)>>8 = 255
        do_pixel(32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF, 1'b1, "mul/white*white");
        // 0 * anything = 0
        do_pixel(32'hFF000000, 32'hFFFF8080, 32'hFF000000, 1'b1, "mul/black*white");
        // mixed channels: R 255*128 = 32640 -> 128 ; G 0*0 = 0 ; B 1*255 = 255 -> 1
        // (the B result is 1, not 0: bg's blue byte is 0xFF, so the product is
        //  255 and (255+1)>>8 = 1. Getting this wrong is how the expectation was
        //  first written, and the test caught it.)
        do_pixel(32'hFFFF0001, 32'hFF8000FF, 32'hFF800001, 1'b1, "mul/mixed");
        // A value where floor and round DIFFER. The identity the engine uses,
        // (x+1+(x>>8))>>8, computes floor(x/255), not round(x/255):
        //   90*90 = 8100, 8100/255 = 31.76, so floor = 31 = 0x1F and round = 32.
        // Every other multiplier case here landed where the two agree, which is
        // why this went unnoticed until an end-to-end test happened to hit it.
        do_pixel(32'hFF5A5A5A, 32'hFF5A5A5A, 32'hFF1F1F1F, 1'b1, "mul/floor-vs-round");

        // ---------------- MODE_SCREEN: 255 - (255-fg)*(255-bg)/255 ----------------
        mode = MODE_SCREEN;
        // 127*127 = 16129 -> 63 ; 255-63 = 192 = 0xC0
        do_pixel(32'hFF808080, 32'hFF808080, 32'hFFC0C0C0, 1'b1, "screen/midpoint");
        // (255-0)*(255-0) = 65025 -> 255 ; 255-255 = 0
        do_pixel(32'hFF000000, 32'hFF000000, 32'hFF000000, 1'b1, "screen/black+black");
        // (255-255) = 0 -> 0 ; 255-0 = 255
        do_pixel(32'hFFFFFFFF, 32'hFF000000, 32'hFFFFFFFF, 1'b1, "screen/white+black");

        // ---------------- blend modes must not disturb colour keying ----------------
        // ADD/MUL/SCREEN all read the background, but they must still write --
        // only MODE_KEY suppresses a write.
        mode = MODE_MUL;
        do_pixel(32'hFF808080, 32'hFF808080, 32'hFF404040, 1'b1, "mul/write-enable-high");

        // ---------------- summary ----------------
        if (errors == 0)
            $display("PASS: all checks OK");
        else
            $display("RESULT: FAILED with %0d error(s)", errors);

        $finish;
    end

endmodule
