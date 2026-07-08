//==============================================================================
// File: mmu_if.sv
// Project: sv-tpu-core 
// Date: 2026-07-08
//
// Description:
//   SystemVerilog interface bundle - the single connection contract between the
//   DUT (mmu_top.sv) and the UVM testbench. 
//
// Features:
//   - AXI-Lite control channel (AW/W/B/AR/R) for the three control registers
//   - Data plane: int8 activations, int8 weights, int32 results
//   - start / done / dim_n observability taps for the 2N latency checkers (C.6)
//   - Three clocking blocks: axi_cb, data_cb, mon_cb
//   - Modports: axi_drv, data_drv, mon, dut
//   - Parameterized on N (4x4), DATA_W (int8), ACC_W (int32)
//==============================================================================

interface mmu_if #(
    parameter int N       = 4,   // physical array dimension (4x4)
    parameter int DATA_W  = 8,   // int8 activations / weights
    parameter int ACC_W   = 32   // int32 accumulator / result
)(
    input logic clk,
    input logic rst_n            // active-low reset 
);

   
    // AXI-Lite control channel  (testbench <-> axi_lite_slave.sv)
    // Standard AXI-Lite slave signals. Address bus kept narrow - only three
    // registers (DIM_REG 0x0, CTRL_REG 0x4, STATUS_REG 0x8).
    
    localparam int ADDR_W = 4;   // 4 bits covers offsets 0x0..0x8
    localparam int AXI_W  = 32;  // AXI data width

    // Write address channel
    logic [ADDR_W-1:0] awaddr;
    logic              awvalid;
    logic              awready;
    // Write data channel
    logic [AXI_W-1:0]  wdata;
    logic [3:0]        wstrb;
    logic              wvalid;
    logic              wready;
    // Write response channel
    logic [1:0]        bresp;
    logic              bvalid;
    logic              bready;
    // Read address channel
    logic [ADDR_W-1:0] araddr;
    logic              arvalid;
    logic              arready;
    // Read data channel
    logic [AXI_W-1:0]  rdata;
    logic [1:0]        rresp;
    logic              rvalid;
    logic              rready;

    
    // Data plane  (data_agent <-> systolic_array via mmu_top)
    
    // Activations: one int8 per row entering from the left (spec A.9).
    logic signed [DATA_W-1:0] activations [N];
    // Weights: int8 weights for the active NxN subset, loaded and held.
    logic signed [DATA_W-1:0] weights     [N][N];
    // Results: int32 per column, drained to output buffer.
    logic signed [ACC_W-1:0]  results     [N];
    // Result read-out handshake from output_buffer.
    logic                     result_valid;
    
    logic start;                 // decoded CTRL_REG start bit
    logic done;                  // drives STATUS_REG done bit
    logic [2:0] dim_n;           // decoded DIM_REG value (active N)

   
    // Clocking blocks - synchronize TB driving/sampling to the clock edge.
   
    // AXI master clocking block (driven by axi_agent driver)
    clocking axi_cb @(posedge clk);
        default input #1step output #1;
        output awaddr, awvalid, wdata, wstrb, wvalid, bready,
               araddr, arvalid, rready;
        input  awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid;
    endclocking

    // Data plane clocking block (driven by data_agent driver)
    clocking data_cb @(posedge clk);
        default input #1step output #1;
        output activations, weights;
        input  results, result_valid, start, done, dim_n;
    endclocking

    // Passive monitor clocking block (samples everything)
    clocking mon_cb @(posedge clk);
        default input #1step;
        input awaddr, awvalid, awready, wdata, wstrb, wvalid, wready,
              bresp, bvalid, bready, araddr, arvalid, arready,
              rdata, rresp, rvalid, rready,
              activations, weights, results, result_valid,
              start, done, dim_n;
    endclocking


    // Modports
   
    modport axi_drv  (clocking axi_cb,  input clk, rst_n);
    modport data_drv (clocking data_cb, input clk, rst_n);
    modport mon      (clocking mon_cb,  input clk, rst_n);

    // DUT-facing modport (connected to mmu_top). Directions are from the DUT's
    // point of view: it receives control/data, drives responses/results.
    modport dut (
        input  clk, rst_n,
        input  awaddr, awvalid, wdata, wstrb, wvalid, bready,
               araddr, arvalid, rready,
        output awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid,
        input  activations, weights,
        output results, result_valid, start, done, dim_n
    );

endinterface : mmu_if