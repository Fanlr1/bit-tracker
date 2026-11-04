// tb_sprdma.v -- focused testbench for the sprite table walker in gfx_regs.
// Writes 3 table entries through the AXI slave port, starts the walker, and
// checks that six commands (erase+draw per sprite) appear on the command FIFO
// with the expected opcodes.
`timescale 1ns/1ps
module tb_sprdma;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [15:0] s_awaddr  = 0;
    reg         s_awvalid = 0;
    reg  [31:0] s_wdata   = 0;
    reg         s_wvalid  = 0;
    wire        s_awready, s_wready, s_bvalid;
    reg         s_bready  = 1;
    reg  [15:0] s_araddr  = 0;
    reg         s_arvalid = 0;
    wire [31:0] s_rdata;
    wire        s_arready, s_rlast, s_rvalid;

    wire        cmd_valid;
    reg         cmd_ready = 0;
    wire [351:0] cmd_data;
    wire [4:0]  cmd_level;

    gfx_regs #(.FIFO_DEPTH(8)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(4'hF), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(), .s_rlast(s_rlast), .s_rvalid(s_rvalid),
        .s_rready(1'b1),
        .irq(),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_data(cmd_data), .cmd_level(cmd_level),
        .core_busy(1'b0), .core_done_cnt(32'd0), .core_error(1'b0),
        .core_clipped(1'b0), .core_err_addr(32'd0), .core_pix_cnt(32'd0),
        .cfg_fb_base(), .cfg_fb_stride(), .cfg_fb_w(), .cfg_fb_h(),
        .cfg_fb_enable(), .cfg_fb_next(), .cfg_fb_seq(), .cfg_fb_commit(),
        .scan_accepted(32'd0), .scan_underruns(32'd0), .scan_shown(32'd0),
        .scan_axi_err(32'd0), .scan_frames(32'd0), .scan_lines(16'd0),
        .scan_blanking(1'b0), .scan_first_under(11'd0),
        .scan_rd_wait_max(16'd0), .scan_rd_gap_max(16'd0),
        .scan_pf_cnt(16'd0), .scan_pf_stall_max(16'd0), .scan_rd_cyc_sum(32'd0),
        .dbg_in(32'd0)
    );

    task axi_write(input [15:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_awaddr <= addr; s_awvalid <= 1'b1;
            s_wdata  <= data; s_wvalid <= 1'b1;
            @(posedge clk);
            while (!(s_awready && s_wready)) @(posedge clk);
            s_awvalid <= 1'b0; s_wvalid <= 1'b0;
            @(posedge clk);
        end
    endtask

    integer ncmd = 0, errs = 0;
    reg [31:0] eo, en;
    reg [2:0] got_op;
    reg [31:0] got_src, got_dst;



    always @(posedge clk) begin
        if (cmd_valid && cmd_ready) begin
            got_op  = cmd_data[322:320];
            got_src = cmd_data[319:288];
            got_dst = cmd_data[287:256];
            $display("  CMD %0d op=%0d src=%h dst=%h", ncmd, got_op, got_src, got_dst);
            if ((ncmd % 2) == 0 && got_op !== 3'd0) begin
                $display("  ERROR: expected FILL(0), got %0d", got_op); errs = errs + 1;
            end
            if ((ncmd % 2) == 1 && got_op !== 3'd5) begin
                $display("  ERROR: expected COPY_KEY(5), got %0d", got_op); errs = errs + 1;
            end
            // erase must target the OLD rect, draw the NEW one (full address)
            case (ncmd >> 1)
                0: begin eo = 32'h0800_0000 + 32'd10*4096 + 32'd10*2;
                          en = 32'h0800_0000 + 32'd30*4096 + 32'd20*2; end
                1: begin eo = 32'h0800_0000 + 32'd60*4096 + 32'd50*2;
                          en = 32'h0800_0000 + 32'd80*4096 + 32'd70*2; end
                default: begin eo = 32'h0800_0000 + 32'd100*4096 + 32'd90*2;
                               en = 32'h0800_0000 + 32'd120*4096 + 32'd110*2; end
            endcase
            if ((ncmd % 2) == 0 && got_dst !== eo) begin
                $display("  ERROR: erase dst expected %h, got %h", eo, got_dst);
                errs = errs + 1;
            end
            if ((ncmd % 2) == 1 && got_dst !== en) begin
                $display("  ERROR: draw dst expected %h, got %h", en, got_dst);
                errs = errs + 1;
            end
            ncmd = ncmd + 1;
        end
    end

    integer i;
    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        axi_write(16'h8000, {16'd10, 16'd10});   // entry0 old (10,10)
        axi_write(16'h8004, {16'd30, 16'd20});   // entry0 new (20,30)
        axi_write(16'h8008, 32'h0887_0000);
        axi_write(16'h800C, 32'd0);
        axi_write(16'h8010, {16'd60, 16'd50});
        axi_write(16'h8014, {16'd80, 16'd70});
        axi_write(16'h8018, 32'h0887_1000);
        axi_write(16'h801C, 32'd0);
        axi_write(16'h8020, {16'd100, 16'd90});
        axi_write(16'h8024, {16'd120, 16'd110});
        axi_write(16'h8028, 32'h0887_2000);
        axi_write(16'h802C, 32'd0);

        axi_write(16'h0040, 32'h0800_0000);      // FB_BASE
        axi_write(16'h0078, 32'hE100_8000);      // SPR_TAB
        axi_write(16'h007C, 32'd0);              // clear START
        axi_write(16'h007C, 32'd3 | (32'd1 << 16));

        cmd_ready = 1;
        for (i = 0; i < 4000; i = i + 1) @(posedge clk);
        cmd_ready = 0;

        $display("=== %0d commands (expect 6), errors=%0d ===", ncmd, errs);
        if (ncmd == 6 && errs == 0) $display("TB PASS");
        else                        $display("TB FAIL");
        $finish;
    end
endmodule
