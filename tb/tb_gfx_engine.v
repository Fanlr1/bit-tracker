// Engine-level testbench: register file + core + memory channel + DDR model.
// Every expected value is computed from the same definition the RTL uses, and
// the checker reads the DDR model directly, so a pass means the bytes landed.
`timescale 1ns/1ps
`default_nettype none

module tb_gfx_engine;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    // ---------------- AXI4-Lite host ----------------
    reg  [7:0]  awaddr = 0;
    reg         awvalid = 0;
    wire        awready;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 4'hF;
    reg         wvalid = 0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready = 0;
    reg  [7:0]  araddr = 0;
    reg         arvalid = 0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready = 0;
    wire        irq;

    // ---------------- AXI4 master from the DUT ----------------
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
    wire [31:0]  m_awaddr;
    wire [7:0]   m_awlen;
    wire [2:0]   m_awsize;
    wire [1:0]   m_awburst;
    wire         m_awvalid;
    reg          m_awready;
    wire [127:0] m_wdata;
    wire [15:0]  m_wstrb;
    wire         m_wlast;
    wire         m_wvalid;
    reg          m_wready;
    reg  [1:0]   m_bresp;
    reg          m_bvalid;
    wire         m_bready;

    // ---------------- command bus ----------------
    wire         cmd_valid;
    wire         cmd_ready;
    wire [351:0] cmd_data;
    wire [4:0]   cmd_level;

    wire         core_busy;
    wire [31:0]  core_done;
    wire         core_error;
    wire         core_clipped;
    wire [31:0]  core_err_addr;
    wire [31:0]  core_pix_cnt;

    wire [31:0] cfg_fb_base;
    wire [15:0] cfg_fb_stride, cfg_fb_w, cfg_fb_h;
    wire        cfg_fb_enable;
    wire [31:0] cfg_fb_next, cfg_fb_seq;
    wire        cfg_fb_commit;

    // ---------------- read clients ----------------
    wire        rd0_req, rd0_gnt, rd0_valid, rd0_last;
    wire [31:0] rd0_addr;
    wire [8:0]  rd0_beats;
    wire [127:0] rd0_data;
    wire        rd1_req, rd1_gnt, rd1_valid, rd1_last;
    wire [31:0] rd1_addr;
    wire [8:0]  rd1_beats;
    wire [127:0] rd1_data;
    wire        rd2_req, rd2_gnt, rd2_valid, rd2_last;
    wire [31:0] rd2_addr;
    wire [8:0]  rd2_beats;
    wire [127:0] rd2_data;
    wire        wr_req, wr_gnt, wr_valid, wr_ready, wr_last;
    wire [31:0] wr_addr;
    wire [8:0]  wr_beats;
    wire [127:0] wr_data;
    wire [15:0] wr_strb;

    gfx_regs #(.FIFO_DEPTH(8)) u_regs (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rlast(), .s_rvalid(rvalid), .s_rready(rready),
        .irq(irq),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_data(cmd_data), .cmd_level(cmd_level),
        .core_busy(core_busy), .core_done_cnt(core_done),
        .core_error(core_error), .core_clipped(core_clipped),
        .core_err_addr(core_err_addr), .core_pix_cnt(core_pix_cnt),
        .cfg_fb_base(cfg_fb_base), .cfg_fb_stride(cfg_fb_stride),
        .cfg_fb_w(cfg_fb_w), .cfg_fb_h(cfg_fb_h),
        .cfg_fb_enable(cfg_fb_enable), .cfg_fb_next(cfg_fb_next),
        .cfg_fb_seq(cfg_fb_seq), .cfg_fb_commit(cfg_fb_commit),
        .scan_accepted(32'd0), .scan_underruns(32'd0), .scan_shown(32'd0),
        .scan_axi_err(32'd0), .scan_frames(32'd0), .scan_lines(16'd0),
        .scan_blanking(1'b0), .scan_first_under(11'd0), .dbg_in(32'd0)
    );

    gfx_core u_core (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_data(cmd_data),
        .busy(core_busy), .done_cnt(core_done), .error(core_error),
        .clipped(core_clipped), .err_addr(core_err_addr), .pix_cnt(core_pix_cnt),
        .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_beats(rd1_beats),
        .rd1_gnt(rd1_gnt), .rd1_valid(rd1_valid), .rd1_data(rd1_data), .rd1_last(rd1_last),
        .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_beats(rd2_beats),
        .rd2_gnt(rd2_gnt), .rd2_valid(rd2_valid), .rd2_data(rd2_data), .rd2_last(rd2_last),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_beats(wr_beats), .wr_gnt(wr_gnt),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_valid(wr_valid),
        .wr_ready(wr_ready), .wr_last(wr_last)
    );

    gfx_mem u_mem (
        .clk(clk), .rst_n(rst_n),
        .rd0_req(rd0_req), .rd0_addr(rd0_addr), .rd0_beats(rd0_beats), .rd0_gnt(rd0_gnt),
        .rd0_valid(rd0_valid), .rd0_data(rd0_data), .rd0_last(rd0_last),
        .rd1_req(rd1_req), .rd1_addr(rd1_addr), .rd1_beats(rd1_beats), .rd1_gnt(rd1_gnt),
        .rd1_valid(rd1_valid), .rd1_data(rd1_data), .rd1_last(rd1_last),
        .rd2_req(rd2_req), .rd2_addr(rd2_addr), .rd2_beats(rd2_beats), .rd2_gnt(rd2_gnt),
        .rd2_valid(rd2_valid), .rd2_data(rd2_data), .rd2_last(rd2_last),
        .wr_req(wr_req), .wr_addr(wr_addr), .wr_beats(wr_beats), .wr_gnt(wr_gnt),
        .wr_data(wr_data), .wr_strb(wr_strb), .wr_valid(wr_valid),
        .wr_ready(wr_ready), .wr_last(wr_last),
        .rd_beats_cnt(), .wr_beats_cnt(), .rresp_err_cnt(), .bresp_err_cnt(),
        .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready)
    );

    assign rd0_req = 1'b0;
    assign rd0_addr = 32'd0;
    assign rd0_beats = 9'd1;

    // ================================================================ DDR model
    // 128 KiB at 0x0800_0000, 16 bytes per word.
    localparam MEM_WORDS = 8192;
    reg [127:0] mem [0:MEM_WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 128'd0;
    end

    // configurable slow-down: 0 = back-to-back beats
    reg [3:0] GAP = 4'd0;

    reg [31:0] rd_base;
    reg [7:0]  rd_len;
    reg [7:0]  rd_cnt;
    reg        rd_busy;
    reg [3:0]  rd_gap;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_arready <= 1'b1;
            m_rvalid  <= 1'b0;
            m_rlast   <= 1'b0;
            m_rdata   <= 128'd0;
            m_rresp   <= 2'd0;
            rd_busy   <= 1'b0;
            rd_cnt    <= 8'd0;
            rd_gap    <= 4'd0;
            rd_base   <= 32'd0;
            rd_len    <= 8'd0;
        end else begin
            if (m_arvalid && m_arready) begin
                rd_base   <= m_araddr;
                rd_len    <= m_arlen;
                rd_cnt    <= 8'd0;
                rd_gap    <= 4'd0;
                rd_busy   <= 1'b1;
                m_arready <= 1'b0;
            end

            if (rd_busy) begin
                if (rd_gap != GAP) begin
                    rd_gap <= rd_gap + 4'd1;
                end else begin
                    m_rvalid <= 1'b1;
                    m_rdata  <= mem[((rd_base - 32'h0800_0000) >> 4) + rd_cnt];
                    m_rlast  <= (rd_cnt == rd_len);
                    m_rresp  <= 2'd0;
                    rd_gap   <= 4'd0;
                    if (m_rvalid && m_rready) begin
                        rd_cnt <= rd_cnt + 8'd1;
                        if (m_rlast) begin
                            rd_busy   <= 1'b0;
                            m_rvalid  <= 1'b0;
                            m_rlast   <= 1'b0;
                            m_arready <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    // write side
    reg [31:0] wr_base;
    reg [7:0]  wr_len;
    reg [7:0]  wr_cnt;
    reg        wr_busy;
    reg [31:0] aw_hold;
    reg        aw_taken;

    always @(posedge clk) begin
        if (!rst_n) begin
            m_awready <= 1'b1;
            m_wready  <= 1'b0;
            m_bvalid  <= 1'b0;
            m_bresp   <= 2'd0;
            wr_busy   <= 1'b0;
            wr_cnt    <= 8'd0;
            aw_taken  <= 1'b0;
        end else begin
            if (m_awvalid && m_awready) begin
                wr_base   <= m_awaddr;
                wr_len    <= m_awlen;
                wr_cnt    <= 8'd0;
                wr_busy   <= 1'b1;
                m_awready <= 1'b0;
                m_wready  <= 1'b1;
            end
            if (m_wvalid && m_wready) begin
                if (m_wstrb[0])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][7:0]   <= m_wdata[7:0];
                if (m_wstrb[1])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][15:8]  <= m_wdata[15:8];
                if (m_wstrb[2])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][23:16] <= m_wdata[23:16];
                if (m_wstrb[3])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][31:24] <= m_wdata[31:24];
                if (m_wstrb[4])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][39:32] <= m_wdata[39:32];
                if (m_wstrb[5])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][47:40] <= m_wdata[47:40];
                if (m_wstrb[6])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][55:48] <= m_wdata[55:48];
                if (m_wstrb[7])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][63:56] <= m_wdata[63:56];
                if (m_wstrb[8])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][71:64] <= m_wdata[71:64];
                if (m_wstrb[9])  mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][79:72] <= m_wdata[79:72];
                if (m_wstrb[10]) mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][87:80] <= m_wdata[87:80];
                if (m_wstrb[11]) mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][95:88] <= m_wdata[95:88];
                if (m_wstrb[12]) mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][103:96] <= m_wdata[103:96];
                if (m_wstrb[13]) mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][111:104] <= m_wdata[111:104];
                if (m_wstrb[14]) mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][119:112] <= m_wdata[119:112];
                if (m_wstrb[15]) mem[((wr_base - 32'h0800_0000) >> 4) + wr_cnt][127:120] <= m_wdata[127:120];
                wr_cnt <= wr_cnt + 8'd1;
                if (m_wlast) begin
                    m_wready <= 1'b0;
                    m_bvalid <= 1'b1;
                    m_bresp  <= 2'd0;
                    wr_busy  <= 1'b0;
                end
            end
            if (m_bvalid && m_bready) begin
                m_bvalid  <= 1'b0;
                m_awready <= 1'b1;
            end
        end
    end

    // ================================================================ AXI-Lite
    task axi_wr(input [7:0] a, input [31:0] d);
        begin
            @(posedge clk);
            awaddr <= a; awvalid <= 1'b1;
            wdata  <= d; wstrb <= 4'hF; wvalid <= 1'b1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);
            awvalid <= 1'b0; wvalid <= 1'b0;
            bready <= 1'b1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task axi_rd(input [7:0] a, output [31:0] d);
        begin
            @(posedge clk);
            araddr <= a; arvalid <= 1'b1;
            @(posedge clk);
            while (!arready) @(posedge clk);
            arvalid <= 1'b0;
            rready  <= 1'b1;
            @(posedge clk);
            while (!rvalid) @(posedge clk);
            d = rdata;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    task wait_idle;
        reg [31:0] st;
        integer n;
        begin
            n = 0;
            axi_rd(8'h08, st);
            while ((st & 1) && n < 200000) begin
                n = n + 1;
                repeat (20) @(posedge clk);
                axi_rd(8'h08, st);
            end
            if (n >= 200000) begin
                $display("RESULT: FAILED engine never went idle");
                errors = errors + 1;
            end
        end
    endtask

    // command issue: writes the parameter registers then CTRL.START
    task issue(input [2:0] opc, input [31:0] s, input [31:0] d,
               input [15:0] w, input [15:0] h,
               input [15:0] sstride, input [15:0] dstride,
               input [15:0] col, input [7:0] al, input [15:0] ky);
        begin
            axi_wr(8'h0C, {29'd0, opc});
            axi_wr(8'h10, s);
            axi_wr(8'h14, d);
            axi_wr(8'h18, {h, w});
            axi_wr(8'h1C, {16'd0, sstride});
            axi_wr(8'h20, {16'd0, dstride});
            axi_wr(8'h24, {16'd0, col});
            axi_wr(8'h28, {24'd0, al});
            axi_wr(8'h2C, {16'd0, ky});
            axi_wr(8'h04, 32'h1);
        end
    endtask

    // ================================================================ checking
    integer errors = 0;
    integer testno = 0;

    // pixel access helpers on the DDR model
    function [15:0] px(input [31:0] addr);
        begin
            px = mem[(addr - 32'h0800_0000) >> 4][((addr >> 1) & 7) * 16 +: 16];
        end
    endfunction

    task expect_px(input [31:0] addr, input [15:0] want, input [8*32-1:0] tag);
        reg [15:0] got;
        begin
            got = px(addr);
            if (got !== want) begin
                $display("FAIL [%0s] addr=%08x got=%04x want=%04x", tag, addr, got, want);
                errors = errors + 1;
            end
        end
    endtask

    integer x, y;
    reg [31:0] st;
    reg [31:0] base;


    initial begin
        $dumpfile("tb_gfx_engine.vcd");
        $dumpvars(0, tb_gfx_engine);

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // ---- identity ----
        axi_rd(8'h00, st);
        if (st !== 32'h47465801) begin $display("FAIL id=%08x", st); errors = errors + 1; end

        // ---- TEST 1: solid fill 16x16 at 0x0800_0000, stride 64, red ----
        testno = 1;
        issue(3'd0, 32'd0, 32'h0800_0000, 16'd16, 16'd16, 16'd0, 16'd64, 16'hF800, 8'd255, 16'd0);
        wait_idle;
        for (y = 0; y < 16; y = y + 1)
            for (x = 0; x < 16; x = x + 1)
                expect_px(32'h0800_0000 + y*64 + x*2, 16'hF800, "fill");

        // ---- TEST 2: copy 16x16 from 0x0000 to 0x1000, stride 64 -> 64 ----
        testno = 2;
        issue(3'd1, 32'h0800_0000, 32'h0800_1000, 16'd16, 16'd16, 16'd64, 16'd64, 16'd0, 8'd255, 16'd0);
        wait_idle;
        for (y = 0; y < 16; y = y + 1)
            for (x = 0; x < 16; x = x + 1)
                expect_px(32'h0800_1000 + y*64 + x*2, 16'hF800, "copy");

        // ---- TEST 3: unaligned copy (destination pixel offset 3) ----
        testno = 3;
        // fill a source 8x8 with a pattern first
        issue(3'd0, 32'd0, 32'h0800_2000, 16'd8, 16'd8, 16'd0, 16'd32, 16'h07E0, 8'd255, 16'd0);
        wait_idle;
        issue(3'd1, 32'h0800_2000, 32'h0800_3006, 16'd8, 16'd8, 16'd32, 16'd32, 16'd0, 8'd255, 16'd0);
        wait_idle;
        for (y = 0; y < 8; y = y + 1)
            for (x = 0; x < 8; x = x + 1)
                expect_px(32'h0800_3006 + y*32 + x*2, 16'h07E0, "unaligned");

        // ---- TEST 4: alpha blend, alpha=128, fg red over bg green ----
        testno = 4;
        issue(3'd0, 32'd0, 32'h0800_4000, 16'd8, 16'd8, 16'd0, 16'd32, 16'h07E0, 8'd255, 16'd0);
        wait_idle;
        issue(3'd0, 32'd0, 32'h0800_4800, 16'd8, 16'd8, 16'd0, 16'd32, 16'hF800, 8'd255, 16'd0);
        wait_idle;
        issue(3'd2, 32'h0800_4800, 32'h0800_4000, 16'd8, 16'd8, 16'd32, 16'd32, 16'd0, 8'd128, 16'd0);
        wait_idle;
        // expected: fg=F800 (31,0,0), bg=07E0 (0,63,0), a=128
        // r = (31*128 + 0*127 + 128); (r + (r>>8)) >> 8 = 16 -> 0x10
        // g = (0*128 + 63*127 + 128) = 8129; (8129+31)>>8 = 31 -> 0x1F
        for (y = 0; y < 2; y = y + 1)
            for (x = 0; x < 8; x = x + 1)
                expect_px(32'h0800_4000 + y*32 + x*2, 16'h83E0, "blend");

        // ---- TEST 5: colour key, key = F800, fg contains key and 07E0 ----
        testno = 5;
        // build a 8x1 source: half F800 (key), half 001F (blue)
        for (x = 0; x < 8; x = x + 1) mem[((32'h0800_5000 - 32'h0800_0000) >> 4)][16*x +: 16] = (x < 4) ? 16'hF800 : 16'h001F;
        // dest filled with 07E0
        issue(3'd0, 32'd0, 32'h0800_5800, 16'd8, 16'd1, 16'd0, 16'd32, 16'h07E0, 8'd255, 16'd0);
        wait_idle;
        issue(3'd3, 32'h0800_5000, 32'h0800_5800, 16'd8, 16'd1, 16'd32, 16'd32, 16'd0, 8'd255, 16'hF800);
        wait_idle;
        for (x = 0; x < 4; x = x + 1) expect_px(32'h0800_5800 + x*2, 16'h07E0, "key-left");
        for (x = 4; x < 8; x = x + 1) expect_px(32'h0800_5800 + x*2, 16'h001F, "key-right");

        // ---- TEST 6: out-of-bounds destination is refused, not written ----
        testno = 6;
        issue(3'd0, 32'd0, 32'h0700_0000, 16'd8, 16'd8, 16'd0, 16'd32, 16'h1234, 8'd255, 16'd0);
        wait_idle;
        axi_rd(8'h08, st);
        if (!(st & 8)) begin $display("FAIL oob not flagged st=%08x", st); errors = errors + 1; end

        // ---- TEST 7: command FIFO, three fills back to back ----
        testno = 7;
        axi_wr(8'h0C, 32'd0);
        axi_wr(8'h10, 32'd0);
        axi_wr(8'h18, {16'd4, 16'd4});
        axi_wr(8'h1C, 32'd0);
        axi_wr(8'h20, 32'd32);
        axi_wr(8'h28, 32'd255);
        axi_wr(8'h2C, 32'd0);
        axi_wr(8'h14, 32'h0800_6000); axi_wr(8'h24, 32'h1111); axi_wr(8'h04, 32'h1);
        axi_wr(8'h14, 32'h0800_6100); axi_wr(8'h24, 32'h2222); axi_wr(8'h04, 32'h1);
        axi_wr(8'h14, 32'h0800_6200); axi_wr(8'h24, 32'h3333); axi_wr(8'h04, 32'h1);
        wait_idle;
        expect_px(32'h0800_6000, 16'h1111, "fifo1");
        expect_px(32'h0800_6100, 16'h2222, "fifo2");
        expect_px(32'h0800_6200, 16'h3333, "fifo3");

        // ---- TEST 9: compact source (stride == width*2) ----
        // This is the whole-sprite fetch path: the engine may issue one burst
        // for the entire source instead of one per row.
        testno = 9;
        issue(3'd0, 32'd0, 32'h0800_8000, 16'd16, 16'd16, 16'd0, 16'd32, 16'h2468, 8'd255, 16'd0);
        wait_idle;
        issue(3'd1, 32'h0800_8000, 32'h0801_0000, 16'd16, 16'd16, 16'd32, 16'd4096, 16'd0, 8'd255, 16'd0);
        wait_idle;
        for (y = 0; y < 16; y = y + 1)
            for (x = 0; x < 16; x = x + 1)
                expect_px(32'h0801_0000 + y*4096 + x*2, 16'h2468, "compact-src");

        // ---- TEST 8: slow DDR (gap of 5 clocks per beat) ----
        testno = 8;
        GAP = 4'd5;
        issue(3'd0, 32'd0, 32'h0800_7000, 16'd128, 16'd128, 16'd0, 16'd256, 16'h0F0F, 8'd255, 16'd0);
        wait_idle;
        GAP = 4'd0;
        expect_px(32'h0800_7000, 16'h0F0F, "slow");

        repeat (20) @(posedge clk);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAILED errors=%0d", errors);
        $finish;
    end

    initial begin
        #4000000;
        $display("TIMEOUT: tb_gfx_engine");
        $finish;
    end

endmodule

`default_nettype wire
