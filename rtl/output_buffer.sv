//==============================================================================
// File: output_buffer.sv
// Project: sv-tpu-core
//
// TIMING FIX: previously gated the capture register on `done` directly
// (`else if (done) results_out <= results_in`). Because `done` is itself a
// registered/state-derived signal, that flop only sees `done` go high on
// the cycle AFTER `done` is externally visible — a spurious extra cycle of
// latency on top of deskew_capture's already-correct, done-cycle-aligned
// result_matrix. Consumers (formal checker, data_agent's monitor) that read
// `results` the same cycle they observe `done` were seeing stale data.
//
// Fixed by splitting into a combinational passthrough (valid the SAME cycle
// `done` is high, matching deskew_capture's timing) plus a held register
// that latches the same value one edge later, so results stay stable and
// correct across subsequent cycles/passes until the next done pulse.
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

    // Masked value of results_in for THIS cycle — same masking role the old
    // code applied, just computed combinationally instead of registered.
    logic signed [ACC_W-1:0] masked_result [N][N];

    always_comb begin
        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++)
                masked_result[r][c] = (r < int'(active_dim) && c < int'(active_dim))
                                       ? results_in[r][c]
                                       : '0;
    end

    // Held register: latches the masked result one cycle after `done` first
    // asserts (same edge deskew_capture's own registers update on), so the
    // correct value persists once `done` deasserts and software has time to
    // read it.
    logic signed [ACC_W-1:0] held [N][N];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    held[r][c] <= '0;
        end
        else if (done) begin
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    held[r][c] <= masked_result[r][c];
        end
        // else: hold — software may still be reading between passes.
    end

    // Present the masked value combinationally WHILE done is high (matches
    // deskew_capture's timing exactly — no extra cycle of lag), and fall
    // back to the latched value the rest of the time.
    always_comb begin
        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++)
                results_out[r][c] = done ? masked_result[r][c] : held[r][c];
    end

    assign result_valid = done;

endmodule : output_buffer