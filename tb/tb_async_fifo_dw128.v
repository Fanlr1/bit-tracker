// Does async_fifo_gray still work at DW=128 / AW=9?
//
// WHY THIS EXISTS (docs/84)
//   Stage 2 of the RGB565 change widened the scan-out FIFO from 96 to 128 bits and
//   shrank it from AW=10 to AW=9. The whole scan-out then produced zeros: the VCD
//   showed a read happening while the FIFO reported "not empty" but was in fact
//   empty. Rather than debug that through the whole scan-out path, this asks the
//   question directly, in the FIFO's own testbench, with nothing else attached.
//
//   THE LESSON IT ENCODES: a shared component must be proven under its new
//   parameters in its OWN testbench before the path around it is rewired. Doing it
//   the other way cost several rounds of waveform debugging.
//
// WHAT IT CHECKS
//   1. reset leaves rempty asserted
//   2. ONE write de-asserts rempty          <- the property that failed on board
//   3. that value reads back EXACTLY (all 128 bits, not just the low ones)
//   4. rempty re-asserts after the read
//   5. a full sweep of 16 distinct values round-trips with no loss or reordering
//   6. wcnt_o counts entries correctly
//
// ASCII only.
`timescale 1ns / 1ps

module tb_async_fifo_dw128;

    localparam DW = 128;
    localparam AW = 9;                  // 512 entries -- the scan-out's new depth

    reg wclk = 0, rclk = 0;
    always #5  wclk = ~wclk;            // 100 MHz
    always #13 rclk = ~rclk;            // ~38 MHz, deliberately not aligned

    reg wrst_n = 0, rrst_n = 0;
    reg                   we = 0;
    reg  [DW-1:0]         wdata = 0;
    wire                  wfull;
    wire                  re;
    wire [DW-1:0]         rdata;
    wire                  rempty;
    wire [AW:0]           wcnt_o;
    wire [AW:0]           wbin_o, rbin_o;

    // feedback topology, exactly as bitblt_video_out drives it
    reg  rd_valid = 0;
    reg  [DW-1:0] rd_hold = 0;
    assign re = ~rempty & rd_valid;

    async_fifo_gray #(.DW(DW), .AW(AW)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .we(we), .wdata(wdata),
        .wfull(wfull), .wcnt_o(wcnt_o), .wbin_o(wbin_o),
        .rclk(rclk), .rrst_n(rrst_n), .re(re), .rdata(rdata),
        .rempty(rempty), .rbin_o(rbin_o)
    );

    integer errors = 0;
    integer i;
    // SEPARATE loop counters for the two halves of the fork below. A single
    // shared integer is a race: both processes increment i, so the reader ends
    // up comparing against the wrong expected value (and reads index 16).
    integer wi, ri;
    reg [DW-1:0] v;

    task fail(input [8*56-1:0] msg);
        begin
            errors = errors + 1;
            $display("  FAIL: %0s", msg);
        end
    endtask

    // distinct, self-describing patterns
    function [DW-1:0] pat;
        input integer n;
        begin
            pat = { 32'hA5A5_0000 + n, 32'h0000_0000 + n, 64'h5A5A_0000_0000_0000 + n };
        end
    endfunction

    integer t;
    initial begin
        $display("=== tb_async_fifo_dw128  (DW=%0d AW=%0d) ===", DW, AW);

        // ---- 1. reset ----
        wrst_n = 0; rrst_n = 0; we = 0; rd_valid = 0;
        repeat (8) @(posedge wclk);
        repeat (8) @(posedge rclk);
        wrst_n = 1; rrst_n = 1;
        repeat (8) @(posedge wclk);
        repeat (8) @(posedge rclk);
        if (rempty !== 1'b1) fail("rempty is not asserted after reset");
        $display("  1. reset asserts rempty                        : %0s", (errors==0)?"OK":"FAILED");

        // ---- 2. ONE write must de-assert rempty ----
        @(negedge wclk); wdata = pat(1); we = 1;
        @(negedge wclk); we = 0;
        repeat (10) @(posedge rclk);        // let it cross
        if (rempty !== 1'b0) fail("rempty stayed high after one write");
        $display("  2. one write de-asserts rempty (after CDC)     : %0s", (errors==0)?"OK":"FAILED");

        // ---- 3. read it back, ALL 128 bits ----
        @(negedge rclk); rd_valid = 1;
        repeat (3) @(posedge rclk);
        v = rdata;
        if (v !== pat(1)) begin
            fail("data did not round-trip");
            $display("     got  = %032h", v);
            $display("     want = %032h", pat(1));
        end
        @(negedge rclk); rd_valid = 0;
        $display("  3. all 128 bits round-trip exactly             : %0s", (errors==0)?"OK":"FAILED");

        // ---- 4. rempty returns ----
        repeat (6) @(posedge rclk);
        if (rempty !== 1'b1) fail("rempty did not re-assert after the read");
        $display("  4. rempty re-asserts when drained              : %0s", (errors==0)?"OK":"FAILED");

        // ---- 5. sweep 16 values through ----
        fork
            begin : writer
                for (wi = 0; wi < 16; wi = wi + 1) begin
                    @(negedge wclk);
                    wdata = pat(wi);
                    we = ~wfull;
                    while (wfull) begin @(negedge wclk); we = ~wfull; end
                end
                @(negedge wclk); we = 0;
            end
            begin : reader
                for (ri = 0; ri < 16; ri = ri + 1) begin
                    // CRITICAL: re is COMBINATIONAL off rd_valid, so rd_valid must
                    // be a ONE-CYCLE PULSE. Holding it high drains one entry per
                    // rclk and the read pointer runs ahead -- that is exactly what
                    // made the first version of this sweep report bogus failures.
                    // bitblt_video_out pulses fifo_re the same way.
                    @(negedge rclk);
                    t = 0;
                    while (rempty && t < 400) begin @(negedge rclk); t = t + 1; end
                    if (t >= 400) begin
                        fail("reader starved during the sweep");
                        ri = 16;
                    end else begin
                        rd_valid = 1;
                        @(negedge rclk);
                        rd_valid = 0;
                        repeat (2) @(posedge rclk);
                        v = rdata;
                        if (v !== pat(ri)) begin
                            fail("sweep value mismatch or reordering");
                            $display("     i=%0d got=%032h want=%032h", ri, v, pat(ri));
                            ri = 16;
                        end
                    end
                end
                @(negedge rclk); rd_valid = 0;
            end
        join
        $display("  5. 16 values round-trip in order, no loss      : %0s", (errors==0)?"OK":"FAILED");

        // ---- 6. wcnt_o ----
        repeat (6) @(posedge rclk);
        if (wcnt_o !== {(AW+1){1'b0}}) fail("wcnt_o is not zero when drained");
        $display("  6. wcnt_o returns to zero                      : %0s", (errors==0)?"OK":"FAILED");

        if (errors == 0) $display("RESULT: PASS (async_fifo_gray at DW=128 AW=9)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
