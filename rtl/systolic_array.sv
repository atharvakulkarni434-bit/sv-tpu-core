// =============================================================================
// File:        systolic_array.sv
// Commented:   August 4, 2026
// Description: NxN grid of processing elements (PEs) implementing the DiP
//              (Diagonal-Input, Permuted weight-stationary) systolic array
//              dataflow for matrix multiplication acceleration. Activations
//              enter externally only at row 0 (a full row of matrix A each
//              cycle) and propagate diagonally downward/leftward through
//              the array, while partial sums accumulate vertically down each
//              column; weights are pre-permuted per DiP Algorithm 1 before
//              being loaded into each PE.
// =============================================================================

// NOTE: For context, Row 0 is fed EXTERNALLY, by the controller, on every cycle

// Standard timescale invariant
`timescale 1ns/1ps

// Module declaration, with  a build-time parameter N, the physical size of the array
// The array is ALWAYS size 4, the DIM_REG is what actually chooses to ACTIVATE a smaller array size
// Essentially, a 4x4 array is always made, but then DIM_REG decides the amount of the array utilized
module systolic_array #(
    parameter int N = 4  
)(
    input  logic                clk,
    input  logic                rst_n,          // active-low

    // One full row of matrix A, the INPUTS. These are 8 bit signed values. One element per column
    // Under DiP, the entire vector size N, in this case 4, is loaded into row 0 EVERY ACTIVE CYCLE
    input  logic signed [7:0]   activations [N],

    // The natural, unpermuted wright matrix. The permutation of the weights are internal, i.e. to THIS file.
    input  logic signed [7:0]   weights [N][N],

    input  logic                load_weight,    // told to each PE, telling them to latch a new weigh from weight_in
    input  logic                pe_clear,       // told to each, except clear
    input  logic                flow_en,        // this GATES whether row 0 is actively receiving new activations THIS cycle, versus holding

    // An N array, so an array of default size 4, of 32 bit values.
    // This represents the bottom row of PE's at all times.
    // This is NOT the final answer... yet, but deskew_capture.sv grabs from this row at the right cycle for each output row
    // In other words, this is where the results are temporarily located, and grabbed to assemble the right answer.
    output logic signed [31:0]  accum_bottom_row [N]
);

    // The weight sitting at [r][c] is NOT weights[r][c] - it is wrights[(r + c) % N][c].
    // In an non-DiP weight stationary systolic array, the weights are loaded straight into the PE's: One-to-One
    // The activations are hten skewed - row r of the input matrix is fed in r cycles late
    // DiP flips this dynamic - activations only enter row 0, unskewed, every cycle
    // Then, the wires flow the activations DOWN and to the LEFT
    // So, the activations are entering diagonally, effectively, hence the weights need to be preloaded in regard to that diagonal nature
    // Therfore, we have to skew the weights entrance as below.
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

    // Internal wire declarations...
    // act_reg_out captures each PE's registered activation OUTPUT
    // essentially, it passes the 8 bit activation Down and to the Left
    // accum_wire carries each PE's accumulator output, so the actual math answer of the PE, downwards
    // This is the partial sum concept.
    logic signed [7:0]  act_reg_out [N][N];
    logic signed [31:0] accum_wire  [N][N];

    // This is where flow_en comes into play
    // We don't want garbage activation data to be used, so we create a new vector called gated_activations
    // This is IDENTICAL in function to the activations array INPUT you see in the port statement
    // This is used as the REAL activation: if flow_en is high, then gated_activations becomes the external input
    // If flow_en is low, then gated_activations is driven with 0's, preventing junk from being sent through
    logic signed [7:0] gated_activations [N];

    genvar gcol;
    generate
        for (gcol = 0; gcol < N; gcol++) begin : gen_gate
            assign gated_activations[gcol] = flow_en ? activations[gcol] : '0;
        end
    endgenerate

    // This is the heart of the DiP architecture.
    // First, for every row and column, it decides where the PE's activation input comes from
    // If the row is 0, then as stated previously, the activation will come externally, from the gated_activations
    // If row is NOT 0, then the activation is passed by the neighbor, which is the diagonal from PE above and to the right! The whole point of DiP.
    
    genvar row, col;
    generate
        for (row = 0; row < N; row++) begin : gen_row
            for (col = 0; col < N; col++) begin : gen_col
                
                // one wire created fresh for every single PE instance
                logic signed [7:0] act_in_wire;

                // if row is 0, then gated activation is your input...
                if (row == 0) begin : gen_row0_external
                    assign act_in_wire = gated_activations[col];
                end
                else begin : gen_diagonal_predecessor
                    // else you get your input from up, and to the right, the inverse of down and to the left
                    assign act_in_wire = act_reg_out[row-1][(col+1) % N];
                end
                // instantiates the pe using the definition in the pe.sv file
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

    // Partial sums are simpling traveling downards, no skew
    // accum_wire[N-1][col] just holds a live continously updating value of the bottom PE in each column
    // deskew_capture.sv is responsible for sampling this accum_bottom_row at the correct cycle. This file merely places all results there.
    // It is the responsibility of the capture to grab the values at teh right time : (N-1) + r cycle for each row.
    generate
        for (col = 0; col < N; col++) begin : gen_bottom_row
            assign accum_bottom_row[col] = accum_wire[N-1][col];
        end
    endgenerate

endmodule

// -----------------------------------------------------------------------
// Design rationale: DiP vs. conventional weight-stationary (WS)
//
// Conventional WS systolic arrays skew the *activation* inputs in time
// (via input FIFOs) so each value arrives at the PE holding its matching
// weight. Those synchronization FIFOs cost area, power, and add latency
// to every activation stream, even though weights are loaded once and
// reused across many activations.
//
// DiP (Abdelmaksoud, Agwa, Prodromakis, 2024) inverts this: activations
// enter unskewed at row 0 every cycle and propagate diagonally, while
// the weight *permutation* is computed once, combinationally, at load
// time (this file's permuted_weights block). This eliminates the
// synchronization FIFOs entirely, at the cost of the one-time diagonal
// wiring/permutation logic implemented below. The tradeoff pays off
// specifically because weights are stationary and reused far more often
// than they're reloaded.
// -----------------------------------------------------------------------
