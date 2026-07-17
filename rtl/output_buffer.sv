//==============================================================================
// File: output_buffer.sv
// Project: sv-tpu-core
//
// Holds the int32 results until the testbench reads them after done (A.4/A.7).
// Latches on mmu_controller's `done`, masked against `active_dim` — the
// CONTROLLER'S LATCHED dimension for the pass that just finished, not the
// live DIM_REG — so a same-cycle-as-done software write to DIM_REG can't
// change which columns get zeroed. Masking is done here rather than trusted
// to weight/activation padding upstream (data_agent.sv only writes weights
// for [0:dim-1][0:dim-1] and never clears the rest of the NxN weight bus),
// which is the defense-in-depth mmu_scoreboard.sv's inactive-column check
// relies on.
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

    input  logic signed [ACC_W-1:0]  results_in  [N],  // raw drain, systolic_array
    output logic signed [ACC_W-1:0]  results_out [N],  // held results (A.9 results port)
    output logic                     result_valid      // mirrors STATUS_REG done (A.9)
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int c = 0; c < N; c++)
                results_out[c] <= '0;
        end
        else if (done) begin
            // Re-capture every cycle done is high. systolic_array's drain is
            // already stable in this window — flow_en=0 forces PE inputs to
            // zero, so accum_out just holds (see pe.sv: accum_in + 0) — but
            // latching decouples read-out timing from the array internals
            // and gives one place to enforce the inactive-column mask.
            for (int c = 0; c < N; c++)
                results_out[c] <= (c < int'(active_dim)) ? results_in[c] : '0;
        end
        // else: hold — software may still be reading between passes.
    end

    assign result_valid = done;

endmodule : output_buffer
