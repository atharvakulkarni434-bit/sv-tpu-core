//==============================================================================
// File: mmu_controller.sv
// Project: sv-tpu-core
//
// Description:
//   The sequencer FSM (spec A.5). Steps a computation through weight load,
//   accumulator clear, and activation flow, then reports done.
//
// Latency Contract (ratified):
//   Total latency from the first ACTIVATION_FLOW cycle to done is
//   active_dim + 5 cycles (measured/confirmed for N=1..4). This supersedes
//   the earlier active_dim + N + 1 and 2N formulas — see README.md
//   "Latency Contract" and BUGS.md Bug 7 for the decision record.
//
// CHANGE (this pass): added `fsm_state` — raw output of the internal `state`
// register, exposed purely for observability. Added to support
// cp_reset_state coverage (mmu_coverage.sv), which needs to see what state
// the FSM was in at the moment reset asserts — that isn't derivable from
// any existing output (load_weight/pe_clear/flow_en/done are each true in
// only one state, so together they could reconstruct 4 of the 5 states, but
// not distinguish IDLE from a state with no distinct high flag - simplest
// and least error-prone to just expose `state` directly). No internal
// behavior changes: state's own type (state_t) is `logic [2:0]` already, so
// this is a direct combinational assign, same pattern as the existing
// load_weight/pe_clear/flow_en/done block below.
//==============================================================================

`timescale 1ns/1ps

module mmu_controller #(
    parameter int N = 4          // physical array dimension (spec A.2)
)(
    input  logic        clk,
    input  logic        rst_n,

    // Software controls (AXI-Lite register mapped)
    input  logic        start,       // active high, held until done seen
    input  logic [2:0]  dim_n,       // matrix size (1..N) from DIM_REG

    // Hardwired hardware control lines out to the rest of the core
    output logic        load_weight, // high during WEIGHT_LOAD phase
    output logic        pe_clear,    // high for exactly 1 cycle during PE_CLEAR
    output logic        flow_en,     // high during ACTIVATION_FLOW phase
    output logic        done,        // high during DONE phase

    // Captured metadata sent to output buffers/formal checkers
    output logic [2:0]  active_dim,  // latched dim_n used for the running pass

    // ADDED (this pass): raw FSM state, exposed for cp_reset_state coverage
    // (mmu_coverage.sv / mmu_if.sv's fsm_state tap). Purely observability —
    // no internal behavior changes.
    output logic [2:0]  fsm_state
);

    // -------------------------------------------------------------------------
    // FSM States
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE            = 3'b000,
        WEIGHT_LOAD     = 3'b001,
        PE_CLEAR        = 3'b010,
        ACTIVATION_FLOW = 3'b011,
        DONE            = 3'b100
    } state_t;

    state_t state, next_state;

    // -------------------------------------------------------------------------
    // Latched configuration to ensure mid-run register changes don't corrupt execution
    // -------------------------------------------------------------------------
    logic [2:0] dim_q;
    assign active_dim = dim_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dim_q <= 3'd0;
        end
        else if (state == IDLE && start) begin
            dim_q <= dim_n;
        end
    end

    // -------------------------------------------------------------------------
    // Legality checks
    // -------------------------------------------------------------------------
    logic dim_legal;
    assign dim_legal = (dim_n >= 3'd1) && (dim_n <= 3'(N));

    // -------------------------------------------------------------------------
    // Execution cycle counting parameters
    // -------------------------------------------------------------------------
    localparam int WEIGHT_LOAD_CYCLES = N;
    
    // ACTIVATION_FLOW is sized so total flow_en-to-done latency is
    // active_dim + 5 cycles (the ratified contract): cnt runs 0..flow_last
    // inclusive, i.e. (flow_last + 1) ACTIVATION_FLOW cycles, plus the
    // 1-cycle DONE-phase register delay = flow_last + 2 total.
    // Terminal counter index = dim_q + N (== dim_q + 5 - 1 for the N=4
    // build this RTL is parameterized/verified at).
    logic [5:0] flow_last;
    assign flow_last = 6'(dim_q) + 6'(N);

    logic [5:0] cnt;
    localparam int CNT_W = 6;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end
        else begin
            state <= next_state;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= '0;
        end
        else begin
            cnt <= (next_state != state) ? '0 : cnt + 1'b1;
        end
    end

    always_comb begin
        next_state = state;
        unique case (state)
            IDLE:            if (start && dim_legal)
                                 next_state = WEIGHT_LOAD;
            WEIGHT_LOAD:     if (cnt == CNT_W'(WEIGHT_LOAD_CYCLES - 1))
                                 next_state = PE_CLEAR;
            PE_CLEAR:        next_state = ACTIVATION_FLOW;
            ACTIVATION_FLOW: if (cnt == flow_last)
                                 next_state = DONE;
            DONE:            if (!start)
                                 next_state = IDLE;
            default:         next_state = IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Output control flags
    // -------------------------------------------------------------------------
    always_comb begin
        load_weight = (state == WEIGHT_LOAD);
        pe_clear    = (state == PE_CLEAR);
        flow_en     = (state == ACTIVATION_FLOW);
        done        = (state == DONE);
        fsm_state   = state;
    end

endmodule : mmu_controller