//============================================================================
// tb_bitblt_burst_eff -- how much does per-row dispatch cost?
//============================================================================
// P3 claims that reading a compact sprite as one block instead of one burst per
// row raises transaction efficiency from 62% to 90%+. Before changing any RTL,
// this measures the gap on the current code.
//
// Two runs over the SAME 640x480 ARGB8888 sprite (1,228,800 bytes):
//
//   A. per-row   : 480 transfers of 2560 bytes each   <- what bitblt_addr_gen
//                                                       does today
//   B. as-one    :   1 transfer  of 1228800 bytes     <- what P3 would do
//
// Both move exactly 76,800 beats, so any difference is pure overhead: AR
// handshake, state machine turnaround, and the dead cycles between transactions.
//
// ---------------------------------------------------------------------------
// KNOWN BIAS -- READ THIS BEFORE QUOTING THE NUMBERS
//
// The slave model below accepts an AR only when no burst is in flight. A real
// DDR3 controller pipelines ARs, and the 8-bit arlen exists precisely so it can.
// So run A is penalised harder here than it would be on hardware: the figure
// this testbench produces is an UPPER BOUND on the loss, not the real one.
//
// The direction of the comparison is still trustworthy, and so is the count of
// AR transactions (that is arithmetic, not simulation).
//============================================================================

`timescale 1ns/1ps

module tb_bitblt_burst_eff;

    localparam AXI_DW = 128;
    localparam AXI_AW = 32;
    localparam BYTES_PER_BEAT = AXI_DW / 8;          // 16

    localparam SPR_W = 640;
    localparam SPR_H = 480;
    localparam BPP     = 4;
    localparam ROW_BYTES  = SPR_W * BPP;             // 2560
    localparam ALL_BYTES  = ROW_BYTES * SPR_H;       // 1228800
    localparam ROW_BEATS  = ROW_BYTES / BYTES_PER_BEAT;   // 160
    localparam ALL_BEATS  = ALL_BYTES / BYTES_PER_BEAT;   // 76800
    localparam MAX_BEATS  = 256;                     // arlen is 8 bits
    localparam ALL_BURSTS = (ALL_BEATS + MAX_BEATS - 1) / MAX_BEATS;  // 300

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg start = 1'b0;
    reg [AXI_AW-1:0] base_addr   = 32'h0000_1000;
    reg [31:0]       total_bytes = 32'd0;

    wire busy, done;
    wire [AXI_DW-1:0] dout;
    wire              dout_valid;
    reg               dout_ready = 1'b1;
    wire [31:0]       beats_sent;

    wire [7:0]        m_axi_arid;
    wire [AXI_AW-1:0] m_axi_araddr;
    wire [7:0]        m_axi_arlen;
    wire [2:0]        m_axi_arsize;
    wire [1:0]        m_axi_arburst;
    wire              m_axi_arlock;
    wire [3:0]        m_axi_arcache;
    wire [2:0]        m_axi_arprot;
    wire              m_axi_arvalid;
    reg               m_axi_arready = 1'b0;
    wire [7:0]        m_axi_rid;
    reg  [AXI_DW-1:0] m_axi_rdata  = {AXI_DW{1'b0}};
    reg  [1:0]        m_axi_rresp  = 2'b00;
    reg               m_axi_rlast  = 1'b0;
    reg               m_axi_rvalid = 1'b0;
    wire              m_axi_rready;

    bitblt_dma_rd #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW), .AXI_ID(8'h30)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .base_addr(base_addr), .total_bytes(total_bytes),
        .row_bytes(32'd0), .row_stride({AXI_AW{1'b0}}),
        .busy(busy), .done(done),
        .dout(dout), .dout_valid(dout_valid), .dout_ready(dout_ready),
        .beats_sent(beats_sent),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    // ---------------- slave: one burst at a time ----------------
    reg [7:0]  slv_len;
    reg [7:0]  slv_cnt;
    reg        slv_active;
    wire [AXI_DW-1:0] slv_data = {120'd0, 8'hA5};

    integer ar_total = 0;
    integer beats_total = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0; m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0;
            slv_len <= 8'd0; slv_cnt <= 8'd0; slv_active <= 1'b0;
        end else begin
            if (!slv_active && m_axi_arvalid) begin
                m_axi_arready <= 1'b1;
                slv_len       <= m_axi_arlen;
                slv_cnt       <= 8'd0;
                slv_active    <= 1'b1;
                ar_total      <= ar_total + 1;
            end else begin
                m_axi_arready <= 1'b0;
            end

            if (slv_active) begin
                m_axi_rvalid <= 1'b1;
                m_axi_rdata  <= slv_data;
                m_axi_rlast  <= (slv_cnt + 8'd1 == slv_len);
                if (m_axi_rvalid && m_axi_rready) begin
                    beats_total <= beats_total + 1;
                    if (slv_cnt == slv_len) begin
                        slv_active   <= 1'b0;
                        m_axi_rvalid <= 1'b0;
                        m_axi_rlast  <= 1'b0;
                    end else begin
                        slv_cnt <= slv_cnt + 8'd1;
                    end
                end
            end
        end
    end

    // ---------------- measurement ----------------
    integer t_start, t_end;
    integer cyc_a, cyc_b;
    integer ar_a,  ar_b;

    task do_start;
        begin
            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
        end
    endtask

    task wait_done;
        integer g;
        begin
            g = 0;
            while (!done && g < 2000000) begin
                @(posedge clk);
                g = g + 1;
            end
            @(posedge clk);
            #1;
        end
    endtask

    integer i;
    integer bad = 0;

    // ---- sweep one square sprite size ----
    integer sw, sh, rowb, allb, rowbeats, allbeats, allbursts;
    integer cA, cB, aA, aB;

    task sweep;
        input integer n;                      // sprite is n x n pixels
        integer r;
        begin
            sw = n; sh = n;
            rowb     = sw * BPP;
            allb     = rowb * sh;
            rowbeats = rowb / BYTES_PER_BEAT;
            allbeats = allb / BYTES_PER_BEAT;
            allbursts = (allbeats + MAX_BEATS - 1) / MAX_BEATS;

            // ---- A: one transfer per row ----
            ar_total = 0; beats_total = 0;
            t_start = $time;
            for (r = 0; r < sh; r = r + 1) begin
                base_addr   = 32'h0000_1000 + r * rowb;
                total_bytes = rowb;
                do_start;
                wait_done;
            end
            t_end = $time;
            cA = (t_end - t_start) / 10;
            aA = ar_total;

            repeat (3) @(posedge clk);

            // ---- B: one transfer for the whole sprite ----
            ar_total = 0; beats_total = 0;
            base_addr   = 32'h0000_1000;
            total_bytes = allb;
            t_start = $time;
            do_start;
            wait_done;
            t_end = $time;
            cB = (t_end - t_start) / 10;
            aB = ar_total;

            if (beats_total != allbeats) begin
                $display("  *** n=%0d: B moved %0d beats, expected %0d", n, beats_total, allbeats);
                bad = bad + 1;
            end

            $display("  %0dx%-4d row=%5d B  beats/row=%-4d  AR: %-4d -> %-4d   cycles: %-7d -> %-7d   eff %2d%% -> %2d%%   %0d.%02dx",
                     sw, sh, rowb, rowbeats, aA, aB, cA, cB,
                     (allbeats * 100) / cA, (allbeats * 100) / cB,
                     cA / cB, ((cA * 100) / cB) % 100);

            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        $display("");
        $display("==================================================");
        $display("  tb_bitblt_burst_eff -- per-row dispatch vs one block");
        $display("  ARGB8888, square sprites, 128-bit beats");
        $display("  ideal cycles = number of beats (no gap at all)");
        $display("--------------------------------------------------");
        $display("  sprite       row bytes   beats/row   AR count        cycles          efficiency   gain");

        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (5) @(posedge clk);

        sweep(16);
        sweep(32);
        sweep(64);
        sweep(128);
        sweep(256);
        sweep(640);

        $display("--------------------------------------------------");
        $display("  NOTE: the slave accepts one AR at a time, so the per-row");
        $display("        column is penalised more here than on hardware.");
        $display("        These are upper bounds on the loss.");
        $display("==================================================");

        if (bad == 0) $display("RESULT: PASS (measurement only, all beat counts consistent)");
        else          $display("RESULT: FAIL (%0d inconsistency/ies)", bad);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
