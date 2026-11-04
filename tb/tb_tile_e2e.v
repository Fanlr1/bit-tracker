// tb_tile_e2e.v -- P4 end-to-end: gfx_sprtab(TILE_MODE=1) -> gfx_core ->
// gfx_mem -> tile framebuffer -> gfx_scanout(TILE_MODE=1) -> RGB pixels.
// 4 static 8x8 sprites at unaligned positions are drawn by the real RTL chain;
// the scan-out pixels must equal a reference framebuffer built in the TB.
`timescale 1ns/1ps
`default_nettype none
module ddr_model_e2e #(parameter MEMW = 8192, parameter FB = 32'h0800_0000) (
    input  wire clk, input wire rst_n,
    input  wire [31:0] s_araddr, input wire [7:0] s_arlen,
    input  wire s_arvalid, output reg s_arready,
    output reg [127:0] s_rdata, output reg s_rlast, output reg s_rvalid,
    input  wire s_rready,
    input  wire [31:0] s_awaddr, input wire [7:0] s_awlen,
    input  wire s_awvalid, output reg s_awready,
    input  wire [127:0] s_wdata, input wire [15:0] s_wstrb,
    input  wire s_wlast, input wire s_wvalid, output wire s_wready,
    output reg s_bvalid
);
    reg [127:0] mem [0:MEMW-1];
    integer i;
    initial for (i = 0; i < MEMW; i = i + 1) mem[i] = 128'd0;
    reg [31:0] rbase, wbase; reg [7:0] rlen, rcnt, wlen, wcnt; reg rbusy, wbusy;
    assign s_wready = 1'b1;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_arready <= 1'b1; s_rvalid <= 1'b0; s_rlast <= 1'b0; s_rdata <= 128'd0;
            rbusy <= 1'b0; rbase <= 32'd0; rlen <= 8'd0; rcnt <= 8'd0;
            s_awready <= 1'b1; wbusy <= 1'b0; wbase <= 32'd0; wlen <= 8'd0; wcnt <= 8'd0;
            s_bvalid <= 1'b0;
        end else begin
            if (!rbusy && s_arvalid && s_arready) begin
                rbase <= s_araddr; rlen <= s_arlen; rcnt <= 8'd0; rbusy <= 1'b1; s_arready <= 1'b0;
            end
            if (rbusy) begin
                if (!s_rvalid) begin
                    s_rvalid <= 1'b1; s_rdata <= mem[(rbase - FB) >> 4]; s_rlast <= (rcnt == rlen);
                end else if (s_rready) begin
                    rcnt <= rcnt + 8'd1;
                    if (s_rlast) begin rbusy <= 1'b0; s_rvalid <= 1'b0; s_rlast <= 1'b0; s_arready <= 1'b1;
                    end else begin
                        s_rdata <= mem[((rbase - FB) >> 4) + rcnt + 1]; s_rlast <= ((rcnt + 8'd1) == rlen);
                    end
                end
            end
            if (!wbusy && s_awvalid && s_awready) begin
                wbase <= s_awaddr; wlen <= s_awlen; wcnt <= 8'd0; wbusy <= 1'b1; s_awready <= 1'b0;
            end
            if (wbusy && s_wvalid) begin
                for (i = 0; i < 16; i = i + 1)
                    if (s_wstrb[i]) mem[((wbase - FB) >> 4) + wcnt][8*i +: 8] <= s_wdata[8*i +: 8];
                wcnt <= wcnt + 8'd1;
                if (s_wlast) begin wbusy <= 1'b0; s_bvalid <= 1'b1; s_awready <= 1'b1; end
            end else if (s_bvalid) s_bvalid <= 1'b0;
        end
    end
endmodule

module tb_tile_e2e;
    reg clk = 0, pclk = 0, rst_n = 0, preset_n = 0;
    always #5 clk = ~clk;
    always #3.4 pclk = ~pclk;
    localparam H_ACT = 512, V_ACT = 64, RAM_AW = 6;
    localparam FB  = 32'h0800_0000;
    localparam SPR = 32'h0801_0000;      // sprite bitmap (128 B)
    localparam BAND_STRIDE = 8192;       // ((512*8*2+4095)/4096)*4096

    // ---- walker ----
    reg         tw_we = 0; reg [11:0] tw_addr = 0; reg [63:0] tw_data = 0;
    reg         go = 0; reg [15:0] n = 16'd4;
    reg  [31:0] fb = FB, spr = SPR; reg [15:0] key = 16'hF81F;
    reg  [7:0]  alp = 8'd200; reg [15:0] fill_col = 16'h1082;
    reg  [15:0] max_x = 16'd504, max_y = 16'd56;
    wire        busy; wire [31:0] prog, dbg_tab0;
    wire        cmd_valid; wire [351:0] cmd_data; wire cmd_ready;
    gfx_sprtab #(.AW(12), .ERASE_DIFF(0), .TILE_MODE(1), .BAND_STRIDE(BAND_STRIDE)) u_walk (
        .clk(clk), .rst_n(rst_n), .tw_we(tw_we), .tw_addr(tw_addr), .tw_data(tw_data),
        .go(go), .n(n), .fb(fb), .spr(spr), .key(key), .alp(alp),
        .fill_col(fill_col), .max_x(max_x), .max_y(max_y),
        .busy(busy), .prog(prog), .dbg_tab0(dbg_tab0),
        .cmd_valid(cmd_valid), .cmd_data(cmd_data), .cmd_ready(cmd_ready));

    // ---- core ----
    wire core_busy, error, clipped; wire [31:0] done_cnt, pix_cnt; wire [3:0] core_dbg;
    wire rd1_req, rd1_gnt, rd1_valid, rd1_last, rd2_req, rd2_gnt, rd2_valid, rd2_last;
    wire wr_req, wr_gnt, wr_valid, wr_ready, wr_last;
    wire [31:0] rd1_addr, rd2_addr, wr_addr; wire [8:0] rd1_beats, rd2_beats, wr_beats;
    wire [127:0] rd1_data, rd2_data, wr_data; wire [15:0] wr_strb;
    gfx_core u_core (.clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_data(cmd_data),
        .busy(core_busy), .done_cnt(done_cnt), .error(error), .clipped(clipped),
        .err_addr(), .pix_cnt(pix_cnt), .dbg_state(core_dbg), .dbg_tag(),
        .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_beats(rd1_beats), .rd1_gnt(rd1_gnt),
        .rd1_valid(rd1_valid), .rd1_data(rd1_data), .rd1_last(rd1_last),
        .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_beats(rd2_beats), .rd2_gnt(rd2_gnt),
        .rd2_valid(rd2_valid), .rd2_data(rd2_data), .rd2_last(rd2_last),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_beats(wr_beats), .wr_gnt(wr_gnt),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_last(wr_last));

    // ---- scanout ----
    reg [15:0] fb_stride = 1024, fb_w = H_ACT, fb_h = V_ACT;
    reg        enable = 0, fb_commit = 0; reg [31:0] fb_next = FB;
    reg  [31:0] fb_seq = 0;
    wire s_rd_req, s_rd_gnt, s_rd_valid, s_rd_last;
    wire [31:0] s_rd_addr; wire [8:0] s_rd_beats; wire [127:0] s_rd_data;
    wire [31:0] under, shown, frames, axierr, accepted;
    wire [23:0] rgb; wire de, hs, vs;
    gfx_scanout #(.H_ACT(H_ACT), .H_FP(16), .H_SYNC(8), .H_BP(8),
                  .V_ACT(V_ACT), .V_FP(2), .V_SYNC(2), .V_BP(2),
                  .RAM_AW(RAM_AW), .TILE_MODE(1), .BAND_LINES(8)) u_scan (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .preset_n(preset_n),
        .fb_base(fb), .fb_stride(fb_stride), .fb_w(fb_w), .fb_h(fb_h),
        .enable(enable), .fb_next(fb_next), .fb_seq(fb_seq), .fb_commit(fb_commit),
        .rd_req(s_rd_req), .rd_addr(s_rd_addr), .rd_beats(s_rd_beats), .rd_gnt(s_rd_gnt),
        .rd_valid(s_rd_valid), .rd_data(s_rd_data), .rd_last(s_rd_last),
        .scan_accepted(accepted), .underruns(under), .shown(shown), .axi_errors(axierr),
        .frames(frames), .lines_last(), .blanking(), .front_now(), .first_under(),
        .fetch_row_dbg(), .dbg_rd_cyc_sum(), .dbg_rd_cyc_max(), .dbg_rd_wait_max(),
        .dbg_rd_gap_max(), .dbg_pf_cnt(), .dbg_pf_stall_max(),
        .rgb(rgb), .de(de), .hs(hs), .vs(vs));

    // ---- shared gfx_mem ----
    wire m_arvalid, m_rready, m_awvalid, m_wvalid, m_bvalid, m_bready;
    wire [31:0] m_araddr, m_awaddr; wire [7:0] m_arlen, m_awlen;
    wire [127:0] m_rdata, m_wdata; wire [15:0] m_wstrb;
    wire m_rlast, m_rvalid, m_arready, m_awready, m_wready, m_wlast;
    assign m_bready = 1'b1;
    gfx_mem u_mem (.clk(clk), .rst_n(rst_n),
        .rd0_req(s_rd_req), .rd0_addr(s_rd_addr), .rd0_beats(s_rd_beats), .rd0_gnt(s_rd_gnt),
        .rd0_valid(s_rd_valid), .rd0_data(s_rd_data), .rd0_last(s_rd_last),
        .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_beats(rd1_beats), .rd1_gnt(rd1_gnt),
        .rd1_valid(rd1_valid), .rd1_data(rd1_data), .rd1_last(rd1_last),
        .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_beats(rd2_beats), .rd2_gnt(rd2_gnt),
        .rd2_valid(rd2_valid), .rd2_data(rd2_data), .rd2_last(rd2_last),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_beats(wr_beats), .wr_gnt(wr_gnt),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_valid(wr_valid), .wr_ready(wr_ready), .wr_last(wr_last),
        .rd_beats_cnt(), .wr_beats_cnt(), .rresp_err_cnt(), .bresp_err_cnt(), .dbg_state(),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(), .m_arburst(),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(2'd0), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(), .m_awburst(), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(2'd0), .m_bvalid(m_bvalid), .m_bready(m_bready));

    ddr_model_e2e #(.MEMW(8192), .FB(FB)) u_ddr (
        .clk(clk), .rst_n(rst_n),
        .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rdata(m_rdata), .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
        .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast), .s_wvalid(m_wvalid),
        .s_wready(m_wready), .s_bvalid(m_bvalid));

    // ---- reference frame & sprite ----
    localparam NS = 4;
    integer sx [0:NS-1];
    integer sy [0:NS-1];
    reg [15:0] pat [0:63];
    reg [15:0] rfb [0:32767];
    integer i, j, r, c, ty, tx;
    integer ax [0:NS-1];
    integer ay [0:NS-1];
    initial begin
        // sprite: 8x8 with every 5th pixel transparent
        for (i = 0; i < 64; i = i + 1) pat[i] = ((i % 5) == 0) ? 16'hF81F : (16'h0400 + i);
        // sprite bitmap in DDR (128 B at SPR)
        for (i = 0; i < 8; i = i + 1)
            u_ddr.mem[(SPR - FB)/16 + i] = {pat[8*i+7], pat[8*i+6], pat[8*i+5], pat[8*i+4],
                                            pat[8*i+3], pat[8*i+2], pat[8*i+1], pat[8*i+0]};
        // tile framebuffer initialised to the erase colour
        for (i = 0; i < 4096; i = i + 1) u_ddr.mem[i] = {8{16'h1082}};
        for (i = 0; i < 8; i = i + 1)
            u_ddr.mem[(SPR - FB)/16 + i] = {pat[8*i+7], pat[8*i+6], pat[8*i+5], pat[8*i+4],
                                            pat[8*i+3], pat[8*i+2], pat[8*i+1], pat[8*i+0]};
        // 4 sprites at unaligned positions, one pair overlapping on the same tile
        sx[0]= 10; sy[0]=  5; ax[0]= 8;  ay[0]= 0;
        sx[1]= 86; sy[1]= 21; ax[1]= 80; ay[1]= 16;
        sx[2]= 83; sy[2]= 19; ax[2]= 80; ay[2]= 16;   // same tile as sprite 1: order test
        sx[3]=250; sy[3]= 43; ax[3]=248; ay[3]= 40;
        // reference: erase every tile, then draw in sprite order
        for (i = 0; i < 32768; i = i + 1) rfb[i] = 16'h1082;
        for (i = 0; i < NS; i = i + 1)
            for (r = 0; r < 8; r = r + 1)
                for (c = 0; c < 8; c = c + 1)
                    if (pat[8*r + c] != 16'hF81F)
                        rfb[(ay[i]+r)*H_ACT + ax[i]+c] = pat[8*r + c];
    end

    // ---- stimulus ----
    task tile_write(input [11:0] a, input [63:0] d);
        begin
            @(negedge clk); tw_addr = a; tw_data = d; tw_we = 1;
            @(negedge clk); tw_we = 0;
        end
    endtask

    integer errs = 0, checks = 0;
    reg [23:0] exp_rgb;
    function [23:0] rgb_of(input [15:0] p);
        begin rgb_of = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]}; end
    endfunction
    integer px = 0, py = 0;
    always @(posedge pclk) begin
        if (!preset_n) begin px <= 0; py <= 0; end
        else if (de) begin
            if (frames >= 2) begin
                checks <= checks + 1;
                exp_rgb = rgb_of(rfb[py*H_ACT + px]);
                if (rgb !== exp_rgb) begin
                    if (errs < 8) $display("PIX MISMATCH got=%06x want=%06x at x=%0d y=%0d", rgb, exp_rgb, px, py);
                    errs <= errs + 1;
                end
            end
            if (px == H_ACT-1) begin px <= 0; py <= (py == V_ACT-1) ? 0 : py + 1; end
            else px <= px + 1;
        end
    end

    initial begin
        repeat (5) @(posedge clk); @(negedge clk); rst_n = 1;
        repeat (5) @(posedge pclk); @(negedge pclk); preset_n = 1;
        repeat (5) @(posedge clk); @(negedge clk);
        // table: x[10:0] y[21:11] vx[29:22](0) vy[39:32](0) transp=0
        for (i = 0; i < NS; i = i + 1)
            tile_write(i[11:0], {1'b0, 23'd0, 8'd0, 2'd0, 8'd0, sy[i][10:0], sx[i][10:0]});
        @(negedge clk); go = 1; @(negedge clk); go = 0;
        wait (!busy);
        repeat (200) @(posedge clk);
        $display("walker done: %0d commands (want %0d), core done=%0d error=%b clipped=%b",
                 prog, 2*NS, done_cnt, error, clipped);
        // enable scan-out on the tile framebuffer
        @(negedge clk); fb_next <= FB; fb_seq <= 32'd1; fb_commit <= 1;
        @(negedge clk); fb_commit <= 0; enable <= 1;
        wait (frames >= 4);
        repeat (20) @(posedge pclk);
        $display("frames=%0d under=%0d axierr=%0d checks=%0d mismatches=%0d", frames, under, axierr, checks, errs);
        if (errs == 0 && checks > H_ACT*V_ACT && prog == 2*NS && !error)
            $display("RESULT: PASS (walker->core->tile FB->scanout pixels all match)");
        else
            $display("RESULT: FAIL");
        $finish;
    end
    initial begin #5000000; $display("TIMEOUT busy=%b prog=%0d frames=%0d", busy, prog, frames); $finish; end
endmodule
`default_nettype wire
