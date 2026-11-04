// Asynchronous FIFO with registered full/empty, on gray-coded pointers.
//
// WHY THIS EXISTS
//   The vendor dual_clock_fifo_wrapper cannot be used where its status outputs
//   feed back into its own handshake inputs, which is exactly how a scan-out
//   pipeline wants to use it:
//
//       wire fifo_we = splitting & ~fifo_full;     // we depends on full
//       ... .i_we (fifo_we) ... .o_full (fifo_full)
//
//   Every status output of that wrapper is a combinational assign that
//   includes the handshake input:
//       w_empty = ... (i_re & ...) ...            -> o_empty, o_aempty
//       w_full  = ... (i_we & ...) ...            -> o_full,  o_afull
//   so the loop is closed in both directions. Measured consequences: under
//   iverilog the simulator wedges with no signal activity and no time advance;
//   under Questa it reports "Iteration limit 10000000 reached".
//
//   Four attempts to work around it by delaying or replacing individual signals
//   failed, all caught by tb_bitblt_video_out. The problem is not which signal
//   is used, it is the interface contract: a status output that combinationally
//   depends on the request input cannot be fed back to that input, at all.
//
// WHAT IS DIFFERENT HERE
//   full and empty are REGISTERS, updated once per clock:
//       always @(posedge wclk) wfull <= wfull_next;
//   wfull_next does depend on we (it predicts whether the next write fills the
//   FIFO), but a register breaks the path, so we -> full -> we is no longer a
//   combinational loop. There is no added latency penalty either: a write is
//   itself a next-cycle event, so a registered full is exactly as timely.
//
//   Pointers are gray coded and each side sees the other through a two-flop
//   synchroniser, which is what makes the crossing safe -- the earlier attempt
//   at tracking occupancy locally failed because it compared two free-running
//   binary counters across clock domains.
//
// NOTE: ASCII only.

`timescale 1ns / 1ps

module async_fifo_gray #(
    parameter DW = 24,
    parameter AW = 11               // depth = 2**AW entries
)(
    // write side
    input  wire             wclk,
    input  wire             wrst_n,
    input  wire             we,
    input  wire [DW-1:0]    wdata,
    output reg              wfull,

    // read side
    input  wire             rclk,
    input  wire             rrst_n,
    input  wire             re,
    output wire [DW-1:0]    rdata,
    output reg              rempty,

    // observation only, for testbenches; no handshake depends on these
    output wire [AW:0]      wbin_o,
    output wire [AW:0]      rbin_o,

    // Occupancy as seen from the write side, for callers that use it to decide
    // whether to fetch more (bitblt_video_out's need_line does exactly that).
    //
    // MUST BE AW+1 BITS WIDE. Depth is 2**AW, so a full FIFO has a pointer
    // difference of 2**AW, whose low AW bits are all zero -- an AW-bit output
    // would read 0 when FULL. That is not hypothetical: it is the same defect as
    // the vendor wrapper's o_rcnt, and copying the AW-bit width here reproduced
    // it. The symptom was wcnt=0 together with fifo_full=1, which stalls
    // splitting (fifo_we = splitting & ~full), blocks need_line behind
    // !splitting, and stops all further line fetches.
    //
    // The synchronized read pointer is gray coded, so it is converted back to
    // binary first. That conversion is combinational but safe across the
    // crossing: only one gray bit changes per read, so the worst case is an
    // occupancy that is briefly off by one -- never a wild value.
    output wire [AW:0]      wcnt_o
);

    localparam DEPTH = (1 << AW);

    // The storage is a simple_dual_port_ram instance, NOT a plain reg array.
    //
    // This started as `reg [DW-1:0] mem [0:DEPTH-1]` with a combinational read
    // (`assign rdata = mem[raddr]`). Simulation was perfectly happy -- 153 checks
    // in tb_async_fifo_gray, 95996 in tb_bitblt_video_out -- but synthesis was
    // not: a block RAM needs a REGISTERED read, so the tools could not map it
    // and built 2048x24 flip-flops plus a 2048:1 multiplexer instead.
    //
    // Measured cost of that mistake: LUT4 11874 -> 55072, FF 10603 -> 59550 on a
    // device with 60800 LUT4, and pnr FAILED. RAM10 actually went DOWN, from 70
    // to 65, which is the tell -- 49152 (= 2048 x 24) landed in logic, not RAM.
    //
    // simple_dual_port_ram is the vendor template and matches what the vendor
    // dual_clock_fifo uses internally, so the tools recognise it.

    // ---------------------------------------------------------------- pointers
    // One extra bit distinguishes full from empty when the low bits match.
    reg  [AW:0] wbin, rbin;
    reg  [AW:0] wgray, rgray;

    // ---------------------------------------------------- cross-domain sync
    reg  [AW:0] wgray_s1, wgray_s2;     // write pointer, seen from the read side
    reg  [AW:0] rgray_s1, rgray_s2;     // read pointer,  seen from the write side

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            wgray_s1 <= {(AW+1){1'b0}};
            wgray_s2 <= {(AW+1){1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            rgray_s1 <= {(AW+1){1'b0}};
            rgray_s2 <= {(AW+1){1'b0}};
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    // ------------------------------------------------------------ write side
    wire        winc    = we & ~wfull;
    wire [AW:0] wbin_n  = wbin + {{AW{1'b0}}, winc};
    wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;

    // Full when the NEXT write pointer equals the synchronized read pointer
    // with its two top bits inverted -- the standard gray-code full test.
    wire wfull_n = (wgray_n == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
            wfull <= 1'b0;
        end else begin
            if (winc) begin
                wbin  <= wbin_n;
                wgray <= wgray_n;
            end
            // unconditional: the synchronized read pointer moves on its own
            wfull <= wfull_n;
        end
    end

    // ------------------------------------------------------------- read side
    wire        rinc    = re & ~rempty;
    wire [AW:0] rbin_n  = rbin + {{AW{1'b0}}, rinc};
    wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

    // Empty when the NEXT read pointer catches the synchronized write pointer.
    wire rempty_n = (rgray_n == wgray_s2);

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin   <= {(AW+1){1'b0}};
            rgray  <= {(AW+1){1'b0}};
            rempty <= 1'b1;
        end else begin
            if (rinc) begin
                rbin  <= rbin_n;
                rgray <= rgray_n;
            end
            rempty <= rempty_n;
        end
    end

    // One read clock of latency, same as the vendor FIFO.
    //
    // OUTPUT_REG="FALSE" still registers the read data once (r_rdata_1P), so
    // rdata becomes valid one rclk after rinc. That is a property of block RAM,
    // not a design choice, and it is exactly why the vendor wrapper's own comment
    // says "o_rdata appears ONE read clock after i_re" despite advertising
    // first-word fall-through.
    //
    // Callers must delay their data-enable by one clock to match. bitblt_video_out
    // does that with de_d1.
    simple_dual_port_ram #(
        .DATA_WIDTH (DW),
        .ADDR_WIDTH (AW),
        .OUTPUT_REG ("FALSE")
    ) u_ram (
        .wdata (wdata),
        .waddr (wbin[AW-1:0]),
        .we    (winc),
        .wclk  (wclk),
        .raddr (rbin[AW-1:0]),
        .re    (rinc),
        .rclk  (rclk),
        .rdata (rdata)
    );

    assign wbin_o = wbin;
    assign rbin_o = rbin;

    // gray -> binary for the synchronized read pointer, then the difference
    wire [AW:0] rbin_s2;
    assign rbin_s2[AW] = rgray_s2[AW];
    genvar gi;
    generate
        for (gi = AW-1; gi >= 0; gi = gi - 1) begin : g_g2b
            assign rbin_s2[gi] = rbin_s2[gi+1] ^ rgray_s2[gi];
        end
    endgenerate

    assign wcnt_o = wbin - rbin_s2;

endmodule
