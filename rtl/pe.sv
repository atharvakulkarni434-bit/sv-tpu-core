
// pe.sv — Single Processing Element (sv-tpu-core)
// UPDATED: added vertical accum_in/accum_out chain (partial sums flow
// top -> bottom down each column), matching the TPU v1 weight-stationary
// MXU dataflow referenced in A.1. Pending A.8/A.9 spec sign-off.
`timescale 1ns/1ps
module pe (
    input  logic               clk,
    input  logic               rst_n,          // active-low
    input  logic signed [7:0]  activation_in,  // int8 from left neighbor
    input  logic signed [7:0]  weight_in,      // int8 weight to hold
    input  logic               load_weight,    // latch weight_in, a control strobe
    input  logic               pe_clear,       // one-cycle accumulator zero
    input  logic signed [31:0] accum_in,       // partial sum from PE above
                                                // (top row: tied to 0 by systolic_array.sv)
    output logic signed [7:0]  activation_out, // to right neighbor (REGISTERED — C.1)
    output logic signed [31:0] accum_out       // partial sum to PE below
                                                // (bottom row: this is the drained result — A.8)
);
    // Weight register — loaded once, held stationary for the whole computation.

    logic signed [7:0] weight_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            weight_q <= '0;
        else if (load_weight)
            weight_q <= weight_in;
    end

    // Pipeline register
    //Saying if rst is low, then activation_in latches onto activation_out
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            activation_out <= '0;
        else
            activation_out <= activation_in;
    end
    //Accumulator register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            accum_out <= '0;
        else if (pe_clear)
            accum_out <= '0;
        else
          accum_out <= accum_in + 32'(activation_in * weight_q);
    end

endmodule
