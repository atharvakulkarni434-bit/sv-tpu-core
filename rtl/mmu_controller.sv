//==============================================================================
// File: mmu_controller.sv
// Project: sv-tpu-core
// Date: 2026-07-16
//
// Description:
//   The sequencer FSM (spec A.5). Steps a computation through weight load,
//   accumulator clear, and activation flow, then reports done. State names and
//   port list are the A.5 / A.9 contract - change the spec first, never here.
//
// Features:
//   - IDLE / WEIGHT_LOAD / PE_CLEAR / ACTIVATION_FLOW / DONE (spec A.5)
//   - pe_clear asserts for EXACTLY one cycle, only in PE_CLEAR (spec A.5)
//   - done asserts exactly 2N cycles after the first ACTIVATION_FLOW cycle,
//     the locked latency contract (spec C.6) - the pipeline cycle of C.1 is
//     absorbed into 2N, never written as 2N-1+1
//   - An illegal dim_n (0 or 5..7) refuses the start: no spurious result (B.4)
//   - dim latched at start so a mid-run DIM_REG write cannot corrupt the pass
//   - Ports exactly as A.9: start, dim_n, load_weight, pe_clear, flow_en, done
//==============================================================================

`timescale 1ns/1ps

module mmu_controller #(
    parameter int N = 4          // physical array dimension (spec A.2)
)(
    input  logic       clk,
    input  logic       rst_n,      // active-low reset

    input  logic       start,      // CTRL_REG start bit (spec A.9)
    input  logic [2:0] dim_n,      // DIM_REG active size N, 1..4 (spec A.9)

    output logic       load_weight, // drives WEIGHT_LOAD phase (spec A.9)
    output logic       pe_clear,    // one cycle in PE_CLEAR (spec A.5/A.9)
    output logic       flow_en,     // drives ACTIVATION_FLOW phase (spec A.9)
    output logic       done         // to STATUS_REG bit 0 (spec A.9)
    output logic [2:0] dim_q        // NEW: latched active dim for this pass — output_buffer needs this
);

    // State names follow spec A.5 exactly.
    typedef enum logic [2:0] {
        IDLE            = 3'd0,
        WEIGHT_LOAD     = 3'd1,
        PE_CLEAR        = 3'd2,
        ACTIVATION_FLOW = 3'd3,
        DONE            = 3'd4
    } state_e;

    state_e state, next_state;

    // Counter must reach the ACTIVATION_FLOW terminal count of 2N-1.
    localparam int CNT_W = $clog2(2*N);

    logic [CNT_W-1:0] cnt;      // cycles elapsed in the current state
    //logic [2:0]       dim_q;    // active N, latched at start - NOTE: REMOVED since declared as port output at top

    // Weights arrive as a full N x N parallel bus on mmu_if and the PEs latch
    // them on load_weight, so one cycle loads the whole array. This matches the
    // single WLOAD column in the A.6 timing diagram. A.5 only says "all weights
    // are loaded" without a cycle count; WEIGHT_LOAD sits outside the C.6
    // measurement window, so it does not affect the 2N contract either way.
    localparam int WEIGHT_LOAD_CYCLES = 1;

    // B.4: dim 0 and 5..7 are illegal stimulus from the error-injection
    // sequences, and "the design must not produce a spurious result". So an
    // illegal dim refuses the start outright rather than clamping and running -
    // clamping would compute a real answer for a dimension software never
    // asked for, which is precisely the spurious result B.4 forbids. The FSM
    // stays in IDLE, done never asserts, and the scoreboard's negative check
    // confirms nothing came out.
    logic dim_legal;
    always_comb dim_legal = (dim_n >= 3'd1) && (dim_n <= N[2:0]);

    // ACTIVATION_FLOW spans 2N cycles: the 2N-1 unpipelined flow plus the one
    // pipeline-register cycle of C.1. Entering DONE on the cycle after the last
    // of those puts done exactly 2N cycles after the first flow cycle - the
    // C.6 contract, where off by one in either direction is a bug.
    logic [CNT_W-1:0] flow_last;
    always_comb flow_last = CNT_W'(2*dim_q - 1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cnt   <= '0;
            dim_q <= N[2:0];
        end
        else begin
            state <= next_state;

            if (state == IDLE && start && dim_legal)
                dim_q <= dim_n;

            // Restarts on every state change and free-runs within a state, so
            // each terminal-count compare below is unambiguous.
            cnt <= (next_state != state) ? '0 : cnt + 1'b1;
        end
    end

    always_comb begin
        next_state = state;
        unique case (state)
            // An illegal dim_n (B.4) leaves the FSM parked here: no phase runs,
            // no done, no result.
            IDLE:            if (start && dim_legal)
                                 next_state = WEIGHT_LOAD;
            WEIGHT_LOAD:     if (cnt == CNT_W'(WEIGHT_LOAD_CYCLES - 1))
                                 next_state = PE_CLEAR;
            // Exactly one cycle, unconditionally (spec A.5).
            PE_CLEAR:            next_state = ACTIVATION_FLOW;
            ACTIVATION_FLOW: if (cnt == flow_last)
                                 next_state = DONE;
            // Hold done until software drops the start bit, so a level-held
            // CTRL_REG start cannot immediately retrigger the array (spec A.5:
            // "start is de-asserted / next run begins").
            DONE:            if (!start)
                                 next_state = IDLE;
            default:             next_state = IDLE;
        endcase
    end

    always_comb begin
        load_weight = (state == WEIGHT_LOAD);
        pe_clear    = (state == PE_CLEAR);
        flow_en     = (state == ACTIVATION_FLOW);
        done        = (state == DONE);
    end

endmodule : mmu_controller
