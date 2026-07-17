//==============================================================================
// File: mmu_top.sv
// Project: sv-tpu-core
//
// Top wrapper (A.4) — the DUT boundary. Instantiates the control panel
// (axi_lite_slave), the sequencer (mmu_controller), the skew_buffer that now
// owns the diagonal wavefront stagger (moved out of data_agent.sv), the
// compute array (systolic_array), and output_buffer. tb_top.sv's job is only
// to wire this module's ports to mmu_if — all instantiation lives here.
//
// PENDING SPEC UPDATE (inherited from skew_buffer.sv): A.4's module list and
// A.8's signal map don't mention skew_buffer.sv yet. Doesn't block anything
// here since mmu_if's port names are unaffected — flagging for the next spec
// pass, same as skew_buffer.sv already does.
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
    output logic signed [ACC_W-1:0]  results     [N],
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
    logic signed [ACC_W-1:0]  array_results       [N];

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
    // output_buffer above.
    skew_buffer #(.N(N), .DATA_W(DATA_W)) u_skew_buffer (
        .clk(clk), .rst_n(rst_n),
        .en(flow_en), .flush(pe_clear),
        .dim_n(active_dim),
        .din(activations),
        .dout(skewed_activations)
    );

    // -------------------- systolic_array.sv --------------------
    systolic_array #(.N(N)) u_systolic_array (
        .clk(clk), .rst_n(rst_n),
        .activations(skewed_activations),
        .weights(weights),
        .load_weight(load_weight), .pe_clear(pe_clear), .flow_en(flow_en),
        .results(array_results)
    );

    // -------------------- output_buffer.sv --------------------
    output_buffer #(.N(N), .ACC_W(ACC_W)) u_output_buffer (
        .clk(clk), .rst_n(rst_n),
        .done(done),
        .active_dim(active_dim),
        .results_in(array_results),
        .results_out(results),
        .result_valid(result_valid)
    );

endmodule : mmu_top
