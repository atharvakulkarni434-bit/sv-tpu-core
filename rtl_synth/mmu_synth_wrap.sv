//==============================================================================
// File: mmu_synth_wrap.sv
// Project: sv-tpu-core
//
// Synthesis-only flattening wrapper around mmu_top.
//
// WHY THIS EXISTS
// ---------------
// mmu_top's data-plane ports are UNPACKED arrays:
//
//     input  logic signed [DATA_W-1:0] activations [N];
//     input  logic signed [DATA_W-1:0] weights     [N][N];
//     output logic signed [ACC_W-1:0]  results     [N][N];
//
// That is perfectly legal SystemVerilog and simulates fine in Xcelium, where
// tb_top wires them to mmu_if. It is NOT legal on the TOP module of a Vivado
// synthesis run: synthesis has to turn every top-level port into a physical
// device pin (or, in out-of-context mode, into a port on the generated
// netlist/stub), and an unpacked array has no defined bit ordering to map onto
// pins. Vivado errors with something like:
//
//     [Synth 8-2778] type error near activations ; expected datatype logic
//
// This wrapper flattens them into packed vectors, instantiates mmu_top
// unchanged, and becomes the synthesis top. No RTL in rtl/ is modified: the
// simulation and formal flows keep using mmu_top directly and are unaffected.
//
// BIT ORDER (row-major, element 0 in the LSBs):
//     activations_flat[i*DATA_W       +: DATA_W]        = activations[i]
//     weights_flat    [(r*N+c)*DATA_W +: DATA_W]        = weights[r][c]
//     results_flat    [(r*N+c)*ACC_W  +: ACC_W]         = results[r][c]
//
// This file lives in rtl_synth/ so the Makefile's rtl/*.sv globs never pick it
// up into a simulation or formal compile.
//==============================================================================
`timescale 1ns/1ps

module mmu_synth_wrap #(
    parameter int N      = 4,
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32,
    parameter int ADDR_W = 4,
    parameter int AXI_W  = 32,
    parameter int DIM_W  = 3
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // ---- AXI-Lite (already flat on mmu_top, passed straight through) ----
    input  logic [ADDR_W-1:0]       awaddr,
    input  logic                    awvalid,
    output logic                    awready,
    input  logic [AXI_W-1:0]        wdata,
    input  logic [3:0]              wstrb,
    input  logic                    wvalid,
    output logic                    wready,
    output logic [1:0]              bresp,
    output logic                    bvalid,
    input  logic                    bready,
    input  logic [ADDR_W-1:0]       araddr,
    input  logic                    arvalid,
    output logic                    arready,
    output logic [AXI_W-1:0]        rdata,
    output logic [1:0]              rresp,
    output logic                    rvalid,
    input  logic                    rready,

    // ---- Data plane, flattened ----
    input  logic [N*DATA_W-1:0]     activations_flat,
    input  logic [N*N*DATA_W-1:0]   weights_flat,
    output logic [N*N*ACC_W-1:0]    results_flat,
    output logic                    result_valid,

    // ---- Observability taps ----
    output logic                    start,
    output logic                    done,
    output logic [DIM_W-1:0]        dim_n,
    output logic                    flow_en,
    output logic [2:0]              fsm_state
);

    // Unpacked views handed to mmu_top.
    logic signed [DATA_W-1:0] activations [N];
    logic signed [DATA_W-1:0] weights     [N][N];
    logic signed [ACC_W-1:0]  results     [N][N];

    genvar r, c;
    generate
        for (r = 0; r < N; r++) begin : gen_act
            assign activations[r] = activations_flat[r*DATA_W +: DATA_W];
        end

        for (r = 0; r < N; r++) begin : gen_row
            for (c = 0; c < N; c++) begin : gen_col
                assign weights[r][c] =
                    weights_flat[(r*N + c)*DATA_W +: DATA_W];
                assign results_flat[(r*N + c)*ACC_W +: ACC_W] =
                    results[r][c];
            end
        end
    endgenerate

    mmu_top #(
        .N      (N),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W),
        .ADDR_W (ADDR_W),
        .AXI_W  (AXI_W),
        .DIM_W  (DIM_W)
    ) u_mmu_top (
        .clk          (clk),
        .rst_n        (rst_n),

        .awaddr       (awaddr),
        .awvalid      (awvalid),
        .awready      (awready),
        .wdata        (wdata),
        .wstrb        (wstrb),
        .wvalid       (wvalid),
        .wready       (wready),
        .bresp        (bresp),
        .bvalid       (bvalid),
        .bready       (bready),
        .araddr       (araddr),
        .arvalid      (arvalid),
        .arready      (arready),
        .rdata        (rdata),
        .rresp        (rresp),
        .rvalid       (rvalid),
        .rready       (rready),

        .activations  (activations),
        .weights      (weights),
        .results      (results),
        .result_valid (result_valid),

        .start        (start),
        .done         (done),
        .dim_n        (dim_n),
        .flow_en      (flow_en),
        .fsm_state    (fsm_state)
    );

endmodule : mmu_synth_wrap
