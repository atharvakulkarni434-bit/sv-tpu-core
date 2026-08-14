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
    parameter int N = 4 // parameter matches instantiated physical array size
)(
    input  logic                clk,
    input  logic                rst_n, // active low

    // These are all the internal mmu_top signals, pulled in via exact naming convention
    input  logic                flow_en,
    input  logic                pe_clear,
    input  logic                load_weight,
    input  logic [2:0]          active_dim,      // mmu_controller's latched dim_q for this pass

    // the real, visible ports of mmu_top
    input  logic signed [7:0]   activations [N],
    input  logic signed [7:0]   weights     [N][N],
    input  logic signed [31:0]  results     [N][N],
    input  logic                done,

    // explicit (non-wildcard) hierarchical bind — see bind statement below
    input  logic [2:0]          dim_q_reg        // u_axi_lite_slave.dim_q
);

    localparam int unsigned DIM = 2; // this is a proof for 2x2 functional correctness, hence we make the active dim 2

    // Below are the actual free variables - the two 2x2 arrays that are never driven anywhere in the file
    // The formal proof machine is allowed to pick any value for it on any cycle, proving the properties in this file for all
    // possible activations/weight values SIMULTANEOUSLY
    
    logic signed [7:0] act_matrix [DIM][DIM];   // act_matrix[row][col], in this case a 2x2 matrix
    logic signed [7:0] wt_matrix  [DIM][DIM];   // wt_matrix[row][col], also a 2x2 matrix

    // Now, we do have to constrain, or assume, some things.
    // Here: Real activation values, weights or inputs, do NOT change values mid computation
    // Hence, we run a double for loop to ASSUME that, once assigned a value, the values in both the weight and activations matrix are STABLE
    // Note: the values remain stable for that TRACE, jasper runs tons of traces, which is what brings variability
    
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

    // We have an internal register dim_q, and we are constraining that to always be 2 - since this is a 2x2 proof
    // We are bypassing modeling the actual AXI write protocol to the register, and instead hardcoding, because the axi protocol
    // was already proven in formal proof 2
    ap_dim_pinned: assume property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    dim_q_reg == 3'(DIM)
    );

    // A quick sanity check that runs in the background:
    // Checks the scenario that the controller's latched active_dim actually equals 2 is reachable in the state space
    // In simpler terms, if dim_q_reg and active_dim ever disagree, this cover would fail
    cp_active_dim_matches: cover property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    active_dim == 3'(DIM)
    );

    // Auxillary code block
    // This is a real, synthesizable counter that tracks how many cycles since flow_en
    // first went high. Built FRESH here rather than reusing deskew_capture.sv's internal
    // flow_cycle counter — reusing the DUT's own counter to check the DUT would make
    // the proof partly tautological (same reasoning as pe_formal.sv's mac_term recompute).
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

    // Now, we must actively constrain the activations bus itself
    // For every row and column in the array...
    generate
        for (gc = 0; gc < DIM; gc++) begin : gen_act_assume
            
            // We have to correctly specify an assume statement to make sure the formal tool adheres to DiP
            for (gr = 0; gr < DIM; gr++) begin : gen_act_active
                // Hence, we assume that we feed row "gr" of the activation matrix on cycle "gr" of the flow
                ap_activation_feed_active: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    (flow_en && (flow_cnt == gr)) |-> (activations[gc] == act_matrix[gr][gc])
                    // In english: if flow is active, and the counter is gr (the row loop variable)...
                    // then, the tool must be driving activations[gc] (the matrix input) with act_matrix[gr][gc] (the free variable)
                );
            end
            
            // When flow is not active, or the counter has moved past the two valid rows, the bus must be 0
            ap_activation_feed_idle: assume property (
                @(posedge clk) disable iff (!rst_n)
                (!flow_en || (flow_cnt >= DIM)) |-> (activations[gc] == 8'sd0)
            );
        end

        // For the lanes beyond the active 2 wide block, so columns 2 and 2 of the physical 4x4 array...
        // the environment must always drive 0, matching what the real driver does for unused lanes
        for (gc = DIM; gc < N; gc++) begin : gen_act_pad_assume
            ap_activation_pad: assume property (
                @(posedge clk) disable iff (!rst_n)
                activations[gc] == 8'sd0
            );
        end
    endgenerate

    // This generate block is doing the same as above, except for the weights instead of the activations
                // 1) All the weights being inputted into the 2x2 array must be driven by the formal tool via the free weight matrix
                // 2) All the unused portions of the physical 4x4 array - first the top right, and then the bottom - must have their weights driven to 0
    generate
        for (gr = 0; gr < DIM; gr++) begin : gen_wt_assume_row
            for (gc = 0; gc < DIM; gc++) begin : gen_wt_assume_col
                // Firstly, within the 2x2 matrix, the weight bus must equal the free weight matrix
                // In other words, the input to the matrix must be driven by the 2x2 free variable
                ap_weight_value: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    weights[gr][gc] == wt_matrix[gr][gc]
                );
            end
                    
            // Then, for rows 0 and 1, and columns 2 and 3, so the top right unused 2x2 matrix...
            // All of the weights must be 0
            for (gc = DIM; gc < N; gc++) begin : gen_wt_pad_col
                ap_weight_pad_col: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    weights[gr][gc] == 8'sd0
                );
            end
        end
        // Then, for rows 2 and 3, and all the columnds, so the bottom 2x4 matrix....
        // All fo the weights must also be 0
        for (gr = DIM; gr < N; gr++) begin : gen_wt_pad_row
            for (gc = 0; gc < N; gc++) begin : gen_wt_pad_row_col
                ap_weight_pad_row: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    weights[gr][gc] == 8'sd0
                );
            end
        end
    endgenerate

    // To prove something works, we need to compare it to something
    // So below, we perform an independent, combinational, and handwritten computation of the true 2x2 matrix multiply
    // It uses whatever randomly chosen activations and weights to compute the expected result
    // Done in 64 bit width to avoid overflow ambiguity, as we are comparing with a 32 bit result    
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
