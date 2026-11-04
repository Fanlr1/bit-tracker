// Self-checking testbench for bitblt_pulse_gen.
//
// Proves the detector emits exactly ONE pulse per rising edge, nothing while the
// level stays high, and nothing on a falling edge -- which is exactly what the
// DMA engines need from M3's held-high line_req.
`timescale 1ns / 1ps

module tb_bitblt_pulse_gen;

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    reg  level = 1'b0;
    wire pulse;

    integer errors    = 0;
    integer pulse_cnt = 0;

    bitblt_pulse_gen dut (
        .clk   (clk),
        .rst_n (rst_n),
        .level (level),
        .pulse (pulse)
    );

    always #5 clk = ~clk;

    // counts pulses AND their width (one count per cycle the pulse is high)
    always @(posedge clk) if (pulse) pulse_cnt = pulse_cnt + 1;

    initial begin
        $dumpfile("tb_bitblt_pulse_gen.vcd");
        $dumpvars(0, tb_bitblt_pulse_gen);

        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---- 1) rising edge -> exactly one pulse (and it is 1 cycle wide) ----
        pulse_cnt = 0;
        @(posedge clk);
        level <= 1'b1;
        repeat (6) @(posedge clk);
        if (pulse_cnt == 1) $display("PASS rising-edge: exactly 1 pulse");
        else begin
            $display("FAIL rising-edge: %0d pulses, want 1", pulse_cnt);
            errors = errors + 1;
        end

        // ---- 2) holding the level high -> no further pulses ----
        pulse_cnt = 0;
        repeat (10) @(posedge clk);
        if (pulse_cnt == 0) $display("PASS hold-high: no extra pulse");
        else begin
            $display("FAIL hold-high: %0d extra pulses, want 0", pulse_cnt);
            errors = errors + 1;
        end

        // ---- 3) falling edge -> no pulse ----
        pulse_cnt = 0;
        @(posedge clk);
        level <= 1'b0;
        repeat (6) @(posedge clk);
        if (pulse_cnt == 0) $display("PASS falling-edge: no pulse");
        else begin
            $display("FAIL falling-edge: %0d pulses, want 0", pulse_cnt);
            errors = errors + 1;
        end

        // ---- 4) a second rising edge -> another single pulse ----
        pulse_cnt = 0;
        @(posedge clk);
        level <= 1'b1;
        repeat (6) @(posedge clk);
        if (pulse_cnt == 1) $display("PASS second-rising-edge: exactly 1 pulse");
        else begin
            $display("FAIL second-rising-edge: %0d pulses, want 1", pulse_cnt);
            errors = errors + 1;
        end

        // ---- 5) back-to-back edges are each detected ----
        //      low for one cycle then high again must give one pulse
        pulse_cnt = 0;
        @(posedge clk);
        level <= 1'b0;
        @(posedge clk);
        level <= 1'b1;
        repeat (6) @(posedge clk);
        if (pulse_cnt == 1) $display("PASS back-to-back: exactly 1 pulse");
        else begin
            $display("FAIL back-to-back: %0d pulses, want 1", pulse_cnt);
            errors = errors + 1;
        end

        // ---- summary ----
        $display("");
        if (errors == 0) $display("PASS: all checks OK");
        else             $display("RESULT: FAILED with %0d error(s)", errors);
        $finish;
    end

endmodule
