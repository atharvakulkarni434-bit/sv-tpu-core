//==============================================================================
// File: mmu_top.sv
// Project: sv-tpu-core
//
// Top wrapper (A.4) — the DUT boundary. Instantiates the control panel
// (axi_lite_slave), the sequencer (mmu_controller), the skew_buffer (input
// wavefront stagger), the compute array (systolic_array), deskew_capture
// (snapshots the array's bottom accum row into a true NxN result matrix),
// and output_buffer. tb_top.sv's job is only to wire this module's ports to
// mmu_if — all instantiation lives here.
//
// FIX (this pass): deskew_capture was missing from the instance list, and
// the systolic_array connection still referenced the old `results` port name
// (systolic_array.sv now exposes `accum_bottom_row`, not `results` — see that
// file's header). Also widened this module's own `results` port from N x32
// to N x N x32 to match mmu_if.sv's CHANGE note (full result matrix, not a
// single vector).
//==============================================================================
`timescale 1ns/1ps

module mmu_top #(
    parameter int N      = 4,
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32,
    parameter int ADDR_W = 4,
    parameter int AXI_W  = 32,
    parameter int DIM_W  = 3
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // AXI-Lite slave (B.2)
    input  logic [ADDR_W-1:0]        awaddr,
    input  logic                     awvalid,
    output logic                     awready,
    input  logic [AXI_W-1:0]         wdata,
    input  logic [3:0]               wstrb,
    input  logic                     wvalid,
    output logic                     wready,
    output logic [1:0]               bresp,
    output logic                     bvalid,
    input  logic                     bready,
    input  logic [ADDR_W-1:0]        araddr,
    input  logic                     arvalid,
    output logic                     arready,
    output logic [AXI_W-1:0]         rdata,
    output logic [1:0]               rresp,
    output logic                     rvalid,
    input  logic                     rready,

    // Data plane (A.9) — activations arrive UNSKEWED from data_agent.sv
    input  logic signed [DATA_W-1:0] activations [N],
    input  logic signed [DATA_W-1:0] weights     [N][N],
    // WIDENED (matches mmu_if.sv CHANGE 2026-07-17): full NxN result matrix,
    // not the old N-wide single vector.
    output logic signed [ACC_W-1:0]  results     [N][N],
    output logic                     result_valid,

    // Observability taps for the latency checkers (A.9 note, C.5)
    output logic                     start,
    output logic                     done,
    output logic [DIM_W-1:0]         dim_n
);

    // ---- internal control ----
    logic       load_weight;
    logic       pe_clear;
    logic       flow_en;
    logic [2:0] active_dim;   // mmu_controller.dim_q — latched dim for the in-flight pass

    // ---- internal data ----
    logic signed [DATA_W-1:0] skewed_activations [N];
    logic signed [ACC_W-1:0]  array_results       [N];        // raw, still-accumulating bottom row
    logic signed [ACC_W-1:0]  result_matrix       [N][N];     // deskewed, true NxN product

    // -------------------- axi_lite_slave.sv (Part B) --------------------
    axi_lite_slave #(.ADDR_W(ADDR_W), .AXI_W(AXI_W), .DIM_W(DIM_W)) u_axi_lite_slave (
        .clk(clk), .rst_n(rst_n),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .araddr(araddr), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rvalid(rvalid), .rready(rready),
        .start(start), .dim_n(dim_n), .done(done)
    );

    // -------------------- mmu_controller.sv (A.5) --------------------
    mmu_controller #(.N(N)) u_mmu_controller (
        .clk(clk), .rst_n(rst_n),
        .start(start), .dim_n(dim_n),
        .load_weight(load_weight), .pe_clear(pe_clear), .flow_en(flow_en),
        .done(done),
        .dim_q(active_dim)
    );

    // -------------------- skew_buffer.sv --------------------
    // en tied to flow_en (chain advances only during ACTIVATION_FLOW); flush
    // tied to pe_clear so no stale activation from the PREVIOUS pass survives
    // into this one (A.7 no-leakage — same spirit as pe_clear zeroing accum).
    // Uses active_dim (latched), not live dim_n, for the same race reason as
    // output_buffer below.
    skew_buffer #(.N(N), .DATA_W(DATA_W)) u_skew_buffer (
        .clk(clk), .rst_n(rst_n),
        .en(flow_en), .flush(pe_clear),
        .dim_n(active_dim),
        .din(activations),
        .dout(skewed_activations)
    );

    // -------------------- systolic_array.sv --------------------
    // FIXED: port name is accum_bottom_row (systolic_array.sv no longer has
    // a `results` port — see that file's header on why the bottom row is
    // exposed raw instead of pre-summed).
    systolic_array #(.N(N)) u_systolic_array (
        .clk(clk), .rst_n(rst_n),
        .activations(skewed_activations),
        .weights(weights),
        .load_weight(load_weight), .pe_clear(pe_clear), .flow_en(flow_en),
        .accum_bottom_row(array_results)
    );

    // -------------------- deskew_capture.sv --------------------
    // NEWLY WIRED: sits between systolic_array and output_buffer. Snapshots
    // accum_bottom_row at the correct per-column cycle (capture_cycle(k) =
    // N+k, per that file's timing derivation) to build the true NxN result
    // matrix. Driven by the same flow_en/pe_clear pair skew_buffer already
    // uses, and the same latched active_dim output_buffer uses below.
    deskew_capture #(.N(N), .ACC_W(ACC_W)) u_deskew_capture (
        .clk(clk), .rst_n(rst_n),
        .flow_en(flow_en), .flush(pe_clear),
        .dim_n(active_dim),
        .accum_bottom_row(array_results),
        .result_matrix(result_matrix)
    );

    // -------------------- output_buffer.sv --------------------
    output_buffer #(.N(N), .ACC_W(ACC_W)) u_output_buffer (
        .clk(clk), .rst_n(rst_n),
        .done(done),
        .active_dim(active_dim),
        .results_in(result_matrix),
        .results_out(results),
        .result_valid(result_valid)
    );

endmodule : mmu_top
