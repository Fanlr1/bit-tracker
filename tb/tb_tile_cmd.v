// tb_tile_cmd.v -- P4: check gfx_sprtab(TILE_MODE=1) emits the 64x1 tile commands
// for one moving sprite: phase0 = TILE FILL at the OLD tile, phase1 = 64x1
// copy-key (or blit) at the NEW tile, with 8-px quantised positions.
`timescale 1ns/1ps
`default_nettype none
module tb_tile_cmd;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         tw_we = 0;
    reg  [11:0] tw_addr = 0;
    reg  [63:0] tw_data = 0;
    reg         go = 0;
    reg  [15:0] n = 16'd1;
    reg  [31:0] fb = 32'h0800_0000;
    reg  [31:0] spr = 32'h0887_0000;
    reg  [15:0] key = 16'hF81F;
    reg  [7:0]  alp = 8'd200;
    reg  [15:0] fill_col = 16'h1082;
    reg  [15:0] max_x = 16'd1912, max_y = 16'd1072;

    wire        busy;
    wire [31:0] prog;
    wire [31:0] dbg_tab0;
    wire        cmd_valid;
    wire [351:0] cmd_data;
    reg         cmd_ready = 1;   // always ready: walker streams commands back-to-back

    gfx_sprtab #(.AW(12), .ERASE_DIFF(0), .TILE_MODE(1), .BAND_STRIDE(32768)) u_walk (
        .clk(clk), .rst_n(rst_n),
        .tw_we(tw_we), .tw_addr(tw_addr), .tw_data(tw_data),
        .go(go), .n(n), .fb(fb), .spr(spr), .key(key), .alp(alp),
        .fill_col(fill_col), .max_x(max_x), .max_y(max_y),
        .busy(busy), .prog(prog), .dbg_tab0(dbg_tab0),
        .cmd_valid(cmd_valid), .cmd_data(cmd_data), .cmd_ready(cmd_ready));

    // capture accepted commands
    integer ncmd = 0, errs = 0;
    reg [351:0] cap0, cap1;
    reg [31:0] op0, op1, src0, src1, dst0, dst1;
    reg [15:0] w0, w1, h0, h1, ss0, ss1, col0;
    reg [15:0] key1;
    always @(posedge clk) begin
        if (cmd_valid && cmd_ready) begin
            if (ncmd == 0) cap0 <= cmd_data; else if (ncmd == 1) cap1 <= cmd_data;
            ncmd <= ncmd + 1;
        end
    end

    integer i;
    initial begin
        repeat (5) @(posedge clk); @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk); @(negedge clk);
        // entry: {transp=0, 23'd0, vy=0, 2'd0, vx=5, y=42, x=99}
        tw_data = {1'b0, 23'd0, 8'd0, 2'd0, 8'sd5, 11'd42, 11'd99};
        tw_addr = 12'd0; tw_we = 1;
        @(negedge clk); tw_we = 0;
        @(negedge clk); go = 1;
        @(negedge clk); go = 0;
        // capture the two commands, then check them
        forever begin
            @(posedge clk);
            if (ncmd >= 2) begin
                repeat (5) @(posedge clk);
                op0 = cap0[322:320]; src0 = cap0[319:288]; dst0 = cap0[287:256];
                w0 = cap0[239:224];  h0 = cap0[255:240]; ss0 = cap0[207:192]; col0 = cap0[143:128];
                op1 = cap1[322:320]; src1 = cap1[319:288]; dst1 = cap1[287:256];
                w1 = cap1[239:224];  h1 = cap1[255:240]; ss1 = cap1[207:192]; key1 = cap1[79:64];
                $display("cmd0: op=%0d dst=%h w=%0d h=%0d col=%h", op0, dst0, w0, h0, col0);
                $display("cmd1: op=%0d src=%h dst=%h w=%0d h=%0d ss=%0d key=%h", op1, src1, dst1, w1, h1, ss1, key1);
                // expected: quantised old (96,40) -> tile 0x08028600 ; new x=104 -> 0x08028680
                if (op0 != 0 || w0 != 64 || h0 != 1 || dst0 != 32'h0802_8600 || col0 != 16'h1082) begin
                    $display("FAIL cmd0"); errs = errs + 1; end
                if (op1 != 6 || w1 != 64 || h1 != 1 || ss1 != 128 || dst1 != 32'h0802_8680
                    || src1 != 32'h0887_0000 || key1 != 16'hF81F) begin
                    $display("FAIL cmd1"); errs = errs + 1; end
                $display("commands=%0d errors=%0d", ncmd, errs);
                if (errs == 0 && ncmd == 2) $display("RESULT: PASS (tile walker commands)");
                else $display("RESULT: FAIL");
                $finish;
            end
        end
    end
    initial begin #200000; $display("TIMEOUT ncmd=%0d", ncmd); $finish; end
endmodule
`default_nettype wire
