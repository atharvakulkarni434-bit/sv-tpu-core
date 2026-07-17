// systolic_array.sv — 4x4 (parameterized NxN) grid of PEs.
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

    // CHANGED (2026-07-17): this port used to be `results [N]`, the bottom
    // row's accum_out directly. That collapsed every activation column that
    // swept through a PE into one blended sum (pe.sv's accumulator has no
    // per-column reset) - see BUGS.md / team discussion, 2026-07-17. The
    // array itself does not (and should not) fix that here; it now simply
    // exposes the raw, still-accumulating bottom row every cycle.
    // deskew_capture.sv (new module, sits between this and output_buffer)
    // is responsible for snapshotting this at the correct per-column cycle
    // to build the real NxN result matrix. This module's own job - MAC plus
    // vertical/horizontal propagation - is unchanged.
    output logic signed [31:0]  accum_bottom_row [N]
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

    // Bottom row, exposed raw (still free-running / not yet deskewed).
    // NOTE: this is NOT a valid result vector by itself — see header note
    // and deskew_capture.sv. Anything downstream that reads this port must
    // go through deskew_capture, never sample it directly as an answer.
    generate
        for (col = 0; col < N; col++) begin : gen_bottom_row
            assign accum_bottom_row[col] = accum_wire[N-1][col];
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
//
// 4. RESOLVED (2026-07-17): item 4 in the prior version of this file's
//    notes ("results are extremely staggered... need ANOTHER deskew
//    module... otherwise this is not going to work") is now addressed by
//    deskew_capture.sv, instantiated in mmu_top.sv between this module and
//    output_buffer.sv. The stagger-on-input half of that note (row r
//    delayed r cycles) was already handled separately by skew_buffer.sv.
//    Both halves of the original note are now covered by real modules.
// ---------------------------------------------------------------------
