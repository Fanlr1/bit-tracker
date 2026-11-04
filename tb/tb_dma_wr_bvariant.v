// Self-checking testbench for bitblt_dma_wr.
//
// The AXI write-slave model captures data/strobes so the TB can prove two
// things the read engine had no equivalent for:
//   1. din_strb is forwarded unchanged to m_axi_wstrb (per-pixel transparency)
//   2. every burst is acknowledged on B before the engine advances
`timescale 1ns / 1ps

module tb_dma_wr_bvariant;

    localparam AXI_DW = 128;
    localparam AXI_AW = 32;
    localparam STRB_W = AXI_DW / 8;      // 16

    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---------------- DUT ports ----------------
    reg                 start       = 1'b0;
    reg  [AXI_AW-1:0]   base_addr   = 32'h0000_2000;
    reg  [31:0]         total_bytes = 32'd0;
    wire                busy, done;
    wire                din_ready;
    wire [31:0]         beats_taken;

    reg  [AXI_DW-1:0]   din       = {AXI_DW{1'b0}};
    wire [STRB_W-1:0]   din_strb;
    reg                 din_valid = 1'b0;

    // The strobe pattern is derived from the data word ITSELF, so the two can
    // never skew relative to each other. (An earlier revision registered
    // din_strb from src_beat, but src_beat only advances on a handshake, so the
    // strobe lagged the data by one beat.)
    assign din_strb = (din[0] == 1'b0) ? {STRB_W{1'b1}}
                                       : {{(STRB_W-8){1'b1}}, 8'h00};

    wire [7:0]          m_axi_awid;
    wire [AXI_AW-1:0]   m_axi_awaddr;
    wire [7:0]          m_axi_awlen;
    wire [2:0]          m_axi_awsize;
    wire [1:0]          m_axi_awburst;
    wire                m_axi_awlock;
    wire [3:0]          m_axi_awcache;
    wire [2:0]          m_axi_awprot;
    wire                m_axi_awvalid;
    reg                 m_axi_awready = 1'b0;
    wire [AXI_DW-1:0]   m_axi_wdata;
    wire [STRB_W-1:0]   m_axi_wstrb;
    wire                m_axi_wlast;
    wire                m_axi_wvalid;
    reg                 m_axi_wready  = 1'b0;
    reg  [7:0]          m_axi_bid     = 8'h00;
    reg  [1:0]          m_axi_bresp   = 2'b00;
    reg                 m_axi_bvalid  = 1'b0;
    wire                m_axi_bready;
    wire                m_axi_b_error;

    integer errors      = 0;
    integer done_pulses = 0;

    // slave-side capture
    integer          total_w_beats = 0;
    integer          bursts_done   = 0;
    reg [STRB_W-1:0] cap_strb0, cap_strb1;
    reg [AXI_DW-1:0] cap_data0;

    bitblt_dma_wr #(.AXI_DW(AXI_DW), .AXI_AW(AXI_AW), .AXI_ID(8'h14)) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .base_addr     (base_addr),
        .total_bytes   (total_bytes),
        .busy          (busy),
        .done          (done),
        .din           (din),
        .din_strb      (din_strb),
        .din_valid     (din_valid),
        .din_ready     (din_ready),
        .beats_taken   (beats_taken),
        .m_axi_awid    (m_axi_awid),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_b_error (m_axi_b_error)
    );

    always @(posedge clk) if (done) done_pulses = done_pulses + 1;

    // ---------------- data source (stands in for the pixel engine) ----------------
    integer src_beat = 0;
    reg     src_rst  = 1'b0;

    // Index of the beat to present in the NEXT cycle. Using the current src_beat
    // would repeat one beat: din is registered every cycle, but src_beat only
    // advances on a handshake, so after a handshake the same word would be sent
    // twice.
    wire [31:0] beat_to_send = din_ready ? (src_beat + 1) : src_beat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || src_rst) begin
            src_beat  <= 0;
            din_valid <= 1'b0;
            din       <= {AXI_DW{1'b0}};
        end else begin
            din_valid <= 1'b1;
            din       <= {32'hBEEF0000, 32'h0, beat_to_send[31:16], beat_to_send[15:0]};
            src_beat  <= beat_to_send;
        end
    end

    // ---------------- AXI4 write-slave model ----------------
    localparam [1:0] SL_IDLE = 2'd0, SL_DATA = 2'd1, SL_RESP = 2'd2;
    reg [1:0] sl_state;
    integer   sl_w_beats;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sl_state      <= SL_IDLE;
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_bresp   <= 2'b00;
            sl_w_beats    <= 0;
        end else begin
            case (sl_state)
                // ---- wait for a command ----
                SL_IDLE: begin
                    m_axi_bvalid <= 1'b0;
                    if (m_axi_awvalid && m_axi_wvalid) begin
                        m_axi_awready <= 1'b1;
                        m_axi_wready  <= 1'b1;
                        sl_w_beats    <= 0;
                        sl_state      <= SL_DATA;
                    end
                end

                // ---- take the data beats ----
                SL_DATA: begin
                    if (m_axi_awready && m_axi_awvalid) m_axi_awready <= 1'b0;

                    if (m_axi_wready && m_axi_wvalid) begin
                        if (sl_w_beats == 0) begin
                            cap_data0 <= m_axi_wdata;
                            cap_strb0 <= m_axi_wstrb;
                        end
                        if (sl_w_beats == 1) begin
                            cap_strb1 <= m_axi_wstrb;
                        end

                        sl_w_beats    <= sl_w_beats + 1;
                        total_w_beats <= total_w_beats + 1;

                        if (m_axi_wlast) begin
                            m_axi_wready <= 1'b0;
                            // VARIANT B: raise BVALID one cycle earlier than the
                            // normal model, so it is ALREADY high on the cycle
                            // the DUT enters S_RESP. AXI permits this -- there is
                            // no minimum delay between the last W beat and
                            // BVALID. The stock testbench always left one cycle
                            // of slack here, and that slack is precisely what
                            // hid the BREADY defect.
                            m_axi_bvalid <= 1'b1;
                            sl_state     <= SL_RESP;
                        end
                    end
                end

                // ---- acknowledge the burst ----
                SL_RESP: begin
                    // BVALID was already raised in SL_DATA (variant B); the only
                    // thing left here is to complete the handshake.
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bvalid <= 1'b0;
                        m_axi_bresp  <= 2'b00;
                        bursts_done  <= bursts_done + 1;
                        sl_state     <= SL_IDLE;
                    end
                end

                default: sl_state <= SL_IDLE;
            endcase
        end
    end

    // ---------------- helper ----------------
    task run_transfer;
        input [31:0]  bytes;
        input [31:0]  exp_beats;
        input [31:0]  exp_bursts;
        input [255:0] name;
        integer guard;
        begin
            done_pulses   = 0;
            total_w_beats = 0;
            bursts_done   = 0;
            total_bytes   = bytes;

            // Restart the beat counter so the strobe pattern is deterministic.
            // src_beat otherwise runs continuously across transfers, and an odd
            // starting value makes the first beat's strobe look "wrong".
            @(posedge clk);
            src_rst <= 1'b1;
            @(posedge clk);
            src_rst <= 1'b0;

            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;

            guard = 0;
            while (!done && guard < 5000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            repeat (2) @(posedge clk);
            #1;

            if (guard >= 5000) begin
                $display("FAIL %0s: TIMEOUT  state=%0d awvalid=%b wvalid=%b bvalid=%b",
                         name, dut.state, m_axi_awvalid, m_axi_wvalid, m_axi_bvalid);
                errors = errors + 1;
            end else if (beats_taken !== exp_beats) begin
                $display("FAIL %0s: beats_taken=%0d want %0d", name, beats_taken, exp_beats);
                errors = errors + 1;
            end else if (total_w_beats !== exp_beats) begin
                $display("FAIL %0s: slave saw %0d beats want %0d", name, total_w_beats, exp_beats);
                errors = errors + 1;
            end else if (bursts_done !== exp_bursts) begin
                $display("FAIL %0s: bursts=%0d want %0d", name, bursts_done, exp_bursts);
                errors = errors + 1;
            end else if (done_pulses != 1) begin
                $display("FAIL %0s: done pulses=%0d want 1", name, done_pulses);
                errors = errors + 1;
            end else if (m_axi_b_error !== 1'b0) begin
                $display("FAIL %0s: unexpected b_error", name);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: beats=%0d bursts=%0d", name, beats_taken, bursts_done);
            end
            repeat (3) @(posedge clk);
        end
    endtask

    // ---------------- stimulus ----------------
    initial begin
        $dumpfile("tb_dma_wr_bvariant.vcd");
        $dumpvars(0, tb_dma_wr_bvariant);

        repeat (4) @(posedge clk);
        #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // 1) one row of 640 ARGB pixels = 2560 B = 160 beats -> 1 burst
        base_addr = 32'h0000_2000;
        run_transfer(32'd2560, 32'd160, 32'd1, "one-row-2560B");

        // 2) 8192 B = 512 beats -> 256 + 256 = 2 bursts
        base_addr = 32'h0000_9000;
        run_transfer(32'd8192, 32'd512, 32'd2, "multi-burst-8192B");

        // 3) 100 B -> ceil(100/16) = 7 beats
        base_addr = 32'h0000_3000;
        run_transfer(32'd100, 32'd7, 32'd1, "unaligned-100B");

        // 4) zero bytes -> immediate done, no burst
        base_addr = 32'h0000_4000;
        run_transfer(32'd0, 32'd0, 32'd0, "empty-transfer");

        // ---------------- strobe forwarding check ----------------
        // Re-run a short transfer and inspect the captured strobes: beat 0 must
        // be all-ones (4 opaque pixels) and beat 1 must have the high 2 pixels
        // masked off -- proving din_strb reaches m_axi_wstrb unchanged.
        total_bytes = 32'd32;                 // 2 beats
        @(posedge clk);
        src_rst <= 1'b1;
        @(posedge clk);
        src_rst <= 1'b0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;
        repeat (60) @(posedge clk);
        #1;

        if (cap_strb0 !== {STRB_W{1'b1}}) begin
            $display("FAIL strb/beat0: got %h want %h", cap_strb0, {STRB_W{1'b1}});
            errors = errors + 1;
        end else if (cap_strb1 !== {{(STRB_W-8){1'b1}}, 8'h00}) begin
            $display("FAIL strb/beat1: got %h want %h", cap_strb1,
                     {{(STRB_W-8){1'b1}}, 8'h00});
            errors = errors + 1;
        end else begin
            $display("PASS strb/forwarding: beat0=%h beat1=%h", cap_strb0, cap_strb1);
        end

        // ---------------- summary ----------------
        $display("");
        if (errors == 0) $display("PASS: all checks OK");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $finish;
    end

endmodule
