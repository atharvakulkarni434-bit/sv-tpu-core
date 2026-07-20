//==============================================================================
// File: output_buffer.sv
// Project: sv-tpu-core
//
// Holds the int32 NxN result matrix until the testbench reads it after done
// (A.4/A.7). Latches on mmu_controller's `done`, masked against `active_dim`
// - the CONTROLLER'S LATCHED dimension for the pass that just finished, not
// the live DIM_REG - so a same-cycle-as-done software write to DIM_REG can't
// change which rows/columns get zeroed.
//
// CHANGE (2026-07-17): widened from N x32 (single vector) to N x N x32 (full
// result matrix), per team decision that A.7's "correct int32 matrix-multiply
// result" means an actual matrix, not one row/column of it. results_in now
// comes from the new deskew_capture.sv module (upstream of this file),
// which snapshots each output row off the array's bottom accum chain at the
// correct cycle - see deskew_capture.sv header for the timing derivation.
//
// Masking is now two-dimensional: rows >= active_dim AND cols >= active_dim
// both zero. Previously only columns were masked (the old N-wide results_in
// only ever carried one dimension of the product). With a full matrix,
// deskew_capture.sv only ever writes rows [0:dim-1] and leaves rows
// [dim:N-1] at their reset/flushed value of 0 - the row mask here is
// defense-in-depth matching the same philosophy as the original column
// mask: don't trust upstream padding alone, enforce it at the latch too.
//==============================================================================
`timescale 1ns/1ps

module output_buffer #(
    parameter int N     = 4,
    parameter int ACC_W = 32
)(
    input  logic                     clk,
    input  logic                     rst_n,        // active-low

    input  logic                     done,         // from mmu_controller
    input  logic [2:0]               active_dim,   // mmu_controller.dim_q — latched for THIS pass

    input  logic signed [ACC_W-1:0]  results_in  [N][N],  // full matrix, from deskew_capture
    output logic signed [ACC_W-1:0]  results_out [N][N],  // held NxN result matrix (A.9 results port)
    output logic                     result_valid         // mirrors STATUS_REG done (A.9)
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    results_out[r][c] <= '0;
        end
        else if (done) begin
            // Re-capture every cycle done is high. deskew_capture.sv has
            // already produced a stable, correctly-timed NxN matrix by this
            // point (all rows captured strictly before done per its timing
            // derivation) - latching here decouples read-out timing from the
            // capture module's internals and gives one place to enforce the
            // inactive-row/inactive-column mask.
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    results_out[r][c] <= (r < int'(active_dim) && c < int'(active_dim))
                                          ? results_in[r][c]
                                          : '0;
        end
        // else: hold — software may still be reading between passes.
    end

    assign result_valid = done;

endmodule : output_buffer