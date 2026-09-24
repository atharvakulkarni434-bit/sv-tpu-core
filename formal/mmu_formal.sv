// =============================================================================
// File:        mmu_formal.sv
// Commented:   August 13, 2026
// Description: Formal proof (JasperGold) for 2x2 Functional Correctness —
//              Proof 3 of the sv-tpu-core formal suite, and the crown jewel
//              of the three: unlike Proof 1 and Proof 2, this binds onto
//              mmu_top (not a leaf module), so the environment has to
//              drive/constrain the full AXI+DiP protocol rather than a
//              handful of ports. DIM_REG is pinned to 2, then all four
//              activation and four weight inputs are left as free int8
//              variables; the core assert (ap_2x2_functional_correctness)
//              checks that on every cycle `done` asserts, `results` holds
//              the true dot product, computed independently in wide
//              (64-bit) arithmetic. A second assert confirms inactive
//              lanes drain to zero rather than leaking stale data. One
//              thing to note:
//              The DiP latency contract is now resolved as active_dim + 5 cycles
//              (see README.md "Latency Contract", BUGS.md Bug 7) — this
//              proof never took a position on cycle count itself, so it
//              needed no change once that contract landed.
// =============================================================================

module mmu_formal_checker #(
    parameter int N = 4 
)(
    input  logic                clk,
    input  logic                rst_n, 

    input  logic                flow_en,
    input  logic                pe_clear,
    input  logic                load_weight,
    input  logic [2:0]          active_dim,      

    input  logic signed [7:0]   activations [N],
    input  logic signed [7:0]   weights     [N][N],
    input  logic signed [31:0]  results     [N][N],
    input  logic                done,

    input  logic [2:0]          dim_q_reg        // u_axi_lite_slave.dim_q
);

    localparam int unsigned DIM = 2; 

    
    logic signed [7:0] act_matrix [DIM][DIM];  
    logic signed [7:0] wt_matrix  [DIM][DIM];  

    genvar gr, gc;
    generate
        for (gr = 0; gr < DIM; gr++) begin : gen_stable_row
            for (gc = 0; gc < DIM; gc++) begin : gen_stable_col
                ap_act_stable: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    $stable(act_matrix[gr][gc])
                );
                ap_wt_stable: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    $stable(wt_matrix[gr][gc])
                );
            end
        end
    endgenerate

    ap_dim_pinned: assume property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    dim_q_reg == 3'(DIM)
    );

    cp_active_dim_matches: cover property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    active_dim == 3'(DIM)
    );

    logic [2:0] flow_cnt;
    logic       flow_active_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flow_cnt      <= '0;
            flow_active_q <= 1'b0;
        end
        else if (flow_en) begin
            flow_cnt      <= flow_active_q ? (flow_cnt + 1'b1) : '0;
            flow_active_q <= 1'b1;
        end
        else begin
            flow_active_q <= 1'b0;
        end
    end

    generate
        for (gc = 0; gc < DIM; gc++) begin : gen_act_assume
            
            for (gr = 0; gr < DIM; gr++) begin : gen_act_active
                ap_activation_feed_active: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    (flow_en && (flow_cnt == gr)) |-> (activations[gc] == act_matrix[gr][gc])
                );
            end
            
            ap_activation_feed_idle: assume property (
                @(posedge clk) disable iff (!rst_n)
                (!flow_en || (flow_cnt >= DIM)) |-> (activations[gc] == 8'sd0)
            );
        end

        for (gc = DIM; gc < N; gc++) begin : gen_act_pad_assume
            ap_activation_pad: assume property (
                @(posedge clk) disable iff (!rst_n)
                activations[gc] == 8'sd0
            );
        end
    endgenerate

    generate
        for (gr = 0; gr < DIM; gr++) begin : gen_wt_assume_row
            for (gc = 0; gc < DIM; gc++) begin : gen_wt_assume_col
                ap_weight_value: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    weights[gr][gc] == wt_matrix[gr][gc]
                );
            end
                    
            for (gc = DIM; gc < N; gc++) begin : gen_wt_pad_col
                ap_weight_pad_col: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    weights[gr][gc] == 8'sd0
                );
            end
        end
        for (gr = DIM; gr < N; gr++) begin : gen_wt_pad_row
            for (gc = 0; gc < N; gc++) begin : gen_wt_pad_row_col
                ap_weight_pad_row: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    weights[gr][gc] == 8'sd0
                );
            end
        end
    endgenerate

    logic signed [63:0] expected [DIM][DIM];

    always_comb begin
        for (int r = 0; r < DIM; r++)
            for (int c = 0; c < DIM; c++)
                expected[r][c] = 64'(act_matrix[r][0]) * 64'(wt_matrix[0][c])
                                + 64'(act_matrix[r][1]) * 64'(wt_matrix[1][c]);
    end

    // -----------------------------------------------------------------
    // The actual Proof 3 claim.
    // -----------------------------------------------------------------
    // It is very simple syntatically: whenever done is asserted...
    // On that same edge, all of the numbers in the results matrix (DUT) must match the above computed results (expected)
    ap_2x2_functional_correctness: assert property (
        @(posedge clk) disable iff (!rst_n)
        done |-> (
            (64'(results[0][0]) == expected[0][0]) &&
            (64'(results[0][1]) == expected[0][1]) &&
            (64'(results[1][0]) == expected[1][0]) &&
            (64'(results[1][1]) == expected[1][1])
        )
    );

    // A small bonus aspect:
    // For every result cell OUTSIDE the active 2x2 block, assert that it reads zero on done, as it should, instead of stale data
    generate
        for (gr = 0; gr < N; gr++) begin : gen_pad_check_row
            for (gc = 0; gc < N; gc++) begin : gen_pad_check_col
                if (gr >= DIM || gc >= DIM) begin : gen_pad_check
                    ap_inactive_lanes_zero: assert property (
                        @(posedge clk) disable iff (!rst_n)
                        done |-> (results[gr][gc] == 32'sd0)
                    );
                end
            end
        end
    endgenerate

    // Lastly, we cover to confirm that, under all these constrains, the sequence of: pe_clear, then flow_en, then done actually happens/is reachable at least once
    // pe_clear to flow_en should be one cycle apart, and then we wait until flow_en goes high, then wait AT MINIMUM one cycle, but up to infinity, until done is asserted
    // If the above happens at least once, then the cover passes
    cp_pe_clear_then_flow_then_done: cover property (
        @(posedge clk) disable iff (!rst_n)
        pe_clear ##1 flow_en [->1] ##0 1 ##[1:$] done
    );

endmodule : mmu_formal_checker

// As aforementioned, we are binding this to mmu_top, with special note to dim_q_reg as an explicity bind, with the rest being done via wildcard
bind mmu_top mmu_formal_checker mmu_formal_checker_i (
    .dim_q_reg (u_axi_lite_slave.dim_q),
    .*
);
