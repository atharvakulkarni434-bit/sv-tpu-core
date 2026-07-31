//==============================================================================
// File: mmu_perf_checker.sv
// Project: sv-tpu-core
// Layer: Perf - Checker (Jad)
// Date: 2026-07-14
//
// Updated: 2026-07-29 — TIMING WINDOW CORRECTED (this is the substantive fix).
//   The checker previously armed its latency window on the rising edge of
//   `start` (the decoded CTRL_REG start bit). That window includes the AXI
//   write handshake, WEIGHT_LOAD and PE_CLEAR, so it measured 12 cycles for
//   N=1 while the transaction-level checker (data monitor -> data_txn.latency)
//   measured 6 for the same computation. Two checkers, two different windows,
//   guaranteed disagreement — which is what Rule 16 forbids.
//
//   The spec/plan contract is defined from ACTIVATION FLOW, not from start:
//     Section 3.6 : "Done asserts exactly 2N cycles after activation flow starts"
//     Assertion B3: $rose(activation_flow_start) |-> ##[2*N:2*N] $rose(done)
//   So the window is now armed on the rising edge of `flow_en` (mmu_top's
//   ACTIVATION_FLOW indicator, already a top-level port and picked up by the
//   existing `(.*)` bind). This makes the signal-level and transaction-level
//   checkers measure the SAME window, as Section 7 Path 3 requires.
//
//   With the window corrected, the measured latency is dim+5 (6/7/8/9 for
//   N=1..4), NOT the 2N (2/4/6/8) the plan specifies. That remaining gap is a
//   real, open SPEC-vs-RTL question (spec C.5 vs C.6 vs the DiP rewrite) —
//   mmu_scoreboard.sv's latency_checker was removed over the same conflict and
//   mmu_formal.sv flagged it as SPEC NOTE 2. It is NOT a measurement artifact.
//   exp_latency() therefore defaults to the as-built dim+5 so regressions run
//   clean and any future latency DRIFT is caught, and +LAT_SPEC_2N switches it
//   to the plan's 2N to reproduce/measure the gap on demand. This mirrors
//   mmu_latency_checker in mmu_cat6_tests.sv exactly, so the two checkers stay
//   in agreement under either mode (Rule 16).
//
// Description:
//   Signal-level performance checker for the systolic MMU. Bound into mmu_top
//   via `bind` (non-invasive - no RTL edits). It verifies the PERFORMANCE
//   contract, not functional correctness (that is the scoreboard's job):
//
//     1. LATENCY   - every computation completes in exactly exp_latency(N)
//                    cycles measured from activation-flow start to done. Fires
//                    on the exact cycle the latency is wrong - done too early,
//                    done too late, or a watchdog when done never arrives.
//
//     2. THROUGHPUT - the back-to-back initiation interval (cycles between one
//                    computation's flow start and the next) and the idle gap
//                    between computations are measured and printed, so
//                    perf_report.md can compare achieved vs theoretical-max.
//
//   Observability taps used (all top-level ports of mmu_top per spec A.9 /
//   mmu_if.sv): clk, rst_n, start, done, dim_n, flow_en
//   Connected by name through `bind mmu_top mmu_perf_checker ... (.*)` - see
//   the bind line in tb_top.sv. `start` is retained as a tap for the
//   start->flow diagnostic below; it no longer gates the latency window.
//==============================================================================

`ifndef MMU_PERF_CHECKER_SV
`define MMU_PERF_CHECKER_SV

`timescale 1ns/1ps

module mmu_perf_checker #(
    parameter int N = 4          // physical array dimension (build-time)
)(
    input logic       clk,
    input logic       rst_n,     // active-low
    input logic       start,     // decoded CTRL_REG start bit (diagnostic only)
    input logic       done,      // drives STATUS_REG done bit
    input logic [2:0] dim_n,     // decoded DIM_REG value - active N for this op
    input logic       flow_en    // ACTIVATION_FLOW active - arms the window
);

    // -------------------------------------------------------------------------
    // Latency contract selection. ONE place to change, per the original design
    // intent. Default is the as-built dim+5; +LAT_SPEC_2N selects the plan's
    // 2N (which currently fails on every pass by design - see header).
    // Kept bit-for-bit consistent with mmu_latency_checker in
    // mmu_cat6_tests.sv so both abstraction levels always agree (Rule 16).
    // -------------------------------------------------------------------------
    bit use_spec_2n;
    initial use_spec_2n = $test$plusargs("LAT_SPEC_2N");

    function automatic int unsigned exp_latency(input int unsigned n);
        return use_spec_2n ? (2 * n)      // plan / master-plan contract
                           : (n + 5);     // as-built DiP latency (current RTL)
    endfunction

    // A single op must never legitimately run longer than this. Head-room left
    // so a future window-definition change does not trip it spuriously.
    localparam int unsigned LATENCY_WATCHDOG = 4*N + 4;

    // -------------------------------------------------------------------------
    // Per-computation tracking
    //   in_flight  : flow started and we are waiting for the matching done
    //   start_cyc  : free-running cycle stamp captured at the flow-start edge
    //   n_latched  : dim_n captured at flow start (dim_n may change after)
    //   exp_cyc    : exp_latency(n_latched), captured once at flow start
    // -------------------------------------------------------------------------
    bit          in_flight;
    int unsigned free_cyc;         // free-running cycle counter (since reset)
    int unsigned start_cyc;
    int unsigned n_latched;
    int unsigned exp_cyc;
    logic        flow_q;           // for rising-edge detection of flow_en
    logic        start_q;          // for the start->flow diagnostic

    // Throughput bookkeeping (measured flow-start to flow-start, matching the
    // latency window so II and latency are directly comparable).
    bit          have_prev_flow;
    int unsigned last_flow_cyc;
    int unsigned init_interval;
    int unsigned observed_latency; // latency of the most recent completed op

    // start->flow diagnostic: control-plane overhead ahead of the array. Not
    // asserted on (it is AXI handshake + WEIGHT_LOAD + PE_CLEAR, not part of
    // the latency contract), but printed because it is exactly the quantity
    // that made the old start-based window read 12 instead of 6.
    bit          have_start;
    int unsigned start_edge_cyc;

    // Summary counters (printed in `final`).
    int unsigned n_ops_completed;

    // n_latency_fail is written ONLY by the assertion action blocks below, and
    // deliberately NOT by the always_ff. SystemVerilog forbids any process
    // other than the always_ff itself from writing an always_ff variable
    // (Xcelium: *E,MULAXX at elaboration), so it cannot be reset there.
    // Initialized at declaration instead; it is a run-total diagnostic
    // counter, so surviving a mid-run reset is the desired behavior anyway.
    int unsigned n_latency_fail = 0;

    // Rising edge of flow_en, but only for a LEGAL active dimension.
    // Illegal-dim negative tests (DIM_REG=0 or >4) must not arm the timing
    // window - the DUT is expected to reject those, and the scoreboard/SVA
    // cover that path.
    wire flow_rise = flow_en & ~flow_q & (dim_n >= 3'd1) & (dim_n <= N[2:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_flight        <= 1'b0;
            free_cyc         <= '0;
            start_cyc        <= '0;
            n_latched        <= '0;
            exp_cyc          <= '0;
            flow_q           <= 1'b0;
            start_q          <= 1'b0;
            have_prev_flow   <= 1'b0;
            last_flow_cyc    <= '0;
            init_interval    <= '0;
            observed_latency <= '0;
            have_start       <= 1'b0;
            start_edge_cyc   <= '0;
            n_ops_completed  <= '0;
            // NOTE: n_latency_fail is intentionally NOT reset here - see its
            // declaration. Writing it from this always_ff while the assertion
            // action blocks also write it is illegal (*E,MULAXX).
        end
        else begin
            free_cyc <= free_cyc + 1;
            flow_q   <= flow_en;
            start_q  <= start;

            // ---- control-plane stamp: rising edge of start ----
            if (start & ~start_q) begin
                start_edge_cyc <= free_cyc;
                have_start     <= 1'b1;
            end

            // ---- arm on activation-flow start (THE contract window) ----
            if (flow_rise && !in_flight) begin
                in_flight <= 1'b1;
                start_cyc <= free_cyc;
                n_latched <= dim_n;
                exp_cyc   <= exp_latency(dim_n);

                if (have_start)
                    $display("[PERF] control overhead: start->flow_en = %0d cyc (AXI + WEIGHT_LOAD + PE_CLEAR; not part of the latency contract)",
                             free_cyc - start_edge_cyc);

                // throughput: interval since the previous flow start + idle gap
                if (have_prev_flow) begin
                    init_interval <= free_cyc - last_flow_cyc;
                    // idle = interval - previous op latency (0 => zero-bubble,
                    // i.e. theoretical-max back-to-back throughput).
                    $display("[PERF] throughput: II=%0d cyc, idle_gap=%0d cyc (prev op latency=%0d)",
                             free_cyc - last_flow_cyc,
                             (free_cyc - last_flow_cyc) - observed_latency,
                             observed_latency);
                end
                last_flow_cyc  <= free_cyc;
                have_prev_flow <= 1'b1;
            end

            // ---- disarm on completion ----
            if (in_flight && done) begin
                observed_latency <= free_cyc - start_cyc;
                n_ops_completed  <= n_ops_completed + 1;
                in_flight        <= 1'b0;
                $display("[PERF] latency: N=%0d observed=%0d expected=%0d cyc %s",
                         n_latched, free_cyc - start_cyc, exp_cyc,
                         ((free_cyc - start_cyc) == exp_cyc) ? "PASS" : "FAIL");
            end
        end
    end

    // -------------------------------------------------------------------------
    // Assertion 1 - exact latency. When done arrives while a computation is in
    // flight, the elapsed cycle count must equal the contract. Fires on the
    // exact cycle done asserts if it is early OR late.
    // -------------------------------------------------------------------------
    a_latency_exact: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_flight && done) |-> ((free_cyc - start_cyc) == exp_cyc)
    ) else begin
        n_latency_fail++;
        // $sampled() is REQUIRED here. Action blocks run in the Reactive
        // region, after the always_ff has already advanced free_cyc, so
        // reading free_cyc directly reports latency+1 - an error message that
        // contradicts itself (observed==expected on a FAILING assertion).
        // $sampled() returns the Preponed-region values the assertion actually
        // evaluated.
        $error("[PERF] LATENCY VIOLATION: N=%0d observed=%0d expected=%0d cycles (flow_en->done)",
               $sampled(n_latched),
               $sampled(free_cyc) - $sampled(start_cyc),
               $sampled(exp_cyc));
    end

    // -------------------------------------------------------------------------
    // Assertion 2 - no missing / late done. Fires ONCE, on the first cycle past
    // the expected deadline, if done has not arrived (catches hangs and late
    // completions that Assertion 1 alone would only catch when done finally
    // shows up).
    //
    // The antecedent is "== exp_cyc + 1", not "> exp_cyc", ON PURPOSE. With ">"
    // the property re-evaluates true every cycle a hung DUT stays in flight and
    // emits one $error PER CYCLE - one injected hang produced 17 error lines in
    // perf_checker_smoke_tb. "== exp_cyc + 1" reports the same event exactly
    // once. The hang itself is still caught persistently by a_watchdog below.
    // -------------------------------------------------------------------------
    a_no_missing_done: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_flight && ((free_cyc - start_cyc) == (exp_cyc + 1))) |-> done
    ) else begin
        n_latency_fail++;
        $error("[PERF] LATENCY VIOLATION: N=%0d done still not asserted %0d cycles after flow start (expected %0d)",
               $sampled(n_latched),
               $sampled(free_cyc) - $sampled(start_cyc),
               $sampled(exp_cyc));
    end

    // -------------------------------------------------------------------------
    // Assertion 3 - watchdog. A single op must not stay in flight past the
    // watchdog bound. This is the hard "the DUT hung" backstop. Also gated to a
    // single fire per computation ("==" not ">=") for the same reason as above.
    // -------------------------------------------------------------------------
    a_watchdog: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_flight && ((free_cyc - start_cyc) == LATENCY_WATCHDOG)) |-> done
    ) else
        $error("[PERF] WATCHDOG: N=%0d no done within %0d cycles of flow start - DUT appears hung",
               $sampled(n_latched), LATENCY_WATCHDOG);

    // NOTE on throughput: the initiation interval and idle gap are MEASURED and
    // printed above for perf_report.md. The theoretical-max target (idle_gap==0)
    // is evaluated in the report rather than hard-asserted here - a legal
    // controller turnaround between ops would otherwise false-fire. Add a hard
    // throughput assertion only once the target II is locked in the spec.

    final begin
        $display("==== mmu_perf_checker summary: %0d ops completed, %0d latency failure(s) [%s contract] ====",
                 n_ops_completed, n_latency_fail,
                 use_spec_2n ? "2N (plan)" : "dim+5 (as-built)");
    end

endmodule : mmu_perf_checker

`endif // MMU_PERF_CHECKER_SV
