// WHY THIS FILE IS NOT NAMED tb_*.v
//   run-regression.ps1 discovers testbenches with the glob tb_*.v and compiles
//   every match. This file cannot be compiled that way: it instantiates the
//   post-map netlist (outflow/bitblt_system.map.v), which does not exist in the
//   RTL regression environment. Naming it tb_* made the suite fail two stages
//   the first time it ran after this file was added.
//   Efinity's sim flow looks for a top MODULE named `sim`; the file name is free.
//============================================================================
// sim -- top-level testbench for post-map (gate-level) simulation
//============================================================================
// WHY THIS EXISTS
//   Efinity's sim flow compiles the flattened post-map netlist
//   (outflow/bitblt_system.map.v) and looks for a top module named `sim`.
//   The project has none -- every existing testbench targets a submodule -- so
//   the flow got as far as elaborating and then failed with
//       vopt-2253 No module name found in ... bitblt_system.lib.sim
//   This file supplies that top level.
//
// WHAT IT CAN AND CANNOT DO
//   The netlist is flattened all the way down: DDR3 controller, PLLs and the SoC
//   are inside it, and sim_models/ ships only primitive models (efx_lut4, efx_ff,
//   efx_dsp48, ...) -- there is no DDR3 or PLL behavioural model to plug in.
//   So the memory interface is left unconnected: DDR3 calibration will never
//   complete, and anything that waits on calibration will sit there.
//
//   That still makes the run worth doing. It exercises the synthesised logic
//   itself -- every LUT, flop, RAM and DSP in the real mapped netlist -- and it
//   proves the netlist elaborates and simulates at all, which nothing has
//   checked until now. It is explicitly NOT a functional test of the
//   accelerator, and must not be reported as one.
//
// WHAT TO LOOK FOR
//   * does it elaborate and run without X propagation through the whole design
//   * does the scan-out path toggle (tmds_* outputs) given a running pixel clock
//   * does the SoC come out of reset and start fetching
//   Anything beyond that needs a memory model we do not have.
//============================================================================

`timescale 1ns / 1ps

module sim;

    // ---- clocks ----------------------------------------------------------
    // The design takes its references from the board: 27 MHz oscillator, plus
    // the SoC and DDR3 clocks that on hardware come from PLLs. Here they are
    // driven directly, at roughly the right periods.
    reg clk_27m  = 1'b0;      // 27 MHz  -> ~37.037 ns
    reg clk_100m = 1'b0;      // core clock the design expects
    reg clk_25m  = 1'b0;

    always #18.5185 clk_27m  = ~clk_27m;
    always #5.0     clk_100m = ~clk_100m;
    always #20.0    clk_25m  = ~clk_25m;

    // Clock outputs that the PLLs would drive. Tie them to the references so
    // the rest of the design has something toggling.
    wire core_clk        = clk_100m;
    wire sdram_clk       = clk_100m;
    wire pix_clk         = clk_25m;
    wire pix_clk_fast    = clk_100m;
    wire rx_cal_clk      = clk_100m;
    wire tx_cal_clk      = clk_100m;
    wire tx_cal_clk_90edge = clk_100m;
    wire pll_fb          = clk_100m;

    // ---- reset -----------------------------------------------------------
    reg i_arstn = 1'b0;
    initial begin
        #200 i_arstn = 1'b1;
    end

    // ---- status ----------------------------------------------------------
    integer cycles = 0;
    always @(posedge clk_100m) cycles = cycles + 1;

    // ---- inputs the board would otherwise provide -------------------------
    reg  [3:0] soc_gpio_IN          = 4'h0;
    reg        system_uart_0_io_rxd = 1'b1;      // idle high
    reg        pll_locked           = 1'b0;
    reg        user_pll_locked      = 1'b0;
    reg  [15:0] ddr_dq_in_hi = 16'h0;
    reg  [15:0] ddr_dq_in_lo = 16'h0;
    reg  [1:0]  ddr_dqs_in_hi = 2'b0;
    reg  [1:0]  ddr_dqs_in_lo = 2'b0;
    reg        system_spi_0_io_data_0_IN = 1'b0;
    reg        system_spi_0_io_data_1_IN = 1'b0;

    // JTAG is not used in simulation
    reg io_jtag_tck = 1'b0, io_jtag_tdi = 1'b0, io_jtag_tms = 1'b0;
    reg jtag_inst1_CAPTURE = 1'b0, jtag_inst1_DRCK = 1'b0, jtag_inst1_RESET = 1'b1;
    reg jtag_inst1_RUNTEST = 1'b0, jtag_inst1_SEL = 1'b0, jtag_inst1_SHIFT = 1'b0;
    reg jtag_inst1_TCK = 1'b0, jtag_inst1_TDI = 1'b0, jtag_inst1_TMS = 1'b0;
    reg jtag_inst1_UPDATE = 1'b0;

    // ---- outputs (observed, not checked) ---------------------------------
    wire        system_uart_0_io_txd;
    wire [3:0]  soc_gpio_OUT, soc_gpio_OE;
    wire [2:0]  pll_shift;
    wire        pll_shift_ena;
    wire [4:0]  pll_shift_sel;
    wire        io_jtag_tdo, jtag_inst1_TDO;
    wire        tmds_clk_TX_OE, tmds_clk_TX_RST;
    wire [9:0]  tmds_clk_o;
    wire        tmds_data0_TX_OE, tmds_data0_TX_RST, tmds_data1_TX_OE, tmds_data1_TX_RST;
    wire        tmds_data2_TX_OE, tmds_data2_TX_RST;
    wire [9:0]  tmds_data0_o, tmds_data1_o, tmds_data2_o;
    wire [15:0] ddr_addr, ddr_dq_out_hi, ddr_dq_out_lo, ddr_dq_oe, ddr_dm_hi, ddr_dm_lo;
    wire [2:0]  ddr_ba;
    wire        ddr_cas_n, ddr_ck_hi, ddr_ck_lo, ddr_ras_n, ddr_reset_n, ddr_we_n;
    wire [0:0]  ddr_cke, ddr_cs_n, ddr_odt;
    wire [1:0]  ddr_dqs_out_hi, ddr_dqs_out_lo, ddr_dqs_oe, ddr_dqs_oe_n;
    wire        system_spi_0_io_data_0_OUT, system_spi_0_io_data_0_OE;
    wire        system_spi_0_io_data_1_OUT, system_spi_0_io_data_1_OE;
    wire        system_spi_0_io_sclk_write, system_spi_0_io_ss;

    // ---- the netlist under test ------------------------------------------
    system_top u_dut (
        .i_arstn(i_arstn),
        .io_jtag_tck(io_jtag_tck), .io_jtag_tdi(io_jtag_tdi), .io_jtag_tms(io_jtag_tms),
        .soc_gpio_IN(soc_gpio_IN),
        .system_uart_0_io_rxd(system_uart_0_io_rxd),
        .user_pll_locked(user_pll_locked), .pll_locked(pll_locked),
        .clk_100m(clk_100m), .pix_clk_fast(pix_clk_fast), .pix_clk(pix_clk),
        .pll_fb(pll_fb), .clk_27m(clk_27m), .core_clk(core_clk), .clk_25m(clk_25m),
        .sdram_clk(sdram_clk),
        .tx_cal_clk_90edge(tx_cal_clk_90edge), .rx_cal_clk(rx_cal_clk), .tx_cal_clk(tx_cal_clk),
        .jtag_inst1_CAPTURE(jtag_inst1_CAPTURE), .jtag_inst1_DRCK(jtag_inst1_DRCK),
        .jtag_inst1_RESET(jtag_inst1_RESET), .jtag_inst1_RUNTEST(jtag_inst1_RUNTEST),
        .jtag_inst1_SEL(jtag_inst1_SEL), .jtag_inst1_SHIFT(jtag_inst1_SHIFT),
        .jtag_inst1_TCK(jtag_inst1_TCK), .jtag_inst1_TDI(jtag_inst1_TDI),
        .jtag_inst1_TMS(jtag_inst1_TMS), .jtag_inst1_UPDATE(jtag_inst1_UPDATE),
        .ddr_dq_in_hi(ddr_dq_in_hi), .ddr_dq_in_lo(ddr_dq_in_lo),
        .ddr_dqs_in_hi(ddr_dqs_in_hi), .ddr_dqs_in_lo(ddr_dqs_in_lo),
        .system_spi_0_io_data_0_IN(system_spi_0_io_data_0_IN),
        .system_spi_0_io_data_1_IN(system_spi_0_io_data_1_IN),
        .io_jtag_tdo(io_jtag_tdo), .soc_gpio_OUT(soc_gpio_OUT), .soc_gpio_OE(soc_gpio_OE),
        .system_uart_0_io_txd(system_uart_0_io_txd),
        .pll_shift(pll_shift), .pll_shift_ena(pll_shift_ena), .pll_shift_sel(pll_shift_sel),
        .jtag_inst1_TDO(jtag_inst1_TDO),
        .tmds_clk_TX_OE(tmds_clk_TX_OE), .tmds_clk_o(tmds_clk_o), .tmds_clk_TX_RST(tmds_clk_TX_RST),
        .tmds_data0_TX_OE(tmds_data0_TX_OE), .tmds_data0_o(tmds_data0_o), .tmds_data0_TX_RST(tmds_data0_TX_RST),
        .tmds_data1_TX_OE(tmds_data1_TX_OE), .tmds_data1_o(tmds_data1_o), .tmds_data1_TX_RST(tmds_data1_TX_RST),
        .tmds_data2_TX_OE(tmds_data2_TX_OE), .tmds_data2_o(tmds_data2_o), .tmds_data2_TX_RST(tmds_data2_TX_RST),
        .ddr_addr(ddr_addr), .ddr_ba(ddr_ba), .ddr_cas_n(ddr_cas_n),
        .ddr_ck_hi(ddr_ck_hi), .ddr_ck_lo(ddr_ck_lo), .ddr_cke(ddr_cke), .ddr_cs_n(ddr_cs_n),
        .ddr_dm_hi(ddr_dm_hi), .ddr_dm_lo(ddr_dm_lo),
        .ddr_dq_out_hi(ddr_dq_out_hi), .ddr_dq_out_lo(ddr_dq_out_lo), .ddr_dq_oe(ddr_dq_oe),
        .ddr_dqs_out_hi(ddr_dqs_out_hi), .ddr_dqs_out_lo(ddr_dqs_out_lo),
        .ddr_dqs_oe(ddr_dqs_oe), .ddr_dqs_oe_n(ddr_dqs_oe_n), .ddr_odt(ddr_odt),
        .ddr_ras_n(ddr_ras_n), .ddr_reset_n(ddr_reset_n), .ddr_we_n(ddr_we_n),
        .system_spi_0_io_data_0_OUT(system_spi_0_io_data_0_OUT),
        .system_spi_0_io_data_0_OE(system_spi_0_io_data_0_OE),
        .system_spi_0_io_data_1_OUT(system_spi_0_io_data_1_OUT),
        .system_spi_0_io_data_1_OE(system_spi_0_io_data_1_OE),
        .system_spi_0_io_sclk_write(system_spi_0_io_sclk_write),
        .system_spi_0_io_ss(system_spi_0_io_ss)
    );

    // ---- what this run is checking ---------------------------------------
    // Only liveness: the netlist elaborates, comes out of reset, and the
    // scan-out and memory interfaces show activity. Anything stronger needs a
    // DDR3 model, which does not exist here.
    reg tmds_seen  = 1'b0;
    reg ddr_seen   = 1'b0;
    always @(posedge clk_25m) if (tmds_data0_o !== 10'h0) tmds_seen <= 1'b1;
    always @(posedge clk_100m) if (ddr_addr !== 16'h0)   ddr_seen  <= 1'b1;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim_map.vcd");
            $dumpvars(0, sim);
        end
        #200000;   // 200 us: long enough for reset release and plenty of clocks
        $display("");
        $display("================ post-map (gate-level) run summary ================");
        $display("  core clock cycles      : %0d", cycles);
        $display("  TMDS data0 ever nonzero : %s", tmds_seen  ? "yes" : "no");
        $display("  DDR address ever nonzero: %s", ddr_seen   ? "yes" : "no");
        $display("  uart txd level          : %b", system_uart_0_io_txd);
        $display("  ------------------------------------------------------------");
        $display("  NOTE: no DDR3 model exists in this environment, so memory");
        $display("  calibration cannot complete. This run checks elaboration and");
        $display("  liveness only -- it is not a functional test.");
        $display("=================================================================");
        $display("");
        $finish;
    end

endmodule
