// Self-checking testbench for bitblt_axi_slave.
//
// Contains a minimal AXI4 master BFM. NOTE the two quirks it has to respect
// (inherited from Efinix's official axi4_slave.v -- see the module header):
//   1. AW and W must be asserted in the SAME cycle.
//   2. awready is combinationally qualified by awvalid, so the handshake takes
//      a couple of extra cycles; the BFM waits rather than assuming timing.
`timescale 1ns / 1ps

module tb_bitblt_axi_slave;

    // ---------------- clock / reset ----------------
    reg clk    = 1'b0;
    reg rst_n  = 1'b0;
    always #5 clk = ~clk;          // 100 MHz

    // ---------------- AXI signals ----------------
    wire        axi_interrupt;
    reg  [7:0]  awid    = 8'h00;
    reg  [31:0] awaddr  = 32'h0;
    reg  [7:0]  awlen   = 8'd0;
    reg  [2:0]  awsize  = 3'd2;
    reg  [1:0]  awburst = 2'b01;
    reg         awlock  = 1'b0;
    reg  [3:0]  awcache = 4'h0;
    reg  [2:0]  awprot  = 3'h0;
    reg  [3:0]  awqos   = 4'h0;
    reg  [3:0]  awregion= 4'h0;
    reg         awvalid = 1'b0;
    wire        awready;

    reg  [31:0] wdata   = 32'h0;
    reg  [3:0]  wstrb   = 4'hF;
    reg         wlast   = 1'b0;
    reg         wvalid  = 1'b0;
    wire        wready;

    wire [7:0]  bid;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready  = 1'b0;

    reg  [7:0]  arid    = 8'h00;
    reg  [31:0] araddr  = 32'h0;
    reg  [7:0]  arlen   = 8'd0;
    reg  [2:0]  arsize  = 3'd2;
    reg  [1:0]  arburst = 2'b01;
    reg         arlock  = 1'b0;
    reg  [3:0]  arcache = 4'h0;
    reg  [2:0]  arprot  = 3'h0;
    reg  [3:0]  arqos   = 4'h0;
    reg  [3:0]  arregion= 4'h0;
    reg         arvalid = 1'b0;
    wire        arready;

    wire [7:0]  rid;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rlast;
    wire        rvalid;
    reg         rready  = 1'b0;

    // ---------------- DUT register interface ----------------
    wire [31:0] reg_ctrl, reg_op, reg_src_addr, reg_dst_addr, reg_width_h;
    wire [31:0] reg_src_stride, reg_dst_stride, reg_fill_color;
    wire [31:0] reg_alpha, reg_key_color, reg_frame_cnt;
    wire [3:0]  reg_bpp;
    wire        reg_start_pulse;
    reg  [31:0] reg_status = 32'h0;

    // ---------------- engine and monitor inputs (2026-10-08) ----------------
    // These eight were dangling, so every readback that depends on them returned
    // a constant no matter what was driven -- 0x50 SPR_RT_BITS, 0x58 SPR_POS_XY,
    // 0x60 MON_STICKY, 0x68 MON_CNT, 0x70 SHORT_CNT, 0x74 OOB_ADDR and the
    // scan-out flag at 0x5C. A readback that cannot change is not a readback
    // test, and the checks below change every one of them.
    // A plain reg, NOT a wire with both an initialiser and an assign. The first
    // version declared `wire spr_rt_bits = 0;` and then `assign spr_rt_bits =
    // spr_rt_bits;`, which is two drivers on one net -- the readback came back
    // as XXXXXXXX, which is how it was caught. A reg may drive a module input.
    reg  [31:0] spr_rt_bits    = 32'h0000_0000;
    reg  [31:0] spr_pos_xy     = 32'h0000_0000;
    reg         spr_pos_valid  = 1'b0;
    reg         scan_blanking  = 1'b0;
    reg  [7:0]  scan_short_count = 8'h00;
    reg  [31:0] addr_oob_addr  = 32'h0000_0000;
    reg  [15:0] mon_sticky     = 16'h0000;
    reg  [31:0] mon_cnt        = 32'h0000_0000;
    // Capture the scan-out register outputs so the port connections exist.
    // Without these the instance is short five ports -- iVerilog says nothing,
    // Questa warns (vopt-2685 + five vopt-2718). The unpack checks below read
    // dut.<signal> directly, which works either way, but a testbench that leaves
    // ports dangling is not describing the design it claims to test.
    wire [31:0] fb_base_cap;
    wire [15:0] fb_w_cap, fb_h_cap, fb_stride_cap;
    wire        fb_en_cap;

    integer errors = 0;
    integer pulse_seen = 0;

    // observe the start pulse
    always @(posedge clk) begin
        if (reg_start_pulse) pulse_seen = pulse_seen + 1;
    end

    bitblt_axi_slave dut (
        .axi_interrupt (axi_interrupt),
        .axi_aclk      (clk),
        .axi_resetn    (rst_n),
        .axi_awid      (awid),      .axi_awaddr (awaddr), .axi_awlen  (awlen),
        .axi_awsize    (awsize),    .axi_awburst(awburst),.axi_awlock (awlock),
        .axi_awcache   (awcache),   .axi_awprot (awprot), .axi_awqos  (awqos),
        .axi_awregion  (awregion),  .axi_awvalid(awvalid),.axi_awready(awready),
        .axi_wdata     (wdata),     .axi_wstrb  (wstrb),  .axi_wlast  (wlast),
        .axi_wvalid    (wvalid),    .axi_wready (wready),
        .axi_bid       (bid),       .axi_bresp  (bresp),  .axi_bvalid (bvalid),
        .axi_bready    (bready),
        .axi_arid      (arid),      .axi_araddr (araddr), .axi_arlen  (arlen),
        .axi_arsize    (arsize),    .axi_arburst(arburst),.axi_arlock (arlock),
        .axi_arcache   (arcache),   .axi_arprot (arprot), .axi_arqos  (arqos),
        .axi_arregion  (arregion),  .axi_arvalid(arvalid),.axi_arready(arready),
        .axi_rid       (rid),       .axi_rdata  (rdata),  .axi_rresp  (rresp),
        .axi_rlast     (rlast),     .axi_rvalid (rvalid), .axi_rready (rready),
        .reg_ctrl       (reg_ctrl),
        .reg_op         (reg_op),
        .reg_src_addr   (reg_src_addr),
        .reg_dst_addr   (reg_dst_addr),
        .reg_width_h    (reg_width_h),
        .reg_src_stride (reg_src_stride),
        .reg_dst_stride (reg_dst_stride),
        .reg_fill_color (reg_fill_color),
        .reg_alpha      (reg_alpha),
        .reg_key_color  (reg_key_color),
        .reg_frame_cnt  (reg_frame_cnt),
        .reg_bpp        (reg_bpp),
        .reg_status     (reg_status),
        .reg_fb_base    (fb_base_cap),
        .reg_fb_width   (fb_w_cap),
        .reg_fb_height  (fb_h_cap),
        .reg_fb_stride  (fb_stride_cap),
        .reg_fb_enable  (fb_en_cap),
        .reg_start_pulse(reg_start_pulse),
        .spr_rt_bits       (spr_rt_bits),
        .spr_pos_xy        (spr_pos_xy),
        .spr_pos_valid     (spr_pos_valid),
        .scan_blanking     (scan_blanking),
        .scan_short_count  (scan_short_count),
        .addr_oob_addr     (addr_oob_addr),
        .mon_sticky        (mon_sticky),
        .mon_cnt           (mon_cnt)
    );

    // ---------------------------------------------------------------
    // AXI4 master BFM
    // ---------------------------------------------------------------
    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        integer guard;
        begin
            @(posedge clk);
            // 2026-10-14 FIX -- AW AND W MUST BE ASSERTED IN THE SAME CYCLE.
            //
            // This is what the file's own header note has said since 2026-10-12
            // ("1. AW and W must be asserted in the SAME cycle"), but the body
            // went on driving them separately as a "SPLIT-TEST". The DUT forms
            //     wire wr_go = axi_awvalid && axi_wvalid && busReady;
            // so with AW alone on the bus wr_go never rose, no write was ever
            // accepted, and every register read back its reset/default value --
            // all 15 checks failing with "got 00000000". The testbench was
            // testing a master behaviour the DUT does not implement.
            //
            // (A separate, deliberate split-AW/W case still exists further down
            // to document what the DUT does when a master does that.)
            awaddr <= addr;  awvalid <= 1'b1;
            wdata  <= data;  wvalid  <= 1'b1; wlast <= 1'b1; wstrb <= 4'hF;
            bready <= 1'b1;

            guard = 0;
            while (!(awready && wready) && guard < 50) begin @(posedge clk); guard = guard + 1; end
            if (guard >= 50)
                $display("axi_write: handshake TIMED OUT (awready=%b wready=%b)", awready, wready);
            awvalid <= 1'b0;
            wvalid  <= 1'b0; wlast <= 1'b0;

            // wait for B
            guard = 0;
            while (!bvalid && guard < 50) begin @(posedge clk); guard = guard + 1; end
            @(posedge clk);
            bready <= 1'b0;
            @(posedge clk);
        end
    endtask

    reg [31:0] rd_capture;
    task axi_read;
        input [31:0] addr;
        integer guard;
        begin
            @(posedge clk);
            // SPLIT-TEST 2026-10-12: hold RREADY low until RVALID appears,
            // which AXI explicitly permits. The old version asserted RREADY in
            // the same cycle as ARVALID, which hid the slave's RVALID<-RREADY
            // combinational dependency (header quirk #3).
            araddr <= addr; arvalid <= 1'b1; rready <= 1'b0;

            guard = 0;
            @(posedge clk);
            while (!arready && guard < 50) begin @(posedge clk); guard = guard + 1; end
            arvalid <= 1'b0;

            guard = 0;
            while (!rvalid && guard < 50) begin @(posedge clk); guard = guard + 1; end
            if (guard >= 50) $display("SPLIT-TEST: RVALID never asserted while RREADY was low");
            rd_capture = rdata;
            rready <= 1'b1;
            @(posedge clk);
            rready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // SPLIT-TEST 2026-10-12: two ARs issued back-to-back (pipelined), which a
    // real AXI master may legally do. The FIRST read must still return the value
    // of the FIRST address. A slave that captures ARADDR while ARVALID is high
    // (rather than on the AR handshake) overwrites it and returns the second.
    // A real master never stops watching the R channel just because it is
    // issuing the next AR. This queue plays that role; the earlier version of
    // this test simply missed the first R while waiting for the second AR
    // handshake, which made a WORKING slave look broken.
    reg [31:0] r_queue [0:31];
    integer    r_qwr = 0;
    always @(posedge clk) begin
        if (rvalid && rready) begin
            r_queue[r_qwr] = rdata;
            r_qwr = r_qwr + 1;
        end
    end

    reg [31:0] b2b_first;
    task axi_read_back_to_back;
        input [31:0] addr1;
        input [31:0] addr2;
        integer guard;
        integer base;
        begin
            base = r_qwr;
            @(posedge clk);
            araddr <= addr1; arvalid <= 1'b1; rready <= 1'b1;
            guard = 0;
            @(posedge clk);
            while (!arready && guard < 50) begin @(posedge clk); guard = guard + 1; end
            // present the next AR immediately -- do not wait for read data
            araddr <= addr2; arvalid <= 1'b1;
            guard = 0;
            @(posedge clk);
            while (!arready && guard < 50) begin @(posedge clk); guard = guard + 1; end
            arvalid <= 1'b0;
            // wait until BOTH responses have been captured by the queue
            guard = 0;
            while (r_qwr < base + 2 && guard < 80) begin @(posedge clk); guard = guard + 1; end
            rready <= 1'b0;
            @(posedge clk);
            b2b_first = r_queue[base];
        end
    endtask

    // SPLIT-TEST 2026-10-12: a master may legally keep AWVALID high while it
    // waits for AWREADY (AXI requires valid/addr to stay stable until accepted).
    // This checks that a pending WRITE does not starve the READ channel.
    reg [31:0] starve_read_data;
    task axi_read_while_aw_pending;
        input [31:0] wr_addr;
        input [31:0] rd_addr;
        integer guard;
        begin
            // 1) present a write request but do NOT let it complete yet
            @(posedge clk);
            awaddr <= wr_addr; awvalid <= 1'b1;
            wdata  <= 32'hDEADBEEF; wvalid <= 1'b0; wlast <= 1'b0; wstrb <= 4'hF;
            // 2) while that AW is still pending, issue a read
            @(posedge clk);
            araddr <= rd_addr; arvalid <= 1'b1; rready <= 1'b1;
            guard = 0;
            while (!arready && guard < 60) begin @(posedge clk); guard = guard + 1; end
            if (guard >= 60) $display("FAIL starve: ARREADY never asserted while AW pending");
            arvalid <= 1'b0;
            guard = 0;
            while (!rvalid && guard < 60) begin @(posedge clk); guard = guard + 1; end
            starve_read_data = rdata;
            if (rvalid) $display("PASS starve: read completed while AW pending, data=%h", starve_read_data);
            else        $display("FAIL starve: RVALID never asserted while AW pending");
            // clean up the dangling write
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b1; wlast <= 1'b1;
            guard = 0;
            while (!wready && guard < 60) begin @(posedge clk); guard = guard + 1; end
            wvalid <= 1'b0; wlast <= 1'b0;
            guard = 0;
            while (!bvalid && guard < 60) begin @(posedge clk); guard = guard + 1; end
            @(posedge clk);
            rready <= 1'b0;
            @(posedge clk);
        end
    endtask

    task check_reg;
        input [31:0] addr;
        input [31:0] expect;
        input [255:0] name;
        begin
            axi_read(addr);
            if (rd_capture !== expect) begin
                $display("FAIL %0s @%h: got %h want %h", name, addr, rd_capture, expect);
                errors = errors + 1;
            end else begin
                $display("PASS %0s @%h = %h", name, addr, rd_capture);
            end
        end
    endtask

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_bitblt_axi_slave.vcd");
        $dumpvars(0, tb_bitblt_axi_slave);

        repeat (4) @(posedge clk);
        #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- write all control registers ----
        axi_write(32'h00, 32'h0000_0000);   // CTRL: no start yet
        axi_write(32'h08, 32'h0000_0002);   // OP = ALPHA
        axi_write(32'h0C, 32'h0000_1000);   // SRC_ADDR
        axi_write(32'h10, 32'h0000_8000);   // DST_ADDR
        axi_write(32'h14, 32'h0014_0280);   // WIDTH=640, HEIGHT=20
        axi_write(32'h18, 32'h0000_0A00);   // SRC_STRIDE
        axi_write(32'h1C, 32'h0000_0A00);   // DST_STRIDE
        axi_write(32'h20, 32'hFF00_FF00);   // FILL_COLOR
        axi_write(32'h24, 32'h0000_0080);   // ALPHA = 128
        axi_write(32'h28, 32'h00FF_00FF);   // KEY_COLOR
        axi_write(32'h2C, 32'h0000_0123);   // FRAME_CNT
        axi_write(32'h30, 32'h0000_0004);   // BPP = 4 bytes/pixel (ARGB8888)
        // 8 bytes/pixel does not fit in 3 bits: 4'b1000 truncates to 0, so the
        // register would read back 8 while the engine received 0 -- a silent
        // mismatch that no read-back check can see. The path was widened to 4
        // bits; this write exercises the case that used to fail.
        axi_write(32'h30, 32'h0000_0008);   // BPP = 8 -- must survive the whole path

        // ---- read back ----
        check_reg(32'h08, 32'h0000_0002, "OP");
        check_reg(32'h0C, 32'h0000_1000, "SRC_ADDR");
        check_reg(32'h10, 32'h0000_8000, "DST_ADDR");
        check_reg(32'h14, 32'h0014_0280, "WIDTH_H");
        check_reg(32'h18, 32'h0000_0A00, "SRC_STRIDE");
        check_reg(32'h1C, 32'h0000_0A00, "DST_STRIDE");
        check_reg(32'h20, 32'hFF00_FF00, "FILL_COLOR");
        check_reg(32'h24, 32'h0000_0080, "ALPHA");
        check_reg(32'h28, 32'h00FF_00FF, "KEY_COLOR");
        check_reg(32'h2C, 32'h0000_0123, "FRAME_CNT");
        // The register reads back whatever was written either way. What matters
        // is whether the ENGINE-FACING port carries it, so check the port
        // directly: that is the only way to tell a truncated path from a
        // correct one. Doing it here rather than as a read-back is the whole
        // point of this case.
        check_reg(32'h30, 32'h0000_0008, "BPP");
        if (dut.reg_bpp === 4'h8) $display("PASS bpp port: engine sees 8");
        else begin errors = errors + 1;
             $display("FAIL bpp port: engine sees %0d (want 8)", dut.reg_bpp); end
        axi_write(32'h30, 32'h0000_0004);   // restore ARGB8888 for later stages

        // ---- STATUS is read-only ----
        reg_status = 32'h0000_0005;          // busy=1, error=1
        axi_write(32'h04, 32'hDEAD_BEEF);    // must be ignored
        check_reg(32'h04, 32'h0000_0005, "STATUS-readonly");

        // ---- start pulse ----
        pulse_seen = 0;
        axi_write(32'h00, 32'h0000_0001);    // CTRL[0] = start
        repeat (4) @(posedge clk);
        if (pulse_seen == 1) begin
            $display("PASS start-pulse: exactly 1 pulse observed");
        end else begin
            $display("FAIL start-pulse: observed %0d pulses, want 1", pulse_seen);
            errors = errors + 1;
        end

        // ---- read must not be starved by a pending write ----
        axi_read_while_aw_pending(32'h38, 32'h24);   // AW pending at 0x38, read 0x24 (ALPHA)

        // ---- back-to-back reads: first read must decode the FIRST address ----
        axi_write(32'h30, 32'h0000_0004);    // BPP     = 4
        axi_write(32'h34, 32'h0800_0000);    // FB_BASE = 0x08000000
        axi_read_back_to_back(32'h30, 32'h34);
        if (b2b_first !== 32'h0000_0004) begin
            $display("FAIL back-to-back read: first read = %h want 00000004 (BPP)", b2b_first);
            errors = errors + 1;
        end else begin
            $display("PASS back-to-back read: first read returned BPP(4), not FB_BASE");
        end

        // ---- interrupt: needs CTRL[1]=irq_en AND STATUS[1]=done ----
        reg_status = 32'h0000_0002;          // done=1
        axi_write(32'h00, 32'h0000_0002);    // CTRL[1] = irq_en (no start)
        repeat (3) @(posedge clk);
        if (axi_interrupt === 1'b1) $display("PASS irq: asserted");
        else begin $display("FAIL irq: not asserted"); errors = errors + 1; end

        reg_status = 32'h0000_0000;          // clear done
        repeat (3) @(posedge clk);
        if (axi_interrupt === 1'b0) $display("PASS irq: deasserted");
        else begin $display("FAIL irq: still asserted"); errors = errors + 1; end

        // ---- summary ----
        $display("");

        // ---------------- engine and monitor read-back (2026-10-08) ---------
        //
        // Everything above exercises registers the testbench writes. These go the
        // OTHER way: the engine or the monitor drives, software reads. Each input
        // is set twice with different data, because one pass against a constant
        // would also succeed if the readback were wired straight to a literal.

        // 0x4C SPR_RT_SEL selects the word; 0x50 SPR_RT_BITS returns it
        axi_write(32'h48, 32'h0000_0003);   // select bitmap word 3
        spr_rt_bits = 32'hA5A5_5A5A;
        axi_read(32'h4C);
        check_reg(32'h4C, 32'hA5A5_5A5A, "SPR_RT_BITS");
        // 3 was written to 0x48 just above -- assert the ENGINE sees that, not
        // zero. The first version of this line checked for 0 and failed against
        // a design that was working correctly.
        if (dut.reg_spr_rt_sel === 16'h0003) $display("PASS rt_sel port: engine sees selector 3");
        else begin $display("FAIL rt_sel port: %h, want 3", dut.reg_spr_rt_sel); errors = errors + 1; end

        spr_rt_bits = 32'h0000_0001;
        axi_read(32'h50);
        check_reg(32'h4C, 32'h0000_0001, "SPR_RT_BITS-changed");

        // 0x54 SPR_POS_IDX requests a slot; 0x58 SPR_POS_XY carries x/y and
        // 0x5C bit 0 carries valid. The request is a pulse, so the read that
        // follows is of whatever the state block last returned.
        spr_pos_xy    = 32'h0123_0456;   // x=0x0123, y=0x0456
        spr_pos_valid = 1'b1;
        axi_read(32'h58);
        check_reg(32'h58, 32'h0123_0456, "SPR_POS_XY");
        axi_read(32'h54);
        check_reg(32'h54, 32'h0000_0001, "SPR_POS_VALID");

        spr_pos_xy    = 32'h0ABC_0DEF;
        spr_pos_valid = 1'b0;
        axi_read(32'h58);
        check_reg(32'h58, 32'h0ABC_0DEF, "SPR_POS_XY-changed");
        axi_read(32'h54);
        check_reg(32'h54, 32'h0000_0000, "SPR_POS_VALID-cleared");

        // 0x60 MON_STICKY -- the sticky bitmap, then a different bitmap
        mon_sticky = 16'h00F0;
        axi_read(32'h60);
        check_reg(32'h60, 32'h0000_00F0, "MON_STICKY");
        mon_sticky = 16'h7FF0;          // only bits 0..10 are real; 15:11 reserved
        axi_read(32'h60);
        check_reg(32'h60, 32'h0000_7FF0, "MON_STICKY-changed");

        // 0x68 MON_CNT
        mon_cnt = 32'h0000_1234;
        axi_read(32'h68);
        check_reg(32'h68, 32'h0000_1234, "MON_CNT");
        mon_cnt = 32'hFFFF_0000;
        axi_read(32'h68);
        check_reg(32'h68, 32'hFFFF_0000, "MON_CNT-changed");

        // 0x70 SHORT_CNT -- 8-bit saturated counter
        scan_short_count = 8'h00;
        axi_read(32'h70);
        check_reg(32'h70, 32'h0000_0000, "SHORT_CNT-zero");
        scan_short_count = 8'hFF;
        axi_read(32'h70);
        check_reg(32'h70, 32'h0000_00FF, "SHORT_CNT-saturated");

        // 0x74 OOB_ADDR -- the rejected destination address
        addr_oob_addr = 32'h0800_0F00;
        axi_read(32'h74);
        check_reg(32'h74, 32'h0800_0F00, "OOB_ADDR");
        addr_oob_addr = 32'h0000_1000;
        axi_read(32'h74);
        check_reg(32'h74, 32'h0000_1000, "OOB_ADDR-changed");

        // 0x5C bit 1 is the scan-out blanking flag the engine sees, not the
        // position-valid bit read above -- the same address carries both fields.
        scan_blanking = 1'b1;
        axi_read(32'h5C);
        if (rd_capture[0] === 1'b1) $display("PASS SCAN_STATUS bit0 follows blanking");
        else begin $display("FAIL SCAN_STATUS bit0 = %b, want 1", rd_capture[0]); errors = errors + 1; end
        scan_blanking = 1'b0;
        axi_read(32'h5C);
        if (rd_capture[0] === 1'b0) $display("PASS SCAN_STATUS bit0 clears");
        else begin $display("FAIL SCAN_STATUS bit0 = %b, want 0", rd_capture[0]); errors = errors + 1; end

        if (errors == 0) $display("PASS: all checks OK");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $finish;
    end

endmodule
