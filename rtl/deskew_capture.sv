//==============================================================================
// File: deskew_capture.sv
// Project: sv-tpu-core
// Date: 2026-07-17
//
// Description:
//   The missing piece flagged in systolic_array.sv's trailing design note:
//   "the results are going to be extremely staggered... we need to make
//   ANOTHER deskew module for this... otherwise this is not going to work."
//
//   Root cause this module fixes: pe.sv's accumulator has no per-column
//   reset - it free-runs across the whole ACTIVATION_FLOW window, so by
//   itself systolic_array's bottom row (accum_wire[N-1][:]) only ever holds
//   a blended sum across every activation column that has swept through,
//   never one column's true dot-product term in isolation. This module
//   snapshots the bottom row at exactly the cycle each output row's term is
//   complete and un-blended, before the next column's contribution starts
//   landing on top of it.
//
// Timing derivation (see BUGS.md / team discussion, 2026-07-17):
//   Row r's activation column k reaches PE[r][0] on cycle r+k (skew_buffer.sv
//   contract), then takes c more registered hops to reach PE[r][c], arriving
//   at PE[r][c] on cycle r+k+c and registering into that PE's accum_out one
//   cycle later, i.e. cycle r+k+c+1. The vertical accum chain is purely
//   combinational (systolic_array.sv: accum_in = accum_wire[row-1][col]), so
//   the bottom row's value for column k is fully settled the cycle the LAST
//   row's (r = N-1) term for that k registers:
//       capture_cycle(k) = (N-1) + k + 1 = N + k
//   relative to the first ACTIVATION_FLOW (flow_en) cycle, taken as cycle 0.
//   For k = 0 .. dim-1, capture_cycle ranges N .. N+dim-1, which is inside
//   the 2*dim-1 cycle flow window and comfortably before done at cycle 2*dim
//   (measured from the same origin per spec C.6) - so every row's capture
//   cycle occurs strictly before done fires.
//
// Features:
//   - One capture register per (row=k, col) pair -> a full NxN result matrix
//   - Captures accum_wire[N-1][:] on cycle N+k for each active k (0..dim-1)
//   - Inactive rows (k >= dim) and inactive cols (col >= dim) never written -
//     output_buffer.sv is still responsible for masking them to 0 on latch
//   - flush (tied to pe_clear, same as skew_buffer.sv) clears all capture
//     registers so no result from the previous pass can leak into this one
//   - Purely a snapshot layer: does NOT modify pe.sv's accumulate-forever
//     behavior, so the underlying MAC datapath needs no changes
//==============================================================================

`timescale 1ns/1ps

module deskew_capture #(
    parameter int N     = 4,
    parameter int ACC_W = 32
)(
    input  logic                     clk,
    input  logic                     rst_n,      // active-low reset

    input  logic                     flow_en,    // ACTIVATION_FLOW phase, from mmu_controller
    input  logic                     flush,      // synchronous clear (tied to pe_clear)
    input  logic [2:0]               dim_n,      // active dimension (latched active_dim, 1..N)

    // Bottom row of the systolic array's vertical accum chain.
    input  logic signed [ACC_W-1:0]  accum_bottom_row [N],   // accum_wire[N-1][:]

    // Full NxN result matrix. result_matrix[row][col] = sum_k A[row][k]*W[k][col].
    output logic signed [ACC_W-1:0]  result_matrix [N][N]
);

    // Local cycle counter, relative to the first flow_en cycle. Restarts
    // whenever flow_en drops (idle between passes) so it is always
    // "cycles since this pass's flow began" - matching the C.6 origin that
    // capture_cycle(k) = N+k is derived from.
    logic [$clog2(2*N)+1:0] flow_cycle;
    logic                   flow_cycle_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flow_cycle        <= '0;
            flow_cycle_active <= 1'b0;
        end
        else if (flush) begin
            flow_cycle        <= '0;
            flow_cycle_active <= 1'b0;
        end
        else if (flow_en) begin
            flow_cycle        <= flow_cycle_active ? (flow_cycle + 1'b1) : '0;
            flow_cycle_active <= 1'b1;
        end
        else begin
            flow_cycle_active <= 1'b0;
        end
    end

    // Capture registers. On cycle N+k (k = flow_cycle - N), latch the bottom
    // row into result_matrix[k][:] - i.e. row k of the true result matrix.
    // Guarded to only fire for k in [0, dim_n-1]; k >= dim_n never happens
    // within the flow window for a legal dim, but the guard keeps this
    // module correct even if driven with dim_n changing mid-flight.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    result_matrix[r][c] <= '0;
        end
        else if (flush) begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    result_matrix[r][c] <= '0;
        end
        else if (flow_en && flow_cycle_active) begin
            // capture_cycle(k) = N + k  =>  k = flow_cycle - N
            if (flow_cycle >= N) begin
                automatic int unsigned k = flow_cycle - N;
                if (k < int'(dim_n)) begin
                    for (int c = 0; c < N; c++)
                        result_matrix[k][c] <= accum_bottom_row[c];
                end
            end
        end
    end

endmodule : deskew_capture
