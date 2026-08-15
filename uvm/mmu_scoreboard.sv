//==============================================================================
// File: mmu_scoreboard.sv
// Description: the judge. Watches every AXI write and every completed
// result, and checks each one against the REAL Python golden model
// (ref_model.py), called through the DPI-C bridge (mmu_dpi_bridge.c) — not
// a hand-computed SystemVerilog reimplementation. If I hand-wrote the
// expected-answer logic in SV too, a bug in my understanding of the spec
// could exist in BOTH the RTL and the checker at once, and I'd never catch it.
//==============================================================================

`ifndef MMU_SCOREBOARD_SV
`define MMU_SCOREBOARD_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "axi_agent.sv"
`include "data_agent.sv"

// Two separate payload types (axi_txn, data_txn) can't both bind to one
// plain write() function — SV has no overloading by argument type — so
// each analysis port gets its own suffixed version.
`uvm_analysis_imp_decl(_axi)
`uvm_analysis_imp_decl(_data)


//------------------------------------------------------------------------------
// DPI-C imports — these have to match mmu_dpi_bridge.c's function
// signatures EXACTLY, or the DPI call breaks.
//------------------------------------------------------------------------------
import "DPI-C" function int  ref_model_init();
import "DPI-C" function int  ref_model_matmul(input  int act[16],
                                               input  int wgt[16],
                                               input  int n,
                                               output int result[16]);
import "DPI-C" function void ref_model_final();


// Software mirror of skew_buffer.sv's timing. The scoreboard's own
// checking doesn't need this per-cycle detail — it works on whole
// matrices — but coverage/directed tests need one shared place to ask
// "when does row r present column k" instead of each re-deriving r+k.
class skew_model #(int N = 4);

    // the cycle number row r's activation for column k shows up on, relative to when the flow started
    static function int unsigned present_cycle(int r, int k);
        present_cycle = r + k;
    endfunction

    // reverse lookup: which column does row r show on cycle t (-1 = idle)
    static function int column_at(int r, int t, int dim);
        int k = t - r;
        column_at = (r < dim && k >= 0 && k < dim) ? k : -1;
    endfunction

    // total cycles the unpipelined skewed feed takes (spec C.2)
    static function int unsigned feed_cycles(int dim);
        feed_cycles = 2*dim - 1;
    endfunction

endclass : skew_model


// NOTE: latency_checker used to live here, got removed — it was wrongly
// asserting 2N cycles when the real, ratified contract is dim+5. Latency
// checking now lives in its own file (mmu_cat6_tests.sv), separate from
// this scoreboard's job of checking pure correctness.


class mmu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(mmu_scoreboard)

    localparam int N         = 4;
    localparam int MAX_ELEMS = N*N;   // must match MMU_MAX_ELEMS in mmu_dpi_bridge.c

    // the 3 register addresses, matching axi_lite_slave.sv exactly
    localparam logic [3:0] DIM_REG    = 4'h0;
    localparam logic [3:0] CTRL_REG   = 4'h4;
    localparam logic [3:0] STATUS_REG = 4'h8;

    localparam int CTRL_START_BIT = 0;

    // the two "mailboxes" that receive transactions from the monitors
    uvm_analysis_imp_axi  #(axi_txn,  mmu_scoreboard) axi_imp;
    uvm_analysis_imp_data #(data_txn, mmu_scoreboard) data_imp;

    // our own tracked copy of DIM_REG, rebuilt purely from observed AXI writes
    int unsigned shadow_dim   = N;
    bit          dim_ever_written = 0;

    // tracks whether a computation is currently running — we can't see the
    // FSM's real state directly, so we infer it from bus activity instead
    bit          pass_in_flight = 0;

    // lets a test tell us "don't expect any data traffic" (e.g. RAL-only tests)
    bit          expect_data_traffic = 1;

    // running counters, printed out at the very end in report_phase
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

        // pull in the expect_data_traffic flag, if a test set one
        uvm_config_db#(bit)::get(this, "", "expect_data_traffic", expect_data_traffic);

        // start the embedded Python interpreter — safe to call even if
        // something else also calls it, since it's idempotent on the C side
        rc = ref_model_init();
        if (rc != 0)
            `uvm_fatal("SB_DPI",
                $sformatf({"ref_model_init() failed (rc=%0d) - check that ref_model.py ",
                           "is on the sim working directory or REF_MODEL_DIR"}, rc))
    endfunction

    // runs exactly once, at the very end — the correct single place to
    // shut the embedded Python interpreter down
    function void final_phase(uvm_phase phase);
        super.final_phase(phase);
        ref_model_final();
    endfunction

    // watches for reset firing mid-computation (from reset-stress
    // sequences). If reset hits mid-pass, that pass is aborted and no
    // result will ever come — so clear pass_in_flight here, or the NEXT
    // legitimate start would wrongly look like a double-start.
    task run_phase(uvm_phase phase);
        uvm_event rst_req = uvm_event_pool::get_global("mmu_reset_req");
        forever begin
            rst_req.wait_trigger();
            if (pass_in_flight)
                `uvm_info("SB_RST",
                    "reset asserted mid-pass - clearing in-flight start (aborted pass, no result to check)",
                    UVM_MEDIUM)
            pass_in_flight = 0;
        end
    endtask

    // only 1..4 is a legal matrix size
    function bit dim_is_legal(int unsigned d);
        return (d >= 1) && (d <= N);
    endfunction


    //---------------------------------------------------------------------
    // fires on every AXI write the monitor publishes — keeps our shadow
    // registers in sync, and enforces the register-write rules
    //---------------------------------------------------------------------
    virtual function void write_axi(axi_txn t);
        if (t.rw != axi_txn::WRITE) return;

        case (t.addr)
            DIM_REG: begin
                shadow_dim       = t.data[2:0];
                dim_ever_written = 1;

                // illegal values are deliberate error-injection stimulus,
                // not a testbench bug — so just track it, don't error;
                // the real check is that no result follows (write_data)
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
                        // premature/double start — same idea, just track it
                        // and check downstream for spurious output
                        illegal_starts++;
                        `uvm_info("SB_AXI",
                            "premature/double start (B.4) - checking for spurious output",
                            UVM_MEDIUM)
                    end
                    else if (!dim_is_legal(shadow_dim)) begin
                        // starting with an illegal dim — leave pass_in_flight
                        // clear on purpose, so ANY result that shows up gets
                        // caught by write_data's spurious-output check
                        illegal_starts++;
                        `uvm_info("SB_AXI",
                            $sformatf("start with illegal dim %0d (B.4) - no result may follow",
                                      shadow_dim), UVM_MEDIUM)
                    end
                    else begin
                        // a genuinely legal start
                        legal_starts++;
                        pass_in_flight = 1;
                    end
                end
            end

            STATUS_REG: begin
                // this one's different — STATUS_REG is strictly read-only,
                // so ANY write here is a hard error, unconditionally
                `uvm_error("SB_AXI", "write to STATUS_REG - register is read-only (B.4)")
            end

            default: begin
                // any address that isn't one of our 3 real registers
                if (t.resp == 2'b00)
                    `uvm_error("SB_AXI",
                        $sformatf("illegal offset 0x%0h answered OKAY, expected an error response",
                                  t.addr))
            end
        endcase
    endfunction


    //---------------------------------------------------------------------
    // fires on every completed result the data monitor publishes — this
    // is where the actual correctness checking happens
    //---------------------------------------------------------------------
    virtual function void write_data(data_txn t);
        int signed exp [N][N];
        bit        dpi_ok;
        bit        pass_ok = 1;
        int        dim = int'(t.dim);

        results_seen++;

        // a result with no legal start outstanding means something illegal
        // produced output — that's exactly what B.4 forbids
        if (!pass_in_flight)
            `uvm_error("SB_DATA",
                "spurious output - a result was published with no legal start outstanding (B.4)")
        pass_in_flight = 0;

        if (dim < 1 || dim > N) begin
            `uvm_error("SB_DATA", $sformatf("observed dim=%0d outside legal range 1..%0d", dim, N))
            return;
        end

        // latency is just measured/reported here, not enforced — the real
        // enforcement lives in mmu_cat6_tests.sv's latency_checker instead
        `uvm_info("SB_DATA",
            $sformatf("dim=%0d: observed latency %0d cycles (first ACTIVATION_FLOW -> done)",
                      dim, t.latency), UVM_HIGH)

        // sanity check: does the chip's own reported dim match what
        // software last wrote to DIM_REG? If not, nothing downstream
        // would be meaningful, so bail out here
        if (dim_ever_written && dim_is_legal(shadow_dim) &&
            dim != int'(shadow_dim)) begin
            dim_conflicts++;
            `uvm_error("SB_DATA",
                $sformatf("dim mismatch: DUT reported %0d, last DIM_REG write was %0d",
                          dim, shadow_dim))
            return;
        end

        // call the actual golden model, through DPI, to get the correct answer
        dpi_ok = predict(t, dim, exp);
        if (!dpi_ok) begin
            // Python itself rejected the input — a meaningful signal, not
            // a testbench crash: the DUT fed the golden model something
            // the spec forbids
            dpi_errors++;
            `uvm_error("SB_DATA",
                $sformatf({"dim=%0d: ref_model_matmul() reported an error - see the DPI ",
                           "stderr output above for the Python exception"}, dim))
            return;
        end

        // compare every real, active position against the golden answer
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

        // separately: anything OUTSIDE the active dim must be exactly 0 —
        // never leftover stale data from a previous, larger run
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


    //---------------------------------------------------------------------
    // predict — calls the actual golden model via DPI, and unpacks the
    // result back into a normal [N][N] matrix
    //---------------------------------------------------------------------
    virtual function bit predict(data_txn t,
                                 int      dim,
                                 output int signed exp [N][N]);
        int act    [MAX_ELEMS];
        int wgt    [MAX_ELEMS];
        int result [MAX_ELEMS];
        int rc;

        // zero out both flat arrays first, since only the active dim*dim
        // portion actually gets filled in below
        for (int i = 0; i < MAX_ELEMS; i++) begin
            act[i] = 0;
            wgt[i] = 0;
        end

        // guard BEFORE flattening: these arrays are 2-state ints, so an
        // unknown 'x' value silently becomes 0 with no warning — this is
        // exactly the bug that once made this scoreboard report "expected
        // 0" for everything, because the monitor sampled the bus before
        // the driver had actually driven it. Catch it here explicitly.
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

        // flatten the active dim x dim block into 1D arrays, matching
        // ref_model.py's expected layout exactly
        for (int r = 0; r < dim; r++)
            for (int c = 0; c < dim; c++) begin
                act[r*dim + c] = int'(t.activations[r][c]);
                wgt[r*dim + c] = int'(t.weights[r][c]);
            end

        // the actual DPI call into C, which in turn calls real Python
        rc = ref_model_matmul(act, wgt, dim, result);
        if (rc != 0)
            return 0;

        // unflatten the result back into [N][N], masking anything outside
        // the active dim to 0
        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++)
                exp[r][c] = (r < dim && c < dim) ? result[r*dim + c] : 0;

        return 1;
    endfunction


    //---------------------------------------------------------------------
    // report_phase — runs once, at the very end of the whole test, and
    // prints the final summary
    //---------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        // suspicious if literally nothing was ever checked
        if (passes_checked == 0 && dpi_errors == 0) begin
            if (expect_data_traffic) begin
                `uvm_error("SB_REPORT",
                    "scoreboard checked zero passes - the data monitor never published a result")
            end else begin
                `uvm_info("SB_REPORT",
                    "scoreboard checked zero passes - expected behavior as expect_data_traffic is 0", UVM_LOW)
            end
            return;
        end

        // whole-run version of the spurious-output check — more results
        // than legal starts means something illegal produced output somewhere
        if (results_seen > legal_starts)
            `uvm_error("SB_REPORT",
                $sformatf({"spurious output: %0d result(s) from %0d legal start(s) and %0d ",
                           "illegal start(s) - an illegal start produced output (B.4)"},
                          results_seen, legal_starts, illegal_starts))

        // the final summary printed at the end of every test run
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
