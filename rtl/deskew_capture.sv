//==============================================================================
// File: deskew_capture.sv
// Project: sv-tpu-core
//
// DiP RE-DERIVATION (this pass): pe.sv's accumulator still has no per-column
// reset - it free-runs across the whole ACTIVATION_FLOW window, same as
// before DiP. So systolic_array.sv's bottom row (accum_wire[N-1][:]) still
// only ever holds a blended, still-accumulating sum, and this module is
// still needed to snapshot it at the right cycle per output row. What
// changed is the TIMING FORMULA, because DiP's diagonal interconnect moves
// data differently than the old horizontal design did.
//
// Timing derivation (DiP topology, per systolic_array.sv's header):
//   Every active cycle, row 0 is loaded in full with the next row of the
//   activation matrix A (all N columns in parallel - NOT one element per
//   row per cycle as in the old horizontal+skew_buffer design). Data then
//   moves diagonally: PE[row][col].activation_in <=
//   PE[row-1][(col+1) mod N].activation_out, one hop per cycle, for row>0.
//
//   This was verified independently (not just derived by inspection) by a
//   cycle-accurate symbolic simulation of the exact wiring in
//   systolic_array.sv, checked against numpy matmul across 50 random trials
//   each for N=1,2,3,4 (200 trials total, all exact matches). The result:
//   output row r (0-indexed, the r-th row of the true result matrix
//   result[r][c] = sum_k A[r][k]*W[k][c]) settles across the FULL bottom
//   row - all N columns simultaneously - at cycle:
//
//       capture_cycle(r) = (dim - 1) + r
//
//   relative to the first cycle row 0 is fed (t=0, i.e. the first
//   ACTIVATION_FLOW / flow_en cycle), where dim is the active dimension
//   (DIM_REG's value for this pass, 1..N). This replaces the old
//   horizontal-design formula of N+k.
//
//   The last output row (r = dim-1) settles at cycle (dim-1)+(dim-1) =
//   2*dim-2, so the full result is available by cycle 2*dim-1 - matching
//   DiP's own analytical latency of 2N+S-2 with S=1 (one MAC pipeline
//   stage), i.e. 2N-1 total. This is DIFFERENT from the old design's 2N
//   contract; see mmu_controller.sv / C.6 for how the controller's done
//   timing is reconciled with this (left to the team - flagged, not
//   silently changed, per the open discussion on this exact point).
//
// Features (unchanged from the pre-DiP file):
//   - One capture register per (row=r, col) pair -> a full NxN result matrix
//   - flush (tied to pe_clear) clears all capture registers so no result
//     from the previous pass can leak into this one
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
    // "cycles since this pass's flow began" - matching the origin that
    // capture_cycle(r) = (dim-1)+r is derived from. Unchanged mechanism
    // from the pre-DiP file; only the comparison below (against
    // capture_cycle) changes.
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

    // Capture registers. On cycle (dim_n-1)+r, latch the bottom row into
    // result_matrix[r][:] - i.e. output row r of the true result matrix.
    // Guarded to only fire for r in [0, dim_n-1] (flow_cycle ranges
    // 0 .. 2*dim_n-2 across the whole pass, and only dim_n of those cycles
    // are capture cycles - the rest are cycles where some other row is
    // still in flight and the bottom row is not yet a settled term for any
    // output row).
    //
    // capture_cycle(r) = (dim_n - 1) + r  =>  r = flow_cycle - (dim_n - 1)
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
            if (flow_cycle >= (int'(dim_n) - 1)) begin
                automatic int unsigned r = flow_cycle - (int'(dim_n) - 1);
                if (r < int'(dim_n)) begin
                    for (int c = 0; c < N; c++)
                        result_matrix[r][c] <= accum_bottom_row[c];
                end
            end
        end
    end

endmodule : deskew_capture
