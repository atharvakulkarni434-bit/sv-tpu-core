//==============================================================================
// File: skew_buffer.sv
// Project: sv-tpu-core
// Date: 2026-07-16
//
// Description:
//   Per-row delay bank that applies the diagonal wavefront skew a
//   weight-stationary systolic array needs. Row r of the activation vector is
//   delayed r cycles, so activation column k reaches PE row r on cycle r + k
//   and every partial sum meets its operand on the right cycle.
//
// Ownership of the skew: RTL, this block. C.1 already describes the stagger as
// a design-side behavior ("row 0 on cycle 0, row 1 on cycle 1"), and the PE's
// registered activation_out is built around it. data_agent.sv drives unskewed
// columns straight from the A matrix - exactly one side applies the skew, or
// row r is delayed twice and every product misaligns.
//
// PENDING SPEC UPDATE - two edits are needed before this block is spec-legal:
//   A.4 - module list names only mmu_top, axi_lite_slave, mmu_controller,
//         systolic_array, pe, output_buffer, mmu_if. Add skew_buffer.sv.
//   A.8 - the activation arrow reads testbench/data_agent -> systolic_array.
//         It becomes testbench/data_agent -> skew_buffer -> systolic_array.
// Until both land and are re-approved, this file is ahead of the spec.
//
// Features:
//   - Row r delayed by exactly r cycles (row 0 is combinational passthrough)
//   - Parameterized on N / DATA_W; delay chain sized from N at elaboration
//   - Rows at or above the active dim are held at zero, not left floating
//   - flush zeroes the whole chain without a full reset
//   - Companion model lives in mmu_scoreboard.sv (skew_model)
//==============================================================================

`timescale 1ns/1ps

module skew_buffer #(
    parameter int N      = 4,    // physical array dimension
    parameter int DATA_W = 8     // int8 activations
)(
    input  logic                     clk,
    input  logic                     rst_n,     // active-low reset

    input  logic                     en,        // advance the delay chain
    input  logic                     flush,     // synchronous zero of all stages
    input  logic [2:0]               dim_n,     // active dimension (1..N)

    input  logic signed [DATA_W-1:0] din  [N],  // unskewed activation column
    output logic signed [DATA_W-1:0] dout [N]   // skewed activations to the array
);

    // Row r needs r stages of delay, so the deepest chain is N-1 stages. The
    // array is declared full-depth for every row and only the first r entries
    // of row r are ever clocked; unused entries are trimmed by synthesis.
    logic signed [DATA_W-1:0] chain [N][N];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < N; r++)
                for (int s = 0; s < N; s++)
                    chain[r][s] <= '0;
        end
        else if (flush) begin
            for (int r = 0; r < N; r++)
                for (int s = 0; s < N; s++)
                    chain[r][s] <= '0;
        end
        else if (en) begin
            for (int r = 1; r < N; r++) begin
                // Rows outside the active dim contribute nothing to the
                // product; feeding zeros keeps their column accumulators clean.
                logic signed [DATA_W-1:0] row_in;
                row_in = (r < int'(dim_n)) ? din[r] : '0;

                chain[r][0] <= row_in;
                for (int s = 1; s < r; s++)
                    chain[r][s] <= chain[r][s-1];
            end
        end
    end

    // Row 0 has zero delay and bypasses the chain entirely; row r taps stage
    // r-1, which holds the sample presented r cycles ago.
    always_comb begin
        for (int r = 0; r < N; r++) begin
            if (r >= int'(dim_n))      dout[r] = '0;
            else if (r == 0)           dout[r] = din[0];
            else                       dout[r] = chain[r][r-1];
        end
    end

endmodule : skew_buffer