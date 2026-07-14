// pe.sv — Single Processing Element (sv-tpu-core)
// Vertical accum_in/accum_out chain (partial sums flow top -> bottom down
// each column), matching the TPU v1 weight-stationary MXU dataflow
// referenced in A.1. Pending A.8/A.9 spec sign-off (accum_in/accum_out are
// not yet listed in A.9's pe.sv port table — see systolic_array.sv notes).
`timescale 1ns/1ps

module pe (
    input  logic                clk,
    input  logic                rst_n,          // active-low
    input  logic signed [7:0]   activation_in,  // int8 from left neighbor
    input  logic signed [7:0]   weight_in,      // int8 weight to hold
    input  logic                load_weight,    // latch weight_in, a control strobe
    input  logic                pe_clear,       // one-cycle accumulator zero
    input  logic signed [31:0]  accum_in,       // partial sum from PE above
                                                 // (top row: tied to 0 by systolic_array.sv)
    output logic signed [7:0]   activation_out, // to right neighbor (REGISTERED — C.1)
    output logic signed [31:0]  accum_out       // partial sum to PE below
                                                 // (bottom row: this is the drained result — A.8)
);

    // -------------------------------------------------------------------
    // Weight register — loaded once, held stationary for the whole
    // computation. Only changes on an explicit load_weight strobe.
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
    // cycle of latency (C.1: required for the 2N latency contract).
    // -------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            activation_out <= 8'sd0;
        else
            activation_out <= activation_in;
    end

    // -------------------------------------------------------------------
    // MAC term — explicit sign-extension to 32 bits before multiplying,
    // rather than relying on implicit expression-context propagation.
    // Named signal also gives formal tools (and waveform/schematic views)
    // a concrete point to reference instead of an anonymous sub-expression
    // buried inside the accumulator's always_ff.
    //
    // Range check (Proof 1 / A.2): max |activation_in * weight_q| is
    // 128*127 = 16,256, far inside signed 32-bit range — this widening
    // cannot itself overflow.
    // -------------------------------------------------------------------
    logic signed [31:0] mac_term;
    assign mac_term = (32'(activation_in)) * (32'(weight_q));

    // -------------------------------------------------------------------
    // Accumulator register — partial sum in, MAC term added, cleared to
    // zero for exactly one cycle on pe_clear (A.5).
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
