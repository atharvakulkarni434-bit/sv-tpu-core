// =============================================================================
// perf_checker_smoke_tb.sv — smoke test for mmu_perf_checker.sv
//
// PURPOSE: satisfy Key Rule 6 — "an assertion that never fires was never
// exercised." Compiling the checker proves nothing about whether it CATCHES a
// timing bug. This TB drives fake start/done/dim_n directly at the checker and
// proves both directions:
//     - a legal 2N computation does NOT fire the assertions
//     - a deliberately wrong latency DOES fire them
//
// No RTL and no UVM required — mmu_perf_checker is a plain SV module, so it is
// instantiated directly here rather than bound into mmu_top (which does not
// exist until RTL Week 3). Same checker, same assertions, fake stimulus.
//
// This front-loads the Phase 3 task "Verify mmu_perf_checker.sv fires correctly
// on a deliberately injected cycle-count violation."
//
// SELF-CHECKING METHOD: the checker already counts assertion failures in
// n_latency_fail (incremented in the assertion action blocks). This TB reads
// that counter hierarchically (dut.n_latency_fail) before and after each
// scenario and checks the DELTA. An expected-fire scenario must increase it;
// a clean scenario must not.
//
// EXPECTED OUTPUT: you WILL see [PERF] LATENCY VIOLATION and [PERF] WATCHDOG
// $error lines in the log. Those are the DELIBERATE injections in T2/T3/T4 —
// they are the checker working. Read this TB's own PASS/FAIL summary at the
// bottom, not the raw error count. (Same convention as
// mmu_scoreboard_smoke_tb.sv, where S5/S6 are supposed to fail.)
//
// RUN:
//   xrun -sv perf/mmu_perf_checker.sv tb/perf_checker_smoke_tb.sv
// =============================================================================

`timescale 1ns/1ps

module perf_checker_smoke_tb;

    localparam int N = 4;                      // must match the checker's param

    logic       clk;                            // we generate this
    logic       rst_n;                          // active-low, we drive it
    logic       start;                          // fake CTRL_REG start tap
    logic       done;                           // fake STATUS_REG done tap
    logic [2:0] dim_n;                          // fake DIM_REG active-N tap

    int pass_count = 0;                         // this TB's own checks passed
    int fail_count = 0;                         // this TB's own checks failed

    int unsigned fails_before;                  // dut.n_latency_fail snapshot
    int unsigned fails_after;                   // dut.n_latency_fail snapshot

    // Instantiate the checker directly. Port names match our locals, so .*
    // connects clk/rst_n/start/done/dim_n automatically.
    mmu_perf_checker #(.N(N)) dut (.*);

    initial clk = 0;                            // clock starts low at time 0
    always #5 clk = ~clk;                       // flip every 5ns => 10ns period => 100MHz

    // ---- helper: record one of THIS TB's pass/fail checks ----
    task automatic check(string name, bit cond);
        if (cond) begin
            pass_count++;
            $display("  PASS  %-56s", name);
        end else begin
            fail_count++;
            $display("  FAIL  %-56s", name);
        end
    endtask

    // ---- helper: full reset pulse, clears the checker's state + counters ----
    task automatic do_reset();
        rst_n = 1'b0;                           // assert reset (active-low)
        start = 1'b0; done = 1'b0; dim_n = 3'd0;
        repeat (3) @(posedge clk); #1;          // hold it a few cycles
        rst_n = 1'b1;                           // release
        @(posedge clk); #1;                     // let the checker settle
    endtask

    // ---- helper: drive one computation with a CHOSEN latency ----
    //
    // Cycle math (traced against mmu_perf_checker's always_ff):
    //   the edge where `start` is sampled high is the arming edge; the checker
    //   captures start_cyc = free_cyc there. `done` sampled high L edges later
    //   yields observed_latency == L. So passing latency=2*n is the legal case,
    //   and anything else is an injected violation.
    task automatic run_op(input int unsigned n, input int unsigned latency);
        dim_n = n[2:0];                         // present the active dimension
        start = 1'b1;                           // raise start...
        @(posedge clk); #1;                     // ...this edge ARMS the checker
        start = 1'b0;                           // one-cycle pulse only

        repeat (latency - 1) @(posedge clk);    // burn L-1 more edges
        #1;
        done = 1'b1;                            // raise done...
        @(posedge clk); #1;                     // ...this edge is arming+L
        done = 1'b0;                            // drop it again
    endtask

    // ---- helper: start an op whose done NEVER arrives (watchdog case) ----
    task automatic run_op_no_done(input int unsigned n, input int unsigned wait_cycles);
        dim_n = n[2:0];
        start = 1'b1;
        @(posedge clk); #1;                     // arming edge
        start = 1'b0;
        done  = 1'b0;                           // done stays low forever
        repeat (wait_cycles) @(posedge clk);    // let the checker time out
        #1;
    endtask

    initial begin

        $dumpfile("perf_checker_smoke.vcd");    // waveform for debug
        $dumpvars(0, perf_checker_smoke_tb);

        do_reset();                             // start from a known state

        // ------------------------------------------------------------------
        // T1: LEGAL 2N latency for every dimension must NOT fire anything.
        //     N=1 -> 2 cyc, N=2 -> 4, N=3 -> 6, N=4 -> 8 (spec 2B table).
        // ------------------------------------------------------------------
        $display("\n---- T1: legal 2N latency, N=1..4 (expect NO fires) ----");
        for (int n = 1; n <= 4; n++) begin
            fails_before = dut.n_latency_fail;
            run_op(n, 2*n);                     // exactly the contract
            @(posedge clk); #1;                 // let the counter settle
            fails_after = dut.n_latency_fail;
            check($sformatf("T1 N=%0d legal 2N=%0d -> no assertion fire", n, 2*n),
                  fails_after == fails_before);
        end

        // ------------------------------------------------------------------
        // T2: done ONE CYCLE LATE at N=4 (9 cycles instead of 8).
        //     This is the exact off-by-one the plan calls out as the most
        //     likely integration bug. a_latency_exact must catch it.
        // ------------------------------------------------------------------
        $display("\n---- T2: injected LATE done, N=4 (expect a FIRE) ----");
        fails_before = dut.n_latency_fail;
        run_op(4, 9);                           // 9 != 2N=8 -> violation
        @(posedge clk); #1;
        fails_after = dut.n_latency_fail;
        check("T2 N=4 done 1 cycle LATE -> checker fired",
              fails_after > fails_before);

        // ------------------------------------------------------------------
        // T3: done ONE CYCLE EARLY at N=4 (7 cycles — the OLD 2N-1 number).
        //     This is exactly what would happen if someone reverted the
        //     pipeline contract to 2N-1 (Rule 15). Must be caught.
        // ------------------------------------------------------------------
        $display("\n---- T3: injected EARLY done, N=4 (expect a FIRE) ----");
        fails_before = dut.n_latency_fail;
        run_op(4, 7);                           // 7 == old 2N-1 -> violation
        @(posedge clk); #1;
        fails_after = dut.n_latency_fail;
        check("T3 N=4 done 1 cycle EARLY (old 2N-1) -> checker fired",
              fails_after > fails_before);

        // ------------------------------------------------------------------
        // T4: done NEVER arrives — a hung DUT.
        //     a_no_missing_done fires past the deadline; a_watchdog fires past
        //     LATENCY_WATCHDOG. See NOTE 1 at the bottom of this file: these
        //     fire EVERY cycle while done is missing, so expect many lines.
        // ------------------------------------------------------------------
        $display("\n---- T4: done NEVER arrives, N=4 (expect FIRES + watchdog) ----");
        fails_before = dut.n_latency_fail;
        run_op_no_done(4, 25);                  // > LATENCY_WATCHDOG (4*4+4=20)
        fails_after = dut.n_latency_fail;
        check("T4 N=4 missing done -> checker fired",
              fails_after > fails_before);
        do_reset();                             // clear the stuck in_flight

        // ------------------------------------------------------------------
        // T5: BACK-TO-BACK throughput — 10 legal N=4 ops in a row.
        //     Proves the checker re-arms cleanly op after op and does not leak
        //     state between computations, and exercises the [PERF] throughput
        //     II / idle_gap prints that feed perf_report.md.
        // ------------------------------------------------------------------
        $display("\n---- T5: 10 back-to-back legal N=4 ops (expect NO fires) ----");
        fails_before = dut.n_latency_fail;
        for (int i = 0; i < 10; i++)
            run_op(4, 8);                       // all legal
        @(posedge clk); #1;
        fails_after = dut.n_latency_fail;
        check("T5 10 back-to-back legal ops -> no assertion fire",
              fails_after == fails_before);
        check("T5 checker counted all 10 ops",
              dut.n_ops_completed >= 10);

        // ------------------------------------------------------------------
        // T6: ILLEGAL dimensions must NOT arm the timing window.
        //     DIM_REG=0 and DIM_REG=5 are negative-test values (TC-024/TC-026).
        //     The DUT is expected to reject them; the perf checker must stay
        //     silent rather than fire a bogus latency violation.
        // ------------------------------------------------------------------
        $display("\n---- T6: illegal dim 0 and 5 (expect NO fires, no arming) ----");
        fails_before = dut.n_latency_fail;
        run_op(0, 8);                           // dim 0 -> must not arm
        run_op(5, 8);                           // dim 5 -> must not arm
        @(posedge clk); #1;
        fails_after = dut.n_latency_fail;
        check("T6 illegal dim 0/5 -> checker did not arm or fire",
              fails_after == fails_before);

        // ---- summary ----
        $display("\n==== perf_checker smoke test: %0d passed, %0d failed ====",
                 pass_count, fail_count);
        if (fail_count == 0)
            $display("SMOKE TEST: ALL PASS  (the [PERF] errors above are the DELIBERATE T2/T3/T4 injections)");
        else
            $display("SMOKE TEST: FAILURES PRESENT");
        $finish;
    end

endmodule

// =============================================================================
// REVIEW NOTES — findings from writing this TB (for BUGS.md / team discussion)
//
// NOTE 1 — repeated fires on a missing done. [FIXED 2026-07-14]
//   Originally a_no_missing_done used "> exp_cyc" and a_watchdog used ">=", so
//   both re-evaluated every cycle and a single hung DUT produced one $error PER
//   CYCLE — T4 emitted 17 a_no_missing_done lines and 6 watchdog lines for ONE
//   injected hang. Both antecedents are now "==" (deadline+1, and the watchdog
//   bound exactly), so each reports once per computation. T4 should now show
//   exactly one of each.
//
// NOTE 1b — off-by-one in the assertion ERROR MESSAGES. [FIXED 2026-07-14]
//   The $error action blocks read free_cyc directly. Action blocks execute in
//   the Reactive region, AFTER the always_ff advanced free_cyc, so every message
//   reported latency+1 — T3 printed "observed=8 expected=8" on a FAILING
//   assertion. The assertions themselves were always correct (they evaluate on
//   Preponed samples); only the printed numbers lied. Fixed by wrapping the
//   action-block reads in $sampled().
//
// NOTE 2 — a_watchdog has no counter.
//   a_latency_exact and a_no_missing_done both increment n_latency_fail, but
//   a_watchdog only $errors. That means this TB cannot self-check the watchdog
//   via the counter — T4 detects a_no_missing_done and you confirm the
//   [PERF] WATCHDOG line by eye. Adding n_latency_fail++ to the watchdog's
//   action block would close that, at the cost of conflating "hung" with
//   "wrong latency" in the summary. Jad's call.
//
// NOTE 3 — this TB proves the CHECKER, not the DUT.
//   The stimulus here is fake by design. It proves the assertion logic reacts
//   correctly to good and bad timing. It says nothing about whether the real
//   mmu_controller hits 2N — that is the Phase 3 integration run, and it still
//   depends on reconciling the start->done window (see the OPEN ITEM header in
//   mmu_perf_checker.sv and Section 2D).
// =============================================================================