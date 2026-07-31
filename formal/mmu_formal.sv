// mmu_formal.sv — Proof 3: 2x2 Functional Correctness (Crown Jewel)
// Bound to: mmu_top.sv (with DIM_REG = 2) | Run via: twobytwo_correct.tcl (JasperGold only)
//
// DRAFT — team review requested before this is treated as sign-off quality.
// Two things below are new relative to Proof 1 / Proof 2 and worth a second
// pair of eyes:
//   1. This binds to mmu_top, not a leaf module, so the environment has to
//      drive/constrain the AXI+DiP protocol, not just a handful of ports.
//   2. Two open items are flagged inline (search "SPEC NOTE") rather than
//      silently resolved. Neither blocks this proof from running, but both
//      should land in the spec before v1.0 sign-off.
//
// ---------------------------------------------------------------------------
// SPEC NOTE 1 — combination count in Part D's Proof 3 prose.
// SpecDoc Part D says the proof covers "the four activation inputs and the
// four weight inputs — all 2^32 combinations". Four int8 activations + four
// int8 weights = 8 bytes = 64 bits of free input, i.e. 2^64 combinations, not
// 2^32. This doesn't change what the proof does (JasperGold explores the
// real state space regardless of what the prose says), but the spec text is
// wrong and should be corrected to 2^64 in the same PR as this file.
//
// SPEC NOTE 2 — RESOLVED 2026-07-30. DiP latency contract ratified as
// active_dim + 5 cycles (measured/confirmed for N=1..4); the earlier 2N
// contract referenced below is superseded and rejected. See README.md
// "Latency Contract" and BUGS.md Bug 7 for the decision record. This proof
// never took a position on cycle count in the first place — it only checks
// the VALUE of `results` on the cycle `done` asserts, never a cycle count —
// so it needed no logic change once the contract was resolved. C.5/C.6
// (Samarth / Jad's checkers, mmu_controller_sva.sv / mmu_perf_checker.sv)
// now assert active_dim + 5 directly.
//
// ---------------------------------------------------------------------------
// Formal assumptions (Part D bullet list), and how each is implemented here:
//
//   "DIM_REG is held at 2 for the duration of the proof"
//     -> pinned directly on axi_lite_slave's internal dim_q register
//        (u_axi_lite_slave.dim_q), bypassing the AXI write handshake
//        entirely. Simpler and tighter than modeling a legal AXI write of
//        value 2 every reachable cycle, and it is a legitimate subset of
//        "software always programs DIM_REG=2 before running" - the actual
//        AXI write protocol itself is already proven independently by
//        Proof 2, so re-deriving it here would just be duplicated work.
//
//   "All four activation inputs are free int8 variables (unconstrained
//    within [-128,127])" / "All four weight inputs are free int8 variables"
//     -> act_matrix[2][2], wt_matrix[2][2] below: plain `logic signed [7:0]`
//        arrays with NO driver anywhere in this file. An undriven signal is
//        a free variable to the formal engine - the standard JasperGold
//        technique for "for all possible values of X". Held constant over
//        time via $stable (see note by the assumes) since a real matrix
//        does not change value cycle-to-cycle.
//
//   "The computation begins from a known-clean state (accumulators zeroed
//    by pe_clear)"
//     -> not assumed separately; this is structurally guaranteed by
//        mmu_controller.sv's FSM (PE_CLEAR is unconditionally on the path
//        from WEIGHT_LOAD to ACTIVATION_FLOW - see A.5). cp_clear_before_flow
//        below covers that the engine actually explores this path rather
//        than trusting it silently.
//
//   "The property is checked at the cycle when done asserts (dim + 5 = 7
//    cycles after activation flow begins, for this proof's DIM_REG = 2)"
//     -> ap_2x2_functional_correctness fires on `done`, unconditionally.
//        Per SPEC NOTE 2 (resolved), this file takes no position on which
//        cycle count done lands on - it only checks that WHENEVER done
//        asserts, the result held at that moment is the correct dot product.
//
// ---------------------------------------------------------------------------
// activations bus semantics — DiP, not the old horizontal design (see
// systolic_array.sv's header, point 1, and the fix already applied to
// data_agent.sv): row 0 is the array's only external entry, and it is fed a
// FULL ROW of the activation matrix every active cycle, not one element per
// row per cycle. flow_cnt below is an INDEPENDENT recount of "cycles since
// flow_en first asserted", built fresh in this checker rather than reused
// from deskew_capture.sv's internal flow_cycle - same reasoning as
// pe_formal.sv's mac_term recomputation: reusing the DUT's own counter to
// check the DUT would make the proof partly tautological.
// ---------------------------------------------------------------------------
// BUGS.md lessons applied:
//   Bug 1 (blackboxing): -bbox_mul -1 is set in twobytwo_correct.tcl, same
//     as pe_overflow.tcl - this proof exercises real PE multiplies too.
//   Bug 2/3/4 ($past / disable_iff pitfalls): avoided by construction here.
//     The only cross-cycle needs (holding act_matrix/wt_matrix constant,
//     counting flow_cnt) are done with `$stable` and a synthesizable
//     always_ff counter instead of raw `$past` in a property, so none of
//     the past-needs-a-clocking-event / past-needs-to-be-evaluated-on-the-
//     right-cycle traps from Proof 1 apply. If a future revision adds a
//     genuine $past-based property here, re-read Bugs 2-4 first.

module mmu_formal_checker #(
    parameter int N = 4
)(
    input  logic                clk,
    input  logic                rst_n,

    // internal mmu_top signals, wildcard-bound by name (see bind statement)
    input  logic                flow_en,
    input  logic                pe_clear,
    input  logic                load_weight,
    input  logic [2:0]          active_dim,      // mmu_controller's latched dim_q for this pass

    // real mmu_top ports
    input  logic signed [7:0]   activations [N],
    input  logic signed [7:0]   weights     [N][N],
    input  logic signed [31:0]  results     [N][N],
    input  logic                done,

    // explicit (non-wildcard) hierarchical bind — see bind statement below
    input  logic [2:0]          dim_q_reg        // u_axi_lite_slave.dim_q
);

    localparam int unsigned DIM = 2;

    // -----------------------------------------------------------------
    // Free variables — the "for all possible int8 inputs" of Proof 3.
    // Deliberately undriven: no always_ff, no assign, anywhere in this
    // file touches act_matrix/wt_matrix. JasperGold treats an undriven
    // signal as a free variable the engine may choose any legal value
    // for, each cycle, subject only to the $stable assumes below.
    // -----------------------------------------------------------------
    logic signed [7:0] act_matrix [DIM][DIM];   // act_matrix[row][col]
    logic signed [7:0] wt_matrix  [DIM][DIM];   // wt_matrix[row][col]

    // Real matrices don't change value mid-run; constrain them stable for
    // the whole proof rather than just "during the pass" so the same fixed
    // matrix is what every subsequent pass (if the engine explores
    // back-to-back runs) is checked against too.
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

    // -----------------------------------------------------------------
    // Pin DIM_REG = 2 for the whole proof (Part D assumption bullet 1).
    // Bypasses the AXI write handshake entirely — Proof 2 already covers
    // that handshake's correctness independently.
    // -----------------------------------------------------------------
    ap_dim_pinned: assume property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    dim_q_reg == 3'(DIM)
    );

    // Sanity: the value we pinned actually propagates to the latched
    // per-pass dimension the controller uses. Not load-bearing for the
    // correctness property itself, but a cheap early warning if dim_q_reg
    // and active_dim ever disagree (e.g. mid-run DIM_REG write races).
    cp_active_dim_matches: cover property (
    @(posedge clk)
    disable iff (!rst_n || $past(!rst_n, 1, 1'b1, @(posedge clk)))
    active_dim == 3'(DIM)
    );

    // -----------------------------------------------------------------
    // Independent flow-cycle counter (see file header — deliberately not
    // reusing deskew_capture.sv's internal flow_cycle).
    // -----------------------------------------------------------------
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

    // -----------------------------------------------------------------
    // Constrain the activations bus to the DiP-correct stimulus pattern.
    // REFACTORED to use static indices instead of dynamic array indexing
    // to prevent formal uninitialized-state artifacts.
    // -----------------------------------------------------------------
    generate
        for (gc = 0; gc < DIM; gc++) begin : gen_act_assume
            
            // 1. When active and in bounds, matching row statically driven
            for (gr = 0; gr < DIM; gr++) begin : gen_act_active
                ap_activation_feed_active: assume property (
                    @(posedge clk) disable iff (!rst_n)
                    (flow_en && (flow_cnt == gr)) |-> (activations[gc] == act_matrix[gr][gc])
                );
            end
            
            // 2. When idle or draining, drive zeros
            ap_activation_feed_idle: assume property (
                @(posedge clk) disable iff (!rst_n)
                (!flow_en || (flow_cnt >= DIM)) |-> (activations[gc] == 8'sd0)
            );
        end
        
        for (gc = DIM; gc < N; gc++) begin : gen_act_pad_assume
            // Physical array is 4 wide; lanes at/above the active dim must
            // be driven to zero by the environment, same as data_agent.sv's
            // real driver does for c >= tr.dim.
            ap_activation_pad: assume property (
                @(posedge clk) disable iff (!rst_n)
                activations[gc] == 8'sd0
            );
        end
    endgenerate

    // -----------------------------------------------------------------
    // Constrain the weights bus to the free weight matrix for the active
    // 2x2 sub-block, and zero for the padding lanes — held for all time
    // (weight-stationary; a real driver only needs to present it during
    // WEIGHT_LOAD, but presenting it always is a legal subset of driver
    // behavior and keeps this assume $stable-simple).
    // -----------------------------------------------------------------
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

    // -----------------------------------------------------------------
    // Golden reference, computed independently in wide (64-bit) arithmetic
    // — same defensive width Proof 1 used (mac_term recomputed, not reused
    // from RTL) — then compared against the DUT's actual 32-bit results.
    // For DIM=2 with int8 inputs the true value never approaches 32 bits
    // (worst case 2*127*127 = 32,258), so no separate overflow guard is
    // needed here the way pe_formal.sv needed one for the running N=4
    // accumulator; this wide compare is just defensive width discipline.
    // -----------------------------------------------------------------
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
    ap_2x2_functional_correctness: assert property (
        @(posedge clk) disable iff (!rst_n)
        done |-> (
            (64'(results[0][0]) == expected[0][0]) &&
            (64'(results[0][1]) == expected[0][1]) &&
            (64'(results[1][0]) == expected[1][0]) &&
            (64'(results[1][1]) == expected[1][1])
        )
    );

    // -----------------------------------------------------------------
    // Bonus (beyond the literal Part D property statement, which only
    // talks about the active 2x2 block): the inactive lanes must drain
    // zero, not stale data from a wider pass — this is A.7's no-leakage
    // requirement, and output_buffer.sv's masking is what's supposed to
    // guarantee it. Cheap to check here since the environment is already
    // set up; flagged separately so it's clear this is extra coverage,
    // not literally what Part D's Proof 3 prose asked for.
    // -----------------------------------------------------------------
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

    // -----------------------------------------------------------------
    // Reachability sanity: confirm the environment actually lets the FSM
    // walk PE_CLEAR -> ACTIVATION_FLOW -> DONE at least once under these
    // constraints (Part D's "if a counterexample appears" guidance for
    // Proof 1 applies here too — an unreachable done makes the assert
    // above vacuously true, which is not a real proof of anything).
    // -----------------------------------------------------------------
    cp_pe_clear_then_flow_then_done: cover property (
        @(posedge clk) disable iff (!rst_n)
        pe_clear ##1 flow_en [->1] ##0 1 ##[1:$] done
    );

endmodule : mmu_formal_checker

bind mmu_top mmu_formal_checker mmu_formal_checker_i (
    .dim_q_reg (u_axi_lite_slave.dim_q),
    .*
);