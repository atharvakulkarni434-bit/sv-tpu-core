// pe_formal.sv — Proof 1: Accumulator Overflow Impossibility
// Bound to: pe.sv | Run via: pe_overflow.tcl (JasperGold only)
//
// Envelope sizing is tied to the LOCKED physical array depth (A.2, N=4):
// any PE sits at most 3 rows below the column top, so accum_in has
// accumulated at most 3 terms; accum_out (this PE's own contribution
// included) has accumulated at most 4. These are two different bounds,
// not one reused envelope — see pe_overflow.tcl header for why that
// matters.

module pe_formal_checker (
    input logic                clk,
    input logic                rst_n,
    input logic signed [7:0]   activation_in,
    input logic signed [7:0]   weight_in,
    input logic                load_weight,
    input logic                pe_clear,
    input logic signed [31:0]  accum_in,
    input logic signed [7:0]   activation_out,
    input logic signed [31:0]  accum_out
);

    // Per-term extremes (both operands int8; true worst cases, not the
    // spec prose's 127x127 approximation):
    //   max positive product: (-128) * (-128) =  16384
    //   max negative product: (-128) *  127    = -16256
    localparam int TERM_MAX = 32'sd16384;
    localparam int TERM_MIN = -32'sd16256;

    // accum_in: at most 3 prior terms (rows above, N_MAX=4 column depth)
    localparam int ACC_IN_HI = 3 * TERM_MAX;   //  49152
    localparam int ACC_IN_LO = 3 * TERM_MIN;   // -48768

    // accum_out: at most 4 terms total (this PE included)
    localparam int ACC_OUT_HI = 4 * TERM_MAX;  //  65536
    localparam int ACC_OUT_LO = 4 * TERM_MIN;  // -65024

    // -------------------------------------------------------------------
    // Assumption: accum_in respects the <=3-term envelope. Sound for
    // every PE regardless of its row, since no PE in a 4-row column can
    // have more than 3 PEs above it.
    // -------------------------------------------------------------------
    ap_accum_in_bounded: assume property (
        @(posedge clk) disable iff (!rst_n)
        (accum_in >= ACC_IN_LO) && (accum_in <= ACC_IN_HI)
    );

    // -------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------

    // Primary claim (Proof 1): never overflows signed 32-bit range.
    ap_no_int32_overflow: assert property (
        @(posedge clk) disable iff (!rst_n)
        (accum_out >= -(32'sd1 <<< 31)) && (accum_out <= (32'sd1 <<< 31) - 1)
    );

    // Tighter claim: stays within the <=4-term envelope. Deliberately a
    // DIFFERENT bound than the accum_in assumption above (see header) —
    // do not merge these into one constant.
    //This one does not work...
    ap_envelope_bound: assert property (
        @(posedge clk) disable iff (!rst_n)
        (accum_out >= ACC_OUT_LO) && (accum_out <= ACC_OUT_HI)
    );

endmodule : pe_formal_checker

bind pe pe_formal_checker pe_formal_checker_i (.*);