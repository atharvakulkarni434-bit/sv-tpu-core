//==============================================================================
// File: mmu_if.sv
// Project: sv-tpu-core 
// Date: 2026-07-17
//
// Description:
//   SystemVerilog interface bundle - the single connection contract between the
//   DUT (mmu_top.sv) and the UVM testbench. 
//
// Features:
//   - AXI-Lite control channel (AW/W/B/AR/R) for the three control registers
//   - Data plane: int8 activations, int8 weights, int32 results
//   - start / done / dim_n observability taps for the dim+5 latency checkers (C.6)
//   - Three clocking blocks: axi_cb, data_cb, mon_cb
//   - Modports: axi_drv, data_drv, mon, dut
//   - Parameterized on N (4x4), DATA_W (int8), ACC_W (int32)
//
// CHANGE (2026-07-17): `results` widened from N x32 (a single vector) to
// N x N x32 (the full result matrix). Team decision: A.7 requires "the
// correct int32 matrix-multiply result", which for an NxN x NxN product is
// genuinely N^2 values, not N. The old N-wide port could only ever hold one
// row/column/guess of the true product - see BUGS.md and mmu_scoreboard.sv's
// predict() history for the "which k is on the bus at done" ambiguity this
// resolves. results_out[row][col] is the standard dot-product definition:
//   results[row][col] = sum over k of activations[row][k] * weights[k][col]
// This is a PENDING SPEC UPDATE against A.8/A.9's N x32 wording - flagging
// for sign-off alongside the RTL change, not silently diverging from it.
//
// CHANGE (this pass): added `flow_en` — an observability tap mirroring
// mmu_controller's ACTIVATION_FLOW state output. data_agent.sv's driver
// (drive_activations) and monitor (run_phase) both already gate on
// vif.data_cb.flow_en / vif.mon_cb.flow_en per the DiP dataflow (row 0 is fed
// a full row every active cycle, gated by flow_en - see systolic_array.sv);
// this signal did not previously exist anywhere in the interface, so those
// references would not compile. Added as an `input` on both clocking blocks
// (TB only ever reads it, never drives it - it is DUT-sourced) and to the
// `dut` modport as an `input` from mmu_top's point of view is wrong; from the
// DUT's point of view it is an OUTPUT (mmu_top drives it out), matching the
// existing start/done/dim_n taps exactly.
//
// CHANGE (this pass): added `fsm_state` — an observability tap mirroring
// mmu_controller's internal state register, added to support cp_reset_state
// coverage (mmu_coverage.sv), which needs to see what state the FSM was in
// at the moment reset asserts. Same rationale/pattern as flow_en above:
// DUT-sourced, TB only ever reads it, added to mon_cb and the dut modport
// as an output from mmu_top's point of view. NOT added to axi_cb/data_cb -
// only the passive monitor needs it, same as why flow_en's presence on
// data_cb is driver-driven by dataflow gating rather than reset tracking;
// fsm_state has no driver-side use case.
//
// WIDTH/ENCODING NOTE on fsm_state: width below is a placeholder (3 bits)
// sized to cover a handful of controller states - confirm against
// mmu_controller's actual state_e enum and widen/narrow to match exactly.
// mmu_coverage.sv's classify_reset_state() bin mapping must be kept in sync
// with whatever the real encoding turns out to be.
//==============================================================================

`timescale 1ns/1ps

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
    // Results: int32 full NxN result matrix, drained to output buffer.
    // results[row][col] = sum_k activations[row][k] * weights[k][col].
    // CHANGED from N x32 (single vector) - see file header.
    logic signed [ACC_W-1:0]  results     [N][N];
    // Result read-out handshake from output_buffer.
    logic                     result_valid;
    
    logic start;                 // decoded CTRL_REG start bit
    logic done;                  // drives STATUS_REG done bit
    logic [2:0] dim_n;           // decoded DIM_REG value (active N)
    logic flow_en;                // ACTIVATION_FLOW phase tap, from mmu_controller
                                   // (DUT-driven; gates the row-0 external entry
                                   // in systolic_array.sv - see data_agent.sv)
    logic [2:0] fsm_state;         // DUT-driven; raw state encoding from
                                    // mmu_controller's internal FSM register
                                    // (see file header CHANGE note - width is
                                    // a placeholder, confirm against the real
                                    // state_e enum)

   
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
        input  results, result_valid, start, done, dim_n, flow_en;
    endclocking

    // Passive monitor clocking block (samples everything)
    clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n,
          awaddr, awvalid, awready, wdata, wstrb, wvalid, wready,
          bresp, bvalid, bready, araddr, arvalid, arready,
          rdata, rresp, rvalid, rready,
          activations, weights, results, result_valid,
          start, done, dim_n, flow_en, fsm_state;
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
        output results, result_valid, start, done, dim_n, flow_en, fsm_state
    );

endinterface : mmu_if