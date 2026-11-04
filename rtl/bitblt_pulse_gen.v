// Level-to-pulse edge detector.
//
// WHY THIS EXISTS
//   M3 (bitblt_addr_gen) asserts line_req and HOLDS it high until the DMA
//   answers with line_ack -- that is the right shape for a handshake. The DMA
//   engines, however, want a one-cycle `start`. This module bridges the two.
//
//   It also naturally serialises the engines: both read engines and the write
//   engine see the same pulse, so a line starts on all three simultaneously.
`timescale 1ns / 1ps

module bitblt_pulse_gen (
    input  wire clk,
    input  wire rst_n,
    input  wire level,      // held-high request
    output wire pulse       // exactly one cycle per rising edge of level
);

    reg level_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) level_d <= 1'b0;
        else        level_d <= level;
    end

    assign pulse = level & ~level_d;

endmodule
