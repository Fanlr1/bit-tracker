// Testbench for bitblt_pixel_engine in FOUR-PIXEL-PER-BEAT mode.
//
// This is the configuration the top level will actually use: the AXI4 data path
// is 128 bits, i.e. four ARGB8888 pixels per clock.
//
// The important new behaviour under test is out_be: within a single beat some
// pixels may be colour-key hits and others not, so the write-enable has to be
// per pixel. A single-bit out_we could not express that.
`timescale 1ns / 1ps

module tb_bitblt_pixel_engine_p4;

    localparam DW  = 32;
    localparam PX  = 4;
    localparam BUS = DW * PX;      // 128

    localparam [1:0] MODE_COPY  = 2'd0,
                     MODE_FILL  = 2'd1,
                     MODE_ALPHA = 2'd2,
                     MODE_KEY   = 2'd3;

    reg              clk   = 1'b0;
    reg              rst_n = 1'b0;
    reg              ce    = 1'b1;

    reg  [1:0]       mode  = MODE_COPY;
    reg  [DW-1:0]    fill_color = 32'h0;
    reg  [7:0]       alpha = 8'd255;
    reg  [DW-1:0]    key_color = 32'h0;
    reg              key_use_pixel_a = 1'b0;

    reg              in_valid = 1'b0;
    wire             in_ready;
    reg  [BUS-1:0]   in_fg = {BUS{1'b0}};
    reg  [BUS-1:0]   in_bg = {BUS{1'b0}};

    wire             out_valid;
    reg              out_ready = 1'b1;
    wire [BUS-1:0]   out_px;
    wire [PX-1:0]    out_be;

    integer errors = 0;
    integer errs_before = 0;

    bitblt_pixel_engine #(.DW(DW), .PX_PER_BEAT(PX)) dut (
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

    always #5 clk = ~clk;

    // convenience: pack 4 pixels into the bus, pixel 0 in the low lane
    function [BUS-1:0] pack4;
        input [DW-1:0] p0, p1, p2, p3;
        begin
            pack4 = {p3, p2, p1, p0};
        end
    endfunction

    // run one beat and check all four lanes
    task do_beat;
        input [BUS-1:0]  fg_bus;
        input [BUS-1:0]  bg_bus;
        input [BUS-1:0]  exp_px;
        input [PX-1:0]   exp_be;
        input [255:0]    name;
        integer i;
        reg [DW-1:0] got_px, want_px;
        begin
            in_fg    = fg_bus;
            in_bg    = bg_bus;
            in_valid = 1'b1;
            @(posedge clk);
            #1;
            in_valid = 1'b0;

            while (!out_valid) begin
                @(posedge clk);
                #1;
            end

            if (out_be !== exp_be) begin
                $display("FAIL %0s: be=%b want %b", name, out_be, exp_be);
                errors = errors + 1;
            end else begin
                // Snapshot before the per-lane loop so the PASS line below is
                // only printed when every lane matched. It used to sit inside
                // this else but outside the loop, so one bad lane still
                // produced a PASS line in the same log entry as its FAIL.
                errs_before = errors;
                for (i = 0; i < PX; i = i + 1) begin
                    got_px  = out_px[i*DW +: DW];
                    want_px = exp_px[i*DW +: DW];
                    if (got_px !== want_px) begin
                        $display("FAIL %0s lane%0d: px=%h want %h", name, i, got_px, want_px);
                        errors = errors + 1;
                    end
                end
                if (errors == errs_before)
                $display("PASS %0s: be=%b  px=%h_%h_%h_%h", name, out_be,
                         out_px[3*DW +: DW], out_px[2*DW +: DW],
                         out_px[1*DW +: DW], out_px[0*DW +: DW]);
            end

            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        $dumpfile("tb_bitblt_pixel_engine_p4.vcd");
        $dumpvars(0, tb_bitblt_pixel_engine_p4);

        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;

        // ---- COPY: all four lanes pass through ----
        mode = MODE_COPY;
        do_beat(pack4(32'h11111111, 32'h22222222, 32'h33333333, 32'h44444444),
                pack4(32'h0, 32'h0, 32'h0, 32'h0),
                pack4(32'h11111111, 32'h22222222, 32'h33333333, 32'h44444444),
                4'b1111, "copy/4lanes");

        // ---- FILL: all four lanes get the same colour ----
        mode       = MODE_FILL;
        fill_color = 32'hFF00FF00;
        do_beat(pack4(32'h1, 32'h2, 32'h3, 32'h4),
                pack4(32'h0, 32'h0, 32'h0, 32'h0),
                pack4(32'hFF00FF00, 32'hFF00FF00, 32'hFF00FF00, 32'hFF00FF00),
                4'b1111, "fill/4lanes");

        // ---- ALPHA a=255: every lane returns its foreground ----
        mode  = MODE_ALPHA;
        alpha = 8'd255;
        do_beat(pack4(32'hFFC86400, 32'hFF0A141E, 32'hFF503C28, 32'hFFFFFFFF),
                pack4(32'hFF000000, 32'hFF000000, 32'hFF000000, 32'hFF000000),
                pack4(32'hFFC86400, 32'hFF0A141E, 32'hFF503C28, 32'hFFFFFFFF),
                4'b1111, "alpha255/4lanes");

        // ---- ALPHA a=0: every lane returns its background ----
        alpha = 8'd0;
        do_beat(pack4(32'hFFC86400, 32'hFF0A141E, 32'hFF503C28, 32'hFFFFFFFF),
                pack4(32'hFF112233, 32'hFF445566, 32'hFF778899, 32'hFFAABBCC),
                pack4(32'hFF112233, 32'hFF445566, 32'hFF778899, 32'hFFAABBCC),
                4'b1111, "alpha0/4lanes");

        // ---- KEY: MIXED within one beat -- this is what a 1-bit we cannot do ----
        //      pack4(p0,p1,p2,p3) puts p0 in the LOW lane, so:
        //        lane0 = p0 = FF00FF00 -> opaque   -> be[0] = 1
        //        lane1 = p1 = FFFF00FF -> KEY HIT  -> be[1] = 0
        //        lane2 = p2 = FF123456 -> opaque   -> be[2] = 1
        //        lane3 = p3 = FFFF00FF -> KEY HIT  -> be[3] = 0
        //      out_be is [3:0] with bit0 = lane0, so the expected value is 4'b0101.
        mode      = MODE_KEY;
        key_color = 32'hFFFF00FF;
        do_beat(pack4(32'hFF00FF00, 32'hFFFF00FF, 32'hFF123456, 32'hFFFF00FF),
                pack4(32'h0, 32'h0, 32'h0, 32'h0),
                pack4(32'hFF00FF00, 32'hFFFF00FF, 32'hFF123456, 32'hFFFF00FF),
                4'b0101, "key/mixed-beat");

        // ---- summary ----
        $display("");
        if (errors == 0) $display("PASS: all checks OK");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $finish;
    end

endmodule
