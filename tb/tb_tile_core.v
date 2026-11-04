// tb_tile_core.v -- P4: prove that a 64x1 / src-stride-128 command writes one
// 8x8 tile as ONE 8-beat burst, using the *existing* gfx_core unchanged.
//   1) FILL 64x1 at tile 0 (erase)
//   2) OP_COPY_KEY_NB 64x1, src=128-byte sprite at 0x08007000 (draw)
// Checks: tile bytes == expected composed pixels, 2 AW bursts, 16 W beats,
//         1 source read burst, no errors.
`timescale 1ns/1ps
`default_nettype none
module ddr_model_core #(parameter MEMW = 4096, parameter FB = 32'h0800_0000) (
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
    // ---- read ----
    reg [31:0] rbase; reg [7:0] rlen, rcnt; reg rbusy;
    // ---- write ----
    reg [31:0] wbase; reg [7:0] wlen, wcnt; reg wbusy;
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
            // write: one AW at a time, W beats streamed with byte strobes
            if (!wbusy && s_awvalid && s_awready) begin
                wbase <= s_awaddr; wlen <= s_awlen; wcnt <= 8'd0; wbusy <= 1'b1; s_awready <= 1'b0;
            end
            if (wbusy && s_wvalid) begin
                for (i = 0; i < 16; i = i + 1)
                    if (s_wstrb[i]) mem[((wbase - FB) >> 4) + wcnt][8*i +: 8] <= s_wdata[8*i +: 8];
                wcnt <= wcnt + 8'd1;
                if (s_wlast) begin
                    wbusy <= 1'b0; s_bvalid <= 1'b1; s_awready <= 1'b1;
                end
            end else if (s_bvalid) begin
                s_bvalid <= 1'b0;
            end
        end
    end
endmodule

module tb_tile_core;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- command stream ----
    reg         cmd_valid = 0;
    wire        cmd_ready;
    reg  [351:0] cmd_data = 0;
    wire        busy, error, clipped;
    wire [31:0] done_cnt;
    wire [31:0] pix_cnt;
    wire [3:0]  dbg_state;

    wire rd1_req, rd1_gnt, rd1_valid, rd1_last;
    wire [31:0] rd1_addr; wire [8:0] rd1_beats; wire [127:0] rd1_data;
    wire rd2_req, rd2_gnt, rd2_valid, rd2_last;
    wire [31:0] rd2_addr; wire [8:0] rd2_beats; wire [127:0] rd2_data;
    wire wr_req, wr_gnt, wr_valid, wr_ready, wr_last;
    wire [31:0] wr_addr; wire [8:0] wr_beats; wire [127:0] wr_data; wire [15:0] wr_strb;

    gfx_core u_core (.clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_data(cmd_data),
        .busy(busy), .done_cnt(done_cnt), .error(error), .clipped(clipped),
        .err_addr(), .pix_cnt(pix_cnt), .dbg_state(dbg_state), .dbg_tag(),
        .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_beats(rd1_beats), .rd1_gnt(rd1_gnt),
        .rd1_valid(rd1_valid), .rd1_data(rd1_data), .rd1_last(rd1_last),
        .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_beats(rd2_beats), .rd2_gnt(rd2_gnt),
        .rd2_valid(rd2_valid), .rd2_data(rd2_data), .rd2_last(rd2_last),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_beats(wr_beats), .wr_gnt(wr_gnt),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_valid(wr_valid), .wr_ready(wr_ready),
        .wr_last(wr_last));

    wire m_arvalid, m_rready, m_awvalid, m_wvalid, m_bvalid, m_bready;
    wire [31:0] m_araddr, m_awaddr; wire [7:0] m_arlen, m_awlen;
    wire [127:0] m_rdata, m_wdata; wire [15:0] m_wstrb;
    wire m_rlast, m_rvalid, m_arready, m_awready, m_wready, m_wlast;
    assign m_bready = 1'b1;

    gfx_mem u_mem (.clk(clk), .rst_n(rst_n),
        .rd0_req(1'b0), .rd0_addr(32'd0), .rd0_beats(9'd1), .rd0_gnt(), .rd0_valid(), .rd0_data(), .rd0_last(),
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

    ddr_model_core #(.MEMW(4096), .FB(32'h0800_0000)) u_ddr (
        .clk(clk), .rst_n(rst_n),
        .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rdata(m_rdata), .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
        .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast), .s_wvalid(m_wvalid),
        .s_wready(m_wready), .s_bvalid(m_bvalid));

    // ---- write-beat trace ----
    integer wtr = 0;
    always @(posedge clk) begin
        if (wr_valid && wr_ready && wtr < 20) begin
            wtr = wtr + 1;
            $display("WRBEAT %0d: pixj=%0d wr_addr=%h data0=%h strb=%h", wtr, u_core.pixj,
                     wr_addr, wr_data[15:0], wr_strb);
        end
        if (wr_req && wtr == 0) $display("WR_REQ acks? req=%b gnt=%b pixj=%0d", wr_req, wr_gnt, u_core.pixj);
    end
    // ---- counters ----
    integer aw_hs = 0, wbeats = 0, ar_hs = 0;
    reg [31:0] aw0, aw1; reg [7:0] awlen0, awlen1;
    always @(posedge clk) begin
        if (m_awvalid && m_awready) begin
            if (aw_hs == 0) begin aw0 <= m_awaddr; awlen0 <= m_awlen; end
            else begin aw1 <= m_awaddr; awlen1 <= m_awlen; end
            aw_hs <= aw_hs + 1;
        end
        if (m_wvalid && m_wready)  wbeats <= wbeats + 1;
        if (m_arvalid && m_arready) ar_hs <= ar_hs + 1;
    end

    // ---- sprite pattern: 8x8, every 5th pixel is the key colour ----
    localparam SRC = 32'h0800_7000;
    localparam DST = 32'h0800_0000;
    reg [15:0] pat [0:63];
    integer i;
    initial begin
        for (i = 0; i < 64; i = i + 1)
            pat[i] = ((i % 5) == 0) ? 16'hF81F : (16'h0400 + i);
        for (i = 0; i < 64; i = i + 1) begin
            u_ddr.mem[(SRC - 32'h0800_0000)/16 + i/8][16*(i%8) +: 16] = pat[i];
        end
        for (i = 0; i < 4096; i = i + 1)  // solid background everywhere else
            u_ddr.mem[i] = {8{16'h1082}};
        for (i = 0; i < 64; i = i + 1)
            u_ddr.mem[(SRC - 32'h0800_0000)/16 + i/8][16*(i%8) +: 16] = pat[i];
    end

    function [351:0] mk_cmd;
        input [31:0] op, src, dst;
        input [15:0] w, h, ss, ds, col;
        begin
            mk_cmd = 352'd0;
            mk_cmd[351:320] = op;
            mk_cmd[319:288] = src;
            mk_cmd[287:256] = dst;
            mk_cmd[255:240] = h;
            mk_cmd[239:224] = w;
            mk_cmd[207:192] = ss;
            mk_cmd[175:160] = ds;
            mk_cmd[143:128] = col;
            mk_cmd[79:64]   = 16'hF81F;
        end
    endfunction

    task send_cmd(input [351:0] c);
        begin
            @(negedge clk); cmd_data = c; cmd_valid = 1;
            @(posedge clk); while (!cmd_ready) @(posedge clk);
            @(negedge clk); cmd_valid = 0;
        end
    endtask

    integer errs = 0;
    reg [15:0] got, want;
    initial begin
        repeat (5) @(posedge clk); @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk); @(negedge clk);
        send_cmd(mk_cmd(32'd0, 32'd0, DST, 16'd64, 16'd1, 16'd16, 16'd16, 16'h1082));  // FILL tile
        wait (done_cnt == 1);
        send_cmd(mk_cmd(32'd6, SRC, DST, 16'd64, 16'd1, 16'd128, 16'd16, 16'h0000));     // COPY_KEY_NB tile
        wait (done_cnt == 2);
        repeat (20) @(posedge clk);
        for (i = 0; i < 64; i = i + 1) begin
            got  = u_ddr.mem[(DST - 32'h0800_0000)/16 + i/8][16*(i%8) +: 16];
            want = (pat[i] == 16'hF81F) ? 16'h1082 : pat[i];
            if (got !== want) begin
                if (errs < 8) $display("PIX %0d got=%h want=%h", i, got, want);
                errs = errs + 1;
            end
        end
        $display("tile content: %0d/64 pixels mismatched", errs);
        $display("AXI: AW bursts=%0d (want 2), W beats=%0d (want 16), AR bursts=%0d (want 1)",
                 aw_hs, wbeats, ar_hs);
        $display("AW0 addr=%h len=%0d | AW1 addr=%h len=%0d", aw0, awlen0, aw1, awlen1);
        for (i = 0; i < 8; i = i + 1)
            $display("mem[S]%0d=%h mem[D]%0d=%h", i,
                     u_ddr.mem[(SRC-32'h0800_0000)/16+i], i, u_ddr.mem[(DST-32'h0800_0000)/16+i]);
        for (i = 0; i < 8; i = i + 1)
            $display("spx[%0d]=%h opx[%0d]=%h", i, u_core.spx[i], i, u_core.opx[i]);
        if (errs == 0 && aw_hs == 2 && wbeats == 16 && ar_hs == 1 && !error && !clipped)
            $display("RESULT: PASS (64x1 tile op = single 8-beat burst, pixels exact)");
        else
            $display("RESULT: FAIL");
        $finish;
    end
    initial begin #500000; $display("TIMEOUT done=%0d", done_cnt); $finish; end
endmodule
`default_nettype wire
