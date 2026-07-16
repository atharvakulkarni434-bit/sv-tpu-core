//==============================================================================
// File: mmu_scoreboard.sv
// Project: sv-tpu-core
// Date: 2026-07-16
//
// Description:
//   Reference-model scoreboard plus the transaction-level latency_checker that
//   spec C.5 assigns to this file. Shadows the three control registers off the
//   AXI monitor, recomputes the expected int32 result in unbounded precision
//   off the data monitor, and checks every pass against the locked 2N latency
//   contract. Replaces the guarded stub in mmu_env.sv.
//
// Features:
//   - latency_checker (spec C.5/C.6): done exactly 2N cycles after the first
//     ACTIVATION_FLOW cycle - off by one in either direction is a bug
//   - B.4 negative check: start=1 while the FSM is not IDLE must produce no
//     spurious output
//   - B.4 register rules: STATUS_REG read-only, DIM_REG legal range 1..4
//   - skew_model: software mirror of skew_buffer.sv wavefront timing
//   - int32 overflow detection - predicts in 64-bit, flags truncation
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



// latency_checker - the transaction-level half of the C.5 pair.
//
// Owner: Samarth. The other half is Jad's signal-level mmu_perf_checker.sv.
// Both must use the same 2N number (C.6); if this one changes, that one changes
// in the same PR, along with C.6, perf_report.md, and the README.
//
// PENDING SPEC UPDATE - C.5 and C.6 disagree on the measurement window. C.5
// describes this checker as recording "the cycle start fires and the cycle done
// asserts", while C.6 - which declares itself the single source of truth, and
// whose N + N derivation only works from the array's input - measures from the
// first ACTIVATION_FLOW cycle. The two differ by the WEIGHT_LOAD and PE_CLEAR
// cycles. This checker follows C.6 (team decision, via the flow_en tap added to
// mmu_if); C.5's wording needs to follow, and A.9's note that only start/done
// feed the latency check needs flow_en added alongside them.

class latency_checker extends uvm_object;
    `uvm_object_utils(latency_checker)

    localparam int N = 4;

    int unsigned checked    = 0;
    int unsigned violations = 0;

    // Which dimensions this checker has actually seen. C.7 is explicit that an
    // unexercised checker is not a passing checker, so a dim that never ran is
    // reported rather than quietly counted as fine.
    bit dim_seen [1:N];

    function new(string name = "latency_checker");
        super.new(name);
        foreach (dim_seen[i]) dim_seen[i] = 0;
    endfunction

    // C.6: latency = 2N. This is the whole contract. The pipeline register of
    // C.1 is absorbed into the 2N - never written as 2N-1+1.
    static function int unsigned expected_latency(int dim);
        expected_latency = 2*dim;
    endfunction

    // Returns 1 on pass. measured is the cycle count from the first
    // ACTIVATION_FLOW cycle to the cycle done asserts.
    virtual function bit check(int dim, int unsigned measured);
        int unsigned exp = expected_latency(dim);

        checked++;
        if (dim >= 1 && dim <= N) dim_seen[dim] = 1;

        if (measured == exp) begin
            `uvm_info("LAT_CHK",
                $sformatf("dim=%0d: latency %0d cycles == 2N (%0d)", dim, measured, exp),
                UVM_HIGH)
            return 1;
        end

        violations++;

        // The one-cycle-early case is called out by name in C.6 as the most
        // likely integration mistake on the project, so it gets its own message
        // rather than being folded into a generic mismatch.
        if (measured == exp - 1)
            `uvm_error("LAT_CHK",
                $sformatf({"dim=%0d: latency %0d cycles is 2N-1, expected 2N (%0d). ",
                           "This is the 2N-1 bug named in C.6 - the pipeline register ",
                           "of C.1 is not accounted for in the FSM done timing."},
                          dim, measured, exp))
        else
            `uvm_error("LAT_CHK",
                $sformatf("dim=%0d: latency %0d cycles, contract requires exactly 2N (%0d)",
                          dim, measured, exp))

        return 0;
    endfunction

    virtual function void report(uvm_report_object log);
        `uvm_info("LAT_CHK",
            $sformatf("checked %0d pass(es), %0d violation(s) of the 2N contract",
                      checked, violations), UVM_LOW)

        for (int d = 1; d <= N; d++)
            if (!dim_seen[d])
                `uvm_warning("LAT_CHK",
                    $sformatf({"dim=%0d never reached the latency checker - C.6 requires ",
                               "all of N=1..4 be verified, and C.7 requires the checker ",
                               "be shown to fire"}, d))
    endfunction

endclass : latency_checker



class mmu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(mmu_scoreboard)

    localparam int N = 4;

    // Register offsets (spec B.2)
    localparam logic [3:0] DIM_REG    = 4'h0;
    localparam logic [3:0] CTRL_REG   = 4'h4;
    localparam logic [3:0] STATUS_REG = 4'h8;

    localparam int CTRL_START_BIT = 0;

    uvm_analysis_imp_axi  #(axi_txn,  mmu_scoreboard) axi_imp;
    uvm_analysis_imp_data #(data_txn, mmu_scoreboard) data_imp;

    latency_checker lat_chk;

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

    function new(string name, uvm_component parent);
        super.new(name, parent);
        axi_imp  = new("axi_imp",  this);
        data_imp = new("data_imp", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        lat_chk = latency_checker::type_id::create("lat_chk");
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


    // Data observations - latency check, then predict and compare.

    virtual function void write_data(data_txn t);
        longint unsigned exp_wide [N];
        int signed       exp      [N];
        bit              ovf      [N];
        bit              pass_ok = 1;
        int              dim = int'(t.dim);

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

        // C.5/C.6: the latency check is part of the per-transaction check.
        void'(lat_chk.check(dim, t.latency));

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

        predict(t, dim, exp, exp_wide, ovf);

        for (int c = 0; c < dim; c++) begin
            if (ovf[c]) begin
                overflows++;
                `uvm_warning("SB_DATA",
                    $sformatf("column %0d: reference product %0d does not fit int32",
                              c, longint'(exp_wide[c])))
            end
            if (t.results[c] !== exp[c]) begin
                pass_ok = 0;
                mismatches++;
                `uvm_error("SB_DATA",
                    $sformatf("dim=%0d column %0d: got %0d, expected %0d",
                              dim, c, t.results[c], exp[c]))
            end
        end

        // Columns outside the active dimension must drain zero, not stale data
        // from a previous, larger pass. A.7 calls accumulator leakage between
        // back-to-back runs out explicitly.
        for (int c = dim; c < N; c++) begin
            if (t.results[c] !== 0) begin
                pass_ok = 0;
                mismatches++;
                `uvm_error("SB_DATA",
                    $sformatf("dim=%0d column %0d is outside the active array but drained %0d, expected 0",
                              dim, c, t.results[c]))
            end
        end

        passes_checked++;
        if (pass_ok)
            `uvm_info("SB_DATA", $sformatf("dim=%0d pass matched reference", dim), UVM_MEDIUM)
    endfunction


    // Reference model.
    //
    // Weights are stationary: W[r][c] sits in PE[r][c]. Activation row r enters
    // from the left and flows right; column c's partial sums flow down through
    // accum_in/accum_out and accumulate. A.9 pins the output down - results is
    // "literally the bottom row's accum_out bus (N x 32), not a separate
    // reduction step", with row 0's accum_in tied to 0 - so results[c] is the
    // column-c dot product:
    //   O_k[c] = sum over r of A[r][k] * W[r][c]
    // for whichever activation column k is draining at that moment.
    //
    // UNRESOLVED AGAINST SPEC - which k is on the bus at done. The form above
    // is derived from A.9, but not the sampling instant: A.7 says the output
    // buffer holds "the correct int32 matrix-multiply result", which for an NxN
    // by NxN product is NxN values, while mmu_if exposes results[] as a single
    // N-wide vector and A.8's 32-bit read_data port is absent from mmu_if
    // entirely. k = dim-1 below (the last column to drain, sampled at done) is
    // an assumption. If the intent is that output_buffer accumulates all N
    // vectors and the testbench reads them back over read_data, then mmu_if and
    // this model both need revisiting.

    virtual function void predict(data_txn   t,
                                  int        dim,
                                  output int signed       exp      [N],
                                  output longint unsigned exp_wide [N],
                                  output bit              ovf      [N]);
        localparam longint INT32_MIN = -(64'sd1 << 31);
        localparam longint INT32_MAX =  (64'sd1 << 31) - 1;

        int k_last = dim - 1;

        for (int c = 0; c < N; c++) begin
            longint signed acc = 0;

            if (c < dim) begin
                for (int r = 0; r < dim; r++)
                    acc += longint'(t.activations[r][k_last]) * longint'(t.weights[r][c]);
            end

            // A.2 proves this cannot overflow at N<=4 (worst case 4*127*127 =
            // 64,516), and Proof 1 formalizes it - but dim is a knob and this
            // model outlives the 4x4 build, so the check stays.
            ovf[c]      = (acc > INT32_MAX) || (acc < INT32_MIN);
            exp_wide[c] = longint unsigned'(acc);
            exp[c]      = int'(acc[31:0]);
        end
    endfunction


    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        if (passes_checked == 0) begin
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

        lat_chk.report(this);

        `uvm_info("SB_REPORT",
            $sformatf({"checked %0d pass(es): %0d mismatch(es), %0d dim conflict(s), ",
                       "%0d overflow warning(s), %0d illegal dim write(s), %0d illegal start(s)"},
                      passes_checked, mismatches, dim_conflicts, overflows,
                      illegal_dims, illegal_starts),
            UVM_LOW)
    endfunction

endclass : mmu_scoreboard

`endif // MMU_SCOREBOARD_SV
