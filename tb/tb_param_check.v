`timescale 1ns/1ps
module tb_param_check;
    reg clk = 0, pclk = 0, rst_n = 0, preset_n = 0;
    always #5 clk = ~clk;
    always #3.4 pclk = ~pclk;
    wire rd_req, rd_gnt, rd_valid, rd_last;
    wire [31:0] rd_addr; wire [8:0] rd_beats; wire [127:0] rd_data;
    wire [31:0] under, shown, frames;
    wire [23:0] rgb; wire de, hs, vs;
    gfx_scanout #(.H_ACT(1920), .H_FP(88), .H_SYNC(44), .H_BP(148),
                  .V_ACT(1080), .V_FP(4), .V_SYNC(5), .V_BP(36),
                  .RAM_AW(8), .TILE_MODE(1), .BAND_LINES(8)) u_dut (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .preset_n(preset_n),
        .fb_base(32'h0800_0000), .fb_stride(16'd4096), .fb_w(16'd1920), .fb_h(16'd1080),
        .enable(1'b0), .fb_next(32'h0800_0000), .fb_seq(32'd0), .fb_commit(1'b0),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats), .rd_gnt(1'b0),
        .rd_valid(1'b0), .rd_data(128'd0), .rd_last(1'b0),
        .scan_accepted(), .underruns(under), .shown(shown), .axi_errors(),
        .frames(frames), .lines_last(), .blanking(), .front_now(), .first_under(),
        .fetch_row_dbg(), .dbg_rd_cyc_sum(), .dbg_rd_cyc_max(), .dbg_rd_wait_max(),
        .dbg_rd_gap_max(), .dbg_pf_cnt(), .dbg_pf_stall_max(), .rgb(rgb), .de(de), .hs(hs), .vs(vs));
    initial begin
        $display("1920x1080 tile localparams: BAND_BEATS=%0d BAND_DATA=%0d BAND_STRIDE=%0d NBANDS=%0d T_BURSTS=%0d LAST_BEATS=%0d", u_dut.BAND_BEATS, u_dut.BAND_DATA, u_dut.BAND_STRIDE, u_dut.NBANDS, u_dut.T_BURSTS, u_dut.T_LAST_BEATS);
        $finish;
    end
endmodule
