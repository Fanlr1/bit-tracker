// Scan-out testbench: line banks, epoch flips, underrun accounting, and a
// pixel-exact comparison of what reaches the encoder against the DDR model.
// Small geometry (64x48) so several frames fit in a short simulation.
`timescale 1ns/1ps
`default_nettype none

module tb_gfx_scanout;
    reg clk = 0;
    reg pclk = 0;
    reg rst_n = 0;
    reg preset_n = 0;
    always #5   clk  = ~clk;
    always #3.4 pclk = ~pclk;

    localparam H_ACT = 64;
    localparam V_ACT = 48;
    localparam STRIDE = 128;
    localparam RAM_AW = 4;

    // scan-out configuration
    reg [31:0] fb_base = 32'h0800_0000;
    reg [15:0] fb_stride = STRIDE;
    reg [15:0] fb_w = H_ACT;
    reg [15:0] fb_h = V_ACT;
    reg        enable = 0;
    reg [31:0] fb_next = 32'h0800_0000;
    reg [31:0] fb_seq = 0;
    reg        fb_commit = 0;

    wire        rd_req;
    wire [31:0] rd_addr;
    wire [8:0]  rd_beats;
    wire        rd_gnt;
    wire        rd_valid;
    wire [127:0] rd_data;
    wire        rd_last;

    wire [31:0] scan_accepted;
    wire [31:0] underruns;
    wire [31:0] shown;
    wire [31:0] axi_errors;
    wire [31:0] frames;
    wire [15:0] lines_last;
    wire        blanking;

    wire [23:0] rgb;
    wire        de, hs, vs;

    gfx_scanout #(
        .H_ACT(H_ACT), .H_FP(16), .H_SYNC(8), .H_BP(8),
        .V_ACT(V_ACT), .V_FP(2), .V_SYNC(2), .V_BP(2),
        .RAM_AW(RAM_AW)
    ) u_scan (
        .clk(clk), .rst_n(rst_n), .pclk(pclk), .preset_n(preset_n),
        .fb_base(fb_base), .fb_stride(fb_stride), .fb_w(fb_w), .fb_h(fb_h),
        .enable(enable), .fb_next(fb_next), .fb_seq(fb_seq), .fb_commit(fb_commit),
        .rd_req(rd_req), .rd_addr(rd_addr), .rd_beats(rd_beats), .rd_gnt(rd_gnt),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_last(rd_last),
        .scan_accepted(scan_accepted), .underruns(underruns), .shown(shown),
        .axi_errors(axi_errors), .frames(frames), .lines_last(lines_last),
        .blanking(blanking), .front_now(), .fetch_row_dbg(), .first_under(),
        .rgb(rgb), .de(de), .hs(hs), .vs(vs)
    );

    // ---------------- single read client on gfx_mem ----------------
    gfx_mem u_mem (
        .clk(clk), .rst_n(rst_n),
        .rd0_req(rd_req), .rd0_addr(rd_addr), .rd0_beats(rd_beats), .rd0_gnt(rd_gnt),
        .rd0_valid(rd_valid), .rd0_data(rd_data), .rd0_last(rd_last),
        .rd1_req(1'b0), .rd1_addr(32'd0), .rd1_beats(5'd1), .rd1_gnt(),
        .rd1_valid(), .rd1_data(), .rd1_last(),
        .rd2_req(1'b0), .rd2_addr(32'd0), .rd2_beats(5'd1), .rd2_gnt(),
        .rd2_valid(), .rd2_data(), .rd2_last(),
        .wr_req(1'b0), .wr_addr(32'd0), .wr_beats(5'd1), .wr_gnt(),
        .wr_data(128'd0), .wr_strb(16'd0), .wr_valid(1'b0), .wr_ready(), .wr_last(1'b0),
        .rd_beats_cnt(), .wr_beats_cnt(), .rresp_err_cnt(), .bresp_err_cnt(),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(), .m_awvalid(), .m_awready(1'b0),
        .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(), .m_wready(1'b0),
        .m_bresp(2'd0), .m_bvalid(1'b0), .m_bready()
    );

    wire [31:0]  m_araddr;
    wire [7:0]   m_arlen;
    wire [2:0]   m_arsize;
    wire [1:0]   m_arburst;
    wire         m_arvalid;
    reg          m_arready;
    reg  [127:0] m_rdata;
    reg  [1:0]   m_rresp;
    reg          m_rlast;
    reg          m_rvalid;
    wire         m_rready;

    // ---------------- DDR model: 64 KiB at 0x0800_0000 ----------------
    localparam MEM_WORDS = 4096;
    reg [127:0] mem [0:MEM_WORDS-1];

    integer i, j;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1)
            for (j = 0; j < 8; j = j + 1)
                mem[i][16*j +: 16] = 16'h1000 + ((i*8 + j) & 16'h0FFF);
        // second page is a different pattern so a flip is unmistakable
        for (i = (32'h0800_8000 - 32'h0800_0000) >> 4;
             i < ((32'h0800_8000 - 32'h0800_0000) >> 4) + (V_ACT*STRIDE/16); i = i + 1)
            for (j = 0; j < 8; j = j + 1)
                mem[i][16*j +: 16] = 16'h2000 + ((i*8 + j) & 16'h0FFF);
    end

    reg [31:0] rd_base;
    reg [7:0]  rd_len, rd_cnt;
    reg        rd_busy;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_arready <= 1'b1;
            m_rvalid  <= 1'b0;
            m_rlast   <= 1'b0;
            m_rdata   <= 128'd0;
            m_rresp   <= 2'd0;
            rd_busy   <= 1'b0;
            rd_cnt    <= 8'd0;
            rd_base   <= 32'd0;
            rd_len    <= 8'd0;
        end else begin
            if (m_arvalid && m_arready) begin
                rd_base   <= m_araddr;
                rd_len    <= m_arlen;
                rd_cnt    <= 8'd0;
                rd_busy   <= 1'b1;
                m_arready <= 1'b0;
            end
            if (rd_busy) begin
                if (!m_rvalid) begin
                    m_rvalid <= 1'b1;
                    m_rdata  <= mem[((rd_base - 32'h0800_0000) >> 4) + rd_cnt];
                    m_rlast  <= (rd_cnt == rd_len);
                    m_rresp  <= 2'd0;
                end else if (m_rready) begin
                    rd_cnt <= rd_cnt + 8'd1;
                    if (m_rlast) begin
                        rd_busy   <= 1'b0;
                        m_rvalid  <= 1'b0;
                        m_rlast   <= 1'b0;
                        m_arready <= 1'b1;
                    end else begin
                        m_rdata <= mem[((rd_base - 32'h0800_0000) >> 4) + rd_cnt + 1];
                        m_rlast <= ((rd_cnt + 1) == rd_len);
                    end
                end
            end
        end
    end

    // ---------------- checker ----------------
    integer errors = 0;
    integer tx = 0, ty = 0;
    integer frame_no = 0;
    integer checked = 0;

    function [15:0] mem_px(input [31:0] addr);
        reg [127:0] w;
        begin
            w = mem[(addr - 32'h0800_0000) >> 4];
            mem_px = w[((addr >> 1) & 7)*16 +: 16];
        end
    endfunction

    task check_px(input [31:0] addr);
        reg [15:0] e16;
        reg [23:0] e24;
        begin
            e16 = mem_px(addr);
            e24 = {e16[15:11], e16[15:13], e16[10:5], e16[10:9], e16[4:0], e16[4:2]};
            if (rgb !== e24) begin
                if (errors < 12)
                    $display("FAIL pixel x=%0d y=%0d got=%06x want=%06x", tx, ty, rgb, e24);
                errors = errors + 1;
            end
            checked = checked + 1;
        end
    endtask

    reg [31:0] cur_front;
    reg        in_line = 0;
    reg        check_en = 1;

    always @(posedge pclk) begin
        if (!preset_n) begin
            tx <= 0; ty <= 0; frame_no <= 0; in_line <= 0;
        end else begin
            if (de) begin
                if (frame_no >= 2 && check_en)
                    check_px(cur_front + ty*STRIDE + tx*2);
                tx <= tx + 1;
                in_line <= 1;
            end else if (in_line) begin
                tx <= 0;
                in_line <= 0;
                if (ty == V_ACT-1) begin
                    ty <= 0;
                    frame_no <= frame_no + 1;
                end else begin
                    ty <= ty + 1;
                end
            end
        end
    end

    integer k;
    reg [31:0] u_before;

    initial begin
        $dumpfile("tb_gfx_scanout.vcd");
        $dumpvars(0, tb_gfx_scanout);
        cur_front = 32'h0800_0000;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);
        preset_n = 1;

        enable = 1;
        repeat (5) @(posedge clk);

        // let a couple of frames run
        wait (frame_no >= 2);
        u_before = underruns;
        wait (frame_no >= 4);

        // after the pipeline is warm, no line may underrun
        if (underruns != u_before) begin
            $display("FAIL: underruns still growing after warm-up (%0d -> %0d)",
                     u_before, underruns);
            errors = errors + 1;
        end
        if (shown == 0) begin
            $display("FAIL: no complete frame reported");
            errors = errors + 1;
        end

        // ---- page flip ----
        @(posedge clk);
        fb_next   = 32'h0800_8000;
        fb_seq    = 32'd7;
        fb_commit = 1'b1;
        @(posedge clk);
        fb_commit = 1'b0;

        // The flip takes effect at the next frame-start fetch; the frame that
        // straddles the flip is a legitimate transition, so stop comparing
        // pixels until two full frames have used the new page.
        check_en = 0;
        wait (scan_accepted == 32'd7);
        $display("accepted after flip: %0d", scan_accepted);
        wait (frames >= 32'd6);
        cur_front = 32'h0800_8000;
        check_en  = 1;

        wait (frames >= 32'd9);

        if (checked == 0) begin
            $display("FAIL: no pixels were checked");
            errors = errors + 1;
        end

        repeat (10) @(posedge clk);
        if (errors == 0) $display("RESULT: PASS (%0d pixels checked)", checked);
        else             $display("RESULT: FAILED errors=%0d", errors);
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT: tb_gfx_scanout");
        $finish;
    end

endmodule

`default_nettype wire
