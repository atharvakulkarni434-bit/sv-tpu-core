//==============================================================================
// File: mmu_controller.sv
// Project: sv-tpu-core
//
// Description:
//   The sequencer FSM (spec A.5). Steps a computation through weight load,
//   accumulator clear, and activation flow, then reports done.
//
// Latency Correction: 
//   Extended ACTIVATION_FLOW duration to accommodate the +1 cycle latency 
//   required for physical drain and data alignment in deskew_capture.
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
    output logic [2:0]  active_dim   // latched dim_n used for the running pass
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
    
    // CORRECTED TIMING CALCULATION (Shifted +1 cycle):
    // deskew_capture.sv now captures output row r at flow_cycle == N + r.
    // The last row to capture is row (dim_q - 1), at flow_cycle = N + dim_q - 1.
    // Because flow_cycle lags cnt by one register stage, flow_en/cnt must 
    // stay asserted long enough. 
    // Terminal counter index = dim_q + N
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
    end

endmodule : mmu_controller