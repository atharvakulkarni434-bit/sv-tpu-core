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
// This assertion is bound to EVERY PE instance - 16 independent copies in a 4x4
// array. TC-035f forces one PE's accumulator on a zero-activation cycle and
// confirms only that instance's copy fires, proving per-instance independence.
//
// Signal names follow Spec A.2 (pe.sv keeps its three registers: weight,
// activation pipeline, accumulator): activation_in (int8), acc (int32). Adjust
// the bind's connections if the RTL names the accumulator differently.
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
    input logic signed [ACC_W-1:0]  acc
);

    //--------------------------------------------------------------------
    // C1 — zero_input_no_accumulate
    //
    // When the activation flowing into a PE is zero, the accumulator must not
    // change (0 x weight = 0 regardless of the stored weight).
    //--------------------------------------------------------------------
    property p_zero_input_no_accumulate;
        @(posedge clk) disable iff (!rst_n)
        (activation_in == '0) |-> (acc == $past(acc));
    endproperty

    a_zero_input_no_accumulate: assert property (p_zero_input_no_accumulate)
        else $error("C1 zero_input_no_accumulate VIOLATED: acc changed on a zero-activation cycle (acc=%0d, prev=%0d) at time %0t",
                     acc, $past(acc), $time);

endmodule : pe_sva

`endif // PE_SVA_SV


// ==============================================================================
// NOTE ON BINDING — tb_top.sv owns the bind statement.
//
// WARNING: Parameter Injection
// Pass DATA_W/ACC_W overrides explicitly if the DUT is not int8/int32; otherwise
// the checker defaults to 8/32.
//
// Bound to every pe instance (the bind attaches one independent copy per PE):
//
//     bind pe pe_sva #(.DATA_W(DATA_W), .ACC_W(ACC_W)) pe_sva_i (.*);
//
// The wildcard bind (.*) connects activation_in/acc AS LONG AS the signal names
// in pe.sv match exactly.
// ==============================================================================
