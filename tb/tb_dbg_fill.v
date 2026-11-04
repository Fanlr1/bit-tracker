`timescale 1ns/1ps
`default_nettype none
module tb_dbg_fill;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire [351:0] cmd = {32'd0, 32'd0, 32'h0800_0000, {16'd64, 16'd64}, 32'd0, 32'd4096,
                        32'h0000_F800, 32'd255, 32'd0, 32'd0, 32'd0};
    reg cmd_valid = 0;
    wire cmd_ready;

    wire busy, error, clipped;
    wire [31:0] done, erra, pixc;
    wire [3:0] core_dbg;

    wire rd1_req, rd1_gnt, rd1_valid, rd1_last;
    wire [31:0] rd1_addr;
    wire [4:0] rd1_beats;
    wire [127:0] rd1_data;
    wire rd2_req, rd2_gnt, rd2_valid, rd2_last;
    wire [31:0] rd2_addr;
    wire [4:0] rd2_beats;
    wire [127:0] rd2_data;
    wire wr_req, wr_gnt, wr_valid, wr_ready, wr_last;
    wire [31:0] wr_addr;
    wire [4:0] wr_beats;
    wire [127:0] wr_data;
    wire [15:0] wr_strb;

    gfx_core u_core (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_data(cmd),
        .busy(busy), .done_cnt(done), .error(error), .clipped(clipped),
        .err_addr(erra), .pix_cnt(pixc), .dbg_state(core_dbg),
        .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_beats(rd1_beats), .rd1_gnt(rd1_gnt),
        .rd1_valid(rd1_valid), .rd1_data(rd1_data), .rd1_last(rd1_last),
        .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_beats(rd2_beats), .rd2_gnt(rd2_gnt),
        .rd2_valid(rd2_valid), .rd2_data(rd2_data), .rd2_last(rd2_last),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_beats(wr_beats), .wr_gnt(wr_gnt),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_valid(wr_valid),
        .wr_ready(wr_ready), .wr_last(wr_last)
    );

    wire [31:0] m_araddr;
    wire [7:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst;
    wire        m_arvalid;
    reg         m_arready = 1;
    reg  [127:0] m_rdata = 0;
    reg  [1:0]  m_rresp = 0;
    reg         m_rlast = 0;
    reg         m_rvalid = 0;
    wire        m_rready;
    wire [31:0] m_awaddr;
    wire [7:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst;
    wire        m_awvalid;
    reg         m_awready = 1;
    wire [127:0] m_wdata;
    wire [15:0] m_wstrb;
    wire        m_wlast, m_wvalid;
    reg         m_wready = 0;
    reg  [1:0]  m_bresp = 0;
    reg         m_bvalid = 0;
    wire        m_bready;
    wire [7:0]  mem_dbg;

    gfx_mem u_mem (
        .clk(clk), .rst_n(rst_n),
        .rd0_req(1'b0), .rd0_addr(32'd0), .rd0_beats(5'd1), .rd0_gnt(),
        .rd0_valid(), .rd0_data(), .rd0_last(),
        .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_beats(rd1_beats), .rd1_gnt(rd1_gnt),
        .rd1_valid(rd1_valid), .rd1_data(rd1_data), .rd1_last(rd1_last),
        .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_beats(rd2_beats), .rd2_gnt(rd2_gnt),
        .rd2_valid(rd2_valid), .rd2_data(rd2_data), .rd2_last(rd2_last),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_beats(wr_beats), .wr_gnt(wr_gnt),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_valid(wr_valid),
        .wr_ready(wr_ready), .wr_last(wr_last),
        .rd_beats_cnt(), .wr_beats_cnt(), .rresp_err_cnt(), .bresp_err_cnt(),
        .dbg_state(mem_dbg),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready)
    );

    // simple write-only slave
    reg [4:0] got;
    always @(posedge clk) begin
        if (!rst_n) begin
            m_awready <= 1; m_wready <= 0; m_bvalid <= 0; got <= 0;
        end else begin
            if (m_awvalid && m_awready) begin
                m_awready <= 0; m_wready <= 1;
                $display("t=%0t AW accepted addr=%h len=%0d", $time, m_awaddr, m_awlen);
            end
            if (m_wvalid && m_wready) begin
                got <= got + 1;
                $display("t=%0t W beat %0d last=%b strb=%h", $time, got, m_wlast, m_wstrb);
                if (m_wlast) begin m_wready <= 0; m_bvalid <= 1; end
            end
            if (m_bvalid && m_bready) begin
                m_bvalid <= 0; m_awready <= 1;
                $display("t=%0t B done", $time);
            end
        end
    end

    integer k;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        @(negedge clk);
        cmd_valid = 1;
        @(negedge clk);
        cmd_valid = 0;
        for (k = 0; k < 120; k = k + 1) begin
            @(posedge clk);
            if (k < 40 || (k % 10) == 0)
                $display("t=%0t core=%0d mem=%b wr_req=%b wr_valid=%b wr_ready=%b wfwp=%0d wfrp=%0d",
                         $time, core_dbg, mem_dbg, wr_req, wr_valid, wr_ready,
                         u_mem.wf_wp, u_mem.wf_rp);
        end
        $display("done_cnt=%0d busy=%b", done, busy);
        $finish;
    end
endmodule
`default_nettype wire
