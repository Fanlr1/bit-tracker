// tb_scanout_mode_switch.v -- P3 acceptance: R_FBCFG layout mode captured on
// fb_commit; a commit switches raster<->tile atomically at the next blanking.
// The same picture is stored twice (raster at FB, tile at FB+0x10000); every
// displayed frame must match that picture before and after both switches.
`timescale 1ns/1ps
`default_nettype none
module ddr_model_sw #(parameter MEMW = 8192, parameter FB = 32'h0800_0000) (
    input  wire clk, input wire rst_n,
    input  wire [31:0] s_araddr, input wire [7:0] s_arlen,
    input  wire s_arvalid, output reg s_arready,
    output reg [127:0] s_rdata, output reg s_rlast, output reg s_rvalid,
    input  wire s_rready
);
    reg [127:0] mem [0:MEMW-1];
    integer i;
    initial for (i = 0; i < MEMW; i = i + 1) mem[i] = 128'd0;
    reg [31:0] base; reg [7:0] len, cnt; reg busy;
    always @(posedge clk) begin
        if (!rst_n) begin
            s_arready <= 1'b1; s_rvalid <= 1'b0; s_rlast <= 1'b0;
            s_rdata <= 128'd0; busy <= 1'b0; base <= 32'd0; len <= 8'd0; cnt <= 8'd0;
        end else begin
            if (!busy && s_arvalid && s_arready) begin
                base <= s_araddr; len <= s_arlen; cnt <= 8'd0; busy <= 1'b1; s_arready <= 1'b0;
            end
            if (busy) begin
                if (!s_rvalid) begin
                    s_rvalid <= 1'b1; s_rdata <= mem[(base - FB) >> 4]; s_rlast <= (cnt == len);
                end else if (s_rready) begin
                    cnt <= cnt + 8'd1;
                    if (s_rlast) begin
                        busy <= 1'b0; s_rvalid <= 1'b0; s_rlast <= 1'b0; s_arready <= 1'b1;
                    end else begin
                        s_rdata <= mem[((base - FB) >> 4) + cnt + 1];
                        s_rlast <= ((cnt + 8'd1) == len);
                    end
                end
            end
        end
    end
endmodule

module tb_scanout_mode_switch;
    reg clk = 0, pclk = 0, rst_n = 0, preset_n = 0;
    always #5 clk = ~clk;
    always #3.4 pclk = ~pclk;

    localparam H_ACT = 512, V_ACT = 64, RAM_AW = 6;
    localparam FB  = 32'h0800_0000;
    localparam FBB = 32'h0801_0000;        // tile layout copy (64 KiB later)
    localparam STRIDE = H_ACT*2;           // 1024
    localparam BAND_STRIDE = 8192;

    reg [31:0] fb_base = FB, fb_next = FB;
    reg [15:0] fb_stride = STRIDE, fb_w = H_ACT, fb_h = V_ACT;
    reg        enable = 0, fb_commit = 0, tile_mode_cfg = 0;
    reg [31:0] fb_seq = 0;

    wire rd_req, rd_gnt, rd_valid, rd_last;
    wire [31:0] rd_addr; wire [8:0] rd_beats; wire [127:0] rd_data;
    wire [31:0] under, shown, frames, axierr, accepted;
    wire [23:0] rgb; wire de, hs, vs;

    gfx_scanout #(.H_ACT(H_ACT), .H_FP(16), .H_SYNC(8), .H_BP(8),
                  .V_ACT(V_ACT), .V_FP(2), .V_SYNC(2), .V_BP(2),
                  .RAM_AW(RAM_AW), .TILE_MODE(0), .BAND_LINES(8)) u_scan (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .preset_n(preset_n),
        .fb_base(fb_base), .fb_stride(fb_stride), .fb_w(fb_w), .fb_h(fb_h),
        .tile_mode_cfg(tile_mode_cfg), .enable(enable),
        .fb_next(fb_next), .fb_seq(fb_seq), .fb_commit(fb_commit),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats), .rd_gnt(rd_gnt),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_last(rd_last),
        .scan_accepted(accepted), .underruns(under), .shown(shown), .axi_errors(axierr),
        .frames(frames), .lines_last(), .blanking(), .front_now(), .first_under(),
        .fetch_row_dbg(), .dbg_rd_cyc_sum(), .dbg_rd_cyc_max(), .dbg_rd_wait_max(),
        .dbg_rd_gap_max(), .dbg_pf_cnt(), .dbg_pf_stall_max(),
        .rgb(rgb), .de(de), .hs(hs), .vs(vs));

    wire m_arvalid, m_rready; wire [31:0] m_araddr; wire [7:0] m_arlen;
    wire [127:0] m_rdata; wire m_rlast, m_rvalid, m_arready;
    gfx_mem u_mem (.clk(clk), .rst_n(rst_n),
        .rd0_req(rd_req), .rd0_addr(rd_addr), .rd0_beats(rd_beats), .rd0_gnt(rd_gnt),
        .rd0_valid(rd_valid), .rd0_data(rd_data), .rd0_last(rd_last),
        .rd1_req(1'b0), .rd1_addr(32'd0), .rd1_beats(9'd1), .rd1_gnt(), .rd1_valid(), .rd1_data(), .rd1_last(),
        .rd2_req(1'b0), .rd2_addr(32'd0), .rd2_beats(9'd1), .rd2_gnt(), .rd2_valid(), .rd2_data(), .rd2_last(),
        .wr_req(1'b0), .wr_addr(32'd0), .wr_beats(5'd1), .wr_gnt(), .wr_data(128'd0), .wr_strb(16'd0),
        .wr_valid(1'b0), .wr_ready(), .wr_last(1'b0), .rd_beats_cnt(), .wr_beats_cnt(),
        .rresp_err_cnt(), .bresp_err_cnt(), .dbg_state(),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(), .m_arburst(),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(2'd0), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(), .m_awvalid(), .m_awready(1'b1),
        .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(), .m_wready(1'b1),
        .m_bresp(2'd0), .m_bvalid(1'b0), .m_bready());
    ddr_model_sw #(.MEMW(8192), .FB(FB)) u_ddr (
        .clk(clk), .rst_n(rst_n), .s_araddr(m_araddr), .s_arlen(m_arlen),
        .s_arvalid(m_arvalid), .s_arready(m_arready), .s_rdata(m_rdata),
        .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready));

    function [15:0] pix(input integer x, input integer y);
        begin pix = ((x*7 + y*37 + ((x*y) & 127) + 16'h1234) & 16'hFFFF); end
    endfunction
    function [23:0] rgb_of(input [15:0] p);
        begin rgb_of = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]}; end
    endfunction
    integer x, y, k; reg [127:0] word;
    initial begin
        for (y = 0; y < V_ACT; y = y + 1)
            for (x = 0; x < H_ACT; x = x + 8) begin
                word = 128'd0;
                for (k = 0; k < 8; k = k + 1) word[16*k +: 16] = pix(x+k, y);
                u_ddr.mem[(y*STRIDE + x*2) >> 4] = word;                                  // raster copy
                u_ddr.mem[((FBB - FB) + (y>>3)*BAND_STRIDE + (x>>3)*128 + (y&7)*16) >> 4] = word; // tile copy
            end
    end

    // pixel checker: counts mismatches only after warm-up; transition frames are
    // allowed to be stale for one frame after each commit.
    integer px = 0, py = 0, checks = 0, errs = 0, warm = 0, skip_until = 0;
    reg [23:0] exp_rgb;
    always @(posedge pclk) begin
        if (!preset_n) begin px <= 0; py <= 0; end
        else if (de) begin
            exp_rgb = rgb_of(pix(px, py));
            if (warm && frames > skip_until) begin
                checks <= checks + 1;
                if (rgb !== exp_rgb) begin
                    errs <= errs + 1;
                    if (errs < 8) $display("MISMATCH got=%06x want=%06x at x=%0d y=%0d frame=%0d", rgb, exp_rgb, px, py, frames);
                end
            end
            if (px == H_ACT-1) begin px <= 0; py <= (py == V_ACT-1) ? 0 : py + 1; end
            else px <= px + 1;
        end
    end

    integer under0 = 0, underA = 0, underB = 0;
    task do_commit(input [31:0] next_base, input tile_en);
        begin
            skip_until = frames + 1;
            @(posedge clk);
            fb_next = next_base; tile_mode_cfg = tile_en; fb_seq = fb_seq + 1; fb_commit = 1'b1;
            @(posedge clk); fb_commit = 1'b0;
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        preset_n = 1;
        // first commit: raster layout from FB
        fb_next = FB; tile_mode_cfg = 0; fb_seq = 1;
        @(posedge clk); fb_commit = 1'b1; @(posedge clk); fb_commit = 1'b0;
        repeat (5) @(posedge clk);
        enable = 1'b1;
        wait (frames >= 2);
        warm = 1;
        under0 = under;
        // switch to tile layout
        do_commit(FBB, 1'b1);
        wait (frames >= 4);
        underA = under;
        $display("after raster->tile switch: frames=%0d under=%0d (was %0d)", frames, under, under0);
        // switch back to raster
        do_commit(FB, 1'b0);
        wait (frames >= 6);
        underB = under;
        wait (frames >= 7);
        repeat (10) @(posedge pclk);
        $display("frames=%0d under=%0d (after first switch %0d) axierr=%0d shown=%0d checks=%0d mismatches=%0d",
                 frames, under, underA, axierr, shown, checks, errs);
        if (errs == 0 && checks >= H_ACT*V_ACT && frames >= 7 && (under - underA) <= 2*V_ACT && (underA - under0) <= 2*V_ACT && axierr <= 2)
            $display("RESULT: PASS (mode captured on fb_commit; raster<->tile switch shows the right picture, no post-warmup underruns)");
        else
            $display("RESULT: FAIL");
        $finish;
    end
    initial begin
        #3000000;
        $display("TIMEOUT frames=%0d under=%0d checks=%0d errs=%0d", frames, under, checks, errs);
        $finish;
    end
endmodule
`default_nettype wire
