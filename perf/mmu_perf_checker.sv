//==============================================================================
// File: mmu_perf_checker.sv
// Description: performance checker — bound onto mmu_top, checks timing only,
// not correctness. Watches latency (right cycle count?) and throughput
// (how fast back-to-back computations run).
// Latency — how long one computation takes, from flow_en starting to done firing: free_cyc - start_cyc.
//Throughput — how far apart two consecutive computations start: free_cyc - last_flow_cyc.
//Control overhead — how long between start and flow_en actually beginning: free_cyc - start_edge_cyc.
//==============================================================================

`ifndef MMU_PERF_CHECKER_SV
`define MMU_PERF_CHECKER_SV

`timescale 1ns/1ps

module mmu_perf_checker #(
    parameter int N = 4          // array size
)(
    input logic       clk,
    input logic       rst_n,
    input logic       start,     // CTRL_REG start bit — used for diagnostic timing only
    input logic       done,      // stops the stopwatch
    input logic [2:0] dim_n,     // decides which latency target to check
    input logic       flow_en    // starts the stopwatch
);

    bit use_spec_2n;
    initial use_spec_2n = $test$plusargs("LAT_SPEC_2N");   // lets you switch contracts without editing code

    // given the active size n, returns how many cycles a computation SHOULD take
    function automatic int unsigned exp_latency(input int unsigned n);
        // if the flag above is set, use the old 2N formula; otherwise use the real, current n+5 formula
        return use_spec_2n ? (2 * n) : (n + 5);
    endfunction

    // the absolute maximum any single operation should ever legitimately take, with extra buffer room built in
    localparam int unsigned LATENCY_WATCHDOG = 4*N + 4;

    bit          in_flight;        // currently timing a computation?
    int unsigned free_cyc;         // ticks every cycle since reset
    int unsigned start_cyc;        // free_cyc when this computation started
    int unsigned n_latched;        // dim_n frozen at op start
    int unsigned exp_cyc;          // expected duration, frozen at computation start
    logic        flow_q;           // previous cycle's flow_en
    logic        start_q;          // previous cycle's start

    bit          have_prev_flow;   // has any earlier computation happened yet, to compare against?
    int unsigned last_flow_cyc;    // when the PREVIOUS computation started
    int unsigned init_interval;    // gap between the previous start and this one — throughput measurement
    int unsigned observed_latency; // how long the MOST RECENT completed computation actually took

    bit          have_start;         // has start ever fired yet, so we have something to measure?
    int unsigned start_edge_cyc;     // when start first went high — diagnostic only

    int unsigned n_ops_completed;    // total computations completed, tallied for the final summary
    int unsigned n_latency_fail = 0; // total latency violations — separate from the always_ff below on purpose, since two different processes can't both write the same variable

    wire flow_rise = flow_en & ~flow_q & (dim_n >= 3'd1) & (dim_n <= N[2:0]);   // flow_en rising edge, only if dim is legal

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
        end
        else begin
            free_cyc <= free_cyc + 1;   // just keep counting, every cycle
            flow_q   <= flow_en;        // remember this cycle's flow_en, for edge detection next cycle
            start_q  <= start;          // remember this cycle's start, same reason

            // did start just go from low to high, right now?
            if (start & ~start_q) begin
                start_edge_cyc <= free_cyc;   // remember when it happened
                have_start     <= 1'b1;       // mark that we now have a valid time to compare against
            end

            // did the REAL timer's trigger (flow_en) just go high, and we're not already timing something?
            if (flow_rise && !in_flight) begin
                in_flight <= 1'b1;               // start timing
                start_cyc <= free_cyc;           // remember when this op started
                n_latched <= dim_n;              // freeze the matrix size for this op
                exp_cyc   <= exp_latency(dim_n); // freeze the expected duration for this op

                // if we captured a start edge earlier, print the gap between start and flow_en
                //Control overhead — how long between start and flow_en actually beginning
                if (have_start)
                    $display("[PERF] control overhead: start->flow_en = %0d cyc (AXI + WEIGHT_LOAD + PE_CLEAR; not part of the latency contract)",
                             free_cyc - start_edge_cyc);

                // if there was a PREVIOUS computation, print how far apart this one's start is from that one's
                // Throughput — how far apart two consecutive computations start
                if (have_prev_flow) begin
                    init_interval <= free_cyc - last_flow_cyc;
                    $display("[PERF] throughput: II=%0d cyc, idle_gap=%0d cyc (prev op latency=%0d)",
                             free_cyc - last_flow_cyc,
                             (free_cyc - last_flow_cyc) - observed_latency,
                             observed_latency);
                end
                last_flow_cyc  <= free_cyc;    // remember this moment, for the NEXT op to compare against
                have_prev_flow <= 1'b1;        // mark that we now have a valid previous-start to compare against
            end

            // did done fire, while we're currently timing something?
            // Latency-how long one computation takes, from flow_en starting to done firing: free_cyc - start_cyc.
            if (in_flight && done) begin
                observed_latency <= free_cyc - start_cyc;   // record how long it actually took
                n_ops_completed  <= n_ops_completed + 1;    // one more op completed
                in_flight        <= 1'b0;                   // stop timing
                $display("[PERF] latency: N=%0d observed=%0d expected=%0d cyc %s",
                         n_latched, free_cyc - start_cyc, exp_cyc,
                         ((free_cyc - start_cyc) == exp_cyc) ? "PASS" : "FAIL");   // print pass/fail for this op
            end
        end
    end

    // checks the op finished in exactly the right number of cycles
    a_latency_exact: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_flight && done) |-> ((free_cyc - start_cyc) == exp_cyc)
    ) else begin
        n_latency_fail++;
        // $sampled() reads the value the assertion actually saw, not the
        // already-updated value from this cycle — without it, this error
        // message would report a count that's off by one
        $error("[PERF] LATENCY VIOLATION: N=%0d observed=%0d expected=%0d cycles (flow_en->done)",
               $sampled(n_latched),
               $sampled(free_cyc) - $sampled(start_cyc),
               $sampled(exp_cyc));
    end

    // catches a missing done, fires exactly once
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

    // hard backstop — DUT genuinely hung
    a_watchdog: assert property (
        @(posedge clk) disable iff (!rst_n)
        (in_flight && ((free_cyc - start_cyc) == LATENCY_WATCHDOG)) |-> done
    ) else
        $error("[PERF] WATCHDOG: N=%0d no done within %0d cycles of flow start - DUT appears hung",
               $sampled(n_latched), LATENCY_WATCHDOG);

    // final summary, printed once at the end of the whole simulation
    final begin
        $display("==== mmu_perf_checker summary: %0d ops completed, %0d latency failure(s) [%s contract] ====",
                 n_ops_completed, n_latency_fail,
                 use_spec_2n ? "2N (plan)" : "dim+5 (as-built)");
    end

endmodule : mmu_perf_checker

`endif // MMU_PERF_CHECKER_SV
