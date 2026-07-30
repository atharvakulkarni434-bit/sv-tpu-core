//==============================================================================
// File: data_agent.sv
// Project: sv-tpu-core 
// Date: 2026-07-08
//
// Description:
//   Data-plane agent. Drives int8 activation columns into the systolic array,
//   one column per cycle during ACTIVATION_FLOW (spec A.1/A.6), drives the int8
//   weight matrix during WEIGHT_LOAD, and monitors the int32 results draining
//   to the output buffer.
//
//   The diagonal wavefront skew is applied in RTL by skew_buffer.sv, not here.
//   C.1 places the stagger on the design side, and skewing on both sides would
//   delay row r twice over.
//
// Features:
//   - data_txn item carrying NxN activation + weight matrices and dim N
//   - Driver: weight load, then N unskewed columns gated on flow_en
//   - Monitor: captures stimulus, results, and the C.6 latency window
//   - UVM_ACTIVE/UVM_PASSIVE aware agent wrapper
//   - dim constrained to 1..N (DIM_REG legal range, spec B.4)
//
// BUG FIX (this pass): back-to-back multi-transaction runs (TC-011/TC-012,
// num_txns==10) hung. Root cause: the driver's forever loop and
// mmu_base_test::run_matmul's per-pass register handshake are two
// independently-paced forked processes that only agreed on ordering by
// accident for num_txns==1. Nothing stopped the driver from calling
// get_next_item() for transaction i+1, staging its weights, and
// re-triggering mmu_stim_staged WHILE run_matmul was still in the middle of
// releasing CTRL_REG and polling STATUS_REG back to idle for transaction i.
// Since run_matmul calls stim_staged.reset() immediately after consuming
// each trigger, a same-time/early re-trigger for i+1 could be wiped by
// run_matmul's own reset() for pass i before run_matmul ever got back
// around to wait_ptrigger() for pass i+1 - a classic lost-wakeup deadlock,
// which is exactly what the hang looked like (STATUS_REG reads stop
// appearing in the log entirely once this happens).
//
// FIX: a second, symmetric handshake event - mmu_pass_release. The driver
// now waits on it before starting every transaction after the first, and
// run_matmul triggers it only after wait_for_idle() confirms the previous
// pass has fully retired (CTRL_REG written back to 0, STATUS_REG.done back
// to 0). This makes the two sides a proper ping-pong: the driver can never
// get further ahead than "stimulus for transaction i+1 is staged and
// waiting", and run_matmul can never have a trigger clobbered out from
// under it, regardless of relative AXI-Lite vs. data-plane timing.
//
// Ownership of reset() matters here and mirrors mmu_stim_staged exactly:
// the CONSUMER of each event calls reset(), after it wakes up and consumes
// the trigger - never the producer, immediately after triggering. A
// trigger()-then-reset() pair with no intervening blocking statement in the
// producer is its own race (nothing guarantees the consumer's process has
// actually resumed and observed the triggered state before the producer's
// very next statement clears it), so pass_release is only ever reset()
// here, in data_driver, after wait_ptrigger() returns - never in
// run_matmul right after trigger().
//==============================================================================

`ifndef DATA_AGENT_SV
`define DATA_AGENT_SV

// UVM base classes and the `uvm_* macros must be visible in this compilation
// unit before the classes below.
`include "uvm_macros.svh"
import uvm_pkg::*;


// Transaction item - one full matrix-multiply payload: an NxN activation
// matrix and an NxN weight matrix for a given dimension N.

class data_txn extends uvm_sequence_item;

    localparam int N = 4;

    // --- inside class data_txn, replace the results field declaration: ---

    rand int unsigned            dim;                 // active N (1..4)
    rand logic signed [7:0]      activations [N][N];  // int8 A matrix
    rand logic signed [7:0]      weights     [N][N];  // int8 B matrix
    // WIDENED: full NxN result matrix, matching mmu_if.sv's `results` port
    // (was `results [N]`, a single vector — no longer matches the DUT/if).
    logic signed [31:0]          results     [N][N];

    // Weight-poisoning hooks (driven by weight_poison_seq in mmu_sequences.sv).
    // The array is weight-stationary, so a weight change after WEIGHT_LOAD is a
    // protocol violation the DUT must either reject or visibly corrupt - either
    // way the scoreboard's clean-weight prediction should no longer match.
    rand bit                     poison_en;              // corrupt weights mid-feed
    rand int unsigned            poison_cycle;           // activation column to corrupt on
    rand logic signed [7:0]      poison_weights [N][N];  // replacement matrix

    constraint c_dim { dim inside {[1:N]}; }

    // Poison lands on one of the dim activation columns, never during
    // WEIGHT_LOAD - the point is to mutate weights the array has already
    // latched and is mid-way through computing on.
    constraint c_poison_cycle { poison_cycle inside {[0 : dim-1]}; }

    // Off unless a sequence asks for it, so existing sequences are unaffected.
    constraint c_poison_default { soft poison_en == 1'b0; }

    // C.6 observation: cycles from the first ACTIVATION_FLOW cycle (flow_en
    // high) to done. Filled in by the monitor; checked by mmu_latency_checker
    // in uvm/mmu_cat6_tests.sv against the ratified dim+5 contract.
    int unsigned latency;

    `uvm_object_utils_begin(data_txn)
        `uvm_field_int(dim, UVM_ALL_ON)
        `uvm_field_int(poison_en, UVM_ALL_ON)
        `uvm_field_int(poison_cycle, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "data_txn");
        super.new(name);
    endfunction

endclass : data_txn



// Driver - feeds weights then skewed activation columns into the array.

class data_driver extends uvm_driver #(data_txn);
    `uvm_component_utils(data_driver)

    virtual mmu_if vif;

    // Handshake with the test's pass conductor (mmu_base_test::run_matmul).
    //
    // WHY THIS EXISTS: the array is weight-stationary, and mmu_controller.sv
    // enters WEIGHT_LOAD the cycle after it sees CTRL_REG.start. The weight
    // matrix therefore has to be sitting on the bus BEFORE software presses
    // start - there is no handshake on the data plane that would let the DUT
    // wait for it. Previously the tests wrote CTRL_REG first and only then
    // called seq.start(), so WEIGHT_LOAD's first edges latched an undriven
    // ('x) weight bus. This event lets the driver tell the test "stimulus is
    // staged, you may press start now", which removes the race entirely.
    //
    // The triggered data is the data_txn itself, so the test can read tr.dim
    // and program DIM_REG for this pass (the DUT will not leave IDLE unless
    // DIM_REG holds a legal 1..4 - dim travelling only inside data_txn was
    // never enough on its own).
    uvm_event stim_staged;

    // BUG FIX (this pass): the other half of the handshake. run_matmul
    // triggers this once it has released CTRL_REG (written back to 0) and
    // confirmed STATUS_REG.done has returned to 0 for the CURRENT pass. The
    // driver waits on it before staging transaction i+1 (for i >= 1), which
    // is what actually prevents the lost-wakeup deadlock described in the
    // file header - previously nothing paced the driver to run_matmul's
    // per-pass register teardown, so the driver could stage and re-trigger
    // stim_staged for the next transaction while run_matmul was still
    // mid-teardown for the current one.
    uvm_event pass_release;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        stim_staged  = uvm_event_pool::get_global("mmu_stim_staged");
        pass_release = uvm_event_pool::get_global("mmu_pass_release");
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal("DATA_DRV", "virtual interface not set for data_driver")
    endfunction

    task run_phase(uvm_phase phase);
        bit first_txn = 1'b1;

        drive_idle();
        wait (vif.rst_n === 1'b1);
        @(vif.data_cb);
        forever begin
            data_txn tr;

            // BUG FIX: block here (for every transaction after the first)
            // until run_matmul confirms the previous pass has fully retired.
            // This is the back-pressure that was missing - without it the
            // driver could race ahead into stage_weights()/trigger() for
            // transaction i+1 while run_matmul was still releasing CTRL_REG
            // and polling STATUS_REG idle for transaction i, and a same-time
            // stim_staged re-trigger could be wiped by run_matmul's own
            // reset() for the pass it was still finishing.
            if (!first_txn) begin
                pass_release.wait_ptrigger();
                pass_release.reset();   // consumer owns reset() - see mmu_base_test.sv
            end
            first_txn = 1'b0;

            seq_item_port.get_next_item(tr);

            stage_weights(tr);
            stim_staged.trigger(tr);      // test may now program DIM_REG + start
            drive_activations(tr);

            // Hold the weight bus stable until the pass actually completes.
            // The array is weight-stationary and mmu_formal.sv's
            // ap_weight_value assumes the matrix does not move mid-pass, so
            // the next transaction's weights must not land early.
            do @(vif.data_cb); while (!vif.data_cb.done);

            seq_item_port.item_done();
        end
    endtask

    task drive_idle();
        for (int r = 0; r < 4; r++) vif.data_cb.activations[r] <= '0;
    endtask

    // Stage the weight matrix on the bus and hold it. Called BEFORE start is
    // written, so it is stable for every WEIGHT_LOAD edge.
    //
    // Lanes at or beyond the active dim are explicitly zeroed rather than
    // left at whatever the previous (possibly larger) pass wrote.
    // mmu_formal.sv's ap_weight_pad_col / ap_weight_pad_row assume exactly
    // this, so driving stale values there would put the DUT outside the
    // environment its 2x2 correctness proof was discharged in.
    task stage_weights(data_txn tr);
        @(vif.data_cb);
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++)
                vif.data_cb.weights[r][c] <=
                    (r < int'(tr.dim) && c < int'(tr.dim)) ? tr.weights[r][c] : 8'sd0;
        @(vif.data_cb);   // let the value settle on the bus before start
    endtask

    // Feed one full ROW of matrix A into row 0 per cycle (DiP — see
    // systolic_array.sv header point 1). Row 0 is the array's only external
    // entry point; the diagonal interconnect staggers it down to the other
    // rows, so this driver applies no skew of its own (skew_buffer.sv is
    // removed under DiP; see mmu_top.sv).
    //
    // TIMING — the bit that actually matters, and the reason this is worth
    // spelling out. The proven feed protocol is:
    //
    //     flow cycle 0        : zeros    (diagonal chain still filling)
    //     flow cycle 1..dim   : rows 0..dim-1 of A
    //     flow cycle >dim     : zeros    (wavefront draining)
    //
    // i.e. row k lands on flow cycle k+1, NOT flow cycle k. That one-cycle
    // offset is what lines each output row up with the cycle deskew_capture.sv
    // samples it (output row r settles on the bottom accumulator at flow cycle
    // N+r, and deskew's flow_cycle counter lags its own input by one). It is
    // also exactly what mmu_formal.sv assumes — ap_activation_feed_active keys
    // off a flow_cnt with the same one-cycle lag — which is the environment the
    // unbounded 2x2 correctness proof was discharged in.
    //
    // The loop below gets that offset for free from the clocking block: the
    // `do @(vif.data_cb); while (!flow_en)` exits on the edge that SAMPLES
    // flow cycle 0, and data_cb's output skew means the assignment made there
    // is not visible to the DUT until flow cycle 1. Do not "simplify" this by
    // hoisting the first assignment above the wait - that shifts every result
    // row by one and is precisely the bug this reads as guarding against.
    task drive_activations(data_txn tr);
        do @(vif.data_cb); while (!vif.data_cb.flow_en);

        for (int k = 0; k < int'(tr.dim); k++) begin
            for (int c = 0; c < 4; c++)
                vif.data_cb.activations[c] <=
                    (c < int'(tr.dim)) ? tr.activations[k][c] : 8'sd0;

            if (tr.poison_en && k == int'(tr.poison_cycle)) begin
                // Pad lanes stay zero even while poisoning: the point of the
                // test is to corrupt the ACTIVE weight block, not to also push
                // the DUT outside its proven padding assumption.
                for (int r = 0; r < 4; r++)
                    for (int c = 0; c < 4; c++)
                        vif.data_cb.weights[r][c] <=
                            (r < int'(tr.dim) && c < int'(tr.dim)) ? tr.poison_weights[r][c] : 8'sd0;
                `uvm_info("DATA_DRV",
                    $sformatf("poisoned weights on activation feed cycle %0d of %0d", k, tr.dim),
                    UVM_MEDIUM)
            end

            @(vif.data_cb);
        end

        drive_idle();
    endtask

endclass : data_driver



// Monitor - samples the int32 results when the buffer signals valid.

class data_monitor extends uvm_monitor;
    `uvm_component_utils(data_monitor)

    virtual mmu_if vif;
    uvm_analysis_port #(data_txn) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal("DATA_MON", "virtual interface not set for data_monitor")
    endfunction

    // Capture a whole pass - stimulus and result - so the scoreboard can run a
    // reference model instead of only eyeballing the result vector. The bus
    // carries unskewed columns (skew_buffer.sv applies the wavefront inside the
    // DUT), so column k is simply what sits on the bus at flow cycle k.
    // A pass is anchored on ACTIVATION_FLOW, not on `start`.
    //
    // WHY NOT `start`: CTRL_REG.start is a level, not a pulse - the FSM holds
    // DONE until software clears it - so `while (!start)` re-triggers on the
    // same pass. Worse, start rises a full WEIGHT_LOAD + PE_CLEAR ahead of any
    // data being meaningful, which is what made the old monitor sample the
    // weight bus while the driver had not driven it yet. Those samples came
    // back 'x, and the scoreboard's flatten into a 2-state `int` array turned
    // every 'x silently into 0 - that, and nothing else, is why the golden
    // model was asked to multiply by an all-zero weight matrix and answered
    // "expected 0" for all sixteen elements.
    //
    // flow_en's rising edge is the right anchor: by then the weights are
    // staged and stable, dim_n is settled, and it is the origin the latency
    // window and the activation row index are both defined against.
    task run_phase(uvm_phase phase);
        wait (vif.rst_n === 1'b1);
        forever begin
            data_txn tr;
            int t;

            // Exits on the edge that samples flow cycle 0.
            do @(vif.mon_cb); while (!vif.mon_cb.flow_en);

            tr = data_txn::type_id::create("tr");
            tr.dim = vif.mon_cb.dim_n;

            // Weights are stationary and were staged before start, so flow
            // cycle 0 is both valid and CLEAN - a weight_poison_seq mutates
            // them from flow cycle 1 onward, so the scoreboard still predicts
            // from the uncorrupted matrix and the mismatch is the test signal.
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tr.weights[r][c] = vif.mon_cb.weights[r][c];

            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tr.activations[r][c] = 8'sd0;

            // Walk the flow window to done, capturing the activation feed.
            // Row k of A is on the bus during flow cycle k+1 (see
            // data_driver::drive_activations for why the feed is offset by
            // one), so flow cycle t carries row t-1 for t = 1..dim. The old
            // code stored the bus straight into row t, which recorded a
            // leading row of zeros, dropped the last real row, and shifted
            // everything in between.
            t = 0;
            while (!vif.mon_cb.done) begin
                if (t >= 1 && t <= int'(tr.dim))
                    for (int c = 0; c < 4; c++)
                        if (c < int'(tr.dim))
                            tr.activations[t-1][c] = vif.mon_cb.activations[c];
                @(vif.mon_cb);
                t++;
            end

            // Cycles from the first ACTIVATION_FLOW cycle to the cycle done
            // asserts. Measured and reported here; checked against the
            // ratified dim+5 contract by mmu_latency_checker in
            // uvm/mmu_cat6_tests.sv (not checked in this agent directly).
            tr.latency = t;

            // Full NxN result matrix. output_buffer.sv presents the masked
            // result combinationally while done is high, so sampling on the
            // done cycle (which is where the loop above exits) is correct.
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tr.results[r][c] = vif.mon_cb.results[r][c];

            ap.write(tr);
        end
    endtask

endclass : data_monitor



// Agent - sequencer + driver + monitor. Active by default.

class data_agent extends uvm_agent;
    `uvm_component_utils(data_agent)

    uvm_sequencer #(data_txn) sequencer;
    data_driver               driver;
    data_monitor              monitor;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor = data_monitor::type_id::create("monitor", this);
        if (get_is_active() == UVM_ACTIVE) begin
            sequencer = uvm_sequencer#(data_txn)::type_id::create("sequencer", this);
            driver    = data_driver::type_id::create("driver", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass : data_agent

`endif // DATA_AGENT_SV