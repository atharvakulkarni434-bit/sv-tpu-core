//==============================================================================
// File: mmu_perf_checker.sv
// Project: sv-tpu-core
// Layer: Perf - Checker (Jad)
// Date: 2026-07-14
//
// Description:
//   Signal-level performance checker for the systolic MMU. Bound into mmu_top
//   via `bind` (non-invasive - no RTL edits). It verifies the PERFORMANCE
//   contract, not functional correctness (that is the scoreboard's job):
//
//     1. LATENCY   - every computation completes in exactly exp_latency(N)
//                    cycles. The locked contract is 2N (pipelined PE, spec C.6
//                    / Rule 15). The assertion fires on the exact cycle the
//                    latency is wrong - done too early, done too late, or a
//                    watchdog when done never arrives.
//
//     2. THROUGHPUT - the back-to-back initiation interval (cycles between one
//                    start and the next) and the idle gap between computations
//                    are measured and printed, so perf_report.md can compare
//                    achieved vs theoretical-maximum throughput.
//
//   Observability taps used (all present on mmu_top per spec A.9 / mmu_if.sv):
//       clk, rst_n, start, done, dim_n
//   Connected by name through `bind mmu_top mmu_perf_checker ... (.*)` - see
//   the bind line in tb_top.sv.
//
//   *** OPEN ITEM - reconcile with the mmu_controller hand-trace (PERF Week 2,
//   spec C.6) BEFORE integration. This checker times the window from the rising
//   edge of `start` to the rising edge of `done` and expects exp_latency(N)=2N,
//   exactly as Section 2D specifies for both this checker and Samarth's
//   scoreboard latency_checker. If the hand-trace shows the WEIGHT_LOAD /
//   PE_CLEAR cycles sit INSIDE that window (so start->done is more than 2N),
//   change exp_latency() below - the ONE place - and nothing else moves.
//   Per Rule 16 this number MUST match Samarth's scoreboard latency_checker. ***
//==============================================================================

`ifndef MMU_PERF_CHECKER_SV
`define MMU_PERF_CHECKER_SV

`timescale 1ns/1ps

module mmu_perf_checker #(
    parameter int N = 4          // physical array dimension (build-time)
)(
    input logic       clk,
    input logic       rst_n,     // active-low
    input logic       start,     // decoded CTRL_REG start bit
    input logic       done,      // drives STATUS_REG done bit
    input logic [2:0] dim_n      // decoded DIM_REG value - active N for this op
);

    // -------------------------------------------------------------------------
    // The single latency formula. 2N (pipelined) is the locked contract.
    // Kept identical in intent to ref_model.expected_latency(n) so the perf
    // checker, the scoreboard latency_checker and the golden model all agree
    // on one number (Rule 15 / Rule 16). Change HERE only - see header note.
    // -------------------------------------------------------------------------
    function automatic int unsigned exp_latency(input int unsigned n);
        return 2 * n;
    endfunction

    // A single op must never legitimately run longer than this. 2N is the
    // contract; anything past the watchdog is a genuine hang / missing-done,
    // not jitter. Head-room left so a future window-definition change (e.g.
    // folding weight-load in) does not trip it spuriously.
    localparam int unsigned LATENCY_WATCHDOG = 4*N + 4;

    // -------------------------------------------------------------------------
    // Per-computation tracking (procedural - unambiguous, easy to waveform).
    //   in_flight  : a start fired and we are waiting for the matching done
    //   start_cyc  : free-running cycle stamp captured at the start edge
    //   n_latched  : dim_n captured at start (dim_n may change afterwards)
    //   exp_cyc    : exp_latency(n_latched), captured once at start
    // -------------------------------------------------------------------------
    bit          in_flight;
    int unsigned free_cyc;       // free-running cycle counter (since reset)
    int unsigned start_cyc;
    int unsigned n_latched;
    int unsigned exp_cyc;
    logic        start_q;        // for rising-edge detection of start

    // Throughput bookkeeping.
    bit          have_prev_start;
    int unsigned last_start_cyc;
    int unsigned init_interval;  // cycles between the last two starts (II)
    int unsigned observed_latency; // latency of the most recent completed op

    // Summary counters (printed in `final`).
    int unsigned n_ops_completed;

    // n_latency_fail is written ONLY by the assertion action blocks below, and
    // deliberately NOT by the always_ff. SystemVerilog forbids any process other
    // than the always_ff itself from writing an always_ff variable (Xcelium:
    // *E,MULAXX at elaboration), so it cannot be reset there. Initialized at
    // declaration instead; it is a run-total diagnostic counter, so surviving a
    // mid-run reset is the desired behavior anyway.
    int unsigned n_latency_fail = 0;

    // Rising edge of start, but only for a LEGAL active dimension. Illegal-dim
    // negative tests (DIM_REG=0 or >4) must not arm the timing window - the DUT
    // is expected to reject those, and the scoreboard/SVA cover that path.
    wire start_rise = start & ~start_q & (dim_n >= 3'd1) & (dim_n <= N[2:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_flight        <= 1'b0;
            free_cyc         <= '0;
            start_cyc        <= '0;
            n_latched        <= '0;
            exp_cyc          <= '0;
            start_q          <= 1'b0;
            have_prev_start  <= 1'b0;
            last_start_cyc   <= '0;
            init_interval    <= '0;
            observed_latency <= '0;
            n_ops_completed  <= '0;
            // NOTE: n_latency_fail is intentionally NOT reset here - see its
            // declaration. Writing it from this always_ff while the assertion
            // action blocks also write it is illegal (*E,MULAXX).
        end
        else begin
            free_cyc <= free_cyc + 1;
            start_q  <= start;

            // ---- arm on the start of a computation ----
            if (start_rise && !in_flight) begin
                in_flight <= 1'b1;
                start_cyc <= free_cyc;
                n_latched <= dim_n;
                exp_cyc   <= exp_latency(dim_n);

                // throughput: interval since the previous start + idle gap
                if (have_prev_start) begin
                    init_interval <= free_cyc - last_start_cyc;
                    // idle = interval - previous op latency (0 => zero-bubble,
                    // i.e. theoretical-max back-to-back throughput).
                    $display("[PERF] throughput: II=%0d cyc, idle_gap=%0d cyc (prev op latency=%0d)",
                             free_cyc - last_start_cyc,
                             (free_cyc - last_start_cyc) - observed_latency,
                             observed_latency);
                end
                last_start_cyc  <= free_cyc;
                have_prev_start <= 1'b1;
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
        // $sampled() is REQUIRED here. Action blocks run in the Reactive region,
        // after the always_ff has already advanced free_cyc, so reading free_cyc
        // directly reports latency+1 - an error message that contradicts itself
        // (observed==expected on a FAILING assertion). $sampled() returns the
        // Preponed-region values the assertion actually evaluated.
        $error("[PERF] LATENCY VIOLATION: N=%0d observed=%0d expected=%0d cycles (start->done)",
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
        $error("[PERF] LATENCY VIOLATION: N=%0d done still not asserted %0d cycles after start (expected %0d)",
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
        $error("[PERF] WATCHDOG: N=%0d no done within %0d cycles of start - DUT appears hung",
               $sampled(n_latched), LATENCY_WATCHDOG);

    // NOTE on throughput: the initiation interval and idle gap are MEASURED and
    // printed above for perf_report.md. The theoretical-max target (idle_gap==0)
    // is evaluated in the report rather than hard-asserted here - a legal
    // controller turnaround between ops would otherwise false-fire. Add a hard
    // throughput assertion only once the target II is locked in the spec.

    final begin
        $display("==== mmu_perf_checker summary: %0d ops completed, %0d latency failure(s) ====",
                 n_ops_completed, n_latency_fail);
    end

endmodule : mmu_perf_checker

`endif // MMU_PERF_CHECKER_SV