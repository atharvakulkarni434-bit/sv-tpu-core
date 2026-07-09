// systolic_array.sv — N×N grid of PEs (sv-tpu-core)
// Per A.4: "The 4×4 grid of PEs. Parameterized on N. Fans pe_clear out to all PEs."
// FIRST DRAFT — pending team review, in particular the accum_in addition to
// pe.sv (needs A.9 sign-off) and the flow_en gating decision described below.
`timescale 1ns/1ps

module systolic_array #(
    parameter int N = 4   // physical array size (build-time). DIM_REG (1-4) selects
                           // the *active* size at runtime — see padding note at bottom.
)(
    input  logic                clk,
    input  logic                rst_n,          // active-low

    // A.9: activations — N×8, "one int8 per row entering from the left"
    input  logic signed [7:0]   activations [N],

    // A.9: weights — N×N×8, "int8 weights for the active N×N subset"
    // weights[row][col] is the stationary weight held at PE[row][col].
    input  logic signed [7:0]   weights [N][N],

    input  logic                load_weight,    // fanned to all PEs
    input  logic                pe_clear,       // fanned to all PEs — one cycle, zeros all accum
    input  logic                flow_en,        // gates activation entry (see note below)

    // A.9: results — N×32, "int32 results draining to the output buffer"
    // = the bottom row's accum_out, one full row of results per cycle.
    output logic signed [31:0]  results [N]
);

    // ---------------------------------------------------------------
    // Internal interconnect
    //   act_wire[row][col]   : activation_in  into PE[row][col]
    //   accum_wire[row][col] : accum_out     out of PE[row][col]
    // Horizontal: act_wire[row][col+1]  <= PE[row][col].activation_out
    // Vertical:   PE[row][col].accum_in <= accum_wire[row-1][col]
    //             (row 0's accum_in is tied to 0 — top boundary)
    // ---------------------------------------------------------------
    logic signed [7:0]  act_wire   [N][N+1];
    logic signed [31:0] accum_wire [N][N];

    // flow_en gate: when not actively flowing, force row-0 entry to zero so
    // the vertical accum chain naturally holds its value (0 * weight = 0
    // contributes nothing) instead of re-accumulating stale data every
    // cycle after DONE. See design note at bottom of file.
    logic signed [7:0] gated_activation [N];

    genvar row, col;
    generate
        for (row = 0; row < N; row++) begin : gen_row
            assign gated_activation[row]  = flow_en ? activations[row] : '0;
            assign act_wire[row][0]       = gated_activation[row];

            for (col = 0; col < N; col++) begin : gen_col
                pe u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .activation_in  (act_wire[row][col]),
                    .weight_in      (weights[row][col]),
                    .load_weight    (load_weight),
                    .pe_clear       (pe_clear),
                    .accum_in       (row == 0 ? 32'sd0 : accum_wire[row-1][col]),
                    .activation_out (act_wire[row][col+1]),
                    .accum_out      (accum_wire[row][col])
                );
            end
        end
    endgenerate

    // Bottom row drains as the result vector.
    generate
        for (col = 0; col < N; col++) begin : gen_result
            assign results[col] = accum_wire[N-1][col];
        end
    endgenerate

endmodule

// ---------------------------------------------------------------------
// Design notes for team review (not yet in the spec — flagging for A.8/A.9):
//
// 1. accum_in/accum_out on pe.sv: this file assumes the updated pe.sv from
//    this session (vertical partial-sum chain). Do not integrate against
//    the original pe.sv — it will build but silently produce wrong results
//    (see prior discussion: a single stationary weight cannot alone sum
//    N dot-product terms).
//
// 2. flow_en gating: implemented here at the array boundary rather than
//    inside pe.sv. Consequence for mmu_controller (A.5/A.8): the controller
//    does NOT need to explicitly drive `activations` to 0 after the last
//    real column — flow_en low is sufficient. Worth a line in A.8/A.9
//    confirming this is the agreed contract, since it changes what the
//    controller (RTL guy's module) is responsible for.
//
// 3. DIM_REG padding (N_active = 1..4 vs physical N=4): this module always
//    instantiates the full N×N grid. For N_active < 4, whatever upstream
//    logic stages `weights`/`activations` must zero-pad the unused rows
//    and columns (both weight AND activation = 0 for inactive lanes).
//    Because the accumulation is linear, a zero-padded lane contributes
//    exactly 0 and does not corrupt active lanes — no special-casing
//    needed inside systolic_array.sv itself. Flagging so whoever owns the
//    DIM_REG data-staging path (controller or a small mux layer) knows
//    this is the assumption being relied on.

// 4. OK, this is the single most important comment, with 2 perogatives. 
//    Firstly, you MUST stagger the inputs of the matrix. Say you have the
//    following matrix multiplication:
//
//  inputs[1   2]   weights[5   6]
//        [3   4]          [7   8]
//
//    Obviously, the weights are loaded into the PE's first, so we are really doing W * I.
//    So, on cycle 1, feed 1 into row 0.
//    Cycle 2, feed 3 into row 0, 2 into row 1.
//    Cycle 3, feed 4 into row 1.
//
//    Secondly, the results are going to be extremely staggered. Obviously, we cannot capture all of the results in this current window.
//    So, we need to make ANOTHER deskew module for this, either inside of mmu_controller.sv, or as a separate sv file entirely to get the results.
//    Otherwise, this is not going to work.
//
//
//    En sum,
//          1: Stagger inputs as dictated above.
//          2: Deskew results in a separate file.
// ---------------------------------------------------------------------
