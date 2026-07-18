// pe.sv — Single Processing Element (sv-tpu-core)
//
// ARCHITECTURE CHANGE (this pass): DiP (Diagonal-Input, Permuted weight
// stationary), per Abdelmaksoud, Agwa, Prodromakis, "DiP: A Scalable,
// Energy-Efficient Systolic Array for Matrix Multiplication Acceleration"
// (arXiv:2412.09709v3), Section III-A/III-B.
//
// WHAT ACTUALLY CHANGED IN THIS FILE: nothing structural. pe.sv still has
// exactly the same three registers it always had — a weight register
// (loaded on load_weight, held stationary), an activation pipeline register
// (registered input -> registered output, one cycle of latency, per C.1),
// and a vertical accumulator (accum_in + activation*weight, cleared on
// pe_clear). The MAC math and Proof 1 overflow bound are byte-for-byte
// unchanged - the widest product is still 128*127 = 16,256 and the
// accumulator is still 32-bit signed.
//
// WHAT CHANGED IS OUTSIDE THIS FILE: in the old (horizontal) array,
// activation_in for PE[row][col] came from PE[row][col-1]'s activation_out
// (same row, one column left) - a fixed horizontal neighbor wired inside
// systolic_array.sv's row-major generate block. In DiP, activation_in for
// PE[row][col] comes from a DIAGONAL predecessor: PE[row][col+1]'s
// activation_out for col < N-1, or PE[row-1][0]'s activation_out (wrapped,
// with row 0 fed externally) for col == N-1. That rewiring is entirely a
// systolic_array.sv interconnect change (see that file's header) - this
// module has no idea what its neighbor even is, and needed zero changes to
// support it. The port names below are intentionally neighbor-agnostic
// (activation_in/activation_out, not "left_in"/"right_out") since "left" and
// "right" no longer describe the topology.
//
// Weight permutation (DiP's other change) also does not touch this file.
// weight_in is still just "the int8 value to latch on load_weight" - the
// PERMUTED value (per Algorithm 1: permuted[row][col] = original[(row+col)
// mod N][col]) is selected upstream, at the point weights are staged into
// the array (systolic_array.sv / mmu_top.sv), not inside the PE.
`timescale 1ns/1ps

module pe (
    input  logic                clk,
    input  logic                rst_n,          // active-low
    input  logic signed [7:0]   activation_in,  // int8 from diagonal predecessor
                                                 // (wiring decided by systolic_array.sv)
    input  logic signed [7:0]   weight_in,      // int8 permuted weight to hold
    input  logic                load_weight,    // latch weight_in, a control strobe
    input  logic                pe_clear,       // one-cycle accumulator zero
    input  logic signed [31:0]  accum_in,       // partial sum from PE above
                                                 // (top row: tied to 0 by systolic_array.sv)
    output logic signed [7:0]   activation_out, // to diagonal successor (REGISTERED — C.1)
    output logic signed [31:0]  accum_out       // partial sum to PE below
                                                 // (bottom row: this is the drained result — A.8)
);

    // -------------------------------------------------------------------
    // Weight register — loaded once, held stationary for the whole
    // computation. Only changes on an explicit load_weight strobe.
    // Unchanged from the pre-DiP design: DiP does not alter *when* or *how*
    // weights are held, only *which* weight value each PE receives (the
    // permutation, applied upstream).
    // -------------------------------------------------------------------
    logic signed [7:0] weight_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            weight_q <= 8'sd0;
        else if (load_weight)
            weight_q <= weight_in;
    end

    // -------------------------------------------------------------------
    // Pipeline register — activation_in -> activation_out, exactly one
    // cycle of latency (C.1). Unchanged: still a single register stage.
    // What's now connected to activation_in/activation_out (the diagonal
    // neighbor instead of the horizontal one) is entirely systolic_array.sv's
    // concern.
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            activation_out <= 8'sd0;
        else
            activation_out <= activation_in;
    end

    // -------------------------------------------------------------------
    // MAC term — explicit sign-extension to 32 bits before multiplying.
    // Byte-for-byte identical to the pre-DiP file. Range check (Proof 1 /
    // A.2): max |activation_in * weight_q| is 128*127 = 16,256, far inside
    // signed 32-bit range.
    // -------------------------------------------------------------------
    logic signed [31:0] mac_term;
    assign mac_term = (32'(activation_in)) * (32'(weight_q));

    // -------------------------------------------------------------------
    // Accumulator register — partial sum in, MAC term added, cleared to
    // zero for exactly one cycle on pe_clear (A.5). Unchanged: still a
    // vertical (column-wise) accumulation chain, per DiP III-A ("psums are
    // accumulated vertically along the columns as well").
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            accum_out <= 32'sd0;
        else if (pe_clear)
            accum_out <= 32'sd0;
        else
            accum_out <= accum_in + mac_term;
    end

endmodule
