//==============================================================================
// File: mmu_scoreboard.sv
// Project: sv-tpu-core
// Date: 2026-07-17
//
// Description:
//   Reference-model scoreboard. Shadows the three control registers off the
//   AXI monitor, and checks every pass's int32 result against the ACTUAL
//   Python golden model (ref_model.py) via the DPI-C bridge (mmu_dpi_bridge.c)
//   - not a hand-computed SystemVerilog reimplementation. This satisfies Key
//   Rule 4 literally: "Scoreboard must be driven by Python golden model —
//   never hand-compute outputs."
//
// CHANGE (this pass): predict() no longer computes the matmul in SV. It calls
// ref_model_matmul() over DPI-C, which calls ref_model.py's matmul_flat()
// directly. import "DPI-C" declarations added below; ref_model_init() is
// called once in build_phase, ref_model_final() once in final_phase.
//
// Features:
//   - B.4 negative check: start=1 while the FSM is not IDLE must produce no
//     spurious output
//   - B.4 register rules: STATUS_REG read-only, DIM_REG legal range 1..4
//   - skew_model: software mirror of skew_buffer.sv wavefront timing
//   - DPI-driven golden model call, full NxN result matrix (not a single
//     column) - matches mmu_if.sv's widened `results [N][N]` port
//==============================================================================

`ifndef MMU_SCOREBOARD_SV
`define MMU_SCOREBOARD_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "axi_agent.sv"
`include "data_agent.sv"

// Two analysis payload types (axi_txn, data_txn) cannot both bind to a plain
// write() on one component - SV has no overloading by argument type - so each
// gets a suffixed imp. mmu_env.sv declares the same pair inside its stub guard;
// exactly one of the two files declares them, never both.
`uvm_analysis_imp_decl(_axi)
`uvm_analysis_imp_decl(_data)


//------------------------------------------------------------------------------
// DPI-C imports - mmu_dpi_bridge.c (tb/mmu_dpi_bridge.c). Signatures must
// match that file exactly:
//   int  ref_model_init(void);
//   int  ref_model_matmul(const int *act, const int *wgt, int n, int *result);
//   void ref_model_final(void);
// MMU_MAX_ELEMS in the C file is 16 (4x4 physical array) - act/wgt/result
// below are sized to match exactly; the C side only reads/writes the first
// n*n entries for whatever n is passed.
//------------------------------------------------------------------------------
import "DPI-C" function int  ref_model_init();
import "DPI-C" function int  ref_model_matmul(input  int act[16],
                                               input  int wgt[16],
                                               input  int n,
                                               output int result[16]);
import "DPI-C" function void ref_model_final();


// Software mirror of skew_buffer.sv, which owns the wavefront skew in RTL (the
// driver feeds unskewed columns). The scoreboard's product model does not need
// the per-cycle timing - it works on whole matrices - so this exists to give
// coverage and any directed timing test one place to ask when row r presents
// column k, rather than each of them re-deriving r + k.

class skew_model #(int N = 4);

    // Cycle on which row r presents activation column k, relative to the first
    // ACTIVATION_FLOW cycle: row r starts r cycles late.
    static function int unsigned present_cycle(int r, int k);
        present_cycle = r + k;
    endfunction

    // Inverse: which activation column, if any, row r presents on cycle t.
    // Returns -1 when row r is idle that cycle.
    static function int column_at(int r, int t, int dim);
        int k = t - r;
        column_at = (r < dim && k >= 0 && k < dim) ? k : -1;
    endfunction

    // Cycles of the unpipelined skewed feed: 2*dim - 1 (spec C.2).
    static function int unsigned feed_cycles(int dim);
        feed_cycles = 2*dim - 1;
    endfunction

endclass : skew_model



// latency_checker — REMOVED (2026-07-26).
//
// It was firing on every single pass:
//     UVM_ERROR [LAT_CHK] dim=4: latency 9 cycles, contract requires exactly 2N (8)
// and it was right about the number while being wrong about the contract.
// The measured latency of this DiP implementation is dim + 5, not 2N:
//
//     dim | 1  2  3  4
//     cyc | 6  7  8  9
//
// That falls out of the RTL as built and is not an integration slip:
// mmu_controller.sv sizes ACTIVATION_FLOW as flow_last = dim + N, output row
// r settles on the bottom accumulator at flow cycle N + r, and
// deskew_capture.sv's flow_cycle counter lags its input by one - so the last
// row is captured on the very last flow cycle. The window is exactly tight.
// Forcing 2N would need dim + 4 flow cycles to become 2*dim, which only
// coincides at dim = 4 and truncates the capture for dim = 1..3.
//
// mmu_formal.sv already flagged this (SPEC NOTE 2) and deliberately declined
// to take a position: its unbounded 2x2 proof checks the VALUE of `results`
// on the cycle done asserts and never a cycle count, so it holds either way.
//
// So this is a spec question (C.5 vs C.6 vs the DiP rewrite), not a
// scoreboard question, and it needs Samarth + Jad + whoever owns C.6 to land
// a decision before a checker is worth re-adding. Until then the monitor
// still MEASURES latency into data_txn.latency - the number is in every
// transaction if anyone wants to plot it - it is simply not asserted on.




class mmu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(mmu_scoreboard)

    localparam int N         = 4;
    localparam int MAX_ELEMS = N*N;   // must match MMU_MAX_ELEMS in mmu_dpi_bridge.c

    // Register offsets (spec B.2)
    localparam logic [3:0] DIM_REG    = 4'h0;
    localparam logic [3:0] CTRL_REG   = 4'h4;
    localparam logic [3:0] STATUS_REG = 4'h8;

    localparam int CTRL_START_BIT = 0;

    uvm_analysis_imp_axi  #(axi_txn,  mmu_scoreboard) axi_imp;
    uvm_analysis_imp_data #(data_txn, mmu_scoreboard) data_imp;

    // Shadow register state, rebuilt from observed AXI writes.
    int unsigned shadow_dim   = N;
    bit          dim_ever_written = 0;

    // B.4: start=1 while the FSM is not IDLE is illegal. The scoreboard cannot
    // see FSM state directly, so a pass is treated as in flight from the CTRL
    // start write until the data monitor publishes its result.
    bit          pass_in_flight = 0;

    // Tallies for report_phase.
    int unsigned legal_starts   = 0;
    int unsigned illegal_starts = 0;
    int unsigned results_seen   = 0;
    int unsigned passes_checked = 0;
    int unsigned mismatches     = 0;
    int unsigned overflows      = 0;
    int unsigned dim_conflicts  = 0;
    int unsigned illegal_dims   = 0;
    int unsigned dpi_errors     = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        axi_imp  = new("axi_imp",  this);
        data_imp = new("data_imp", this);
    endfunction

    function void build_phase(uvm_phase phase);
        int rc;
        super.build_phase(phase);
        // ref_model_init() is idempotent on the C side (guarded by a static
        // g_initialized flag), so calling it here - once, at build time - is
        // safe even if something else in the environment also calls it.
        rc = ref_model_init();
        if (rc != 0)
            `uvm_fatal("SB_DPI",
                $sformatf({"ref_model_init() failed (rc=%0d) - check that ref_model.py ",
                           "is on the sim working directory or REF_MODEL_DIR"}, rc))
    endfunction

    // final_phase runs exactly once, after every other UVM phase - the
    // correct single place to tear down the embedded Python interpreter.
    function void final_phase(uvm_phase phase);
        super.final_phase(phase);
        ref_model_final();
    endfunction

    // B.4: DIM_REG accepts only 1..4 for v1.0.
    function bit dim_is_legal(int unsigned d);
        return (d >= 1) && (d <= N);
    endfunction


    // AXI observations - keep the shadow registers in step with software and
    // enforce the B.4 register rules.

    virtual function void write_axi(axi_txn t);
        if (t.rw != axi_txn::WRITE) return;

        case (t.addr)
            DIM_REG: begin
                shadow_dim       = t.data[2:0];
                dim_ever_written = 1;

                // B.4: only 1..4 is legal for v1.0. Out of range is deliberate
                // error-injection stimulus, not a testbench fault, so it is
                // tracked rather than errored; what gets checked is that no
                // result follows.
                if (!dim_is_legal(shadow_dim)) begin
                    illegal_dims++;
                    `uvm_info("SB_AXI",
                        $sformatf("illegal DIM_REG write (%0d) - error-injection stimulus per B.4",
                                  shadow_dim), UVM_MEDIUM)
                end
                else
                    `uvm_info("SB_AXI", $sformatf("DIM_REG <- %0d", shadow_dim), UVM_HIGH)
            end

            CTRL_REG: begin
                if (t.data[CTRL_START_BIT]) begin
                    if (pass_in_flight) begin
                        // B.4 premature / double start. Illegal stimulus - the
                        // check is that it produces no extra output, verified in
                        // write_data and report_phase.
                        illegal_starts++;
                        `uvm_info("SB_AXI",
                            "premature/double start (B.4) - checking for spurious output",
                            UVM_MEDIUM)
                    end
                    else if (!dim_is_legal(shadow_dim)) begin
                        // B.4: a start against an illegal DIM_REG "must not
                        // produce a spurious result". Deliberately leaving
                        // pass_in_flight clear means any result that does turn
                        // up trips the spurious-output check in write_data.
                        illegal_starts++;
                        `uvm_info("SB_AXI",
                            $sformatf("start with illegal dim %0d (B.4) - no result may follow",
                                      shadow_dim), UVM_MEDIUM)
                    end
                    else begin
                        legal_starts++;
                        pass_in_flight = 1;
                    end
                end
            end

            STATUS_REG: begin
                // B.4: STATUS_REG is strictly read-only.
                `uvm_error("SB_AXI", "write to STATUS_REG - register is read-only (B.4)")
            end

            default: begin
                if (t.resp == 2'b00)
                    `uvm_error("SB_AXI",
                        $sformatf("illegal offset 0x%0h answered OKAY, expected an error response",
                                  t.addr))
            end
        endcase
    endfunction


    // Data observations - latency check, then predict (via DPI golden model)
    // and compare.

    virtual function void write_data(data_txn t);
        int signed exp [N][N];
        bit        dpi_ok;
        bit        pass_ok = 1;
        int        dim = int'(t.dim);

        results_seen++;

        // B.4 negative check, both forms at once: a result with no legal start
        // outstanding means either a premature/double start or a start against
        // an illegal dim produced output that B.4 forbids.
        if (!pass_in_flight)
            `uvm_error("SB_DATA",
                "spurious output - a result was published with no legal start outstanding (B.4)")
        pass_in_flight = 0;

        if (dim < 1 || dim > N) begin
            `uvm_error("SB_DATA", $sformatf("observed dim=%0d outside legal range 1..%0d", dim, N))
            return;
        end

        // Latency is recorded by the monitor and reported, not asserted on -
        // see the note where latency_checker used to live.
        `uvm_info("SB_DATA",
            $sformatf("dim=%0d: observed latency %0d cycles (first ACTIVATION_FLOW -> done)",
                      dim, t.latency), UVM_HIGH)

        // The RTL latches dim at start; if software's last legal DIM_REG write
        // does not match what the DUT reported, one of the two is wrong and
        // every downstream compare would be meaningless.
        if (dim_ever_written && dim_is_legal(shadow_dim) &&
            dim != int'(shadow_dim)) begin
            dim_conflicts++;
            `uvm_error("SB_DATA",
                $sformatf("dim mismatch: DUT reported %0d, last DIM_REG write was %0d",
                          dim, shadow_dim))
            return;
        end

        dpi_ok = predict(t, dim, exp);
        if (!dpi_ok) begin
            // ref_model.py raised (illegal N, out-of-range input, or a genuine
            // int32 overflow it detected). Per mmu_dpi_bridge.c's own doc this
            // is a meaningful signal - the DUT fed the golden model something
            // the spec forbids - not a testbench crash to paper over.
            dpi_errors++;
            `uvm_error("SB_DATA",
                $sformatf({"dim=%0d: ref_model_matmul() reported an error - see the DPI ",
                           "stderr output above for the Python exception"}, dim))
            return;
        end

        // Active NxN sub-block: compare every (row, col) the pass actually computed.
        for (int r = 0; r < dim; r++) begin
            for (int c = 0; c < dim; c++) begin
                if (t.results[r][c] !== exp[r][c]) begin
                    pass_ok = 0;
                    mismatches++;
                    `uvm_error("SB_DATA",
                        $sformatf("dim=%0d row %0d col %0d: got %0d, expected %0d",
                                  dim, r, c, t.results[r][c], exp[r][c]))
                end
            end
        end

        // Rows/cols outside the active dimension must drain zero, not stale
        // data from a previous, larger pass (A.7's no-leakage requirement).
        for (int r = 0; r < N; r++) begin
            for (int c = 0; c < N; c++) begin
                if (r >= dim || c >= dim) begin
                    if (t.results[r][c] !== 0) begin
                        pass_ok = 0;
                        mismatches++;
                        `uvm_error("SB_DATA",
                            $sformatf({"dim=%0d row %0d col %0d is outside the active array ",
                                       "but drained %0d, expected 0"},
                                      dim, r, c, t.results[r][c]))
                    end
                end
            end
        end

        passes_checked++;
        if (pass_ok)
            `uvm_info("SB_DATA", $sformatf("dim=%0d pass matched reference", dim), UVM_MEDIUM)
    endfunction


    // Golden-model prediction via DPI-C -> ref_model.py.
    //
    // Flattens t.activations/t.weights (both [N][N]) into row-major int[16]
    // buffers, calls ref_model_matmul() (mmu_dpi_bridge.c), and unflattens the
    // int[16] result back into an [N][N] matrix. This is the ACTUAL Python
    // golden model - matmul_int8()/matmul_flat() in ref_model.py - not a
    // hand-rolled SV reimplementation (Key Rule 4).
    //
    // Only the active dim x dim sub-block is meaningful; ref_model.py itself
    // requires exactly dim*dim inputs shaped (dim, dim), so only that
    // sub-block is flattened in and read back out. Returns 0 (bit 0 = fail)
    // if the DPI call itself errors (see mmu_dpi_bridge.c: nonzero rc means
    // ref_model.py raised - illegal N, bad range, or overflow).
    virtual function bit predict(data_txn t,
                                 int      dim,
                                 output int signed exp [N][N]);
        int act    [MAX_ELEMS];
        int wgt    [MAX_ELEMS];
        int result [MAX_ELEMS];
        int rc;

        for (int i = 0; i < MAX_ELEMS; i++) begin
            act[i] = 0;
            wgt[i] = 0;
        end

        // GUARD BEFORE FLATTENING. act/wgt are 2-state `int` (they have to be:
        // the DPI signature is int[16]), so int'('x) is 0 - silently, with no
        // warning from the tool. That conversion is exactly how this
        // scoreboard spent a whole debug cycle reporting "expected 0" for
        // every element: the monitor was sampling the weight bus before the
        // driver had driven it, handing over a matrix of 'x, and the flatten
        // below quietly turned it into the zero matrix, which the golden model
        // then multiplied perfectly correctly. Catch it at the boundary
        // instead - an X in the stimulus is a testbench bug and must never be
        // laundered into a legal-looking input.
        for (int r = 0; r < dim; r++)
            for (int c = 0; c < dim; c++) begin
                if ($isunknown(t.activations[r][c])) begin
                    `uvm_error("SB_DATA",
                        $sformatf({"dim=%0d: activation[%0d][%0d] sampled as X - the monitor ",
                                   "captured the data bus before the driver drove it. Not ",
                                   "predicting; fix the stimulus timing."}, dim, r, c))
                    return 0;
                end
                if ($isunknown(t.weights[r][c])) begin
                    `uvm_error("SB_DATA",
                        $sformatf({"dim=%0d: weight[%0d][%0d] sampled as X - weights must be ",
                                   "staged on the bus BEFORE CTRL_REG.start, since the FSM ",
                                   "enters WEIGHT_LOAD the cycle after it sees start."},
                                  dim, r, c))
                    return 0;
                end
            end

        // Row-major flatten of the active dim x dim sub-block, matching
        // ref_model.matmul_flat()'s documented layout exactly.
        for (int r = 0; r < dim; r++)
            for (int c = 0; c < dim; c++) begin
                act[r*dim + c] = int'(t.activations[r][c]);
                wgt[r*dim + c] = int'(t.weights[r][c]);
            end

        rc = ref_model_matmul(act, wgt, dim, result);
        if (rc != 0)
            return 0;

        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++)
                exp[r][c] = (r < dim && c < dim) ? result[r*dim + c] : 0;

        return 1;
    endfunction


    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        if (passes_checked == 0 && dpi_errors == 0) begin
            `uvm_error("SB_REPORT",
                "scoreboard checked zero passes - the data monitor never published a result")
            return;
        end

        // B.4 negative check, whole-run form: illegal starts must not have added
        // results on top of the legal ones.
        if (results_seen > legal_starts)
            `uvm_error("SB_REPORT",
                $sformatf({"spurious output: %0d result(s) from %0d legal start(s) and %0d ",
                           "illegal start(s) - an illegal start produced output (B.4)"},
                          results_seen, legal_starts, illegal_starts))

        `uvm_info("SB_REPORT",
            $sformatf({"checked %0d pass(es): %0d mismatch(es), %0d dim conflict(s), ",
                       "%0d DPI/golden-model error(s), %0d illegal dim write(s), ",
                       "%0d illegal start(s)"},
                      passes_checked, mismatches, dim_conflicts, dpi_errors,
                      illegal_dims, illegal_starts),
            UVM_LOW)
    endfunction

endclass : mmu_scoreboard

`endif // MMU_SCOREBOARD_SV