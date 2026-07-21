//==============================================================================
// File: deskew_capture.sv
// Project: sv-tpu-core
//
// Capture timing (CORRECTED): Output row r of the true result settles into
// the bottom accumulator row at flow_cycle == N + r (relative to the
// first flow_en cycle). The physical pipeline requires N cycles for the 
// first row to drain, accounting for activation feed latency.
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
    input  logic signed [ACC_W-1:0]  accum_bottom_row [N],

    // Captured result matrix presented back out to output_buffer.sv
    output logic signed [ACC_W-1:0]  result_matrix    [N][N]
);

    // -------------------------------------------------------------------------
    // Cycle counter: increments every clock cycle while flow_en is active.
    // -------------------------------------------------------------------------
    logic [5:0] flow_cycle;
    logic       flow_cycle_active;

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

    // -------------------------------------------------------------------------
    // Staggered capture logic (Shifted +1 cycle for data_agent pipeline delay)
    //
    // For a physical matrix of size N, Row 0 is valid at flow_cycle = N.
    // Row r is valid at flow_cycle = N + r.
    // Therefore, the target row is: r = flow_cycle - N.
    // -------------------------------------------------------------------------
    logic [5:0] target_row_wide;
    logic [2:0] target_row;
    logic       capture_en;

    // Prevent underflow when flow_cycle < N
    assign target_row_wide = (flow_cycle >= 6'(N)) ? (flow_cycle - 6'(N)) : 6'd63;
    assign target_row      = target_row_wide[2:0];

    // Enable capturing only if the target row is within the active software dimension bounds
    assign capture_en = flow_en && flow_cycle_active &&
                        (flow_cycle >= 6'(N)) &&
                        (target_row < {2'b00, dim_n});

    // Loop variables declared at module level for strict tool compatibility.
    integer r_idx, c_idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r_idx = 0; r_idx < N; r_idx = r_idx + 1) begin
                for (c_idx = 0; c_idx < N; c_idx = c_idx + 1) begin
                    result_matrix[r_idx][c_idx] <= '0;
                end
            end
        end
        else if (flush) begin
            for (r_idx = 0; r_idx < N; r_idx = r_idx + 1) begin
                for (c_idx = 0; c_idx < N; c_idx = c_idx + 1) begin
                    result_matrix[r_idx][c_idx] <= '0;
                end
            end
        end
        else begin
            // Static unroll over all physical rows; internal `if` selects the
            // one active row this cycle.
            for (r_idx = 0; r_idx < N; r_idx = r_idx + 1) begin
                if (capture_en && (r_idx == int'(target_row))) begin
                    for (c_idx = 0; c_idx < N; c_idx = c_idx + 1) begin
                        // Only capture elements within the active column dimension
                        if (c_idx < int'(dim_n)) begin
                            result_matrix[r_idx][c_idx] <= accum_bottom_row[c_idx];
                        end
                    end
                end
            end
        end
    end

endmodule : deskew_capture