// BitBlt DMA write engine -- AXI4 burst writer with per-byte strobes.
//
// DIFFERENCES FROM THE READ ENGINE (bitblt_dma_rd)
//   1. wstrb: the pixel engine emits a PER-PIXEL write-enable (out_be) because
//      colour keying is decided per pixel, not per beat. This engine carries a
//      matching din_strb[AXI_DW/8-1:0] alongside the data so partial beats reach
//      memory correctly.
//   2. B RESPONSE: on the write channel "the data went out" does not mean "it
//      landed". Each burst must be acknowledged by bvalid before the engine moves
//      on, so the FSM has an extra S_RESP state.
//
// wvalid IS QUALIFIED BY din_valid (this was a real bug)
//   The FSM's intent to send is wvalid_r; the actual m_axi_wvalid is
//   wvalid_r & din_valid. Without that qualification the engine keeps emitting
//   beats using whatever value happens to sit on din while the pixel pipeline is
//   stalled by back-pressure -- which wrote the SAME pixel twice, let the engine
//   "finish" early, and (because din_ready then went low) deadlocked the pixel
//   engine and both readers behind it.
//
// PATTERN NOTES (same source as the read engine -- D1's axi4_ctrl.v)
//   * AW and W are asserted in the same cycle; each is retired independently
//     (awvalid clears on awready, wvalid clears on the last wready).
//   * wlast comes from a beat counter, not from an empty FIFO.
//   * Bursts are capped at 256 beats (awlen is 8-bit); longer transfers loop.
`timescale 1ns / 1ps

module bitblt_dma_wr #(
    parameter AXI_DW = 128,
    parameter AXI_AW = 32,
    parameter AXI_ID = 8'h14          // distinct from the SoC and the read engines
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // ---------------- command ----------------
    input  wire                 start,          // one-cycle pulse
    input  wire [AXI_AW-1:0]    base_addr,
    input  wire [31:0]          total_bytes,    // 0 = nothing to do
    output wire                 busy,           // combinational: see the note below
    output reg                  done,           // one-cycle pulse

    // ---------------- streaming input (from the pixel engine) ----------------
    input  wire [AXI_DW-1:0]    din,
    input  wire [AXI_DW/8-1:0]  din_strb,       // per-pixel write enable expanded
    input  wire                 din_valid,
    output wire                 din_ready,      // one beat consumed per w handshake
    output reg  [31:0]          beats_taken,

    // ---------------- AXI4 write master ----------------
    output wire [7:0]           m_axi_awid,
    output wire [AXI_AW-1:0]    m_axi_awaddr,
    output wire [7:0]           m_axi_awlen,
    output wire [2:0]           m_axi_awsize,
    output wire [1:0]           m_axi_awburst,
    output wire                 m_axi_awlock,
    output wire [3:0]           m_axi_awcache,
    output wire [2:0]           m_axi_awprot,
    output reg                  m_axi_awvalid,
    input  wire                 m_axi_awready,
    output wire [AXI_DW-1:0]    m_axi_wdata,
    output wire [AXI_DW/8-1:0]  m_axi_wstrb,
    output wire                 m_axi_wlast,
    output wire                 m_axi_wvalid,
    input  wire                 m_axi_wready,
    input  wire [7:0]           m_axi_bid,
    input  wire [1:0]           m_axi_bresp,
    input  wire                 m_axi_bvalid,
    output wire                 m_axi_bready,
    output reg                  m_axi_b_error      // sticky: a non-OKAY response was seen
);

    // Sized to the FULL address width on purpose. Declaring this as
    // [AXI_DW/8-1:0] (16 bits) and then reading BYTES_PER_BEAT[AXI_AW-1:0]
    // selects out-of-range bits, which synthesis and simulation fill with x --
    // the address increment silently became undefined in its upper bits.
    localparam [AXI_AW-1:0]   BYTES_PER_BEAT = AXI_DW / 8;
    localparam [2:0]          AXSIZE         = 3'd4;      // 128 bit = 16 B
    localparam [31:0]         MAX_BURST      = 32'd256;   // 256 beats per burst

    // ---------------------------------------------------------------
    // BOUNDED WRITE PIPELINING (2026-10-15)
    // ---------------------------------------------------------------
    // A burst used to be complete only once its B response arrived, so every
    // row's line_ack waited out a full DDR write round trip (docs/73 section
    // 5.5). Simply not waiting was tried on 2026-10-14 and reverted: in-flight
    // writes grew without bound, the write path monopolised the shared DDR, and
    // every run landed in the slow state (docs/74).
    //
    // This keeps the idea but BOUNDS it: at most B_LIMIT responses may be
    // outstanding. That hides one round trip while making it impossible for the
    // write side to take more than its share -- the same lesson the deeper-FIFO
    // experiment taught the same day (docs/79 section 7): on a shared resource,
    // whoever takes more than their share makes everyone slower.
    localparam [2:0] B_LIMIT = 3'd2;
    reg  [2:0]       b_pending;      // write responses not yet received

    // total beats to write = ceil(total_bytes / BYTES_PER_BEAT)
    wire [31:0] total_beats = (total_bytes + BYTES_PER_BEAT - 32'd1)
                              / BYTES_PER_BEAT;

    reg  [31:0]       beats_left;    // beats still to write (whole transfer)
    reg  [7:0]        burst_cnt;     // beats already written in this burst
    reg  [7:0]        burst_len_m1;  // (beats in this burst) - 1, latched at start
    reg  [AXI_AW-1:0] cur_addr;
    reg  [AXI_AW-1:0] aw_addr;      // latched per burst, held while AWVALID is high
    reg  [2:0]        state;
    reg               wvalid_r;      // FSM intent to drive W (see header note)

    localparam [2:0] S_IDLE = 3'd0,
                     S_WAIT = 3'd1,   // waiting for the first valid beat
                     S_DATA = 3'd2,   // streaming a burst
                     S_RESP = 3'd3,   // waiting for the write response
                     S_DONE = 3'd4;

    // this burst's length, capped at MAX_BURST
    wire [31:0] burst_want = (beats_left > MAX_BURST) ? MAX_BURST : beats_left;

    assign m_axi_awid    = AXI_ID;
    // AWADDR must not move while AWVALID is asserted. It used to be wired
    // straight to cur_addr, which increments on every W handshake -- and AXI
    // allows W to be accepted before AW, so any back-pressure on the write
    // address channel let the address drift mid-burst and the slave would
    // latch base + 16N as the burst start. aw_addr is latched once per burst
    // and held until the next one begins.
    assign m_axi_awaddr  = aw_addr;
    assign m_axi_awlen   = burst_len_m1;
    assign m_axi_awsize  = AXSIZE;
    assign m_axi_awburst = 2'b01;      // INCR
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'h0;
    assign m_axi_awprot  = 3'h0;

    // Data path is pass-through; the source must hold din/din_strb until the
    // w handshake completes, which din_ready communicates.
    //
    // wvalid = FSM intent AND a valid beat present. See the header note.
    wire m_axi_wvalid_int = wvalid_r & din_valid;

    assign m_axi_wvalid = m_axi_wvalid_int;
    assign m_axi_wdata  = din;
    assign m_axi_wstrb  = din_strb;
    assign m_axi_wlast  = (burst_cnt >= burst_len_m1);
    assign din_ready    = m_axi_wvalid_int & m_axi_wready;

    wire w_fire = m_axi_wvalid_int & m_axi_wready;

    // BREADY is combinational so that it is already high on the cycle the FSM
    // enters S_RESP. Previously it was a register set inside S_RESP, and because
    // the same block also cleared it when BVALID was seen in that same cycle,
    // the two assignments collided: with a slave that returns BVALID promptly
    // (AXI imposes no minimum delay), bready was driven back to 0 before it ever
    // went high, so the response was consumed by the FSM while the bus handshake
    // never completed. The stale response was then picked up by the next burst.
    // BREADY held high: responses are absorbed as they arrive, so the FSM never
    // has to park waiting for one. b_pending is what keeps "busy" honest.
    assign m_axi_bready = 1'b1;
    wire   b_fire       = m_axi_bvalid & m_axi_bready;

    // "Idle" must still mean "every write has landed" -- blt_wait() and the
    // on-chip monitor depend on that meaning (docs/74 section 2). It has to be
    // combinational because b_pending can outlive the FSM's own activity.
    assign busy = (state != S_IDLE) | (b_pending != 3'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            // busy is combinational now -- see the assign near the top.
            done          <= 1'b0;
            m_axi_awvalid <= 1'b0;
            wvalid_r      <= 1'b0;
            m_axi_b_error <= 1'b0;
            beats_left    <= 32'd0;
            burst_cnt     <= 8'd0;
            burst_len_m1  <= 8'd0;
            cur_addr      <= {AXI_AW{1'b0}};
            aw_addr       <= {AXI_AW{1'b0}};
            beats_taken   <= 32'd0;
            b_pending     <= 3'd0;
        end else begin
            done <= 1'b0;                       // default: pulse only

            // One push (a burst's data is away) and one pop (its response
            // arrived) can happen in the SAME cycle, so they must be a single
            // expression -- two separate non-blocking assignments would let one
            // silently overwrite the other and the count would drift (docs/74).
            b_pending <= b_pending
                       + (((state == S_DATA) && w_fire && m_axi_wlast) ? 3'd1 : 3'd0)
                       - (b_fire ? 3'd1 : 3'd0);

            // A response can now arrive in ANY state, because BREADY is held
            // high, so the error check can no longer live in S_RESP: a burst that
            // skipped the wait would silently drop its SLVERR. tb_bitblt_top
            // caught exactly that -- "SLVERR injected but dbg_b_error stayed 0".
            // The sticky flag is sticky for the whole transfer, as before.
            if (b_fire && (m_axi_bresp != 2'b00)) begin
                m_axi_b_error <= 1'b1;
            end

            // retire AW independently of the data phase
            if (m_axi_awvalid && m_axi_awready) begin
                m_axi_awvalid <= 1'b0;
            end

            case (state)
                // ------------------------------------------------
                S_IDLE: begin
                    m_axi_awvalid <= 1'b0;
                    wvalid_r      <= 1'b0;
                    if (start) begin
                        beats_taken   <= 32'd0;
                        m_axi_b_error <= 1'b0;
                        if (total_beats == 32'd0) begin
                            done  <= 1'b1;      // nothing to do (busy stays low: state is S_IDLE)
                        end else begin
                            beats_left <= total_beats;
                            cur_addr   <= base_addr;
                            state      <= S_WAIT;
                        end
                    end
                end

                // ------------------------------------------------
                // Do not assert wvalid until there is real data to send.
                S_WAIT: begin
                    if (din_valid) begin
                        aw_addr       <= cur_addr;   // latch: must stay put while AWVALID is high
                        m_axi_awvalid <= 1'b1;
                        wvalid_r      <= 1'b1;
                        burst_cnt     <= 8'd0;
                        burst_len_m1  <= burst_want[7:0] - 8'd1;
                        state         <= S_DATA;
                    end
                end

                // ------------------------------------------------
                // stream the burst; a beat is only consumed on a real handshake,
                // and a handshake only happens when din_valid is high
                S_DATA: begin
                    if (w_fire) begin
                        burst_cnt   <= burst_cnt + 8'd1;
                        beats_left  <= beats_left - 32'd1;
                        beats_taken <= beats_taken + 32'd1;
                        cur_addr    <= cur_addr + BYTES_PER_BEAT;

                        if (m_axi_wlast) begin
                            wvalid_r <= 1'b0;
                            // This burst's response is now in flight. Wait for it
                            // ONLY if we are already at the in-flight limit; the
                            // push itself happens in the shared expression above.
                            if (b_pending < B_LIMIT) begin
                                if (beats_left == 32'd1) begin
                                    done  <= 1'b1;      // all of the data is away
                                    state <= S_IDLE;
                                end else begin
                                    state <= S_WAIT;    // next burst, no wait
                                end
                            end else begin
                                state <= S_RESP;        // at the limit: drain one
                            end
                        end
                    end
                end

                // ------------------------------------------------
                // the burst is only complete once the slave acknowledges it
                S_RESP: begin
                    // BREADY is held high (see the assign near the top), so this
                    // state now only waits for the in-flight count to fall. The
                    // response's error bit is checked globally, not here.
                    if (m_axi_bvalid) begin
                        if (beats_left == 32'd0) begin
                            state <= S_DONE;
                        end else begin
                            state <= S_WAIT;         // next burst
                        end
                    end
                end

                // ------------------------------------------------
                S_DONE: begin
                    m_axi_awvalid <= 1'b0;
                    wvalid_r      <= 1'b0;
                    done          <= 1'b1;
                    state         <= S_IDLE;
                end

                // An illegal state encoding must not leave the bus driven.
                // state is 3 bits and only 0..4 are defined, so 5/6/7 are
                // reachable on hardware after a glitch or an SEU. This branch
                // previously reset only state, so if wvalid_r happened to be 1
                // the master kept driving WVALID with stale data. Park the
                // handshake outputs low instead.
                default: begin
                    state         <= S_IDLE;
                    m_axi_awvalid <= 1'b0;
                    wvalid_r      <= 1'b0;
                end
            endcase
        end
    end

endmodule
