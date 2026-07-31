//==============================================================================
// File: pe_sva.sv
// Project: sv-tpu-core
// Bound to: pe.sv  (every N x N processing-element instance)
//
// Properties: C1 (zero_input_no_accumulate)
//
// RESET STRATEGY (read before touching the property below):
//   The property uses `disable iff (!rst_n)`. The accumulator `acc` is cleared
//   by reset (and by pe_clear); the disable iff keeps the reset window from
//   being mistaken for an illegal accumulation on a zero-activation cycle.
//
// ACCUMULATION MODEL (read before touching the property below):
//   accum_out (bound here as `acc`) is NOT a self-referential accumulator
//   (acc <= acc + local_term). It is one stage in a vertical, column-wise
//   partial-sum pipeline (DiP, Section III-A): every cycle it latches
//   accum_in (the partial sum arriving from the PE above) plus this PE's
//   own local MAC term. So `acc` legitimately changes every cycle, driven
//   by accum_in, independent of this PE's own activation_in.
//
//   C1 is therefore NOT "acc == $past(acc)" when activation_in == 0 (that
//   assumes a stationary accumulator, which this design is not). The real
//   invariant is: when this PE's activation_in was zero last cycle, this
//   PE's own MAC contribution was zero, so this cycle's acc should equal
//   last cycle's accum_in, unmodified. pe_clear is excluded from the
//   antecedent since it forces accum_out to 0 regardless of accum_in and
//   is a separate, already-correct behavior (A.5), not a C1 concern.
//
// This assertion is bound to EVERY PE instance - 16 independent copies in a 4x4
// array. TC-035f forces one PE's accumulator on a zero-activation cycle and
// confirms only that instance's copy fires, proving per-instance independence.
//
// Signal names follow Spec A.2 (pe.sv keeps its three registers: weight,
// activation pipeline, accumulator): activation_in (int8), acc (int32),
// accum_in (int32, partial sum from the PE above), pe_clear (1-bit strobe).
// Adjust the bind's connections if the RTL names these differently.
//==============================================================================

`ifndef PE_SVA_SV
`define PE_SVA_SV

module pe_sva #(
    parameter int DATA_W = 8,    // int8 activations (Spec A.3)
    parameter int ACC_W  = 32    // int32 accumulator (Spec A.3)
) (
    input logic                     clk,
    input logic                     rst_n,
    input logic signed [DATA_W-1:0] activation_in,
    input logic signed [ACC_W-1:0]  accum_in,
    input logic                     pe_clear,
    input logic signed [ACC_W-1:0]  acc
);

    //--------------------------------------------------------------------
    // C1 — zero_input_no_accumulate
    //
    // When the activation flowing into a PE was zero on the previous cycle,
    // this PE contributed nothing to the vertical partial-sum chain that
    // cycle (0 x weight = 0 regardless of the stored weight), so this
    // cycle's acc must equal last cycle's accum_in unchanged — unless
    // pe_clear was asserted, which forces acc to 0 independently of C1.
    //--------------------------------------------------------------------
    property p_zero_input_no_accumulate;
        @(posedge clk) disable iff (!rst_n)
        (activation_in == '0 && !pe_clear) |=> (acc == $past(accum_in));
    endproperty

    a_zero_input_no_accumulate: assert property (p_zero_input_no_accumulate)
        else $error("C1 zero_input_no_accumulate VIOLATED: acc changed on a zero-activation cycle (acc=%0d, past_accum_in=%0d) at time %0t",
                     acc, $past(accum_in), $time);

endmodule : pe_sva

`endif // PE_SVA_SV


// ==============================================================================
// NOTE ON BINDING — tb_top.sv owns the bind statement.
//
// WARNING: Parameter Injection
// Pass DATA_W/ACC_W overrides explicitly if the DUT is not int8/int32; otherwise
// the checker defaults to 8/32.
//
// Bound to every pe instance (the bind attaches one independent copy per PE).
// acc, accum_in, and pe_clear must be connected explicitly — pe.sv has no
// signal literally named "acc", and the wildcard bind cannot infer that
// accum_out is the intended target:
//
//     bind pe pe_sva pe_sva_i (
//         .acc(accum_out),
//         .accum_in(accum_in),
//         .pe_clear(pe_clear),
//         .*
//     );
//
// The wildcard (.*) picks up clk, rst_n, and activation_in, whose names
// match exactly between pe.sv and pe_sva.sv.
// ==============================================================================