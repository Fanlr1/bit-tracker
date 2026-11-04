// Self-checking testbench for alpha_blend (validates DS48 primitive + iVerilog flow).
`timescale 1ns / 1ps

module tb_alpha_blend;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    reg        ce    = 1'b1;
    reg  [7:0] fg    = 8'd0;
    reg  [7:0] bg    = 8'd0;
    reg  [7:0] alpha = 8'd0;
    wire [7:0] out;

    integer errors = 0;

    alpha_blend dut (
        .clk   (clk),
        .rst_n (rst_n),
        .ce    (ce),
        .fg    (fg),
        .bg    (bg),
        .alpha (alpha),
        .out   (out)
    );

    // 100 MHz
    always #5 clk = ~clk;

    task do_check;
        input [7:0]   f;
        input [7:0]   b;
        input [7:0]   a;
        input [7:0]   exp;
        input [127:0] name;
        begin
            fg    = f;
            bg    = b;
            alpha = a;
            repeat (5) @(posedge clk);   // wait for the DSP pipeline
            #1;                          // step past the clock edge
            if (out !== exp) begin
                $display("FAIL %0s: fg=%0d bg=%0d a=%0d -> out=%0d (expect %0d)",
                         name, f, b, a, out, exp);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: fg=%0d bg=%0d a=%0d -> out=%0d", name, f, b, a, out);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_alpha_blend.vcd");
        $dumpvars(0, tb_alpha_blend);

        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;

        // Expectations come from the SPECIFICATION, not from the implementation.
        //
        // These two cases are definitional rather than arithmetic:
        //   alpha = 255 means fully foreground, so the result IS the foreground
        //   alpha = 0   means fully background, so the result IS the background
        //
        // An earlier revision expected 199 and 9, which are what the old
        // >>8 approximation produced. Comparing against those made the check
        // pass while the design was wrong -- the testbench was measuring the
        // bug rather than the requirement.
        do_check(8'd200, 8'd10,  8'd255, 8'd200, "full-fg");
        do_check(8'd200, 8'd10,  8'd0,   8'd10,  "full-bg");
        // alpha = 128 -> (100*128 + 0*127)/255 = 12800/255 = 50.19 -> 50
        do_check(8'd100, 8'd0,   8'd128, 8'd50,  "half");

        if (errors == 0)
            $display("PASS: all checks OK");
        else
            $display("RESULT: FAILED with %0d error(s)", errors);

        $finish;
    end

endmodule
