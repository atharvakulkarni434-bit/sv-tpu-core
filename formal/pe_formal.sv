// pe_formal.sv — Proof 1: Accumulator Overflow Impossibility
// Bound to: pe.sv | Run via: pe_overflow.tcl (JasperGold only)

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
    input logic signed [7:0]   weight_q       
);

    localparam int ACC_IN_HI = 32'sd49152;    
    localparam int ACC_IN_LO = -32'sd49152;

    ap_accum_in_bounded: assume property (
        @(posedge clk) disable iff (!rst_n)
        (accum_in >= ACC_IN_LO) && (accum_in <= ACC_IN_HI)
    );

    cp_pe_clear_hits: cover property (
    @(posedge clk) disable iff (!rst_n)
    pe_clear ##1 (accum_out == 32'sd0)
    );  

    logic signed [63:0] wide_sum;
    assign wide_sum = 64'(accum_in) + (64'(activation_in) * 64'(weight_q));
        
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
