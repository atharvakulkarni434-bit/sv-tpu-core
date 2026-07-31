//==============================================================================
// File: mmu_top.sv
// Project: sv-tpu-core
//
// Top wrapper (A.4) — the DUT boundary. Instantiates the control panel
// (axi_lite_slave), the sequencer (mmu_controller), the compute array
// (systolic_array, now DiP dataflow), deskew_capture (snapshots the array's
// bottom accum row into a true NxN result matrix, DiP-specific timing), and
// output_buffer. tb_top.sv's job is only to wire this module's ports to
// mmu_if — all instantiation lives here.
//
// DiP CHANGE (this pass): skew_buffer.sv is REMOVED from the instance list.
// Under the old horizontal-activation design, skew_buffer applied the
// per-row diagonal stagger externally, before activations reached the
// array. DiP's systolic_array.sv now performs that staggering internally
// via its diagonal interconnect (row 0 fed fresh every cycle, every other
// row fed diagonally from the row above) — see systolic_array.sv's header.
// Pre-skewing the feed here would double-stagger every row past row 0 and
// silently corrupt every result past the first. data_agent's raw,
// UNSKEWED activations are therefore wired straight into
// u_systolic_array.activations below, with nothing in between.
//
// CHANGE (this pass): added a `flow_en` output port, wired straight from
// u_mmu_controller.flow_en. mmu_controller already produces this signal
// internally (it always has — it's the ACTIVATION_FLOW state flag) but it
// was never brought out past this module's boundary. data_agent.sv's driver
// and monitor both gate on vif.data_cb.flow_en / vif.mon_cb.flow_en (the DiP
// dataflow requires it — row 0's external entry is only live during
// ACTIVATION_FLOW, per systolic_array.sv), so the testbench needs a live tap
// on it same as start/done/dim_n. No internal behavior changes — this is
// purely exposing an existing internal signal at the port list, the same way
// start/done/dim_n already are.
//
// CHANGE (this pass): added a `fsm_state` output port, wired straight from
// u_mmu_controller.fsm_state (itself new — see mmu_controller.sv's header).
// Same rationale/pattern as flow_en above: exposes an existing internal
// register at the port boundary for cp_reset_state coverage
// (mmu_coverage.sv), no internal behavior change.
//
// Everything else (axi_lite_slave, mmu_controller, deskew_capture's port
// list, output_buffer) is structurally unchanged from the pre-DiP file;
// only the middle of the data path (skew_buffer removed, systolic_array's
// internals) changed.
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

    // Data plane (A.9) — activations arrive UNSKEWED from data_agent.sv,
    // and stay unskewed all the way into systolic_array.sv under DiP (see
    // header note above — this is a deliberate change from the pre-DiP
    // file, not an oversight).
    input  logic signed [DATA_W-1:0] activations [N],
    input  logic signed [DATA_W-1:0] weights     [N][N],
    output logic signed [ACC_W-1:0]  results     [N][N],
    output logic                     result_valid,

    // Observability taps for the latency checkers (A.9 note, C.5), the
    // data-plane driver/monitor's DiP flow gating, and cp_reset_state
    // coverage (see header note above).
    output logic                     start,
    output logic                     done,
    output logic [DIM_W-1:0]         dim_n,
    output logic                     flow_en,
    output logic [2:0]               fsm_state
);

    // ---- internal control ----
    logic       load_weight;
    logic       pe_clear;
    logic [2:0] active_dim;   // mmu_controller.dim_q — latched dim for the in-flight pass

    // ---- internal data ----
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
        .active_dim(active_dim),
        .fsm_state(fsm_state)
    );

    // -------------------- systolic_array.sv (DiP dataflow) --------------------
    // REMOVED: skew_buffer.sv instance. data_agent's raw, unskewed
    // `activations` port is wired directly here — see file header. The
    // diagonal interconnect inside systolic_array.sv now performs the
    // staggering that skew_buffer used to do externally.
    systolic_array #(.N(N)) u_systolic_array (
        .clk(clk), .rst_n(rst_n),
        .activations(activations),
        .weights(weights),
        .load_weight(load_weight), .pe_clear(pe_clear), .flow_en(flow_en),
        .accum_bottom_row(array_results)
    );

    // -------------------- deskew_capture.sv --------------------
    // Port list unchanged from the pre-DiP file; internal timing formula is
    // now DiP-specific ((dim-1)+r per output row — see that file's header).
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