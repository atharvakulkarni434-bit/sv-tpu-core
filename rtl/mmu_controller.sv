//==============================================================================
// File: mmu_controller.sv
// Description: the FSM (brain) of the chip. Once the CPU presses start, this
//              walks through the real computation steps in order — load
//              weights, clear old accumulator junk, stream activations
//              through, then report done. States: IDLE -> WEIGHT_LOAD ->
//              PE_CLEAR -> ACTIVATION_FLOW -> DONE -> back to IDLE.
//
// Latency contract: total time from the first ACTIVATION_FLOW cycle to done
// is active_dim + 5 cycles — this is what flow_last (below) computes.
//==============================================================================

`timescale 1ns/1ps

module mmu_controller #(
    parameter int N = 4          // physical array size (always 4x4)
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,       // from CTRL_REG — "go" signal from axi_lite_slave.sv
    input  logic [2:0]  dim_n,       // from DIM_REG — matrix size for this run

    output logic        load_weight, // tells systolic_array: shift weights in now
    output logic        pe_clear,    // tells systolic_array: wipe old accumulators
    output logic        flow_en,     // tells systolic_array: real data may flow now
    output logic        done,        // reported back out as STATUS_REG

    output logic [2:0]  active_dim,  // frozen copy of dim_n, safe from mid-run changes

    output logic [2:0]  fsm_state    // raw current state, for testbench observability only
);

    // the 5 states this FSM can be in, each given its own fixed 3-bit code
    typedef enum logic [2:0] {
        IDLE            = 3'b000,
        WEIGHT_LOAD     = 3'b001,
        PE_CLEAR        = 3'b010,
        ACTIVATION_FLOW = 3'b011,
        DONE            = 3'b100
    } state_t;

    // state = where we are right now. next_state = where we're about to go.
    state_t state, next_state;

    // -------------------------------------------------------------------------
    // Freeze the matrix size the moment a run starts, so a later CPU write
    // to DIM_REG mid-computation can't corrupt a pass that's already running
    // -------------------------------------------------------------------------
    logic [2:0] dim_q;                     // our own private, frozen copy of the size
    assign active_dim = dim_q;             // export it outward under a clearer name

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dim_q <= 3'd0;                 // reset: clear to 0
        end
        else if (state == IDLE && start) begin
            dim_q <= dim_n;                // copy the live dim_n value — ONLY at this exact moment
        end
    end

    // -------------------------------------------------------------------------
    // Is the current dim_n actually a legal size? (must be 1 through N)
    // -------------------------------------------------------------------------
    logic dim_legal;
    assign dim_legal = (dim_n >= 3'd1) && (dim_n <= 3'(N));

    // -------------------------------------------------------------------------
    // How long each timed phase needs to last
    // -------------------------------------------------------------------------
    localparam int WEIGHT_LOAD_CYCLES = N;   // weights take N cycles to fully shift in

    // flow_last = the exact cycle count where ACTIVATION_FLOW should end.
    // dim_q cycles to finish feeding data in, plus N more cycles for the
    // LAST piece of data to finish traveling across the fixed-size array.
    logic [5:0] flow_last;
    assign flow_last = 6'(dim_q) + 6'(N); // active_dim + 4

    logic [5:0] cnt;                        // counts how long we've been in the current state
    localparam int CNT_W = 6;

    // -------------------------------------------------------------------------
    // The actual state register — this is the real "memory" of where we are
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;                 // reset: always start at IDLE
        end
        else begin
            state <= next_state;           // every cycle, become whatever next_state decided
        end
    end

    // -------------------------------------------------------------------------
    // The cycle counter — resets to 0 every time we change states,
    // otherwise just counts up by 1 each cycle
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= '0;
        end
        else begin
            cnt <= (next_state != state) ? '0 : cnt + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // The actual rulebook: decide, every cycle, where to go next
    // -------------------------------------------------------------------------
    always_comb begin
        next_state = state;   // default: assume no change unless a rule below says otherwise
        unique case (state)

            // sit here until the CPU presses start AND the size is legal
            IDLE:            if (start && dim_legal)
                                 next_state = WEIGHT_LOAD;

            // wait exactly N cycles for all rows of weights to finish shifting in
            WEIGHT_LOAD:     if (cnt == CNT_W'(WEIGHT_LOAD_CYCLES - 1))
                                 next_state = PE_CLEAR;

            // no condition — always move on after just 1 cycle (single-cycle pulse)
            PE_CLEAR:        next_state = ACTIVATION_FLOW;

            // wait until flow_last cycles have passed — all data has flowed through
            ACTIVATION_FLOW: if (cnt == flow_last)
                                 next_state = DONE;

            // sit here until the CPU acknowledges by dropping start back to 0
            DONE:            if (!start)
                                 next_state = IDLE;

            // safety net: if state is ever somehow invalid/corrupted, recover to IDLE
            default:         next_state = IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Turn the abstract "state" into simple, individual signals other
    // modules can actually react to — each one just means "am I in that state?"
    // -------------------------------------------------------------------------
    always_comb begin
        load_weight = (state == WEIGHT_LOAD);
        pe_clear    = (state == PE_CLEAR);
        flow_en     = (state == ACTIVATION_FLOW);
        done        = (state == DONE);
        fsm_state   = state;   // raw state, exposed for testbench coverage only
    end

endmodule : mmu_controller
