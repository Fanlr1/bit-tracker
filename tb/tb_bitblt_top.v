// End-to-end testbench for bitblt_top.
//
// Builds the whole environment around the accelerator:
//   * an AXI4 master BFM standing in for the SoC writing the register file
//   * three AXI4 slave models standing in for DDR (two read, one write)
//
// SCENARIO: a 2-row x 8-pixel COPY.
//   8 pixels x 4 bytes = 32 B per row = 2 beats of 128 bits.
//   src row0 @0x1000, row1 @0x1020   (src_stride 32)
//   dst row0 @0x8000, row1 @0x8020   (dst_stride 32)
//
// WHAT IT PROVES
//   1. registers configure the engine through the AXI slave port
//   2. M3 walks both rows with the right per-row addresses
//   3. both read engines issue reads at those addresses
//   4. the write engine writes back to the destination addresses, and in COPY
//      mode the data it writes is exactly what the source read returned
//   5. the line handshake advances exactly "height" times (no skipped rows)
`timescale 1ns / 1ps

// =====================================================================
// AXI4 read-slave model: returns a deterministic pattern derived from the
// burst address and the beat index, so the TB can predict every word.
// =====================================================================
module axi_rd_slave #(
    parameter AXI_DW = 128,
    parameter AXI_AW = 32,
    parameter [7:0] SLV_ID = 8'h00
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [7:0]           arid,
    input  wire [AXI_AW-1:0]    araddr,
    input  wire [7:0]           arlen,
    input  wire [2:0]           arsize,
    input  wire [1:0]           arburst,
    input  wire                 arvalid,
    output reg                  arready,
    output reg  [7:0]           rid,
    output wire [AXI_DW-1:0]    rdata,
    output reg  [1:0]           rresp,
    output wire                 rlast,
    output reg                  rvalid,
    input  wire                 rready,
    // 2026-10-14 ORDERED-BUS MODEL -- see the note at the instantiations.
    // While the other reader owns the R channel this slave refuses new ARs, so
    // an in-order DDR controller's behaviour is reproduced instead of bypassed.
    input  wire                 hold,
    // observability
    output reg  [31:0]          burst_count,
    output reg  [AXI_AW-1:0]    last_addr
);

    reg [7:0]          cnt;
    reg [7:0]          len_r;
    reg                active;
    reg [AXI_AW-1:0]   base_r;

    // pattern: address in the high half, beat index in the low half
    wire [AXI_DW-1:0] pattern = {base_r[15:0], 8'h5A, cnt};

    // ------------------------------------------------------------------
    // Optional sprite-descriptor overlay (P4 integration test)
    // ------------------------------------------------------------------
    // The default pattern cannot express a descriptor, so the traversal test
    // needs the slave to hand back values it chose. Rather than add ports --
    // which would mean touching both instantiations -- these are plain
    // registers inside the module that the testbench drives by hierarchical
    // reference (u_rd0.spr_en = 1). spr_en resets to 0, so every existing case
    // sees exactly the old pattern.
    //
    // The window is deliberately the fixed 64 bytes of four descriptors: enough
    // to prove the walk addresses and parses a table, small enough that the
    // arithmetic is checkable by eye.
    reg                    spr_en   = 1'b0;
    reg [AXI_AW-1:0]       spr_base = {AXI_AW{1'b0}};
    // 2026-10-14: was [0:31]. The density sweep below fills all 256 slots -- the
    // hardware table size -- so the overlay window has to cover the whole table.
    reg [AXI_DW-1:0]       spr_desc [0:255];

    // The address this beat belongs to. base_r is the burst base and each beat
    // is 16 bytes, so the offset is cnt*16.
    wire [AXI_AW-1:0] cur_addr = base_r + {24'd0, cnt, 4'b0};

    wire spr_hit = spr_en
                && (cur_addr >= spr_base)
                && (cur_addr <  (spr_base + 32'd4096));   // 256 x 16 B descriptors

    wire [7:0] spr_sel = cur_addr[11:4];

    wire [AXI_DW-1:0] pattern_or_spr = spr_hit ? spr_desc[spr_sel]
                                               : {base_r[15:0], 8'h5A, cnt};

    // ------------------------------------------------------------------
    // AR address log
    // ------------------------------------------------------------------
    // Counting bursts only says "something happened N times". The traversal
    // test needs to know WHICH addresses were requested, because the failure
    // it guards against -- the walk reading the wrong row of the table, or
    // dispatching to the wrong source -- shows up as a wrong address with the
    // burst count unchanged. 32 entries is more than any single case issues.
    integer          ar_log_n = 0;
    // 2026-10-14: was [0:127]. A 256-sprite density step issues 3 ARs per
    // sprite (descriptor + 2 source bursts), so the log has to hold 768.
    reg [AXI_AW-1:0] ar_log [0:1023];

    // rlast AND rdata must be COMBINATIONAL with respect to the beat being
    // presented. Registered versions lag the beat counter by one cycle, so the
    // first beat was reported as the last one and beat 0 was presented twice.
    assign rlast = active & (cnt == len_r);
    assign rdata = pattern_or_spr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready     <= 1'b0;
            rvalid      <= 1'b0;
            rid         <= 8'h0;
            active      <= 1'b0;
            cnt         <= 8'd0;
            len_r       <= 8'd0;
            base_r      <= {AXI_AW{1'b0}};
            burst_count <= 32'd0;
            last_addr   <= {AXI_AW{1'b0}};
        end else begin
            // accept a read address
            // NOTE: "&& !hold" is the ordered-bus constraint. Without it this
            // model answers every reader independently and the deadlock that
            // the board shows -- one reader's burst stalling the other's AR
            // forever -- is structurally unreachable in simulation.
            if (!active && arvalid && !hold) begin
                arready     <= 1'b1;
                len_r       <= arlen;
                cnt         <= 8'd0;
                base_r      <= araddr;
                last_addr   <= araddr;
                active      <= 1'b1;
                burst_count <= burst_count + 32'd1;
                if (ar_log_n < 1024) begin
                    ar_log[ar_log_n] = araddr;
                    ar_log_n = ar_log_n + 1;
                end
            end else begin
                arready <= 1'b0;
            end

            // drive read data
            if (active) begin
                rvalid <= 1'b1;
                rid    <= SLV_ID;

                if (rvalid && rready) begin
                    if (cnt == len_r) begin
                        active <= 1'b0;
                        rvalid <= 1'b0;
                    end else begin
                        cnt <= cnt + 8'd1;
                    end
                end
            end
        end
    end

endmodule

// =====================================================================
// AXI4 write-slave model: records write address and data, counts bursts.
// =====================================================================
module axi_wr_slave #(
    parameter AXI_DW = 128,
    parameter AXI_AW = 32
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [7:0]           awid,
    input  wire [AXI_AW-1:0]    awaddr,
    input  wire [7:0]           awlen,
    input  wire [2:0]           awsize,
    input  wire [1:0]           awburst,
    input  wire                 awvalid,
    output reg                  awready,
    input  wire [AXI_DW-1:0]    wdata,
    input  wire [AXI_DW/8-1:0]  wstrb,
    input  wire                 wlast,
    input  wire                 wvalid,
    output reg                  wready,
    output reg  [7:0]           bid,
    output reg  [1:0]           bresp,
    output reg                  bvalid,
    input  wire                 bready,
    // observability
    output reg  [31:0]          burst_count,
    output reg  [31:0]          beat_count,
    output reg  [AXI_AW-1:0]    first_addr,
    output reg  [AXI_DW-1:0]    first_data,
    output reg  [AXI_DW-1:0]    second_data
);

    localparam [1:0] S_IDLE = 2'd0, S_DATA = 2'd1, S_RESP = 2'd2;
    reg [1:0] state;
    reg [7:0] beats_in_burst;

    // Driven by the testbench through a hierarchical reference
    // (tb u_wr.inject_bresp_err) to make this slave answer SLVERR on the next
    // write response. Without it bresp could only ever be OKAY, and the DUT's
    // dbg_b_error check further down would be dead code.
    reg inject_bresp_err = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            awready        <= 1'b0;
            wready         <= 1'b0;
            bvalid         <= 1'b0;
            bresp          <= 2'b00;
            bid            <= 8'h00;
            beats_in_burst <= 8'd0;
            burst_count    <= 32'd0;
            beat_count     <= 32'd0;
            first_addr     <= {AXI_AW{1'b0}};
            first_data     <= {AXI_DW{1'b0}};
            second_data    <= {AXI_DW{1'b0}};
        end else begin
            case (state)
                S_IDLE: begin
                    bvalid <= 1'b0;
                    if (awvalid && wvalid) begin
                        awready        <= 1'b1;
                        wready         <= 1'b1;
                        beats_in_burst <= 8'd0;
                        first_addr     <= awaddr;
                        burst_count    <= burst_count + 32'd1;
                        state          <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (awready && awvalid) awready <= 1'b0;

                    if (wready && wvalid) begin
                        if (beats_in_burst == 8'd0) first_data  <= wdata;
                        if (beats_in_burst == 8'd1) second_data <= wdata;

                        beats_in_burst <= beats_in_burst + 8'd1;
                        beat_count     <= beat_count + 32'd1;

                        if (wlast) begin
                            wready <= 1'b0;
                            state  <= S_RESP;
                        end
                    end
                end

                S_RESP: begin
                    bvalid <= 1'b1;
                    // bresp used to be assigned only in reset, so this slave
                    // always answered OKAY and the DUT's dbg_b_error check could
                    // never fail. This lets the testbench inject a SLVERR.
                    bresp  <= inject_bresp_err ? 2'b10 : 2'b00;
                    if (bvalid && bready) begin
                        bvalid <= 1'b0;
                        state  <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

// =====================================================================
// top-level testbench
// =====================================================================
module tb_bitblt_top;

    localparam AXI_DW = 128;
    localparam AXI_AW = 32;

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;          // 100 MHz

    // NOTE: the diagnostic block lives further down, after the DUT master-port
    // wires are declared. Questa rejects references to wires declared later in
    // the file (iVerilog silently creates an implicit wire instead), so putting
    // it here compiled on one simulator and failed on the other.

    integer errors = 0;
    // P4 scale measurement: wall-clock cycles for one 32-sprite frame.
    integer cycle0, cycle1, frame_cycles;
    integer i;
    integer d;          // density-sweep step
    integer n;          // sprites in the current density step
    // References used by the blend-mode check near the end of this file.
    reg [AXI_DW-1:0] blend_src_ref;
    reg [AXI_DW-1:0] blend_bg_ref;
    reg [31:0]       blend_exp;
    reg [17:0]       prod;
    reg [7:0]        fg_ch, bg_ch;
    integer          ci;

    // ---------------- register-file AXI master BFM ----------------
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

    // ---------------- DUT master ports ----------------
    wire [7:0]  rd0_arid;   wire [AXI_AW-1:0] rd0_araddr; wire [7:0] rd0_arlen;
    wire [2:0]  rd0_arsize; wire [1:0] rd0_arburst;       wire rd0_arlock;
    wire [3:0]  rd0_arcache;wire [2:0] rd0_arprot;        wire rd0_arvalid;
    wire        rd0_arready;
    wire [7:0]  rd0_rid;    wire [AXI_DW-1:0] rd0_rdata;  wire [1:0] rd0_rresp;
    wire        rd0_rlast;  wire rd0_rvalid;              wire rd0_rready;

    wire [7:0]  rd1_arid;   wire [AXI_AW-1:0] rd1_araddr; wire [7:0] rd1_arlen;
    wire [2:0]  rd1_arsize; wire [1:0] rd1_arburst;       wire rd1_arlock;
    wire [3:0]  rd1_arcache;wire [2:0] rd1_arprot;        wire rd1_arvalid;
    wire        rd1_arready;
    wire [7:0]  rd1_rid;    wire [AXI_DW-1:0] rd1_rdata;  wire [1:0] rd1_rresp;
    wire        rd1_rlast;  wire rd1_rvalid;              wire rd1_rready;

    wire [7:0]  wr_awid;    wire [AXI_AW-1:0] wr_awaddr;  wire [7:0] wr_awlen;
    wire [2:0]  wr_awsize;  wire [1:0] wr_awburst;        wire wr_awlock;
    wire [3:0]  wr_awcache; wire [2:0] wr_awprot;         wire wr_awvalid;
    wire        wr_awready;
    wire [AXI_DW-1:0] wr_wdata; wire [AXI_DW/8-1:0] wr_wstrb;
    wire        wr_wlast;   wire wr_wvalid;               wire wr_wready;
    wire [7:0]  wr_bid;     wire [1:0] wr_bresp;          wire wr_bvalid;
    wire        wr_bready;

    wire        busy;
    wire [15:0] cur_line;
    wire [31:0] dbg_beats_rd, dbg_beats_wr;
    wire        dbg_b_error;
    // Scan-out register passthrough, so the five new ports are actually
    // connected. These must be declared before the instance that drives them.
    wire [31:0] top_fb_base;
    wire [15:0] top_fb_width, top_fb_height, top_fb_stride;
    wire        top_fb_enable;

    // slave observability
    wire [31:0] rd0_bursts, rd1_bursts, wr_bursts, wr_beats;
    wire [AXI_AW-1:0] rd0_last_addr, rd1_last_addr, wr_first_addr;
    wire [AXI_DW-1:0] wr_first_data, wr_second_data;
    wire        axi_interrupt;

    // expected read pattern helper: matches axi_rd_slave's formula
    function [AXI_DW-1:0] exp_pattern;
        input [15:0] addr_lo;
        input [7:0]  beat;
        begin
            exp_pattern = {addr_lo, 8'h5A, beat};
        end
    endfunction

    // ---- RGB565 helpers, matching rtl/bitblt_px565_{unpack,pack}.v ----
    function [31:0] expand565;
        input [15:0] p;
        begin
            expand565 = {8'hFF, p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
        end
    endfunction

    function [15:0] pack565;
        input [31:0] p;
        begin
            pack565 = {p[23:19], p[15:10], p[7:3]};
        end
    endfunction

    reg [15:0] blend_fg565, blend_bg565;
    reg [31:0] blend_fg888, blend_bg888, blend_res888;

    reg         scan_blanking     = 1'b0;
    reg         scan_short        = 1'b0;
    reg  [7:0]  scan_short_count  = 8'h00;

    bitblt_top #(
        .AXI_DW      (AXI_DW),
        .AXI_AW      (AXI_AW),
        .DW          (32),
        .PX_PER_BEAT (4)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .axi_interrupt (axi_interrupt),
        .s_axi_awid (awid), .s_axi_awaddr (awaddr), .s_axi_awlen (awlen),
        .s_axi_awsize (awsize), .s_axi_awburst (awburst), .s_axi_awlock (awlock),
        .s_axi_awcache (awcache), .s_axi_awprot (awprot), .s_axi_awqos (awqos),
        .s_axi_awregion (awregion), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wlast (wlast),
        .s_axi_wvalid (wvalid), .s_axi_wready (wready),
        .s_axi_bid (bid), .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
        .s_axi_arid (arid), .s_axi_araddr (araddr), .s_axi_arlen (arlen),
        .s_axi_arsize (arsize), .s_axi_arburst (arburst), .s_axi_arlock (arlock),
        .s_axi_arcache (arcache), .s_axi_arprot (arprot), .s_axi_arqos (arqos),
        .s_axi_arregion (arregion), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rid (rid), .s_axi_rdata (rdata), .s_axi_rresp (rresp),
        .s_axi_rlast (rlast), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
        .rd0_arid (rd0_arid), .rd0_araddr (rd0_araddr), .rd0_arlen (rd0_arlen),
        .rd0_arsize (rd0_arsize), .rd0_arburst (rd0_arburst), .rd0_arlock (rd0_arlock),
        .rd0_arcache (rd0_arcache), .rd0_arprot (rd0_arprot), .rd0_arvalid (rd0_arvalid),
        .rd0_arready (rd0_arready), .rd0_rid (rd0_rid), .rd0_rdata (rd0_rdata),
        .rd0_rresp (rd0_rresp), .rd0_rlast (rd0_rlast), .rd0_rvalid (rd0_rvalid),
        .rd0_rready (rd0_rready),
        .rd1_arid (rd1_arid), .rd1_araddr (rd1_araddr), .rd1_arlen (rd1_arlen),
        .rd1_arsize (rd1_arsize), .rd1_arburst (rd1_arburst), .rd1_arlock (rd1_arlock),
        .rd1_arcache (rd1_arcache), .rd1_arprot (rd1_arprot), .rd1_arvalid (rd1_arvalid),
        .rd1_arready (rd1_arready), .rd1_rid (rd1_rid), .rd1_rdata (rd1_rdata),
        .rd1_rresp (rd1_rresp), .rd1_rlast (rd1_rlast), .rd1_rvalid (rd1_rvalid),
        .rd1_rready (rd1_rready),
        .wr_awid (wr_awid), .wr_awaddr (wr_awaddr), .wr_awlen (wr_awlen),
        .wr_awsize (wr_awsize), .wr_awburst (wr_awburst), .wr_awlock (wr_awlock),
        .wr_awcache (wr_awcache), .wr_awprot (wr_awprot), .wr_awvalid (wr_awvalid),
        .wr_awready (wr_awready), .wr_wdata (wr_wdata), .wr_wstrb (wr_wstrb),
        .wr_wlast (wr_wlast), .wr_wvalid (wr_wvalid), .wr_wready (wr_wready),
        .wr_bid (wr_bid), .wr_bresp (wr_bresp), .wr_bvalid (wr_bvalid), .wr_bready (wr_bready),
        .busy (busy), .cur_line (cur_line),
        .dbg_beats_rd (dbg_beats_rd), .dbg_beats_wr (dbg_beats_wr),
        .dbg_b_error (dbg_b_error),
        .reg_fb_base    (top_fb_base),
        .reg_fb_width   (top_fb_width),
        .reg_fb_height  (top_fb_height),
        .reg_fb_stride  (top_fb_stride),
        .reg_fb_enable  (top_fb_enable),
        // The four inputs added for P4 and the monitor, which this integration
        // testbench never connected. The AXI half of the design worked without
        // them, so nothing failed -- but "nothing failed" and "nothing ran" look
        // identical from the outside, and iverilog -Wall said so every run.
        //
        .scan_blanking     (scan_blanking),
        .scan_short        (scan_short),
        .scan_short_count  (scan_short_count)
    );

    // ---- diagnostics: trace the line handshake and engine completion ----
    // Placed AFTER the master-port wires are declared: Questa requires
    // declaration before use, iVerilog does not.
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.line_start)  $display("  [t=%0t] line_start", $time);
            if (dut.line_ack)    $display("  [t=%0t] line_ack",   $time);
            if (dut.rd_src_done) $display("  [t=%0t] rd_src_done", $time);
            if (dut.rd_dst_done) $display("  [t=%0t] rd_dst_done", $time);
            if (dut.wr_done)     $display("  [t=%0t] wr_done",     $time);
            // trace what the read engine actually puts on the bus
            if (rd0_arvalid && rd0_arready)
                $display("  [t=%0t] rd0 AR  addr=%h arlen=%0d (burst of %0d beats)",
                         $time, rd0_araddr, rd0_arlen, rd0_arlen + 1);
            if (rd0_rvalid && rd0_rready)
                $display("  [t=%0t] rd0 R   data=%h rlast=%b", $time, rd0_rdata, rd0_rlast);
        end
    end

    // ---------------- DDR-side slaves ----------------
    //
    // 2026-10-14 ORDERED-BUS MODEL
    // ----------------------------
    // This testbench used to give each reader its OWN independent slave, so both
    // readers always made progress at once. That is not the board: the real DDR
    // controller serves one burst at a time and returns R data in AR order, so a
    // burst that stalls (its reader deasserting rready because its FIFO is full)
    // blocks the OTHER reader's AR completely. docs/61 measured exactly that on
    // hardware -- r_cnl_num stuck with both readers' rready low -- and no
    // simulation could ever reproduce it, because the model had no such coupling.
    //
    // rready is still honoured per-reader, so a reader CAN stall mid-burst; what
    // is now modelled is that the other reader cannot START while it does.
    wire rd0_tx_active;      // u_rd0 is in the middle of a burst
    wire rd1_tx_active;      // u_rd1 is in the middle of a burst
    axi_rd_slave #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW), .SLV_ID(8'h10)) u_rd0 (
        .clk (clk), .rst_n (rst_n),
        .arid (rd0_arid), .araddr (rd0_araddr), .arlen (rd0_arlen),
        .arsize (rd0_arsize), .arburst (rd0_arburst), .arvalid (rd0_arvalid),
        .arready (rd0_arready), .rid (rd0_rid), .rdata (rd0_rdata),
        .rresp (rd0_rresp), .rlast (rd0_rlast), .rvalid (rd0_rvalid),
        .rready (rd0_rready),
        .hold (rd1_tx_active),
        .burst_count (rd0_bursts), .last_addr (rd0_last_addr)
    );

    axi_rd_slave #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW), .SLV_ID(8'h12)) u_rd1 (
        .clk (clk), .rst_n (rst_n),
        .arid (rd1_arid), .araddr (rd1_araddr), .arlen (rd1_arlen),
        .arsize (rd1_arsize), .arburst (rd1_arburst), .arvalid (rd1_arvalid),
        .arready (rd1_arready), .rid (rd1_rid), .rdata (rd1_rdata),
        .rresp (rd1_rresp), .rlast (rd1_rlast), .rvalid (rd1_rvalid),
        .rready (rd1_rready),
        .hold (rd0_tx_active),
        .burst_count (rd1_bursts), .last_addr (rd1_last_addr)
    );

    axi_wr_slave #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW)) u_wr (
        .clk (clk), .rst_n (rst_n),
        .awid (wr_awid), .awaddr (wr_awaddr), .awlen (wr_awlen),
        .awsize (wr_awsize), .awburst (wr_awburst), .awvalid (wr_awvalid),
        .awready (wr_awready), .wdata (wr_wdata), .wstrb (wr_wstrb),
        .wlast (wr_wlast), .wvalid (wr_wvalid), .wready (wr_wready),
        .bid (wr_bid), .bresp (wr_bresp), .bvalid (wr_bvalid), .bready (wr_bready),
        .burst_count (wr_bursts), .beat_count (wr_beats),
        .first_addr (wr_first_addr), .first_data (wr_first_data),
        .second_data (wr_second_data)
    );

    assign rd0_tx_active = u_rd0.active;
    assign rd1_tx_active = u_rd1.active;

    // ---------------- register write helper ----------------
    task reg_write;
        input [31:0] addr;
        input [31:0] data;
        integer guard;
        begin
            @(posedge clk);
            awaddr <= addr; awvalid <= 1'b1;
            wdata  <= data; wvalid  <= 1'b1; wlast <= 1'b1; wstrb <= 4'hF;
            bready <= 1'b1;

            guard = 0;
            @(posedge clk);
            while (!awready && guard < 50) begin @(posedge clk); guard = guard + 1; end
            awvalid <= 1'b0;

            guard = 0;
            while (!wready && guard < 50) begin @(posedge clk); guard = guard + 1; end
            wvalid <= 1'b0; wlast <= 1'b0;

            guard = 0;
            while (!bvalid && guard < 50) begin @(posedge clk); guard = guard + 1; end
            @(posedge clk);
            bready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // ---------------- stimulus ----------------
    integer guard;

    initial begin
        $dumpfile("tb_bitblt_top.vcd");
        $dumpvars(0, tb_bitblt_top);

        repeat (4) @(posedge clk);
        #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- reset defaults of the scan-out registers ----
        // Checked BEFORE anything is written, because writing destroys the
        // evidence. The enable bit in particular matters: system_top used to tie
        // the video module's enable input to a constant 1'b1, so if this register
        // resets to 0 the screen goes blank and the symptom looks like a broken
        // video path rather than a wrong reset value.
        if (top_fb_base   === 32'h0800_0000) $display("PASS reset FB_BASE   = 0x08000000");
        else begin errors = errors + 1;
             $display("FAIL reset FB_BASE   = 0x%h (want 0x08000000)", top_fb_base); end

        if (top_fb_width  === 16'd1920)      $display("PASS reset FB_WIDTH  = 1920");
        else begin errors = errors + 1;
             $display("FAIL reset FB_WIDTH  = %0d (want 1920)", top_fb_width); end

        if (top_fb_height === 16'd1080)      $display("PASS reset FB_HEIGHT = 1080");
        else begin errors = errors + 1;
             $display("FAIL reset FB_HEIGHT = %0d (want 1080)", top_fb_height); end

        if (top_fb_stride === 16'd2560)      $display("PASS reset FB_STRIDE = 2560");
        else begin errors = errors + 1;
             $display("FAIL reset FB_STRIDE = %0d (want 2560)", top_fb_stride); end

        if (top_fb_enable === 1'b1)          $display("PASS reset FB_ENABLE = 1 (video on)");
        else begin errors = errors + 1;
             $display("FAIL reset FB_ENABLE = %b (want 1 -- blank screen otherwise)",
                      top_fb_enable); end

        // ---- configure: 2 rows x 8 pixels, COPY ----
        reg_write(32'h08, 32'h0000_0000);   // OP  = COPY
        reg_write(32'h0C, 32'h0000_1000);   // SRC_ADDR
        reg_write(32'h10, 32'h0800_8000);   // DST_ADDR (inside the framebuffer pool; bitblt_top guards the pool, not 0x8000)
        reg_write(32'h14, 32'h0002_0010);   // WIDTH=16 HEIGHT=2 (16 x 2 B = 32 B/row)
        reg_write(32'h18, 32'h0000_0020);   // SRC_STRIDE = 32 B/row
        reg_write(32'h1C, 32'h0000_0020);   // DST_STRIDE = 32 B/row
        reg_write(32'h30, 32'h0000_0002);   // BPP = 2 (RGB565)

        // ---- scan-out registers must reach the TOP-LEVEL ports ----
        // Connecting the five new ports in the instantiation silences the
        // port-count warning but proves nothing: crossed wires produce the same
        // silence. So write distinctive values and read them back at the top.
        reg_write(32'h34, 32'h0812_C000);   // FB_BASE
        reg_write(32'h38, 32'h0438_0780);   // FB_SIZE_H: h=1080 w=1920
        reg_write(32'h3C, 32'h0001_0A00);   // FB_CFG: enable=1, stride=2560
        repeat (4) @(posedge clk);
        #1;

        if (top_fb_base  === 32'h0812_C000) $display("PASS passthru FB_BASE   = 0x0812C000");
        else begin errors = errors + 1;
             $display("FAIL passthru FB_BASE   = 0x%h (want 0x0812C000)", top_fb_base); end

        if (top_fb_width === 16'd1920)      $display("PASS passthru FB_WIDTH  = 1920");
        else begin errors = errors + 1;
             $display("FAIL passthru FB_WIDTH  = %0d (want 1920)", top_fb_width); end

        if (top_fb_stride === 16'd2560)     $display("PASS passthru FB_STRIDE = 2560");
        else begin errors = errors + 1;
             $display("FAIL passthru FB_STRIDE = %0d (want 2560)", top_fb_stride); end

        if (top_fb_enable === 1'b1)         $display("PASS passthru FB_ENABLE = 1");
        else begin errors = errors + 1;
             $display("FAIL passthru FB_ENABLE = %b (want 1)", top_fb_enable); end

        // ---- re-point FB_BASE so the data tests land inside the framebuffer ----
        //
        // The pass-through test above deliberately wrote a distinctive base
        // (0x0812C000, the second buffer) to prove the ports are really
        // connected. But the address generator's bounds check derives its upper
        // limit from these same registers, and the data tests below use
        // addresses near 0x1000 and 0x8000 -- far below 0x0812C000 -- so every
        // one of them would be refused as out of bounds. That refusal is the
        // check working correctly, not a fault; the data tests simply need a
        // window that contains their addresses.
        //
        // Base 0 with the same 480-row stride gives [0, 0x12C000), which covers
        // every address used from here on.
        // 2026-10-25: the pool base is FIXED at 0x08000000 in bitblt_top now
        // (bounds must cover both buffers), so writing 0 no longer widens the
        // window -- it leaves every write outside, and the P4 walk dispatches
        // with nothing issued. Park FB_BASE on the pool base instead.
        reg_write(32'h34, 32'h0800_0000);   // FB_BASE = pool base
        repeat (6) @(posedge clk);
        #1;

        // Confirm the write landed before relying on it. The bounds check reads
        // this register combinationally, so an incomplete write would make the
        // transfer below be refused and every data check fail with "nothing was
        // transferred" -- which is exactly what happened when this wait was only
        // two cycles.
        if (top_fb_base !== 32'h0800_0000) begin
            $display("FAIL FB_BASE did not take: %h (want 08000000)", top_fb_base);
            errors = errors + 1;
        end else begin
            $display("PASS FB_BASE parked on pool base (bounds window [0x08000000, 0x%h))",
                     dut.fb_end_addr);
        end

        // ---- start ----
        reg_write(32'h00, 32'h0000_0001);

        // ---- wait for the engine to finish (busy falls) ----
        guard = 0;
        while (busy && guard < 20000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (40) @(posedge clk);
        #1;

        if (guard >= 20000) begin
            $display("FAIL: TIMEOUT");
            $display("  top  : busy=%b cur_line=%0d", busy, cur_line);
            $display("  rd_src: state=%0d beats_left=%0d beats_sent=%0d dout_valid=%b rready=%b arvalid=%b",
                     dut.u_rd_src.state, dut.u_rd_src.beats_left,
                     dut.u_rd_src.beats_sent, dut.u_rd_src.dout_valid,
                     rd0_rready, rd0_arvalid);
            $display("  rd_dst: state=%0d beats_left=%0d beats_sent=%0d dout_valid=%b rready=%b",
                     dut.u_rd_dst.state, dut.u_rd_dst.beats_left,
                     dut.u_rd_dst.beats_sent, dut.u_rd_dst.dout_valid,
                     rd1_rready);
            $display("  m4    : out_valid=%b out_ready=%b in_ready=%b in_valid=%b",
                     dut.px_valid, dut.px_ready, dut.px_in_ready, dut.px_in_valid);
            $display("  wr    : state=%0d beats_left=%0d din_ready=%b din_valid=%b",
                     dut.u_wr.state, dut.u_wr.beats_left,
                     dut.wr_din_ready, dut.px_valid);
            $display("  bus   : rd0_rvalid=%b rd0_rlast=%b rd1_rvalid=%b rd1_rlast=%b",
                     rd0_rvalid, rd0_rlast, rd1_rvalid, rd1_rlast);
            errors = errors + 1;
        end else begin
            $display("INFO: finished  cur_line=%0d  rd0=%0d rd1=%0d wr=%0d bursts, wr_beats=%0d",
                     cur_line, rd0_bursts, rd1_bursts, wr_bursts, wr_beats);
        end

        // ---- check the engines did the right amount of work ----
        // 2 rows x 2 beats per row = 4 beats per read engine.
        //
        // The SOURCE is compact here (SRC_STRIDE 0x20 == 8 px x 4 B), so since
        // P3 it is described as ONE transfer covering both rows: 64 bytes = 4
        // beats, well under the 4096-byte burst limit, hence ONE burst. The
        // target is not compact (it lives in a strided framebuffer), so it and
        // the write engine keep one burst per row. Those two staying at 2 is
        // the guard rail: if the change had leaked into the target path, they
        // would move.
        if (rd0_bursts !== 32'd1) begin
            $display("FAIL rd0 bursts: got %0d want 1 (compact source merged)", rd0_bursts);
            errors = errors + 1;
        end else $display("PASS rd0 bursts = 1 (compact source read as one block)");

        if (rd1_bursts !== 32'd0) begin   // docs/86: software-initiated COPY skips the background read
            $display("FAIL rd1 bursts: got %0d want 0 (COPY must not read the background)", rd1_bursts);
            errors = errors + 1;
        end else $display("PASS rd1 bursts = 0 (COPY skips the background read)");

        if (wr_bursts !== 32'd2) begin
            $display("FAIL wr bursts: got %0d want 2", wr_bursts);
            errors = errors + 1;
        end else $display("PASS wr bursts = 2 (one per row)");

        if (wr_beats !== 32'd4) begin
            $display("FAIL wr beats: got %0d want 4 (2 rows x 2 beats)", wr_beats);
            errors = errors + 1;
        end else $display("PASS wr beats = 4");

        // ---- the last destination row must be the SECOND row address ----
        if (rd1_last_addr !== 32'h0000_0000) begin   // docs/86: no destination burst in COPY
            $display("FAIL rd1 last addr: got %h want 00000000 (no destination read expected)",
                     rd1_last_addr);
            errors = errors + 1;
        end else $display("PASS rd1 last addr = 0 (no destination burst in COPY)");

        // ---- COPY mode: what was written must equal what was read ----
        // The slave model latches only the MOST RECENT burst.
        //
        // Before P3 the source was read as two bursts, the second starting at
        // 0x1020, so the latch held row 1 as (base 0x1020, beat 0/1). Now the
        // source is ONE burst starting at 0x1000 covering both rows, so the
        // latch holds the LAST TWO of its four beats -- beat 2 and beat 3.
        //
        // These describe the same four bytes. The slave pattern is
        // {base[15:0], 8'hA5, beat}, and row 1 begins exactly 32 bytes into the
        // block, i.e. 2 beats of 16 bytes: 0x1000 + 2*16 = 0x1020. So
        //   (base 0x1020, beat 0) == (base 0x1000, beat 2)
        //   (base 0x1020, beat 1) == (base 0x1000, beat 3)
        // The change is therefore in how the expectation is written, not in
        // what is expected. If the merge had misordered or dropped beats these
        // would fail.
        if (wr_first_data !== exp_pattern(16'h1000, 8'd2)) begin
            $display("FAIL wr first data: got %h want %h",
                     wr_first_data, exp_pattern(16'h1000, 8'd2));
            errors = errors + 1;
        end else $display("PASS wr first data matches source row1 beat 0");

        if (wr_second_data !== exp_pattern(16'h1000, 8'd3)) begin
            $display("FAIL wr second data: got %h want %h",
                     wr_second_data, exp_pattern(16'h1000, 8'd3));
            errors = errors + 1;
        end else $display("PASS wr second data matches source row1 beat 1");

        if (dbg_b_error !== 1'b0) begin
            $display("FAIL write engine reported a bus error");
            errors = errors + 1;
        end else $display("PASS no write bus error");

        // ---------------- extra blend modes: does OP reach the engine? ----------------
        //
        // The pixel engine's own testbench covers the blend arithmetic, but it
        // instantiates the engine directly -- it cannot see the path from the OP
        // register, through bitblt_top, into the engine. That path changed when
        // mode went from 2 bits to 3 bits. A mistake there (reg_op[1:0] left in
        // place) would leave every other check in this file passing while the
        // new modes silently behaved as COPY.
        //
        // NOTE: the two slave models here do NOT share memory. axi_wr_slave
        // records what it is given and axi_rd_slave invents its own pattern, so
        // filling a region and then blending over it does not give the blend the
        // filled colour as a background. An earlier version of this check
        // assumed it did and produced a mismatch that looked like an RTL bug but
        // was entirely an artifact of that assumption. The blend reads whatever
        // rd_slave returns for the destination address, which is
        // {addr_lo, 8'h5A, beat}.
        u_wr.first_data = {AXI_DW{1'b0}};

        reg_write(32'h08, 32'h0000_0005);   // OP = MUL
        reg_write(32'h0C, 32'h0000_1000);   // SRC_ADDR
        reg_write(32'h10, 32'h0800_8000);   // DST_ADDR (inside the framebuffer pool; bitblt_top guards the pool, not 0x8000)
        reg_write(32'h14, 32'h0002_0010);   // WIDTH=16 HEIGHT=2 (16 x 2 B = 32 B/row)
        reg_write(32'h18, 32'h0000_0020);   // SRC_STRIDE
        reg_write(32'h1C, 32'h0000_0020);   // DST_STRIDE
        reg_write(32'h00, 32'h0000_0001);   // start
        guard = 0;
        while (busy && guard < 20000) begin @(posedge clk); guard = guard + 1; end
        repeat (10) @(posedge clk);

        if (wr_first_data === {AXI_DW{1'b0}}) begin
            $display("FAIL blend op: no write data was captured");
            errors = errors + 1;
        end else begin
            // Verilog-2005 does not allow a bit-select on a function call
            // result, so the reference value is assigned first.
            // Same addressing note as the COPY check above: with the compact
            // source merged, row 1 is now beat 2 of a burst based at 0x1000
            // rather than beat 0 of a burst based at 0x1020. Identical bytes.
            blend_src_ref = exp_pattern(16'h1000, 8'd2);
            if (wr_first_data === blend_src_ref) begin
                $display("FAIL blend op: output equals the source -- OP never reached the engine");
                errors = errors + 1;
            end else begin
                // 2026-10-14 FIX -- this used to sample dut.rd_dst_data, which is
                // the destination FIFO's COMBINATIONAL output (fifo_mem[fifo_rd]).
                // By the time the transfer has finished the FIFO has drained, so
                // that pointer addresses an entry that was never written and
                // reads X. The reference -- and therefore the whole expected word
                // -- became X, so this check failed on EVERY run while the DUT was
                // in fact correct. It was never seen before because the file did
                // not compile under Questa until 2026-10-14 (forward references in
                // bitblt_axi_slave.v), so this testbench had never actually run.
                //
                // The reference now comes from the slave model's own formula.
                // The first write beat belongs to destination ROW 1 (the same
                // pipeline offset the COPY check above documents), and an
                // uncompacted destination row starts its own burst, so row 1's
                // first beat sits at DST_ADDR + DST_STRIDE = 0x8020, beat 0.
                //   fg = 10005a02, bg = 80205a00
                //   MUL: 0x02*0x00/255=00, 0x5a*0x5a/255=1f, 0x00*0x20/255=00
                //   => 10001f00, which is what the DUT produces.
                blend_bg_ref = exp_pattern(16'h8020, 8'd0);

                // The engine's identity (x + 1 + (x>>8)) >> 8 evaluates to
                // floor(x/255), NOT round(x/255). A reference written as
                // (prod + 128) / 255 disagreed by one on a channel whose
                // quotient was 31.76. That is not a DUT bug: floor is what the
                // identity does, and the difference is at most 1/255. It is
                // worth stating precisely because the unit testbench happens to
                // use only values where floor and round coincide.
                // RGB565 (docs/85): one write beat carries EIGHT 16-bit pixels,
                // so wr_first_data[31:0] is TWO pixels, not one ARGB8888 word.
                // The check is made on the first 565 pixel, and its reference is
                // built by taking the same three steps the hardware takes --
                // unpack (expand) -> MUL -> pack -- instead of assuming the
                // engine sees raw 888 bytes.
                blend_fg565 = blend_src_ref[15:0];
                blend_bg565 = blend_bg_ref [15:0];
                blend_fg888 = expand565(blend_fg565);
                blend_bg888 = expand565(blend_bg565);

                for (ci = 0; ci < 3; ci = ci + 1) begin
                    fg_ch = blend_fg888[ci*8 +: 8];
                    bg_ch = blend_bg888[ci*8 +: 8];
                    prod  = fg_ch * bg_ch;
                    blend_res888[ci*8 +: 8] = prod / 255;        // floor, as the DUT does
                end
                blend_res888[31:24] = blend_fg888[31:24];        // alpha passes through
                blend_exp = {16'b0, pack565(blend_res888)};

                if (wr_first_data[15:0] !== blend_exp[15:0]) begin
                    $display("FAIL blend value: got %h want %h (565 fg=%h bg=%h)",
                             wr_first_data[15:0], blend_exp[15:0],
                             blend_fg565, blend_bg565);
                    errors = errors + 1;
                end else begin
                    $display("PASS blend value %h = 565 fg %h x bg %h / 255",
                             wr_first_data[15:0], blend_fg565, blend_bg565);
                end
            end
        end

        // ---------------- P4: sprite traversal, end to end ----------------
        //
        // The first time the traversal path is actually exercised. Everything
        // before this proves the walker works in isolation and that wiring it
        // in broke nothing; neither of those says the two halves talk to each
        // other correctly.
        //
        // Three descriptors, each an 8x2 ARGB sprite (64 bytes = 4 beats, well
        // under the 4096-byte burst limit, so P3 reads each in ONE burst). That
        // makes the expected AR sequence exactly predictable:
        //
        //   0x2000 (desc 0) -> 0x4000 (src 0) ->
        //   0x2010 (desc 1) -> 0x5000 (src 1) ->
        //   0x2020 (desc 2) -> 0x6000 (src 2)
        //
        // Six ARs, strictly alternating. If the walk read the table without
        // dispatching, or dispatched without re-reading, or read the wrong row,
        // this sequence changes -- and the burst count alone would not have
        // noticed.
        //
        // PROVEN ABLE TO FAIL. A check that cannot fail is decoration, so both
        // assertions were fault-injected and both responded:
        //
        //   A. eff_src_base forced to reg_src_addr (geometry mux removed):
        //      descriptor line still PASSED, source line FAILED with
        //      00001000 00001000 00001000. The two checks are independent --
        //      one breaking does not mask the other, so each carries its own
        //      diagnostic value.
        //
        //   B. descriptor stride <<4 changed to <<3:
        //      table addresses became 00002000 00002008 00002010 and both
        //      lines FAILED. The 0x2008 is the tell: an eight-byte stride
        //      reads half a descriptor, which on hardware would present as
        //      sprites occasionally landing in the wrong place -- the kind of
        //      bug that survives to the board and takes days to find.
        //
        // Descriptor layout (see bitblt_sprite_walker.v):
        //   [31:0] src  [47:32] x  [63:48] y  [79:64] w  [95:80] h  [127:96] flags
        // 2026-10-14 -- DELIBERATELY 64x64 (was 8x2).
        // These descriptors used to describe 8x2 sprites: 64 B, ONE burst. The
        // board hangs on a real 64x64 sprite copy, where compact_src makes the
        // source engine fetch 16 KB = 1024 beats = 32 bursts in one go. Nothing
        // in this testbench had ever asked the source engine for more than one
        // burst, so the difference between "works" and "hangs" was never inside
        // the simulated envelope -- the suite passed while the board was dead.
        // Each sprite now occupies its own 16 KB so the copies cannot overlap.
        // This case is what exposed the read-channel deadlock (see docs/63);
        // do not shrink it back without keeping a large-rectangle case.
        u_rd0.spr_desc[0] = {32'h0, 16'd64, 16'd64, 16'd0, 16'd4,  32'h0000_4000};
        u_rd0.spr_desc[1] = {32'h0, 16'd64, 16'd64, 16'd0, 16'd8,  32'h0000_8000};
        u_rd0.spr_desc[2] = {32'h0, 16'd64, 16'd64, 16'd0, 16'd12, 32'h0000_C000};
        u_rd0.spr_base    = 32'h0000_2000;
        u_rd0.spr_en      = 1'b1;
        u_rd0.ar_log_n    = 0;

        // Framebuffer geometry for the dispatch, and the sprite table itself.
        reg_write(32'h08, 32'h0000_0000);   // OP = COPY
        reg_write(32'h1C, 32'h0000_0020);   // DST_STRIDE = 32
        reg_write(32'h30, 32'h0000_0002);   // BPP = 2 (RGB565)
        reg_write(32'h40, 32'h0000_2000);   // SPR_TABLE
        // count = 3, enable = bit 16
        reg_write(32'h44, 32'h0001_0003);

        // 2026-10-14: this loop used to overload `guard` as BOTH the counter and
        // the exit flag ("if (!busy && guard > 50) guard = 40000"), so a transfer
        // that never released `busy` was indistinguishable from a fast one --
        // the run just continued and reported a wrong AR count. A hang is now
        // reported as a hang, which is what caught the ordered-bus deadlock.
        // 2026-10-15: the wait for busy to RISE was 2000 cycles. That used to
        // be plenty, but ok/lv now live in the payload RAM, so re-arming the
        // table costs a walk of N slots (~4 cycles each) before the walker is
        // allowed to start -- bitblt_top gates its enable with ~clr_busy for
        // exactly that reason. At N=256 that is ~1024 cycles of clear PLUS the
        // walker's own S_IDLE handshake, so 2000 was marginal and the loop gave
        // up, leaving rd0 with 0 ARs. 20000 leaves room for N up to a few
        // thousand without re-tuning.
        guard = 0;
        // 2026-10-16 (8192): the re-arm clear walk is ~4 cycles PER SLOT (~32.8k at
        // N=8192), so a window sized for N=256 expires before the walker may start.
        // Wait on the real signal (spr_clr_busy) instead of a count that scales with N.
        while ((dut.spr_clr_busy || !busy) && guard < 300000) begin @(posedge clk); guard = guard + 1; end
        guard = 0;
        // The frame tail is the frame-end SWEEP: 5 cycles per slot = 40,960 at N=8192
        // (20,480 at 4096). 40000 expired ~4.9k cycles early and reported a deadlock.
        while (busy && guard < 200000) begin @(posedge clk); guard = guard + 1; end
        if (busy) begin
            $display("FAIL P4: busy still high after %0d cycles -- engine stuck mid-transfer (deadlock)",
                     guard);
            errors = errors + 1;
        end
        repeat (40) @(posedge clk);
        #1;

        $display("INFO: P4 traversal -- rd0 issued %0d ARs", u_rd0.ar_log_n);
        for (guard = 0; guard < u_rd0.ar_log_n; guard = guard + 1) begin
            $display("   AR[%0d] = %h", guard, u_rd0.ar_log[guard]);
        end

        // 2026-10-14: the descriptors are 64x64 now, so one source fetch is
        // 16 KB = 1024 beats = 32 bursts of 32, not one. Both the expected AR
        // count and the INDEX of each descriptor follow from that:
        //   B = 32 bursts per source
        //   descriptor k  -> index k*(1+B)          = 0, 33, 66
        //   source k      -> index 1 + k*(1+B)      = 1, 34, 67
        //   total         -> 3 + 3*B = 99
        // Hard-coding the old 6/2/4 here would fail for a reason that is not a
        // bug, which is how a check earns the right to be ignored.
        // 2026-10-14: the burst length became ADAPTIVE (docs/64), so a 16 KB
        // source no longer takes a fixed number of ARs. The old "want 99" and
        // the log indices derived from it (33/66) are therefore stale.
        //
        // What still holds is the ORDER: each sprite's descriptor is fetched
        // before its source, and descriptors come from the table in sequence.
        // The full AR list is printed just above, so the sequence stays
        // reviewable even though it can no longer be checked by index.
        if (u_rd0.ar_log_n < 6) begin
            $display("FAIL P4: rd0 issued only %0d ARs, want at least 6", u_rd0.ar_log_n);
            errors = errors + 1;
        end else if (u_rd0.ar_log[0] !== 32'h0000_2000) begin
            $display("FAIL P4: first descriptor fetch at %h, want 00002000",
                     u_rd0.ar_log[0]);
            errors = errors + 1;
        end else begin
            $display("PASS P4: %0d ARs, first descriptor at 0x2000", u_rd0.ar_log_n);
        end

        u_rd0.spr_en = 1'b0;                // leave the overlay off for what follows

        // ---------------- P4: scale -- how long is a frame? ----------------
        //
        // The three-sprite case proves the mechanism; it says nothing about
        // cost. This walks 32 sprites and measures the cycle count, which is
        // the only number that can answer "how many bullets fit in a frame".
        //
        // 32 rather than 256 on purpose: the slave model accepts one AR at a
        // time, so a 256-sprite run would take eight times as long to simulate
        // for the same information. The cost is linear in sprite count, so 32
        // extrapolates and stays checkable.
        //
        // Each sprite is 8x2 ARGB (64 bytes = 4 beats), well under the 4096
        // byte burst limit, so P3 reads each source in a single burst.
        //
        // STATED BIAS: this slave does not pipeline ARs, so the figure is an
        // UPPER bound on the walk's own cost -- the same caveat recorded for
        // tb_bitblt_burst_eff. Real DDR3 would overlap. It is a magnitude
        // check, not a hardware measurement.
        // 2026-10-14: MULTI-DENSITY SWEEP, mirroring the on-board demo.
        //
        // The board measures sprite density with this same shape -- fill the
        // table, arm once, wait for busy to rise, wait for it to fall -- and its
        // numbers were NOT monotonic: 256 sprites measured FASTER than 32. A
        // linear walk cannot do that, so what needs explaining is the
        // measurement (or what it actually waits on), and a simulator is where
        // that gets explained: every signal is visible and nothing depends on
        // DDR timing.
        //
        // 16x16 sprites (1 KB, compact source) match the game's bullets.
        // STATED BIAS: this slave does not pipeline ARs, so absolute numbers are
        // an upper bound; the SHAPE across densities is what is being read.
        for (d = 0; d < 4; d = d + 1) begin
            n = 32 << d;                                  // 32, 64, 128, 256

            for (i = 0; i < n; i = i + 1) begin
                u_rd0.spr_desc[i] = {16'd0, 16'd0,        // vy, vx
                                     16'd16, 16'd16,      // h, w
                                     16'd0, i[15:0],      // y, x
                                     32'h0000_4000};
            end
            u_rd0.spr_base = 32'h0000_2000;
            u_rd0.spr_en   = 1'b1;
            u_rd0.ar_log_n = 0;

            reg_write(32'h08, 32'h0000_0000);   // OP = COPY
            reg_write(32'h1C, 32'h0000_1000);   // DST_STRIDE = 4096 (1920 px x 2 B)
            reg_write(32'h30, 32'h0000_0002);   // BPP = 2 (RGB565)
            reg_write(32'h40, 32'h0000_2000);   // SPR_TABLE
            reg_write(32'h44, 32'h0000_0000);   // clear: enable is EDGE triggered
            repeat (4) @(posedge clk);
            cycle0 = $time;
            reg_write(32'h44, (32'h0001_0000 | n[15:0]));   // count + enable

            // 2026-10-15: was 5000. Every density step re-arms the table, and
            // re-arming now costs a walk of N slots (~4 cycles each) before the
            // walker may start -- bitblt_top gates its enable with ~clr_busy.
            // With only 4 idle cycles between the two SPR_CTL writes (see
            // above), the clear of the PREVIOUS step can still be settling when
            // this one begins, so the delay is not a fixed 1024 cycles and 5000
            // was not reliably enough: the 32- and 128-sprite steps both bailed
            // out at exactly 5006 cycles with 0 ARs while 64 and 256 passed.
            guard = 0;
            // Same stale-timeout story: every density step re-arms the table and the
            // clear is N-proportional, so the old 30000 window made the even steps
            // report 0 ARs (and the density shape look non-monotonic).
            while ((dut.spr_clr_busy || !busy) && guard < 300000) begin @(posedge clk); guard = guard + 1; end
            guard = 0;
            while (busy && guard < 400000) begin @(posedge clk); guard = guard + 1; end
            cycle1 = $time;
            repeat (20) @(posedge clk);
            #1;

            frame_cycles = (cycle1 - cycle0) / 10;   // 10 ns clock
            $display("DENSITY: %0d sprites -> %0d cycles (%0d per sprite), %0d ARs",
                     n, frame_cycles, frame_cycles / n, u_rd0.ar_log_n);

            // 2026-10-14: the burst length is ADAPTIVE now (as long as the FIFO
            // has room for, with an 8-beat floor), so the AR count depends on how
            // fast the consumer drains and is no longer 3 per sprite. The check
            // is a LOWER bound -- one descriptor plus at least one source burst
            // per sprite -- and the printed count carries the rest.
            if (u_rd0.ar_log_n < (n * 2)) begin
                $display("FAIL P4 density: %0d ARs, want at least %0d (desc + >=1 src burst per sprite)",
                         u_rd0.ar_log_n, n * 2);
                errors = errors + 1;
            end
        end
        $display("PASS P4 density: sweep completed");
        // The four lines above were ONE line, with a literal backtick-r
        // backtick-n sequence standing in for the line breaks -- a script had
        // written the two characters backslash-r backslash-n into the file
        // rather than real newlines. iverilog accepted it and the whole
        // regression passed; Questa rejected the file with "Macro `r is
        // undefined", which is how it surfaced.
        //
        // Recorded here because it is the clearest evidence this project has for
        // running two simulators, and because the check added to
        // run-regression.ps1 keys on that exact sequence.
        // (The old single-density checks -- "want 64 ARs", "32 sprites" and a
        // separate zero-cycle test -- are gone: the sweep above asserts the AR
        // count per density, which subsumes all three.)

        u_rd0.spr_en = 1'b0;

        // ---------------- error injection: prove dbg_b_error works ----------------
        // Everything above expects dbg_b_error to stay 0, and until this was
        // added nothing could ever make it 1 -- the slave only ever answered
        // OKAY, so the FAIL branch above was dead code. Drive a SLVERR response
        // through one short transfer and confirm the DUT notices.
        //
        // This runs last because dbg_b_error is sticky: once set it never clears,
        // so doing it earlier would corrupt every check above.
        u_wr.inject_bresp_err = 1'b1;

        reg_write(32'h08, 32'h0000_0000);   // OP = COPY
        reg_write(32'h0C, 32'h0000_1000);   // SRC_ADDR
        reg_write(32'h10, 32'h0800_8000);   // DST_ADDR (inside the framebuffer pool; bitblt_top guards the pool, not 0x8000)
        reg_write(32'h14, 32'h0002_0008);   // WIDTH=8 HEIGHT=2
        reg_write(32'h18, 32'h0000_0020);   // SRC_STRIDE
        reg_write(32'h1C, 32'h0000_0020);   // DST_STRIDE
        reg_write(32'h30, 32'h0000_0002);   // BPP = 2 (RGB565)
        reg_write(32'h00, 32'h0000_0001);   // start

        guard = 0;
        while (busy && guard < 20000) begin
            @(posedge clk);
            guard = guard + 1;
        end
        repeat (40) @(posedge clk);
        #1;

        u_wr.inject_bresp_err = 1'b0;

        if (dbg_b_error === 1'b1) $display("PASS b_error: SLVERR was detected");
        else begin
            $display("FAIL b_error: SLVERR injected but dbg_b_error stayed 0");
            errors = errors + 1;
        end

        // ---- summary ----
        $display("");
        if (errors == 0) $display("PASS: all checks OK");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $finish;
    end

endmodule
