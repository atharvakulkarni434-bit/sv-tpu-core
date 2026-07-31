//==============================================================================
// File: mmu_controller_sva.sv  (Corrected version)
// Project: sv-tpu-core
// Bound to: mmu_controller.sv
//
// Properties: B1 (no_skip_weight_load), B2 (pe_clear_one_cycle),
//             B3 (result_latency), B4 (no_spurious_done)
//
// RESET STRATEGY (read before touching any property below):
//   Every property here uses `disable iff (!rst_n)`. This is the same class
//   of bug as the pe.sv formal CEX Atharva already chased down: a state
//   machine's `state` register is not meaningfully defined until at least
//   one cycle after rst_n deasserts.
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
    input logic [2:0] dim_n,       // [FIX]: Added to evaluate dimension legality
    input logic       pe_clear,
    input logic       done,
    input logic       flow_en,     // mmu_controller.sv: flow_en
    input logic [2:0] active_dim   // mmu_controller.sv: active_dim
);

    // Mirrors mmu_controller.sv's state_t encoding exactly.
    localparam logic [2:0] IDLE        = 3'b000;
    localparam logic [2:0] WEIGHT_LOAD = 3'b001;

    //--------------------------------------------------------------------
    // B1 — no_skip_weight_load
    //
    // The FSM must enter WEIGHT_LOAD as the first state after START from
    // IDLE, *provided the requested dimension is legal*.
    // [FIX]: Factored in the RTL's dim_legal check to prevent false
    // failures during negative testing (e.g., dim_n = 0 or > N).
    //--------------------------------------------------------------------
    property p_no_skip_weight_load;
        @(posedge clk) disable iff (!rst_n)
        (state == IDLE) && start && (dim_n >= 3'd1) && (dim_n <= 3'(N)) |=> (state == WEIGHT_LOAD);
    endproperty

    a_no_skip_weight_load: assert property (p_no_skip_weight_load)
        else $error("B1 no_skip_weight_load VIOLATED: state left IDLE on legal start but did not enter WEIGHT_LOAD (state=%0d) at time %0t",
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
    // LATENCY CONTRACT (ratified): active_dim + 5 cycles, measured from the
    // first ACTIVATION_FLOW cycle (flow_en high) to done. This replaces the
    // earlier active_dim + N + 1 formula and the even earlier 2N
    // (verification-plan) formula, both superseded once the team measured
    // the as-built DiP RTL for N=1..4 and confirmed dim + 5 is what the
    // silicon actually does. See README.md "Latency Contract" section and
    // BUGS.md Bug 7 for the history/decision record.
    //
    // TRIGGER FIX (2026-07-30): this property used to also trigger on
    // $rose(start), on the theory that a back-to-back transaction where
    // start stays held might not re-assert flow_en's rose edge cleanly.
    // That was wrong and caused a real (previously-undetected) false
    // failure: start rises 6 cycles before flow_en (AXI + WEIGHT_LOAD +
    // PE_CLEAR overhead - confirmed by mmu_perf_checker's own
    // "control overhead: start->flow_en = 6 cyc" log line), so the
    // start-triggered thread and the flow_en-triggered thread raced with
    // different deadlines every transaction, and the start-triggered one
    // was always going to fail — it expected done 6 cycles before the RTL
    // could possibly produce it. flow_en is what the RTL's own cnt/flow_last
    // counter measures from (mmu_controller.sv) and what mmu_perf_checker.sv
    // independently confirms is the correct anchor, so this property now
    // triggers on flow_en only, matching both.
    //--------------------------------------------------------------------
    property p_result_latency;
        int cnt;
        @(posedge clk) disable iff (!rst_n)
        // OFF-BY-ONE FIX (2026-07-30): this used |=>, which inserts one cycle
        // BEFORE the countdown starts, so with cnt seeded at active_dim+5 and a
        // trailing ##1 the property demanded done at flow_en+(active_dim+6). The
        // RTL (mmu_controller.sv: flow_last = dim+N, DONE one cycle later) and
        // mmu_perf_checker both land done at flow_en+(active_dim+5) - the perf
        // checker even logs observed==expected==9 on the same pass this used to
        // fire. Anchor the countdown ON the first flow_en cycle instead (|->,
        // overlap): tick that cycle as the first decrement, and done rises the
        // cycle after cnt hits 0 -> exactly flow_en+(active_dim+5). Keeps the
        // '+5' matching the ratified contract (BUGS.md Bug 7 / README).
        ( $rose(flow_en), cnt = active_dim + 6'd5 ) |->
            // first_match forces a single-thread evaluation: stop the loop the
            // exact cycle cnt hits 0.
            first_match( (!done, cnt = cnt - 1) [*1:$] ##0 (cnt == 0) )
            // done MUST rise on the very next cycle.
            ##1 $rose(done);
    endproperty

    a_result_latency: assert property (p_result_latency)
        else $error("B3 result_latency VIOLATED: done did not assert at active_dim+5 (active_dim=%0d) at time %0t",
                     active_dim, $time);

    //--------------------------------------------------------------------
    // B4 — no_spurious_done
    //
    // done must never assert while state == IDLE.
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


// ==============================================================================
// NOTE ON BINDING — tb_top.sv owns the bind statements.
//
// WARNING 1: Parameter Injection
// When uncommenting the bind statement in tb_top.sv, you MUST pass the parameter
// overrides explicitly. If omitted, the checker defaults to N=4 and will break
// if the DUT is instantiated at a different size.
//
// WARNING 2: Port Updates
// The SVA port list was updated to include `dim_n` for B1 legality checks.
// Your wildcard bind (.*) will connect this automatically AS LONG AS the
// signal names in the tb_top scope perfectly match.
//
// The bind block in tb_top.sv MUST look exactly like this:
//
//     bind mmu_controller mmu_controller_sva #(.N(N))
//         mmu_ctrl_sva_i (.*);
//
// Do NOT omit the parameter: bind mmu_controller mmu_controller_sva mmu_ctrl_sva_i (.*);
// ==============================================================================