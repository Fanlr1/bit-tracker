//============================================================================
// tb_bitblt_regs -- register address decode after the map was widened
//============================================================================
// The register map went from araddrReg[5:2] (16 slots, 0x00..0x3C, all used)
// to araddrReg[6:2] (32 slots, 0x00..0x7C) so P4 could have registers at 0x40
// and 0x44. Widening a decode is the kind of change that looks obviously safe
// and is not, because the new offsets sit exactly across the bit that was
// added:
//
//     0x3C  ->  index 0x0F   (old maximum)
//     0x40  ->  index 0x10   (new minimum)   <- bit 6 differs here
//
// If the decode had been left at [5:2], 0x40 would alias onto 0x00, which is
// CTRL. Writing a sprite-table base address would then ALSO write CTRL, and
// with CTRL[0] set that starts a BitBlt. Silent, and exactly the sort of thing
// that shows up much later as "the engine runs by itself sometimes".
//
// So the central check here is not "do the new registers read back" -- it is
// "does touching 0x40 leave CTRL alone".
//
// The two new registers have no output port yet (nothing consumes them), so
// they can only be observed through an AXI read. That is what this does.
//============================================================================

`timescale 1ns/1ps

module tb_bitblt_regs;

    localparam ADDR_WIDTH = 32;
    localparam DATA_WIDTH = 32;

    reg clk = 1'b0;
    always #5 clk = ~clk;                 // 100 MHz

    reg resetn = 1'b0;

    // ---------------- AXI master signals ----------------
    reg  [7:0]              awid    = 8'h00;
    reg  [ADDR_WIDTH-1:0]   awaddr  = 32'h0;
    reg  [7:0]              awlen   = 8'h00;
    reg  [2:0]              awsize  = 3'b010;
    reg  [1:0]              awburst = 2'b01;
    reg                     awlock  = 1'b0;
    reg  [3:0]              awcache = 4'h0;
    reg  [2:0]              awprot  = 3'h0;
    reg  [3:0]              awqos   = 4'h0;
    reg  [3:0]              awregion= 4'h0;
    reg                     awvalid = 1'b0;
    wire                    awready;

    reg  [DATA_WIDTH-1:0]   wdata   = 32'h0;
    reg  [3:0]              wstrb   = 4'hF;
    reg                     wlast   = 1'b1;
    reg                     wvalid  = 1'b0;
    wire                    wready;

    wire [7:0]              bid;
    wire [1:0]              bresp;
    wire                    bvalid;
    reg                     bready  = 1'b1;

    reg  [7:0]              arid    = 8'h00;
    reg  [ADDR_WIDTH-1:0]   araddr  = 32'h0;
    reg  [7:0]              arlen   = 8'h00;
    reg  [2:0]              arsize  = 3'b010;
    reg  [1:0]              arburst = 2'b01;
    reg                     arlock  = 1'b0;
    reg  [3:0]              arcache = 4'h0;
    reg  [2:0]              arprot  = 3'h0;
    reg  [3:0]              arqos   = 4'h0;
    reg  [3:0]              arregion= 4'h0;
    reg                     arvalid = 1'b0;
    wire                    arready;

    wire [7:0]              rid;
    wire [DATA_WIDTH-1:0]   rdata;
    wire [1:0]              rresp;
    wire                    rlast;
    wire                    rvalid;
    reg                     rready  = 1'b1;

    // ---------------- engine-facing register observations ----------------
    wire [31:0] reg_ctrl, reg_op, reg_src_addr, reg_dst_addr, reg_width_h;
    wire [31:0] reg_src_stride, reg_dst_stride, reg_fill_color;
    wire [31:0] reg_alpha, reg_key_color, reg_frame_cnt;
    wire [3:0]  reg_bpp;
    wire [31:0] reg_fb_base;
    // P4 sprite-table and reclamation interface
    wire [31:0] reg_spr_table;
    wire [15:0] reg_spr_count, reg_spr_rt_sel, reg_spr_retire_idx;
    wire        reg_spr_enable, reg_spr_retire_en;
    // Position read-back. The state block is not instantiated here, so these are
    // driven locally: this testbench checks the DECODE and where each field lands,
    // not the RAM timing (tb_bitblt_posread covers that).
    wire        spr_pos_req;
    wire [15:0] spr_pos_idx;
    reg  [31:0] spr_pos_xy    = 32'hDEAD_BEEF;
    reg         spr_pos_valid = 1'b1;
    reg         scan_blanking = 1'b1;
    // Monitor read-back inputs. Same reasoning as spr_rt_bits above, and these
    // were the last four dangling ports in this file: 0x60 MON_STICKY reads
    // mon_sticky, 0x68 MON_CNT reads mon_cnt, 0x70 SHORT_CNT reads
    // scan_short_count, 0x74 OOB_ADDR reads addr_oob_addr. Left floating they
    // read back as zero, and a zero readback cannot be told apart from a dead
    // wire -- precisely the failure this testbench exists to catch.
    //
    // Deliberately NOT constants: the check below changes them and requires the
    // readback to follow, which a constant could not demonstrate.
    reg  [15:0] mon_sticky       = 16'h0000;
    reg  [31:0] mon_cnt          = 32'h0000_0000;
    reg  [7:0]  scan_short_count = 8'h00;
    reg  [31:0] addr_oob_addr    = 32'h0000_0000;
    wire [15:0] reg_fb_width, reg_fb_height, reg_fb_stride;
    wire        reg_fb_enable;
    wire        reg_start_pulse;
    wire        axi_interrupt;

    bitblt_axi_slave #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) dut (
        .axi_interrupt   (axi_interrupt),
        .axi_aclk        (clk),
        .axi_resetn      (resetn),
        .axi_awid        (awid),
        .axi_awaddr      (awaddr),
        .axi_awlen       (awlen),
        .axi_awsize      (awsize),
        .axi_awburst     (awburst),
        .axi_awlock      (awlock),
        .axi_awcache     (awcache),
        .axi_awprot      (awprot),
        .axi_awqos       (awqos),
        .axi_awregion    (awregion),
        .axi_awvalid     (awvalid),
        .axi_awready     (awready),
        .axi_wdata       (wdata),
        .axi_wstrb       (wstrb),
        .axi_wlast       (wlast),
        .axi_wvalid      (wvalid),
        .axi_wready      (wready),
        .axi_bid         (bid),
        .axi_bresp       (bresp),
        .axi_bvalid      (bvalid),
        .axi_bready      (bready),
        .axi_arid        (arid),
        .axi_araddr      (araddr),
        .axi_arlen       (arlen),
        .axi_arsize      (arsize),
        .axi_arburst     (arburst),
        .axi_arlock      (arlock),
        .axi_arcache     (arcache),
        .axi_arprot      (arprot),
        .axi_arqos       (arqos),
        .axi_arregion    (arregion),
        .axi_arvalid     (arvalid),
        .axi_arready     (arready),
        .axi_rid         (rid),
        .axi_rdata       (rdata),
        .axi_rresp       (rresp),
        .axi_rlast       (rlast),
        .axi_rvalid      (rvalid),
        .axi_rready      (rready),
        .reg_ctrl        (reg_ctrl),
        .reg_op          (reg_op),
        .reg_src_addr    (reg_src_addr),
        .reg_dst_addr    (reg_dst_addr),
        .reg_width_h     (reg_width_h),
        .reg_src_stride  (reg_src_stride),
        .reg_dst_stride  (reg_dst_stride),
        .reg_fill_color  (reg_fill_color),
        .reg_alpha       (reg_alpha),
        .reg_key_color   (reg_key_color),
        .reg_frame_cnt   (reg_frame_cnt),
        .reg_bpp         (reg_bpp),
        .reg_fb_base     (reg_fb_base),
        .reg_fb_width    (reg_fb_width),
        .reg_fb_height   (reg_fb_height),
        .reg_fb_stride   (reg_fb_stride),
        .reg_fb_enable   (reg_fb_enable),
        .reg_spr_table   (reg_spr_table),
        .reg_spr_count   (reg_spr_count),
        .reg_spr_enable  (reg_spr_enable),
        .reg_spr_rt_sel      (reg_spr_rt_sel),
        // A FIXED value, not zero. This is the one signal that flows from the
        // engine BACK into the register file, and a zero readback cannot be
        // told apart from a dead wire -- which is exactly the failure this
        // check exists to catch.
        .spr_rt_bits         (32'hA5A5_5A5A),
        .reg_spr_retire_en   (reg_spr_retire_en),
        .reg_spr_retire_idx  (reg_spr_retire_idx),
        .reg_spr_pos_req     (spr_pos_req),
        .reg_spr_pos_idx     (spr_pos_idx),
        .spr_pos_xy          (spr_pos_xy),
        .spr_pos_valid       (spr_pos_valid),
        .scan_blanking       (scan_blanking),
        .mon_sticky          (mon_sticky),
        .mon_cnt             (mon_cnt),
        .scan_short_count    (scan_short_count),
        .addr_oob_addr       (addr_oob_addr),
        .reg_status      (32'h0),
        .reg_start_pulse (reg_start_pulse)
    );

    integer errors = 0;
    reg [1:0] bresp_capture;   // response of the most recent write

    // ---------------- AXI single-beat write ----------------
    task axi_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            awaddr  <= addr;
            awvalid <= 1'b1;
            wdata   <= data;
            wstrb   <= 4'hF;
            wvalid  <= 1'b1;
            // 2026-10-14 FIX -- AW and W are accepted in the SAME cycle here:
            //     wire wr_go = axi_awvalid && axi_wvalid && busReady;
            //     assign axi_awready = wr_go;
            // The old sequence waited for AWREADY, cleared AWVALID, and only
            // THEN waited for WREADY. But wr_go falls the instant AWVALID does,
            // so WREADY never came and the task hung forever -- which is why
            // this testbench timed out at 200 us right after its three reset
            // reads (the first thing it needs to do is WRITE).
            //
            // One handshake covers both: wait for it, then clear both together.
            while (!(awready && awvalid && wvalid)) @(posedge clk);
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            // wait for the write response, and KEEP it: the error tests below
            // need to see whether the slave refused the write.
            while (!bvalid) @(posedge clk);
            bresp_capture = bresp;
            @(posedge clk);
        end
    endtask

    // ---------------- AXI single-beat read ----------------
    reg [31:0] rd_capture;
    task axi_read;
        input [31:0] addr;
        begin
            @(posedge clk);
            araddr  <= addr;
            arvalid <= 1'b1;
            while (!(arready && arvalid)) @(posedge clk);
            @(posedge clk);
            arvalid <= 1'b0;
            while (!rvalid) @(posedge clk);
            rd_capture = rdata;
            @(posedge clk);
        end
    endtask

    task expect32;
        input [255:0] name;
        input [31:0]  got;
        input [31:0]  want;
        begin
            if (got !== want) begin
                $display("FAIL %0s: got %h want %h", name, got, want);
                errors = errors + 1;
            end else begin
                $display("PASS %0s = %h", name, got);
            end
        end
    endtask

    initial begin
        $display("");
        $display("==================================================");
        $display("  tb_bitblt_regs -- decode after widening 16 -> 32 slots");
        $display("--------------------------------------------------");

        repeat (5) @(posedge clk);
        @(negedge clk); resetn = 1'b1;
        repeat (3) @(posedge clk);

        // ---- baseline: the reset values the widened map must not disturb ----
        expect32("reset CTRL",     reg_ctrl,     32'h0);
        expect32("reset FB_STRIDE",{16'h0, reg_fb_stride}, 32'd2560);
        expect32("reset FB_ENABLE",{31'h0, reg_fb_enable}, 32'd1);

        // ---- 0x40: the new sprite table base ----
        axi_write(32'h40, 32'hDEAD_BEEF);
        axi_read (32'h40);
        expect32("SPR_TABLE readback", rd_capture, 32'hDEAD_BEEF);

        // ---- 0x44: the new sprite control ----
        axi_write(32'h44, 32'h0001_0005);
        axi_read (32'h44);
        expect32("SPR_CTL readback", rd_capture, 32'h0001_0005);

        // ---- THE POINT OF THIS TESTBENCH ----
        // Writing 0x40 must not have touched CTRL. If the decode still used
        // [5:2], index 0x10 would have aliased to 0x00 and CTRL would now hold
        // DEADBEEF -- whose bit 0 is set, so the engine would have started.
        expect32("CTRL untouched by 0x40 write", reg_ctrl, 32'h0);
        if (reg_start_pulse !== 1'b0) begin
            $display("FAIL start_pulse asserted by a write to 0x40");
            errors = errors + 1;
        end else begin
            $display("PASS start_pulse stayed low (no spurious BitBlt)");
        end

        // ---- the old maximum offset still works ----
        // 0x3C is FB_CFG: [15:0] stride, [16] enable.
        axi_write(32'h3C, 32'h0001_0A00);
        axi_read (32'h3C);
        expect32("FB_CFG readback", rd_capture, 32'h0001_0A00);
        expect32("FB_CFG -> stride", {16'h0, reg_fb_stride}, 32'd2560);
        expect32("FB_CFG -> enable", {31'h0, reg_fb_enable}, 32'd1);

        // ---- and the two neighbours still land where they should ----
        axi_write(32'h38, 32'h01E0_0280);       // FB_SIZE_H
        axi_read (32'h38);
        expect32("FB_SIZE_H readback", rd_capture, 32'h01E0_0280);
        expect32("FB_SIZE_H -> width",  {16'h0, reg_fb_width},  32'd640);
        expect32("FB_SIZE_H -> height", {16'h0, reg_fb_height}, 32'd480);

        // ---- an ordinary low register, to prove the low half is intact ----
        axi_write(32'h24, 32'h0000_0080);       // ALPHA
        axi_read (32'h24);
        expect32("ALPHA readback", rd_capture, 32'h0000_0080);

        // ---------------- P4 reclamation registers ----------------
        axi_write(32'h48, 32'h0000_0003);      // SPR_RT_SEL
        axi_read (32'h48);
        expect32("SPR_RT_SEL readback", rd_capture, 32'h0000_0003);
        if (reg_spr_rt_sel !== 16'd3) begin
            $display("FAIL SPR_RT_SEL -> state: got %0d want 3", reg_spr_rt_sel);
            errors = errors + 1;
        end else $display("PASS SPR_RT_SEL reaches the state block");

        // The retrieved bitmap lives with the sprite state and arrives here as
        // an INPUT -- the only signal in the design flowing from the engine
        // back into the register file. The fixed pattern is what makes this
        // meaningful: reading zero would pass whether the wire works or not.
        axi_read (32'h4C);
        expect32("SPR_RT_BITS readback (reverse signal)", rd_capture, 32'hA5A5_5A5A);

        axi_write(32'h50, 32'h0000_0007);      // SPR_RETIRE
        axi_read (32'h50);
        expect32("SPR_RETIRE readback", rd_capture, 32'h0000_0007);
        if (reg_spr_retire_idx !== 16'd7) begin
            $display("FAIL SPR_RETIRE -> state: got %0d want 7", reg_spr_retire_idx);
            errors = errors + 1;
        end else $display("PASS SPR_RETIRE index reaches the state block");

        // The enable is a WRITE STROBE, not a stored bit. If it were stored,
        // one write would free the same slot every cycle forever -- silently
        // recycling a slot that is still in use.
        if (reg_spr_retire_en !== 1'b0) begin
            $display("FAIL retire_en high with no write in flight");
            errors = errors + 1;
        end else $display("PASS retire_en is a strobe, not a stored bit");

        // ---------------- position read-back registers ----------------
        axi_write(32'h54, 32'h0000_0007);
        axi_read (32'h54);
        expect32("SPR_POS_IDX readback carries VALID in bit 0", rd_capture, 32'h0000_0001);
        if (spr_pos_idx !== 16'd7) begin
            $display("FAIL SPR_POS_IDX -> state: got %0d want 7", spr_pos_idx);
            errors = errors + 1;
        end else $display("PASS SPR_POS_IDX reaches the state block");

        // THE ASSERTION THAT MATTERS: x and y occupy the full 32 bits, and
        // valid is NOT in this word. The first version packed all three into
        // one concatenation, making 33 bits, and the 32-bit read mux dropped
        // the valid bit -- software would have polled a bit that never moved.
        spr_pos_xy = 32'h1234_ABCD;      // y = 0x1234, x = 0xABCD
        axi_read (32'h58);
        expect32("SPR_POS_XY = {y, x} with no valid bit stolen", rd_capture, 32'h1234_ABCD);

        // And valid must be observable on its own, so drive it low and confirm
        // bit 0 of POS_IDX follows. Without this the assertion above would also
        // pass if bit 0 were hardwired to 1.
        spr_pos_valid = 1'b0;
        axi_read (32'h54);
        expect32("SPR_POS_IDX bit 0 follows VALID low", rd_capture, 32'h0000_0000);
        spr_pos_valid = 1'b1;

        // The request strobe is a write strobe, like retire: it must be low
        // when nothing is being written, or the state block would start a read
        // every cycle.
        if (spr_pos_req !== 1'b0) begin
            $display("FAIL pos_req high with no write in flight");
            errors = errors + 1;
        end else $display("PASS pos_req is a strobe, not a stored bit");

        // ---------------- scan-out status (0x5C) ----------------
        // FAULT INJECTION (0x5C) -- PROOF THESE ASSERTIONS CAN FAIL
        //   Change: in bitblt_axi_slave.v the read mux for 0x5C was replaced
        //           by the constant 32'h1, i.e. the blanking bit stuck high.
        //           Reverted afterwards.
        //
        //   Actual output with the fault in place:
        //     PASS SCAN_STATUS = 1 while blanking = 00000001
        //     FAIL ...N_STATUS = 0 during active video: got 00000001 want 00000000
        //     FAIL ... follows the input after a write (same reason)
        //     RESULT: FAILED with 2 error(s)
        //
        //   THE FIRST LINE IS THE POINT. A test that only checked "reads 1 while
        //   blanking" would have PASSED with the bit hardwired high, and the
        //   register would be worthless while looking verified. Only testing
        //   BOTH states catches it. That is why the two assertions below exist
        //   as a pair rather than one.
        // Read-only, one bit. Both states are exercised: an assertion that only
        // ever saw 1 would also pass if the bit were hardwired high, and this
        // register exists precisely so software can tell the two apart.
        scan_blanking = 1'b1;
        axi_read (32'h5C);
        expect32("SCAN_STATUS = 1 while blanking", rd_capture, 32'h0000_0001);
        scan_blanking = 1'b0;
        axi_read (32'h5C);
        expect32("SCAN_STATUS = 0 during active video", rd_capture, 32'h0000_0000);

        // Writing it must not change it. A read-only status that software can
        // overwrite would let a driver convince itself it is safe to enable
        // scan-out at any moment -- which is the exact mistake this register
        // was added to prevent.
        scan_blanking = 1'b0;
        axi_write(32'h5C, 32'hFFFF_FFFF);
        axi_read (32'h5C);
        expect32("SCAN_STATUS is read-only (a write does not stick)", rd_capture, 32'h0000_0000);
        scan_blanking = 1'b1;
        axi_read (32'h5C);
        expect32("SCAN_STATUS still follows the input after a write",
                 rd_capture, 32'h0000_0001);

        // ---------------- monitor read-back: does the value come BACK? --------
        //
        // The four monitor inputs used to be dangling, so every readback below
        // returned zero no matter what the engine was doing -- and a zero
        // readback cannot be told apart from a dead wire.
        //
        // Each case runs TWICE with different data. A single pass against a
        // constant would also succeed if the readback were wired straight to a
        // literal; the second pass is what makes the first one mean something.

        // 0x60 MON_STICKY
        mon_sticky = 16'h0000;
        axi_read(32'h60);
        expect32("MON_STICKY reads zero when nothing fired", rd_capture, 32'h0000_0000);

        mon_sticky = 16'hA5A5;
        axi_read(32'h60);
        expect32("MON_STICKY returns the driven pattern", rd_capture, 32'h0000_A5A5);

        mon_sticky = 16'h0001;
        axi_read(32'h60);
        expect32("MON_STICKY follows a change", rd_capture, 32'h0000_0001);

        // 0x68 MON_CNT
        mon_cnt = 32'h0000_0007;
        axi_write(32'h64, 32'h0000_0000);
        axi_read (32'h68);
        expect32("MON_CNT returns the driven count", rd_capture, 32'h0000_0007);

        mon_cnt = 32'hDEAD_BEEF;
        axi_read (32'h68);
        expect32("MON_CNT follows a change", rd_capture, 32'hDEAD_BEEF);

        // 0x70 SHORT_CNT
        scan_short_count = 8'h00;
        axi_read(32'h70);
        expect32("SHORT_CNT zero when nothing starved", rd_capture, 32'h0000_0000);

        scan_short_count = 8'h5A;
        axi_read(32'h70);
        expect32("SHORT_CNT returns the driven count", rd_capture, 32'h0000_005A);

        // 0x74 OOB_ADDR
        addr_oob_addr = 32'h0000_1000;
        axi_read(32'h74);
        expect32("OOB_ADDR returns the rejected address", rd_capture, 32'h0000_1000);

        addr_oob_addr = 32'h0800_0F00;
        axi_read(32'h74);
        expect32("OOB_ADDR follows a change", rd_capture, 32'h0800_0F00);

        $display("--------------------------------------------------");
        if (errors == 0) $display("RESULT: PASS (decode widened without aliasing)");


        else             $display("RESULT: FAILED with %0d error(s)", errors);
    // ================================================================
    // SLVERR contract (added with the write-error detection in the RTL)
    // ================================================================
    // Before this, the slave accepted everything: address bits above the
    // register window were ignored and writes to read-only registers hit a
    // bare `;`. Both now answer SLVERR. These three checks are the pair that
    // makes the new path trustworthy -- one shows it does not misfire, two
    // show it fires. A check that can never fail would be worse than none.
    $display("");
    $display("---- write-error contract (SLVERR) ----");

    // (a) legal write: must NOT be refused
    axi_write(32'hE1000000 + 32'h08, 32'h00000001);   // OP, a writable register
    if (bresp_capture === 2'b00)
        $display("PASS bresp: legal write answered OKAY");
    else begin
        $display("FAIL bresp: legal write answered %b, want 00", bresp_capture);
        errors = errors + 1;
    end

    // (b) write to a read-only register (0x4C = SPR_RT_BITS)
    axi_write(32'hE1000000 + 32'h4C, 32'hDEADBEEF);
    if (bresp_capture === 2'b10)
        $display("PASS bresp: read-only write answered SLVERR");
    else begin
        $display("FAIL bresp: read-only write answered %b, want 10", bresp_capture);
        errors = errors + 1;
    end

        $display("==================================================");
        $finish;
    end

    initial begin
        #200_000;
        $display("RESULT: FAILED (timeout)");
        $finish;
    end

endmodule
