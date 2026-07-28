//==============================================================================
// File: mmu_controller_sva.sv
// Project: sv-tpu-core
// Bound to: mmu_controller.sv
//
// Properties: B1 (no_skip_weight_load), B2 (pe_clear_one_cycle),
//             B3 (result_latency), B4 (no_spurious_done)
//
// RESET STRATEGY (read before touching any property below):
//   Every property here uses `disable_iff (!rst_n)`. This is the same class
//   of bug as the pe.sv formal CEX Atharva already chased down: a state
//   machine's `state` register is not meaningfully defined until at least
//   one cycle after rst_n deasserts, and evaluating any of these properties
//   while rst_n is low (or in the same delta-cycle it's still settling)
//   produces spurious antecedent matches that have nothing to do with real
//   controller behavior.
//
//   disable_iff (!rst_n) means: "this property is simply not checked on any
//   cycle where rst_n is low." It does NOT delay re-arming after rst_n goes
//   high - the property is live again the very next posedge clk after
//   rst_n == 1. That's fine for B1/B2/B4 below because none of them read
//   $past() of something that predates reset - they only look at the
//   CURRENT state/pe_clear/done relative to the CURRENT (or next) cycle.
//
//   B3 is the one exception worth its own note - see the comment directly
//   above that property.
//
//   Signal names below (state, pe_clear, done, start, flow_en, active_dim)
//   match mmu_controller.sv's actual port list / internal signals directly
//   (confirmed against the RTL, not just the test plan's looser naming -
//   the test plan calls flow_en "activation_flow_start", same signal). The
//   `bind` statement in tb_top.sv should connect these 1:1 by name.
//
//   LATENCY CONTRACT CORRECTION: the original test plan documents B3/D1 as
//   a flat "2N cycles" contract. That is stale - see the comment directly
//   above p_result_latency below for the corrected active_dim + N + 1
//   derivation, confirmed against mmu_controller.sv's actual terminal
//   count (flow_last = active_dim + N) plus one registered FSM transition
//   cycle. Per Atharva: the RTL is the source of truth here, not the plan.
//==============================================================================

`ifndef MMU_CONTROLLER_SVA_SV
`define MMU_CONTROLLER_SVA_SV

module mmu_controller_sva #(
    parameter int N = 4          // must match mmu_controller.sv's N param
) (
    input logic       clk,
    input logic       rst_n,
    input logic [2:0] state,       // mmu_controller.sv: state_t state
    input logic       start,
    input logic       pe_clear,
    input logic       done,
    input logic       flow_en,     // mmu_controller.sv: flow_en (== "activation_flow_start" in the test plan's looser naming)
    input logic [2:0] active_dim   // mmu_controller.sv: active_dim (latched dim_q for the in-flight pass)
);

    // Mirrors mmu_controller.sv's state_t encoding exactly (see
    // mmu_ral_and_negative_tests.sv's mmu_force_state_pkg for the same
    // values used on the testbench side).
    localparam logic [2:0] IDLE            = 3'b000;
    localparam logic [2:0] WEIGHT_LOAD     = 3'b001;

    //--------------------------------------------------------------------
    // B1 — no_skip_weight_load
    //
    // The FSM must always enter WEIGHT_LOAD as the first state after
    // START from IDLE. Targeted by TC-035a (force state = PE_CLEAR while
    // in IDLE with start asserted, bypassing WEIGHT_LOAD entirely).
    //--------------------------------------------------------------------
    property p_no_skip_weight_load;
        @(posedge clk) disable iff (!rst_n)
        (state == IDLE) && start |=> (state == WEIGHT_LOAD);
    endproperty
    a_no_skip_weight_load: assert property (p_no_skip_weight_load)
        else $error("B1 no_skip_weight_load VIOLATED: state left IDLE on start but did not enter WEIGHT_LOAD (state=%0d) at time %0t",
                     state, $time);

    //--------------------------------------------------------------------
    // B2 — pe_clear_one_cycle
    //
    // pe_clear must assert for exactly one cycle. Targeted by TC-035b
    // (force pe_clear to remain asserted for a second consecutive cycle).
    //--------------------------------------------------------------------
    property p_pe_clear_one_cycle;
        @(posedge clk) disable iff (!rst_n)
        $rose(pe_clear) |=> !pe_clear;
    endproperty
    a_pe_clear_one_cycle: assert property (p_pe_clear_one_cycle)
        else $error("B2 pe_clear_one_cycle VIOLATED: pe_clear still asserted one cycle after rising at time %0t",
                     $time);

    //--------------------------------------------------------------------
    // B3 — result_latency
    //
    // *** SPEC CORRECTION - READ BEFORE CHANGING ***
    // The original test plan (Section 5, B3) documents this as a flat
    // "2N cycles" contract. That is STALE. The RTL's actual terminal count
    // is flow_last = active_dim + N (see mmu_controller.sv's "Latency
    // Correction" comment - a +1 cycle was added to accommodate
    // deskew_capture.sv's physical drain/alignment requirement), and the
    // FSM->DONE transition itself costs one more registered cycle on top
    // of that. Walking it explicitly:
    //   - flow_en rises combinationally the same cycle state becomes
    //     ACTIVATION_FLOW; cnt resets to 0 that same cycle.
    //   - the FSM leaves ACTIVATION_FLOW (next_state = DONE) on the cycle
    //     where cnt == flow_last; that transition is registered, so
    //     state == DONE (and done asserts) one clock edge later.
    //   - total latency from $rose(flow_en) to $rose(done) is therefore
    //     active_dim + N + 1 cycles, NOT 2*active_dim.
    // Per Atharva (2026-07-28): "the RTL is always correct, the spec doc is
    // horribly outdated" - so this property (and D1 in mmu_perf_checker.sv,
    // and the TC-027..031 expected latencies in the test plan / scoreboard)
    // are written against the RTL's real contract, not the stale plan.
    // flow_en is this file's local name for what the negative-test file
    // and test plan call activation_flow_start - same signal.
    //
    // RESET NOTE: this property spans a multi-cycle window
    // (##[W:W]). Plain disable_iff(!rst_n) only blocks evaluation on
    // cycles where rst_n is currently low - it does NOT retroactively
    // cancel an in-flight, already-armed property instance if rst_n drops
    // partway through the window (e.g. TC-018/019/020's reset-stress
    // tests, which deliberately reset mid-computation). SVA semantics
    // actually handle this correctly on their own: disable_iff aborts any
    // in-flight attempt of the property the moment its condition goes true,
    // not just new attempts - so a reset asserted mid-window correctly
    // kills that in-flight attempt rather than letting it either falsely
    // pass or falsely CEX. This comment exists so nobody "fixes" this
    // later by trying to add extra bookkeeping that isn't needed.
    //--------------------------------------------------------------------
    property p_result_latency;
        @(posedge clk) disable iff (!rst_n)
        $rose(flow_en) |-> ##[(active_dim + N + 1):(active_dim + N + 1)] $rose(done);
    endproperty
    a_result_latency: assert property (p_result_latency)
        else $error("B3 result_latency VIOLATED: done did not rise exactly %0d cycles after flow_en rose (active_dim=%0d, N=%0d, window closed at time %0t)",
                     active_dim + N + 1, active_dim, N, $time);

    //--------------------------------------------------------------------
    // B4 — no_spurious_done
    //
    // done must never assert while state == IDLE. Highest trigger-count
    // assertion in the project (every IDLE cycle). Targeted by TC-035e
    // (force done = 1 while state == IDLE).
    //--------------------------------------------------------------------
    property p_no_spurious_done;
        @(posedge clk) disable iff (!rst_n)
        (state == IDLE) |-> !done;
    endproperty
    a_no_spurious_done: assert property (p_no_spurious_done)
        else $error("B4 no_spurious_done VIOLATED: done asserted while state == IDLE at time %0t",
                     $time);

endmodule : mmu_controller_sva

`endif // MMU_CONTROLLER_SVA_SV
