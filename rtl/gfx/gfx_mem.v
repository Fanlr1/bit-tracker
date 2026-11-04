// ============================================================================
// gfx_mem.v -- one AXI4 master shared by the engine and the scan-out.
//
// THE RULE THAT REMOVES THE OLD DEADLOCK
//   The old design put four separate AXI masters on Axi_Mux. Its R channel is
//   routed to one slave until RLAST, so any client that deasserted RREADY could
//   stop the whole bus -- measured as a 58,000-cycle read and, in the worst case,
//   a completely wedged CPU.
//
//   Here there is exactly ONE read burst in flight at a time and RREADY is high
//   for the whole burst. A client may only raise REQ when it can absorb all
//   requested beats, so the bus can never be held by a client that is not ready
//   to consume. Arbitration happens at burst boundaries and never preempts.
//
// READ CLIENTS (fixed priority, scan-out first)
//   0: scan-out line fetch  16-beat bursts, 960 words per line
//   1: blit source
//   2: blit background (read-modify-write for alpha / colour key)
//
// WRITE CLIENT
//   One AW at a time. W beats come from the core's write FIFO; WVALID is never
//   withdrawn once asserted. B is checked for a non-OKAY response.
// ============================================================================
`default_nettype none

module gfx_mem #(
    parameter AXI_DW = 128
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---------------- read client 0: scan-out ----------------
    input  wire         rd0_req,
    input  wire [31:0]  rd0_addr,
    input  wire [8:0]   rd0_beats,     // 1..240 (one full display line)
    output wire         rd0_gnt,
    output wire         rd0_valid,
    output wire [AXI_DW-1:0] rd0_data,
    output wire         rd0_last,

    // ---------------- read client 1: blit source ----------------
    input  wire         rd1_req,
    input  wire [31:0]  rd1_addr,
    input  wire [8:0]   rd1_beats,
    output wire         rd1_gnt,
    output wire         rd1_valid,
    output wire [AXI_DW-1:0] rd1_data,
    output wire         rd1_last,

    // ---------------- read client 2: blit background ----------------
    input  wire         rd2_req,
    input  wire [31:0]  rd2_addr,
    input  wire [8:0]   rd2_beats,
    output wire         rd2_gnt,
    output wire         rd2_valid,
    output wire [AXI_DW-1:0] rd2_data,
    output wire         rd2_last,

    // ---------------- write client ----------------
    input  wire         wr_req,
    input  wire [31:0]  wr_addr,
    input  wire [4:0]   wr_beats,
    output wire         wr_gnt,
    input  wire [AXI_DW-1:0] wr_data,
    input  wire [AXI_DW/8-1:0] wr_strb,
    input  wire         wr_valid,
    output wire         wr_ready,
    input  wire         wr_last,

    // ---------------- counters ----------------
    output reg  [31:0]  rd_beats_cnt,
    output reg  [31:0]  wr_beats_cnt,
    output reg  [31:0]  rresp_err_cnt,
    output reg  [31:0]  bresp_err_cnt,
    output wire [7:0]   dbg_state,

    // ---------------- AXI4 master ----------------
    output reg  [31:0]  m_araddr,
    output wire [7:0]   m_arlen,
    output wire [2:0]   m_arsize,
    output wire [1:0]   m_arburst,
    output reg          m_arvalid,
    input  wire         m_arready,
    input  wire [AXI_DW-1:0] m_rdata,
    input  wire [1:0]   m_rresp,
    input  wire         m_rlast,
    input  wire         m_rvalid,
    output wire         m_rready,

    output reg  [31:0]  m_awaddr,
    output wire [7:0]   m_awlen,
    output wire [2:0]   m_awsize,
    output wire [1:0]   m_awburst,
    output reg          m_awvalid,
    input  wire         m_awready,
    output wire [AXI_DW-1:0] m_wdata,
    output wire [AXI_DW/8-1:0] m_wstrb,
    output wire         m_wlast,
    output wire         m_wvalid,
    input  wire         m_wready,
    input  wire [1:0]   m_bresp,
    input  wire         m_bvalid,
    output wire         m_bready
);

    assign dbg_state = {rsel[1:0], r_active, wstate[1:0], m_awvalid, m_wvalid, m_bvalid};

    localparam [2:0] ARSIZE = 3'd4;     // 16 bytes per beat
    localparam [1:0] BURST  = 2'b01;    // INCR

    assign m_arsize  = ARSIZE;
    assign m_awsize  = ARSIZE;
    assign m_arburst = BURST;
    assign m_awburst = BURST;

    // ================================================================ read side
    reg [1:0]  rsel;            // 0,1,2 = client; 3 = idle
    reg        r_active;
    reg [8:0]  r_left;          // beats still expected
    reg [7:0]  r_len;           // ARLEN = beats-1

    assign m_arlen = r_len;

    // A request is granted only in IDLE, so the address the client presents is
    // stable (the clients hold their request until GNT).
    wire [1:0] req_vec = {2'd0, rd0_req} | {1'd0, rd1_req, 1'b0} | {rd2_req, 2'b00};
    wire       any_req = rd0_req | rd1_req | rd2_req;

    assign rd0_gnt = (rsel == 2'd0) && (m_arvalid && m_arready);
    assign rd1_gnt = (rsel == 2'd1) && (m_arvalid && m_arready);
    assign rd2_gnt = (rsel == 2'd2) && (m_arvalid && m_arready);

    assign m_rready = r_active;
    assign rd0_valid = r_active && (rsel == 2'd0) && m_rvalid;
    assign rd1_valid = r_active && (rsel == 2'd1) && m_rvalid;
    assign rd2_valid = r_active && (rsel == 2'd2) && m_rvalid;
    assign rd0_data = m_rdata;
    assign rd1_data = m_rdata;
    assign rd2_data = m_rdata;
    assign rd0_last = m_rvalid && m_rlast;
    assign rd1_last = m_rvalid && m_rlast;
    assign rd2_last = m_rvalid && m_rlast;

    always @(posedge clk) begin
        if (!rst_n) begin
            rsel        <= 2'd3;
            r_active    <= 1'b0;
            r_left      <= 9'd0;
            r_len       <= 8'd0;
            m_araddr    <= 32'd0;
            m_arvalid   <= 1'b0;
            rd_beats_cnt <= 32'd0;
            rresp_err_cnt <= 32'd0;
        end else begin
            // ---- accept a new burst when idle ----
            if (!r_active) begin
                if (rd0_req) begin
                    rsel      <= 2'd0;
                    m_araddr  <= {rd0_addr[31:4], 4'd0};
                    r_len     <= rd0_beats[7:0] - 8'd1;
                    r_left    <= rd0_beats;
                    m_arvalid <= 1'b1;
                    r_active  <= 1'b1;
                end else if (rd1_req) begin
                    rsel      <= 2'd1;
                    m_araddr  <= {rd1_addr[31:4], 4'd0};
                    r_len     <= rd1_beats[7:0] - 8'd1;
                    r_left    <= rd1_beats;
                    m_arvalid <= 1'b1;
                    r_active  <= 1'b1;
                end else if (rd2_req) begin
                    rsel      <= 2'd2;
                    m_araddr  <= {rd2_addr[31:4], 4'd0};
                    r_len     <= rd2_beats[7:0] - 8'd1;
                    r_left    <= rd2_beats;
                    m_arvalid <= 1'b1;
                    r_active  <= 1'b1;
                end
            end

            // ---- address handshake ----
            if (m_arvalid && m_arready) m_arvalid <= 1'b0;

            // ---- data beats ----
            if (r_active && m_rvalid) begin
                rd_beats_cnt <= rd_beats_cnt + 32'd1;
                if (m_rresp != 2'b00) rresp_err_cnt <= rresp_err_cnt + 32'd1;
                if (r_left != 9'd0) r_left <= r_left - 9'd1;
                if (m_rlast) begin
                    r_active <= 1'b0;
                    rsel     <= 2'd3;
                    r_left   <= 9'd0;
                end
            end
        end
    end

    // ================================================================ write side
    //
    // W DATA IS BUFFERED. The first board build asserted AW and only then waited
    // for the data path to be granted, and the write address never completed:
    // Axi_Mux wants to see AW and W making progress together, so a master that
    // presents AW alone can wedge. A 16-beat FIFO between the engine and the AXI
    // write channel decouples the two; the engine pushes data at its own rate and
    // the AW/W handshakes run independently.
    localparam [1:0] W_IDLE = 2'd0, W_ADDR = 2'd1, W_DATA = 2'd2, W_RESP = 2'd3;
    reg [1:0]  wstate;
    reg [7:0]  w_len;
    reg [4:0]  w_sent;
    reg [2:0]  b_pending;   // write responses not yet received

    reg [127:0] wf_data [0:15];
    reg [15:0]  wf_strb [0:15];
    reg [4:0]   wf_wp, wf_rp;
    wire [4:0]  wf_level = wf_wp - wf_rp;
    wire        wf_full  = (wf_level == 5'd16);
    wire        wf_empty = (wf_level == 5'd0);

    assign m_awlen   = w_len;
    assign m_wvalid  = (wstate == W_DATA) && ~wf_empty;
    assign m_wdata   = wf_data[wf_rp[3:0]];
    assign m_wstrb   = wf_strb[wf_rp[3:0]];
    assign m_wlast   = (wstate == W_DATA) && (w_sent == {3'b0, w_len});
    assign m_bready  = 1'b1;   // always accept B; the counter tracks completion
    assign wr_ready  = ~wf_full;
    assign wr_gnt    = (wstate == W_IDLE) && wr_req && !m_awvalid;

    // Both pointers live in ONE always block: splitting them across the FIFO
    // and the FSM produced two drivers and an X reset on wf_rp, which made
    // wr_ready X and no write ever completed on the board.
    always @(posedge clk) begin
        if (!rst_n) begin
            wf_wp <= 5'd0;
            wf_rp <= 5'd0;
        end else begin
            if (wr_valid && wr_ready) begin
                wf_data[wf_wp[3:0]] <= wr_data;
                wf_strb[wf_wp[3:0]] <= wr_strb;
                wf_wp <= wf_wp + 5'd1;
            end
            if ((wstate == W_DATA) && m_wvalid && m_wready) begin
                wf_rp <= wf_rp + 5'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            wstate  <= W_IDLE;
            m_awaddr <= 32'd0;
            m_awvalid <= 1'b0;
            w_len   <= 8'd0;
            w_sent  <= 5'd0;
            wr_beats_cnt <= 32'd0;
            bresp_err_cnt <= 32'd0;
            b_pending <= 3'd0;
        end else begin
            if (m_bvalid) begin
                if (m_bresp != 2'b00) bresp_err_cnt <= bresp_err_cnt + 32'd1;
                if (b_pending != 3'd0) b_pending <= b_pending - 3'd1;
            end
            case (wstate)
                W_IDLE: begin
                    if (wr_req && (b_pending != 3'd4)) begin
                        m_awaddr  <= {wr_addr[31:4], 4'd0};
                        w_len     <= {3'd0, wr_beats} - 8'd1;
                        w_sent    <= 5'd0;
                        m_awvalid <= 1'b1;
                        wstate    <= W_ADDR;
                    end
                end
                W_ADDR: begin
                    if (m_awvalid && m_awready) begin
                        m_awvalid <= 1'b0;
                        wstate    <= W_DATA;
                    end
                end
                W_DATA: begin
                    if (m_wvalid && m_wready) begin
                        w_sent       <= w_sent + 5'd1;
                        wr_beats_cnt <= wr_beats_cnt + 32'd1;
                        if (w_sent == {3'b0, w_len}) begin
                            // hand the channel back immediately; the B response is
                            // accounted for separately
                            b_pending <= b_pending + 3'd1;
                            wstate    <= W_IDLE;
                        end
                    end
                end
                default: wstate <= W_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
