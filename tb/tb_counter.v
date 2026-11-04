// Self-checking testbench: verifies clock, reset, enable and wraparound.
`timescale 1ns / 1ps

module tb_counter;

    localparam WIDTH = 8;

    reg              clk   = 1'b0;
    reg              rst_n = 1'b0;
    reg              en    = 1'b0;
    wire [WIDTH-1:0] cnt;

    counter #(.WIDTH(WIDTH)) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .cnt   (cnt)
    );

    // 100 MHz clock
    always #5 clk = ~clk;

    integer errors = 0;

    initial begin
        $dumpfile("tb_counter.vcd");
        $dumpvars(0, tb_counter);

        // hold reset for 3 cycles
        repeat (3) @(posedge clk);
        #1;   // step past the clock edge, otherwise TB and DUT race in the same time step
        rst_n = 1'b1;

        if (cnt !== 8'd0) begin
            $display("FAIL: cnt=%0d after reset, expected 0", cnt);
            errors = errors + 1;
        end

        // enable for 20 cycles -> expect 20
        en = 1'b1;
        repeat (20) @(posedge clk);
        #1;
        if (cnt !== 8'd20) begin
            $display("FAIL: cnt=%0d after 20 enables, expected 20", cnt);
            errors = errors + 1;
        end

        // disable for 5 cycles -> must hold
        en = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        if (cnt !== 8'd20) begin
            $display("FAIL: cnt=%0d while disabled, expected hold at 20", cnt);
            errors = errors + 1;
        end

        // wraparound: 20 + 300 = 320, 320 % 256 = 64
        en = 1'b1;
        repeat (300) @(posedge clk);
        #1;
        if (cnt !== 8'd64) begin
            $display("FAIL: cnt=%0d after wraparound, expected 64", cnt);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: all 4 checks OK (final cnt=%0d)", cnt);
        else
            $display("RESULT: FAILED with %0d error(s)", errors);

        $finish;
    end

endmodule
