//==============================================================================
// File: tb_top.sv
// Project: sv-tpu-core 
// Date: 2026-07-17
//
// Description:
//   Testbench top. Generates clock and active-low reset, instantiates the
//   mmu_if interface bundle and the DUT (mmu_top.sv) through it, lists the SVA
//   bind statements (assertions bound to RTL, non-invasive), hands the virtual
//   interface to the UVM env via config_db, and starts UVM with run_test().
//
// Features:
//   - 100 MHz clock + 5-cycle active-low reset generation
//   - mmu_if instance parameterized on N / DATA_W / ACC_W
//   - DUT port map following spec A.9 — mmu_top.sv now exists, enabled below
//   - bind statements for axi/ctrl/pe SVA + mmu_perf_checker (enabled as each
//     .sv file lands — pe_sva.sv/mmu_controller_sva.sv/mmu_perf_checker.sv are
//     not yet in sva/, so those three stay commented)
//   - Global watchdog timeout so a hung DUT fails loudly
//
// NOTE: mmu_top.sv does ALL internal instantiation (axi_lite_slave,
// mmu_controller, skew_buffer, systolic_array, output_buffer). tb_top.sv only
// wires mmu_if's signals to mmu_top's top-level ports — it never reaches
// inside mmu_top. Formal .sv files (pe_formal.sv, axi_formal.sv) are never
// bound here; they run only through JasperGold per Rule 8.
//==============================================================================

`ifndef TB_TOP_SV
`define TB_TOP_SV

`timescale 1ns/1ps

module tb_top;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

   
    localparam int N      = 4;
    localparam int DATA_W = 8;
    localparam int ACC_W  = 32;
    localparam int ADDR_W = 4;
    localparam int AXI_W  = 32;
    localparam int DIM_W  = 3;
    localparam time CLK_PERIOD = 10ns;   // 100 MHz reference


    // Clock and active-low reset
   
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        rst_n = 1'b0;               // assert reset
        repeat (5) @(posedge clk);
        rst_n = 1'b1;               // release reset
    end

    
    // Interface instance
   
    mmu_if #(.N(N), .DATA_W(DATA_W), .ACC_W(ACC_W)) vif (
        .clk   (clk),
        .rst_n (rst_n)
    );

    //--------------------------------------------------------------------------
    // DUT instantiation — mmu_top.sv connected through the interface.
    // Port names follow spec A.9 and match mmu_top.sv exactly (verified
    // signal-by-signal against mmu_top.sv's port list and mmu_if.sv's bundle).
    // All six mmu_top parameters are passed explicitly rather than relying on
    // matching defaults across two files — if mmu_if.sv's defaults ever
    // change, this line will now visibly need updating instead of silently
    // drifting out of sync.
    //--------------------------------------------------------------------------
    mmu_top #(
        .N     (N),
        .DATA_W(DATA_W),
        .ACC_W (ACC_W),
        .ADDR_W(ADDR_W),
        .AXI_W (AXI_W),
        .DIM_W (DIM_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        // AXI-Lite slave
        .awaddr     (vif.awaddr),
        .awvalid    (vif.awvalid),
        .awready    (vif.awready),
        .wdata      (vif.wdata),
        .wstrb      (vif.wstrb),
        .wvalid     (vif.wvalid),
        .wready     (vif.wready),
        .bresp      (vif.bresp),
        .bvalid     (vif.bvalid),
        .bready     (vif.bready),
        .araddr     (vif.araddr),
        .arvalid    (vif.arvalid),
        .arready    (vif.arready),
        .rdata      (vif.rdata),
        .rresp      (vif.rresp),
        .rvalid     (vif.rvalid),
        .rready     (vif.rready),
        // Data plane
        .activations(vif.activations),
        .weights    (vif.weights),
        .results    (vif.results),
        .result_valid(vif.result_valid),
        // Observability taps for latency checkers
        .start      (vif.start),
        .done       (vif.done),
        .dim_n      (vif.dim_n)
    );

    //--------------------------------------------------------------------------
    // SVA bind statements — assertions bound to RTL, non-invasive.
    // Bound via `bind` so no RTL edits are needed. Formal .sv files run only
    // through JasperGold (Rule 8), never here — pe_formal.sv/axi_formal.sv are
    // NOT bound in this file under any circumstance.
    //
    // Enabled only as the actual .sv files land in sva/ — none of the three
    // below exist in the repo yet (sva/ currently holds only .gitkeep), so
    // all three stay commented until their owners (Samarth / RTL guy per the
    // ownership table) commit them. Un-comment one line per file landing,
    // not all three at once, so a missing file doesn't block the others.
    //--------------------------------------------------------------------------
    // bind axi_lite_slave   axi_lite_sva        axi_sva_i    (.*);
    // bind mmu_controller   mmu_controller_sva  ctrl_sva_i   (.*);
    // bind pe               pe_sva              pe_sva_i     (.*);
    // Jad's perf checker (2N latency + throughput), bound at top:
    // bind mmu_top          mmu_perf_checker    perf_i       (.*);

    //--------------------------------------------------------------------------
    // Hand the virtual interface to the UVM env and start the test.
    //--------------------------------------------------------------------------
    initial begin
        uvm_config_db#(virtual mmu_if)::set(null, "*", "vif", vif);
        run_test();
    end

    //--------------------------------------------------------------------------
    // Global watchdog so a hung DUT fails loudly instead of running forever.
    //--------------------------------------------------------------------------
    initial begin
        #1ms;
        `uvm_fatal("TB_TOP", "global timeout reached - simulation hung")
    end

endmodule : tb_top

`endif // TB_TOP_SV
