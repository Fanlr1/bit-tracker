// First-word fall-through FIFO with a SYNCHRONOUS (BRAM-mappable) read port.
//
// WHY THIS EXISTS (docs/66 section 7, docs/78 section 10)
//   The read engines used a COMBINATIONALLY read array --
//       assign dout = fifo_mem[fifo_rd];
//   -- which cannot map to block RAM (BRAM has a registered read only), so the
//   whole thing was burned as LUT/FF. That was survivable at 32 entries; when
//   2026-10-14 raised it to 128 entries to cut the AR count, LUT went
//   22,608 -> 40,508 and the build broke. Latency, not bandwidth, is the
//   measured bottleneck, and the AR count is limited by the FIFO depth, so the
//   FIFO has to be able to grow -- hence this module.
//
// HOW IT KEEPS FULL THROUGHPUT
//   A registered BRAM output costs one cycle, and the naive fix (register dout,
//   expose it next cycle) halves the throughput: prefetch, present, prefetch...
//   The fix is to READ AHEAD one word. rd_ptr always points at the NEXT slot to
//   prefetch, and a prefetch is issued on the same cycle the current word is
//   consumed, so a new word lands in out_r exactly when the old one leaves.
//   Steady state is therefore one word per cycle.
//
//       cycle n   : prefetch fires (address presented), out_r holds word W
//       cycle n+1 : out_r now holds W+1, out_valid still 1 -- no bubble
//
// OCCUPANCY AND full
//   The word sitting in out_r has already left the FIFO array (rd_ptr moved past
//   it), so it must be counted separately: full is asserted when
//   (wr_ptr - rd_ptr) + out_valid == DEPTH. Without that term the FIFO can
//   overflow by exactly one word -- which is the classic FWFT bug.
//
// ASCII only -- the Windows PowerShell parser and the vendor tools both prefer it.
`timescale 1ns / 1ps

module bitblt_fwft_fifo #(
    parameter DW = 128,             // data width in bits
    parameter AW = 5                // depth = 2**AW entries
) (
    input  wire             clk,
    input  wire             rst_n,

    // ---------------- write side ----------------
    input  wire             wr_en,
    input  wire [DW-1:0]    din,
    output wire             full,
    // ARRAY occupancy -- deliberately EXCLUDES the word held in the output
    // register, which has already left the array. An admission controller
    // budgeting a burst against free space must use this one: charging it for
    // the promoted word makes every burst one beat short (see the note below).
    output wire [AW:0]      used,
    // True only when nothing is held anywhere -- array AND output register.
    // This is the drop-in replacement for the old "wr_ptr == rd_ptr": callers
    // use it to mean "all beats have been consumed".
    output wire             empty,

    // ---------------- read side (first word falls through) ----------------
    output wire [DW-1:0]    dout,
    output wire             dout_valid,
    input  wire             dout_ready
);

    localparam DEPTH = 1 << AW;

    reg  [DW-1:0]  mem [0:DEPTH-1];
    reg  [AW:0]    wr_ptr, rd_ptr;      // extra bit = wrap flag, so a plain
                                        // subtraction is the occupancy
    reg  [DW-1:0]  out_r;
    reg            out_valid;

    // rd_ptr points at the next slot to prefetch, so "the array still holds a
    // word we have not taken" is exactly wr_ptr != rd_ptr.
    wire fifo_have = (wr_ptr != rd_ptr);
    wire out_pop   = out_valid & dout_ready;

    // Read ahead: allowed with nothing in hand, or in the same cycle the word in
    // hand is being taken. NEVER while holding a word the consumer is not
    // taking -- that would silently drop it.
    wire prefetch  = fifo_have & (~out_valid | out_pop);

    // Occupancy AS SEEN BY THE WRITER is the array occupancy only. The word in
    // out_r has already left the array (rd_ptr advanced past it), so counting it
    // here would under-report the free space by one entry -- and that is not a
    // cosmetic error: the DMA admission logic budgets a burst against this
    // number, so every burst after the first came out one beat short and the
    // burst count went UP (measured: 6 bursts where 5 were expected, and a
    // strided case that timed out). Keeping the two separate makes the usable
    // capacity DEPTH + 1 words with no risk of overwriting the array: a burst is
    // never longer than the free space measured this way.
    assign used = wr_ptr - rd_ptr;
    assign full = (used == DEPTH[AW:0]);

    // "Nothing anywhere" -- the array AND the output register. This is what the
    // old "wr_ptr == rd_ptr" meant to its callers ("every beat consumed"), so the
    // promoted word must be included here even though it is excluded above.
    assign empty = (used == {(AW+1){1'b0}}) & ~out_valid;

    assign dout       = out_r;
    assign dout_valid = out_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr    <= {(AW+1){1'b0}};
            rd_ptr    <= {(AW+1){1'b0}};
            out_r     <= {DW{1'b0}};
            out_valid <= 1'b0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr[AW-1:0]] <= din;
                wr_ptr              <= wr_ptr + 1'b1;
            end

            if (prefetch) begin
                out_r     <= mem[rd_ptr[AW-1:0]];
                rd_ptr    <= rd_ptr + 1'b1;
                out_valid <= 1'b1;
            end else if (out_pop) begin
                out_valid <= 1'b0;
            end
        end
    end

endmodule
