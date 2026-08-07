//==============================================================================
// File: deskew_capture.sv
// Project: sv-tpu-core
//
// Description: Reconstructs the true NxN result matrix from the systolic
// array's raw, continuously-updating bottom accumulator row. Because DiP's
// diagonal dataflow settles each output row at a different cycle, this
// module tracks elapsed flow cycles and snapshots accum_bottom_row into
// result_matrix at the moment each row becomes valid, discarding rows/
// columns outside the active software dimension (dim_n). Feeds into
// mmu_controller.sv's ACTIVATION_FLOW sizing and DONE register stage,
// which together produce the module-level ratified latency contract of
// active_dim + 5 cycles (flow_en to done) — see README.md "Latency
// Contract" and BUGS.md Bug 7.
//==============================================================================

`timescale 1ns/1ps

module deskew_capture #(
    parameter int N     = 4,
    parameter int ACC_W = 32
)(
    input  logic                     clk,        // Same common clock
    input  logic                     rst_n,      // active-low reset

    input  logic                     flow_en,    // The activation flow phase, see systolic_array.sv for full implementation.
    input  logic                     flush,      // synchronous clear (tied to pe_clear)
    input  logic [2:0]               dim_n,      // This is the active dimension mentioned in systolic_array.sv - ranging from 1 to N.
    // the above input masks which rows/columns of the result actually get captured: i.e. only 2 cols, 1 col, 3 col, etc.

    // Bottom row of the systolic array's vertical accum chain, exposed as output in that file.
    input  logic signed [ACC_W-1:0]  accum_bottom_row [N],

    // Captured result matrix presented back out to output_buffer.sv
    output logic signed [ACC_W-1:0]  result_matrix    [N][N]
);

    // This block is the cycle counter
    // In layman's terms, it counts how many consecutive cycles flow_en has been high

    // Flow_cycle is the number of cycles active
    logic [5:0] flow_cycle;
    // Flow_cycle_active is the boolean that mirrors flow_en
    logic       flow_cycle_active;

    always_ff @(posedge clk or negedge rst_n) begin
        // if async reset, everything is zeroed.
        if (!rst_n) begin
            flow_cycle        <= '0;
            flow_cycle_active <= 1'b0;
        end
        else if (flush) begin
            // if flushed, everything zeroed (synchronous)
            flow_cycle        <= '0;
            flow_cycle_active <= 1'b0;
        end
        else if (flow_en) begin
            // if we were ALREADY counting last cycle, increment, otherwise, this is a fresh start, so start at 0
            flow_cycle        <= flow_cycle_active ? (flow_cycle + 1'b1) : '0;
            // matches flow_en
            flow_cycle_active <= 1'b1;
        end
        else begin
            // flow_en is not high, so match that with a value of 0
            flow_cycle_active <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Staggered capture logic (Shifted +1 cycle for data_agent pipeline delay)
    //
    // For a physical matrix of size N, Row 0 is valid at flow_cycle = N.
    // Row r is valid at flow_cycle = N + r.
    // Therefore, the target row is: r = flow_cycle - N. - ***MAIN FORMULA***
    // -------------------------------------------------------------------------
    logic [5:0] target_row_wide;
    logic [2:0] target_row;
    logic       capture_en;

    // Prevent underflow when flow_cycle < N
    // since if flow_cycle < N, then the result wraps around to a huge unsigned number.
    // Hence, it checks for validity, and if not, forces target_row_wide to an obvious out of range number
    // Since the target row can never be 63 (in this design)
    
    assign target_row_wide = (flow_cycle >= 6'(N)) ? (flow_cycle - 6'(N)) : 6'd63;
    
    // Truncate down to the actual row within the 3 bits (range of 0 to 7).
    assign target_row      = target_row_wide[2:0];

    // Enable capturing IF:
    // 1) flow_en is high - we are curerntly in the activation flowing state
    // 2) flow_cycle_active is high - we are incrementing flow_cycle actively
    // 3) Enough cycles have elapsed that SOME row has settled, so flow_cycle < N is not true (no wraparound_)
    // 4) Discard any target row that is outside of the software-enabled "active dimension limit".
    assign capture_en = flow_en && flow_cycle_active &&
                        (flow_cycle >= 6'(N)) &&
                        (target_row < {2'b00, dim_n});

    // Loop variables declared at module level for strict tool compatibility.
    integer r_idx, c_idx;

    // this is an always_ff, so synchronously evaluated at every edge.
    always_ff @(posedge clk or negedge rst_n) begin
        // if reset low, zero the result matrix.
        if (!rst_n) begin
            for (r_idx = 0; r_idx < N; r_idx = r_idx + 1) begin
                for (c_idx = 0; c_idx < N; c_idx = c_idx + 1) begin
                    result_matrix[r_idx][c_idx] <= '0;
                end
            end
        end
        // if flush high, zero the result matrix.
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
            // In simpler terms, for each row...
                // if capture enable is high and we are ON the target row...
                    // Capture each column result in the target row.
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
