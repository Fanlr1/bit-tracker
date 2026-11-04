// ============================================================================
// tb_scanout_tile.v -- raster vs tile scan-out comparison (P2, 2026-11-03).
//
// Same frame content is laid out TWICE in two DDR models:
//   raster : addr = FB + y*stride + x*2
//   tile   : addr = FB + (y/8)*BAND_STRIDE + (x/8)*128 + (y%8)*16 + (x%8)*2
// Two gfx_scanout instances (TILE_MODE=0 / =1) run on the same clocks and are
// fed by two identical AXI/DDR models.  The RGB/de/hs/vs streams must match
// pixel for pixel, and the tile instance must do 8x fewer read bursts.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module ddr_model #(parameter MEMW = 4096, parameter FB = 32'h0800_0000) (
    input  wire clk, input wire rst_n,
    input  wire [31:0] s_araddr,
    input  wire [7:0]  s_arlen,
    input  wire        s_arvalid,
    output reg         s_arready,
    output reg  [127:0] s_rdata,
    output reg         s_rlast,
    output reg         s_rvalid,
    input  wire        s_rready
);
    reg [127:0] mem [0:MEMW-1];
    integer i;
    initial for (i = 0; i < MEMW; i = i + 1) mem[i] = 128'd0;
    reg [31:0] base;
    reg [7:0]  len, cnt;
    reg        busy;
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
                    s_rvalid <= 1'b1;
                    s_rdata  <= mem[(base - FB) >> 4];
                    s_rlast  <= (cnt == len);
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

module tb_scanout_tile;
    reg clk = 0, pclk = 0, rst_n = 0, preset_n = 0;
    always #5   clk  = ~clk;
    always #3.4 pclk = ~pclk;

    localparam H_ACT = 512, V_ACT = 64, RAM_AW = 6;
    localparam STRIDE = H_ACT*2;             // raster row stride (bytes)
    localparam BAND_STRIDE = 8192;           // 512*8*2 = 8192, already 4K aligned
    localparam NBANDS = V_ACT/8;
    localparam FB = 32'h0800_0000;
    localparam FRAME_WORDS = (H_ACT*V_ACT*2)/16;   // 4096

    reg [31:0] fb_base = FB;
    reg [15:0] fb_stride = STRIDE;
    reg [15:0] fb_w = H_ACT, fb_h = V_ACT;
    reg        enable = 0;
    reg [31:0] fb_next = FB;
    reg [31:0] fb_seq = 0;
    reg        fb_commit = 0;

    // ---------------------------------------------------------- raster instance
    wire        r_rd_req; wire [31:0] r_rd_addr; wire [8:0] r_rd_beats;
    wire        r_rd_gnt, r_rd_valid; wire [127:0] r_rd_data; wire r_rd_last;
    wire [31:0] r_under, r_shown, r_frames; wire [10:0] r_first;
    wire [23:0] r_rgb; wire r_de, r_hs, r_vs;
    gfx_scanout #(.H_ACT(H_ACT), .H_FP(16), .H_SYNC(8), .H_BP(8),
                  .V_ACT(V_ACT), .V_FP(2), .V_SYNC(2), .V_BP(2),
                  .RAM_AW(RAM_AW), .TILE_MODE(0), .BAND_LINES(8)) u_ras (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .preset_n(preset_n),
        .fb_base(fb_base), .fb_stride(fb_stride), .fb_w(fb_w), .fb_h(fb_h),
        .enable(enable), .fb_next(fb_next), .fb_seq(fb_seq), .fb_commit(fb_commit),
        .rd_req(r_rd_req), .rd_addr(r_rd_addr), .rd_beats(r_rd_beats), .rd_gnt(r_rd_gnt),
        .rd_valid(r_rd_valid), .rd_data(r_rd_data), .rd_last(r_rd_last),
        .scan_accepted(), .underruns(r_under), .shown(r_shown), .axi_errors(),
        .frames(r_frames), .lines_last(), .blanking(), .front_now(), .first_under(r_first),
        .fetch_row_dbg(), .dbg_rd_cyc_sum(), .dbg_rd_cyc_max(), .dbg_rd_wait_max(),
        .dbg_rd_gap_max(), .dbg_pf_cnt(), .dbg_pf_stall_max(),
        .rgb(r_rgb), .de(r_de), .hs(r_hs), .vs(r_vs));

    // ------------------------------------------------------------ tile instance
    wire        t_rd_req; wire [31:0] t_rd_addr; wire [8:0] t_rd_beats;
    wire        t_rd_gnt, t_rd_valid; wire [127:0] t_rd_data; wire t_rd_last;
    wire [31:0] t_under, t_shown, t_frames; wire [10:0] t_first;
    wire [23:0] t_rgb; wire t_de, t_hs, t_vs;
    gfx_scanout #(.H_ACT(H_ACT), .H_FP(16), .H_SYNC(8), .H_BP(8),
                  .V_ACT(V_ACT), .V_FP(2), .V_SYNC(2), .V_BP(2),
                  .RAM_AW(RAM_AW), .TILE_MODE(1), .BAND_LINES(8)) u_til (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .preset_n(preset_n),
        .fb_base(fb_base), .fb_stride(fb_stride), .fb_w(fb_w), .fb_h(fb_h),
        .enable(enable), .fb_next(fb_next), .fb_seq(fb_seq), .fb_commit(fb_commit),
        .rd_req(t_rd_req), .rd_addr(t_rd_addr), .rd_beats(t_rd_beats), .rd_gnt(t_rd_gnt),
        .rd_valid(t_rd_valid), .rd_data(t_rd_data), .rd_last(t_rd_last),
        .scan_accepted(), .underruns(t_under), .shown(t_shown), .axi_errors(),
        .frames(t_frames), .lines_last(), .blanking(), .front_now(), .first_under(t_first),
        .fetch_row_dbg(), .dbg_rd_cyc_sum(), .dbg_rd_cyc_max(), .dbg_rd_wait_max(),
        .dbg_rd_gap_max(), .dbg_pf_cnt(), .dbg_pf_stall_max(),
        .rgb(t_rgb), .de(t_de), .hs(t_hs), .vs(t_vs));

    // ------------------------------------------------------------ DDR models
    wire r_m_arvalid, r_m_rready; wire [31:0] r_m_araddr; wire [7:0] r_m_arlen;
    wire [127:0] r_m_rdata; wire r_m_rlast, r_m_rvalid; wire r_m_arready;
    wire t_m_arvalid, t_m_rready; wire [31:0] t_m_araddr; wire [7:0] t_m_arlen;
    wire [127:0] t_m_rdata; wire t_m_rlast, t_m_rvalid; wire t_m_arready;

    gfx_mem u_mem_ras (.clk(clk), .rst_n(rst_n),
        .rd0_req(r_rd_req), .rd0_addr(r_rd_addr), .rd0_beats(r_rd_beats), .rd0_gnt(r_rd_gnt),
        .rd0_valid(r_rd_valid), .rd0_data(r_rd_data), .rd0_last(r_rd_last),
        .rd1_req(1'b0), .rd1_addr(32'd0), .rd1_beats(9'd1), .rd1_gnt(), .rd1_valid(), .rd1_data(), .rd1_last(),
        .rd2_req(1'b0), .rd2_addr(32'd0), .rd2_beats(9'd1), .rd2_gnt(), .rd2_valid(), .rd2_data(), .rd2_last(),
        .wr_req(1'b0), .wr_addr(32'd0), .wr_beats(5'd1), .wr_gnt(), .wr_data(128'd0), .wr_strb(16'd0),
        .wr_valid(1'b0), .wr_ready(), .wr_last(1'b0), .rd_beats_cnt(), .wr_beats_cnt(),
        .rresp_err_cnt(), .bresp_err_cnt(), .dbg_state(),
        .m_araddr(r_m_araddr), .m_arlen(r_m_arlen), .m_arsize(), .m_arburst(),
        .m_arvalid(r_m_arvalid), .m_arready(r_m_arready),
        .m_rdata(r_m_rdata), .m_rresp(2'd0), .m_rlast(r_m_rlast), .m_rvalid(r_m_rvalid), .m_rready(r_m_rready),
        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(), .m_awvalid(), .m_awready(1'b1),
        .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(), .m_wready(1'b1),
        .m_bresp(2'd0), .m_bvalid(1'b0), .m_bready());

    gfx_mem u_mem_til (.clk(clk), .rst_n(rst_n),
        .rd0_req(t_rd_req), .rd0_addr(t_rd_addr), .rd0_beats(t_rd_beats), .rd0_gnt(t_rd_gnt),
        .rd0_valid(t_rd_valid), .rd0_data(t_rd_data), .rd0_last(t_rd_last),
        .rd1_req(1'b0), .rd1_addr(32'd0), .rd1_beats(9'd1), .rd1_gnt(), .rd1_valid(), .rd1_data(), .rd1_last(),
        .rd2_req(1'b0), .rd2_addr(32'd0), .rd2_beats(9'd1), .rd2_gnt(), .rd2_valid(), .rd2_data(), .rd2_last(),
        .wr_req(1'b0), .wr_addr(32'd0), .wr_beats(5'd1), .wr_gnt(), .wr_data(128'd0), .wr_strb(16'd0),
        .wr_valid(1'b0), .wr_ready(), .wr_last(1'b0), .rd_beats_cnt(), .wr_beats_cnt(),
        .rresp_err_cnt(), .bresp_err_cnt(), .dbg_state(),
        .m_araddr(t_m_araddr), .m_arlen(t_m_arlen), .m_arsize(), .m_arburst(),
        .m_arvalid(t_m_arvalid), .m_arready(t_m_arready),
        .m_rdata(t_m_rdata), .m_rresp(2'd0), .m_rlast(t_m_rlast), .m_rvalid(t_m_rvalid), .m_rready(t_m_rready),
        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(), .m_awvalid(), .m_awready(1'b1),
        .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(), .m_wready(1'b1),
        .m_bresp(2'd0), .m_bvalid(1'b0), .m_bready());

    ddr_model #(.MEMW(FRAME_WORDS), .FB(FB)) u_ddr_ras (
        .clk(clk), .rst_n(rst_n), .s_araddr(r_m_araddr), .s_arlen(r_m_arlen),
        .s_arvalid(r_m_arvalid), .s_arready(r_m_arready), .s_rdata(r_m_rdata),
        .s_rlast(r_m_rlast), .s_rvalid(r_m_rvalid), .s_rready(r_m_rready));
    ddr_model #(.MEMW(FRAME_WORDS), .FB(FB)) u_ddr_til (
        .clk(clk), .rst_n(rst_n), .s_araddr(t_m_araddr), .s_arlen(t_m_arlen),
        .s_arvalid(t_m_arvalid), .s_arready(t_m_arready), .s_rdata(t_m_rdata),
        .s_rlast(t_m_rlast), .s_rvalid(t_m_rvalid), .s_rready(t_m_rready));

    // ---------------------------------------------------------- frame content
    function [15:0] pix(input integer x, input integer y);
        begin pix = ((x*7 + y*37 + ((x*y) & 127) + 16'h1234) & 16'hFFFF); end
    endfunction
    integer x, y, k; reg [127:0] word;
    initial begin
        for (y = 0; y < V_ACT; y = y + 1)
            for (x = 0; x < H_ACT; x = x + 8) begin
                word = 128'd0;
                for (k = 0; k < 8; k = k + 1) word[16*k +: 16] = pix(x+k, y);
                u_ddr_ras.mem[(y*STRIDE + x*2) >> 4] = word;
                u_ddr_til.mem[((y>>3)*BAND_STRIDE + (x>>3)*128 + (y&7)*16) >> 4] = word;
            end
    end

    // ------------------------------------------------------------ comparison
    integer checks = 0, errs = 0, ar_hs_ras = 0, ar_hs_til = 0, beats_ras = 0, beats_til = 0;
    reg started = 0;
    integer bad_beats_r = 0, bad_beats_t = 0, bad_align_t = 0;
    always @(posedge clk) begin
        if (r_m_arvalid && r_m_arready) begin
            ar_hs_ras <= ar_hs_ras + 1;
            if (r_rd_beats != (H_ACT/8))   bad_beats_r <= bad_beats_r + 1;
        end
        if (t_m_arvalid && t_m_arready) begin
            ar_hs_til <= ar_hs_til + 1;
            if (t_rd_beats != 9'd256)      bad_beats_t <= bad_beats_t + 1;
            if (t_rd_addr[11:0] != 12'd0)  bad_align_t <= bad_align_t + 1;
        end
        if (r_m_rvalid && r_m_rready) beats_ras <= beats_ras + 1;
        if (t_m_rvalid && t_m_rready) beats_til <= beats_til + 1;
    end
    integer px = 0, py = 0;
    always @(posedge pclk) begin
        if (!preset_n) begin px <= 0; py <= 0; end
        else if (r_de) begin
            if (px == H_ACT-1) begin px <= 0; py <= (py == V_ACT-1) ? 0 : py + 1; end
            else px <= px + 1;
        end
        if (preset_n && r_de && t_de) begin
            if (!started && r_frames >= 1 && t_frames >= 1) started <= 1;
            if (started) begin
                checks <= checks + 1;
                if (r_rgb !== t_rgb) begin
                    errs <= errs + 1;
                    if (errs < 8) $display("PIX MISMATCH raster=%06x tile=%06x at x=%0d y=%0d frame_r=%0d frame_t=%0d", r_rgb, t_rgb, px, py, r_frames, t_frames);
                end
            end
        end
    end

    // ---- tile-mode debug probe at the first line of every frame ----
    always @(posedge pclk) begin
        if (preset_n && u_til.x == 12'd0 && u_til.y == 11'd0) begin
            $display("Y0 frame=%0d epoch=%0d t_front=%h t_pf=%0d ack_tog=%b done_band=%0d done_epoch=%0d",
                     u_til.frames, u_til.epoch, u_til.t_front, u_til.t_pf_band,
                     u_til.t_ack_from_core, u_til.t_done_band_s2, u_til.t_done_epoch_s2);
            $display("   bank_ok=%b%b%b%b %b%b%b%b %b%b%b%b %b%b%b%b",
                     u_til.bank_ok[15],u_til.bank_ok[14],u_til.bank_ok[13],u_til.bank_ok[12],
                     u_til.bank_ok[11],u_til.bank_ok[10],u_til.bank_ok[9],u_til.bank_ok[8],
                     u_til.bank_ok[7],u_til.bank_ok[6],u_til.bank_ok[5],u_til.bank_ok[4],
                     u_til.bank_ok[3],u_til.bank_ok[2],u_til.bank_ok[1],u_til.bank_ok[0]);
            $display("   bank_row=%0d %0d %0d %0d %0d %0d %0d %0d",
                     u_til.bank_row[0], u_til.bank_row[1], u_til.bank_row[2], u_til.bank_row[3],
                     u_til.bank_row[4], u_til.bank_row[5], u_til.bank_row[6], u_til.bank_row[7]);
            $display("   bank_ep=%0d %0d %0d %0d", u_til.bank_epoch[0], u_til.bank_epoch[1],
                     u_til.bank_epoch[2], u_til.bank_epoch[3]);
        end
    end

    // ---------------------------------------------------------------- stimulus
    integer under0_r = 0, under0_t = 0;
    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        preset_n = 1;
        // commit the frame buffer before enabling scan-out (applied at band/row 0)
        fb_seq = 32'd1; fb_next = FB;
        @(posedge clk); fb_commit = 1'b1;
        @(posedge clk); fb_commit = 1'b0;
        repeat (5) @(posedge clk);
        enable = 1'b1;
        wait (r_frames >= 1 && t_frames >= 1);
        $display("frame1: raster under=%0d first=%0d | tile under=%0d first=%0d t_pf_band=%0d",
                 r_under, r_first, t_under, t_first, u_til.t_pf_band);
        under0_r = r_under; under0_t = t_under;
        wait (r_frames >= 3 && t_frames >= 3);
        repeat (10) @(posedge pclk);
        $display("frames raster=%0d tile=%0d  under raster=%0d tile=%0d (after warmup %0d/%0d)",
                 r_frames, t_frames, r_under, t_under, under0_r, under0_t);
        $display("read bursts raster=%0d tile=%0d | read beats raster=%0d tile=%0d",
                 ar_hs_ras, ar_hs_til, beats_ras, beats_til);
        $display("pixel stream checks=%0d mismatches=%0d", checks, errs);
        $display("burst pattern: raster beats!=%0d: %0d | tile beats!=256: %0d, tile addr misaligned: %0d",
                 H_ACT/8, bad_beats_r, bad_beats_t, bad_align_t);
        if (errs == 0 && checks >= 2*H_ACT*V_ACT - 16 && r_under == under0_r && t_under == under0_t
            && bad_beats_r == 0 && bad_beats_t == 0 && bad_align_t == 0)
            $display("RESULT: PASS (raster and tile pixel streams are byte-identical, no post-warmup underruns)");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT: raster frames=%0d tile frames=%0d under %0d/%0d checks=%0d errs=%0d",
                 r_frames, t_frames, r_under, t_under, checks, errs);
        $finish;
    end
endmodule
`default_nettype wire
