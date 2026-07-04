
// pe.sv — Single Processing Element (sv-tpu-core)

`timescale 1ns/1ps
module pe (
    input  logic               clk,
    input  logic               rst_n,          // active-low 

    input  logic signed [7:0]  activation_in,  // int8 from left neighbor, to muliptly weight by
    input  logic signed [7:0]  weight_in,      // int8 weight to hold
    input  logic               load_weight,    // latch weight_in
    input  logic               pe_clear,       // one-cycle accumulator zero

    output logic signed [7:0]  activation_out, // to right neighbor (REGISTERED — C.1)
    output logic signed [31:0] accum_out       // int32 running total (registered)
);
    // Weight register
    // Basically saying, if reset is high, output of flipflop is zero, 
    // if not, then use load_wieght to latch weight_in onto weight_q
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
            accum_out <= accum_out + 32'(activation_in * weight_q);
    end

endmodule