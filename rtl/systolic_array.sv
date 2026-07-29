// systolic_array.sv — NxN grid of PEs, DiP (Diagonal-Input, Permuted weight
// stationary) dataflow.
//
// ARCHITECTURE CHANGE (this pass): replaces the old horizontal-activation /
// vertical-accum wiring with DiP's diagonal-activation / vertical-accum
// wiring, per Abdelmaksoud, Agwa, Prodromakis, "DiP: A Scalable,
// Energy-Efficient Systolic Array for Matrix Multiplication Acceleration"
// (arXiv:2412.09709v3), Section III-A/III-B. Wiring below is derived
// directly from the paper's worked 3x3 example (Fig. 3 / Section III-B
// cycle-by-cycle walkthrough) and independently checked against a
// cycle-accurate symbolic model for N=1..4 before being written here (every
// output row's dot product settles across the full bottom row
//
// WHAT STAYS THE SAME (unchanged from the pre-DiP file):
//   - Vertical accumulator interconnect: PE[row][col].accum_in comes from
//     PE[row-1][col].accum_out (row 0's accum_in tied to 0). "psums are
//     accumulated vertically along the columns" (DiP III-A) - identical to
//     the old design, no change here.
//   - load_weight / pe_clear fan out to every PE unchanged.
//
// WHAT CHANGED (the actual DiP rewiring):
//
//   1. EVERY ROW-0 PE IS AN EXTERNAL ENTRY POINT, LOADED EVERY CYCLE. This
//      is the detail an earlier draft of this file got wrong: DiP does NOT
//      have a single external input that trickles diagonally through the
//      whole array. Per the paper's walkthrough, "the input data is loaded
//      in parallel to Row-0" and this happens EVERY cycle activation flow
//      is active — cycle 0 loads input row 1 into Row-0, cycle 1 loads
//      input row 2 into Row-0 (while row 0's PREVIOUS contents have already
//      moved diagonally down to row 1), and so on. So activations[] (all N
//      elements, one full row of matrix A) feeds PE[0][0..N-1] directly,
//      every cycle, for as long as there are more input rows to feed
//      (gated by flow_en / the active dim, same role gated_activation
//      played before).
//
//   2. DIAGONAL DOWNWARD MOVEMENT, PER THE PAPER'S STATED PE TRANSITIONS.
//      Working through the paper's example (PE00->PE12, PE01->PE10,
//      PE02->PE11 for its 3x3 case): PE[row][col]'s registered
//      activation_out feeds PE[row+1][(col+1) mod N]'s activation_in. Read
//      the other way (which is what the RTL below actually needs — each
//      PE's *input* wiring): PE[row][col].activation_in comes from
//      PE[row-1][(col+1) mod N].activation_out, for row > 0. Row 0 never
//      reads from any other PE — see point 1.
//
//   3. WEIGHT PERMUTATION (DiP Algorithm 1, unchanged from the prior
//      revision of this file):
//          permuted_matrix[row][col] = original_matrix[(row+col) mod N][col]
//      Applied to the `weights` input port here; mmu_top.sv / data_agent.sv
//      continue to hand this module the natural (unpermuted) matrix.
//
//      skew_buffer.sv is REMOVED — see mmu_top.sv and the design notes at
//      the bottom of this file. The diagonal interconnect above performs
//      the staggering that skew_buffer.sv used to do externally; feeding
//      pre-skewed activations into this module would double-stagger every
//      row past row 0.
`timescale 1ns/1ps

module systolic_array #(
    parameter int N = 4   // physical array size (build-time). DIM_REG (1-4) selects
                           // the *active* size at runtime — see padding note at bottom.
)(
    input  logic                clk,
    input  logic                rst_n,          // active-low

    // A.9: activations — N×8. Under DiP this is a FULL ROW of matrix A,
    // loaded in parallel into PE[0][0..N-1] every active cycle (spec A.1/
    // A.6's "one column per cycle" language now means one *input-matrix
    // row* per cycle into systolic row 0, not one element per row per
    // cycle as in the old horizontal design — see file header point 1).
    input  logic signed [7:0]   activations [N],

    // A.9: weights — N×N×8. This is the NATURAL (unpermuted) weight
    // matrix, weights[row][col]. The DiP permutation (Algorithm 1) is
    // applied internally, below.
    input  logic signed [7:0]   weights [N][N],

    input  logic                load_weight,    // fanned to all PEs
    input  logic                pe_clear,       // fanned to all PEs — one cycle, zeros all accum
    input  logic                flow_en,        // gates the row-0 external entry (see below)

    // Raw, still-accumulating bottom row (same contract as before this
    // pass): deskew_capture.sv is responsible for snapshotting this at the
    // correct per-output-row cycle to build the real NxN result matrix.
    output logic signed [31:0]  accum_bottom_row [N]
);

    // ---------------------------------------------------------------
    // Weight permutation (DiP Algorithm 1):
    //   permuted[row][col] = weights[(row+col) mod N][col]
    // Applied once here, combinationally, from the natural weight matrix.
    // ---------------------------------------------------------------
    logic signed [7:0] permuted_weights [N][N];

    genvar prow, pcol;
    generate
        for (prow = 0; prow < N; prow++) begin : gen_perm_row
            for (pcol = 0; pcol < N; pcol++) begin : gen_perm_col
                assign permuted_weights[prow][pcol] =
                    weights[(prow + pcol) % N][pcol];
            end
        end
    endgenerate

    // ---------------------------------------------------------------
    // Internal interconnect
    //   act_reg_out[row][col] : activation_out FROM PE[row][col]
    //   accum_wire[row][col]  : accum_out out of PE[row][col]
    //
    //   Vertical (unchanged):  PE[row][col].accum_in <= accum_wire[row-1][col]
    //                          (row 0's accum_in tied to 0 — top boundary)
    //
    //   Diagonal (row 0):      PE[0][col].activation_in <= gated activations[col]
    //                          — external, every cycle, all N columns in
    //                          parallel (file header point 1).
    //
    //   Diagonal (row > 0):    PE[row][col].activation_in <=
    //                            act_reg_out[row-1][(col+1) % N]
    //                          (file header point 2).
    // ---------------------------------------------------------------
    logic signed [7:0]  act_reg_out [N][N];
    logic signed [31:0] accum_wire  [N][N];

    // flow_en gate on the row-0 external entry: when not actively flowing,
    // present zero on every row-0 input so the internal diagonal chain
    // naturally holds rather than re-circulating stale data. Same role
    // gated_activation played in the pre-DiP file, now applied to the full
    // row-0 vector instead of per-row (DiP has one true external entry
    // ROW, fed in full every cycle, not N independent single-element
    // entries).
    logic signed [7:0] gated_activations [N];

    genvar gcol;
    generate
        for (gcol = 0; gcol < N; gcol++) begin : gen_gate
            assign gated_activations[gcol] = flow_en ? activations[gcol] : '0;
        end
    endgenerate

    genvar row, col;
    generate
        for (row = 0; row < N; row++) begin : gen_row
            for (col = 0; col < N; col++) begin : gen_col

                logic signed [7:0] act_in_wire;
                if (row == 0) begin : gen_row0_external
                    assign act_in_wire = gated_activations[col];
                end
                else begin : gen_diagonal_predecessor
                    assign act_in_wire = act_reg_out[row-1][(col+1) % N];
                end

                pe u_pe (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .activation_in  (act_in_wire),
                    .weight_in      (permuted_weights[row][col]),
                    .load_weight    (load_weight),
                    .pe_clear       (pe_clear),
                    .accum_in       (row == 0 ? 32'sd0 : accum_wire[row-1][col]),
                    .activation_out (act_reg_out[row][col]),
                    .accum_out      (accum_wire[row][col])
                );
            end
        end
    endgenerate

    // Bottom row, exposed raw (still free-running / not yet deskewed).
    // deskew_capture.sv owns snapshotting this into a real result matrix -
    // see that file for the DiP-specific timing derivation ((N-1)+r per
    // output row r, verified by simulation, file header above).
    generate
        for (col = 0; col < N; col++) begin : gen_bottom_row
            assign accum_bottom_row[col] = accum_wire[N-1][col];
        end
    endgenerate

endmodule

// ---------------------------------------------------------------------
// Design notes for team review:
//
// 1. accum_in/accum_out on pe.sv: unchanged from the pre-DiP file, still
//    the vertical partial-sum chain.
//
// 2. flow_en gating: applied once, to the full row-0 input vector, rather
//    than the old per-row gated_activation array. This is a direct
//    structural consequence of DiP: row 0 is the array's only external
//    entry, fed a complete row of A every active cycle; rows 1..N-1 never
//    touch flow_en directly, they only ever see what row 0 (eventually,
//    diagonally) hands them.
//
// 3. DIM_REG padding (N_active = 1..4 vs physical N=4): unchanged in
//    spirit — upstream staging must zero-pad inactive rows/columns of the
//    NATURAL weight matrix and present 0 on activations[] for inactive
//    rows/columns, exactly as before. Because the weight permutation is a
//    pure index remap, an inactive weight lane permutes to another
//    inactive weight lane and needs no special-casing here.
//
// 4. skew_buffer.sv is REMOVED (no longer instantiated upstream of this
//    module). Its entire purpose — staggering row r's activation feed by r
//    cycles before the array — is now performed BY the diagonal
//    interconnect above, internally, as data moves row-to-row. Feeding
//    pre-skewed activations into this module would double-stagger every
//    row past row 0 and produce wrong results. mmu_top.sv wires
//    data_agent's raw (unskewed) activations[] straight into this module's
//    activations[] port — see mmu_top.sv's updated instantiation.
//
// 5. deskew_capture.sv's capture-cycle formula is (N-1)+r for output row r
//    (measured from the first cycle row 0 is fed), replacing the old
//    horizontal design's N+k formula — see that file's header for the
//    full derivation and verification method.
// ---------------------------------------------------------------------
