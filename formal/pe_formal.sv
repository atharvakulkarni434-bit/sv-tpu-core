// pe_formal.sv — Proof 1: Accumulator Overflow Impossibility
// Bound to: pe.sv | Run via: pe_overflow.tcl (JasperGold only)
//
// IMPORTANT: this checks the WIDE (64-bit), pre-truncation sum against
// int32 bounds — not accum_out itself. accum_out is declared as a 32-bit
// signed register, so "accum_out fits in 32-bit signed range" is a
// tautology (true by SV's type system, proves nothing about the RTL).
// The real claim is: the arithmetic VALUE of accum_in + activation*weight,
// computed without truncation, never actually needed more than 32 bits.
//
// weight_q is pe.sv's internal register (not a top-level port). Adding it
// as a checker port works because `bind` places this instance inside pe's
// scope — `.*` resolves it by name against pe's internal signals, same as
// any top-level port.

module pe_formal_checker (
    input logic                clk,
    input logic                rst_n,
    input logic signed [7:0]   activation_in,
    input logic signed [7:0]   weight_in,
    input logic                load_weight,
    input logic                pe_clear,
    input logic signed [31:0]  accum_in,
    input logic signed [7:0]   activation_out,
    input logic signed [31:0]  accum_out,
    input logic signed [7:0]   weight_q       // internal signal, bound by name
);

    localparam int ACC_IN_HI = 32'sd49152;    // 3 * 16384, see prior derivation
    localparam int ACC_IN_LO = -32'sd49152;

    ap_accum_in_bounded: assume property (
        @(posedge clk) disable iff (!rst_n)
        (accum_in >= ACC_IN_LO) && (accum_in <= ACC_IN_HI)
    );

    cp_pe_clear_hits: cover property (
    @(posedge clk) disable iff (!rst_n)
    pe_clear ##1 (accum_out == 32'sd0)
    );  

    // Independently recomputed, full-precision (64-bit) MAC term. Deliberately
    // NOT reusing pe.sv's own `mac_term` wire — that signal sits downstream of
    // the RTL's multiplier, which the tool may blackbox/abstract. Recomputing
    // here from activation_in/weight_q keeps the check self-contained.
    logic signed [63:0] wide_sum;
    assign wide_sum = 64'(accum_in) + (64'(activation_in) * 64'(weight_q));

    // The actual Proof 1 claim: the true, untruncated sum always fits in
    // int32 — i.e. the 32-bit register never had to discard information.
    ap_no_int32_overflow: assert property (
        @(posedge clk) disable iff (!rst_n)
        (!pe_clear) |->
            (wide_sum >= -64'sd2147483648) && (wide_sum <= 64'sd2147483647)
    );

    ap_functional_equivalence: assert property (
    @(posedge clk)
    disable iff (
        !rst_n
        || $past(!rst_n, 1, 1'b1, @(posedge clk))
        || $past(pe_clear,  1, 1'b1, @(posedge clk))
    )
    accum_out ==
        $past(accum_in) +
        ($past(activation_in) * $past(weight_q))
    );

    ap_weight_holds: assert property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    !$past(load_weight) |-> weight_q == $past(weight_q)
    );

    ap_activation_pipeline: assert property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    activation_out == $past(activation_in)
    );

endmodule : pe_formal_checker

bind pe pe_formal_checker pe_formal_checker_i (.*);