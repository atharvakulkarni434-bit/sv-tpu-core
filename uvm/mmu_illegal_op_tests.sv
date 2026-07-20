//==============================================================================
// File: mmu_illegal_op_tests.sv
// Project: sv-tpu-core
// Category: 3.5 - Illegal Operation / Error Injection
//
// Implements the four Category 5 test cases from FULL_UVMVerification_PLAN:
//   TC-023 - Write to Read-Only STATUS_REG
//   TC-024 - START Asserted Before DIM_REG Written (dim=0)
//   TC-025 - Double START (Second START Mid-Computation)
//   TC-026 - Invalid Dimension (DIM_REG > 4)
//
// Every Category 5 test: drive a violation, confirm NO output / NO spurious
// done during the illegal window (the scoreboard's negative path also guards
// this), then run a clean legal pass and let the scoreboard verify it against
// the golden model - proving internal state survived the illegal stimulus.
//
// ---------------------------------------------------------------------------
// IMPORTANT design facts these tests are written against (verified in RTL):
//
//  * mmu_controller START handshake is LEVEL-HELD. `start` = CTRL_REG.ctrl_q,
//    which does NOT self-clear. The FSM only returns DONE -> IDLE when start
//    is dropped (`DONE: if (!start) next_state = IDLE`). So a legal pass MUST
//    de-assert start (CTRL_REG <= 0) after done, or the FSM stays parked in
//    DONE and the data monitor re-arms on the still-high start. Every pass
//    below follows: write DIM -> start=1 -> wait done -> start=0 -> wait IDLE.
//
//  * An illegal dim (0 or 5..7) makes dim_legal=0, so the FSM refuses the
//    start and stays in IDLE - no done, no result (matches TC-024/TC-026).
//    We still de-assert start afterward to leave a clean IDLE for recovery.
//
//  * `flow_en` is NOT relied on here. It is an internal mmu_controller signal
//    and is not part of the start/done/dim_n observability taps on mmu_if, so
//    TC-025 times its second-START injection off `start` + the FSM's known
//    latency (1 cyc WEIGHT_LOAD + 1 cyc PE_CLEAR, then 2N of ACTIVATION_FLOW).
//
// Handles depended on (names verified against the TB):
//   env.reg_model            - mmu_reg_block (RAL), public member of mmu_env
//   env.axi_agt.sequencer    - uvm_sequencer#(axi_txn)
//   env.data_agt.sequencer   - uvm_sequencer#(data_txn)
//   mmu_matmul_seq           - clean legal pass (num_txns, fixed_dim knobs)
//   vif.clk / vif.done       - raw interface nets used for negative checks
//
// A1/A2 "should-fire" handshake injections (plan Section 8) - the awvalid-drop
// on TC-023 and awvalid-without-wvalid on TC-025 - live in the TC-035 driver
// hooks, not here; flagged inline where they attach.
//==============================================================================

`ifndef MMU_ILLEGAL_OP_TESTS_SV
`define MMU_ILLEGAL_OP_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_env.sv"
`include "mmu_sequences.sv"


//------------------------------------------------------------------------------
// axi_reg_write_seq - one raw AXI-Lite register write, addr/data pinned by the
// test. Used for the STATUS_REG physical write in TC-023: the RAL model refuses
// to drive a bus write to an RO register, so to exercise the hardware's RO
// enforcement we drive the transaction directly through the AXI agent. addr
// 0x8 is a legal offset, so axi_txn::c_addr is untouched.
//------------------------------------------------------------------------------
class axi_reg_write_seq extends uvm_sequence #(axi_txn);
    `uvm_object_utils(axi_reg_write_seq)

    rand logic [3:0]  wr_addr;
    rand logic [31:0] wr_data;

    function new(string name = "axi_reg_write_seq");
        super.new(name);
    endfunction

    virtual task body();
        axi_txn t = axi_txn::type_id::create("t");
        start_item(t);
        if (!t.randomize() with {
                rw   == axi_txn::WRITE;
                addr == wr_addr;
                data == wr_data;
            })
            `uvm_fatal(get_type_name(), "axi_reg_write_seq randomize failed")
        finish_item(t);
    endtask
endclass : axi_reg_write_seq


//==============================================================================
// mmu_illegal_op_base_test - shared scaffolding for the Category 5 tests.
//
// If the project already has a common base test, reparent these four tests onto
// it and delete this class; the tests only need a built env, the vif, and the
// reusable tasks below.
//==============================================================================
class mmu_illegal_op_base_test extends uvm_test;
    `uvm_component_utils(mmu_illegal_op_base_test)

    mmu_env        env;
    virtual mmu_if vif;
    uvm_status_e   status;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = mmu_env::type_id::create("env", this);

        // tb_top publishes the vif globally, so the test can read the done tap
        // directly for its negative checks.
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal(get_type_name(), "virtual interface 'vif' not found in config_db")
    endfunction

    // ---- register-write helpers (RAL -> AXI adapter) ------------------------

    virtual task write_dim(int unsigned n);
        env.reg_model.DIM_REG.write(status, n);
        if (status != UVM_IS_OK)
            `uvm_warning(get_type_name(), $sformatf("DIM_REG.write(%0d) status=%s", n, status.name()))
    endtask

    // CTRL_REG start is level-held (see file header). assert_start raises it;
    // clear_start drops it so the FSM can complete DONE -> IDLE.
    virtual task assert_start();
        env.reg_model.CTRL_REG.write(status, 32'h1);
        if (status != UVM_IS_OK)
            `uvm_warning(get_type_name(), $sformatf("CTRL_REG.write(1) status=%s", status.name()))
    endtask

    virtual task clear_start();
        env.reg_model.CTRL_REG.write(status, 32'h0);
        if (status != UVM_IS_OK)
            `uvm_warning(get_type_name(), $sformatf("CTRL_REG.write(0) status=%s", status.name()))
    endtask

    virtual function bit status_done();
        uvm_reg_data_t val;
        // STATUS_REG is a read-through of the live `done` net (declared volatile),
        // so always read; never trust the RAL mirror.
        env.reg_model.STATUS_REG.read(status, val);
        return val[0];
    endfunction

    // ---- interface-tap helpers ----------------------------------------------

    // Assert done stays low for a fixed illegal-operation window. Redundant
    // with the scoreboard's negative check, on purpose.
    virtual task expect_no_done(int unsigned cycles, string ctx);
        repeat (cycles) begin
            @(posedge vif.clk);
            if (vif.done === 1'b1)
                `uvm_error(get_type_name(),
                    $sformatf("spurious done asserted during illegal-op window (%s)", ctx))
        end
    endtask

    virtual task wait_done(int unsigned timeout = 300);
        int unsigned c = 0;
        while (vif.done !== 1'b1) begin
            @(posedge vif.clk);
            if (++c > timeout) begin
                `uvm_error(get_type_name(), "done never asserted for a computation expected to complete")
                return;
            end
        end
    endtask

    // After clear_start, the FSM leaves DONE and done drops - confirms IDLE.
    virtual task wait_idle(int unsigned timeout = 50);
        int unsigned c = 0;
        while (vif.done !== 1'b0) begin
            @(posedge vif.clk);
            if (++c > timeout) begin
                `uvm_error(get_type_name(), "done never de-asserted after clearing START (FSM stuck in DONE)")
                return;
            end
        end
    endtask

    // ---- one clean, legal N x N computation ---------------------------------
    //
    // Forks the legal data-plane pass and, once the data driver is presenting
    // weights, kicks the FSM (DIM then START), waits for done, then DROPS start
    // so the FSM returns to IDLE. The multi-cycle AXI writes give the driver
    // time to present weights before WEIGHT_LOAD latches them, so B1
    // (no_skip_weight_load) sees a legal transition. The scoreboard verifies
    // the result against the golden model; this task only orchestrates.
    virtual task run_legal_pass(int unsigned n);
        mmu_matmul_seq legal_seq;
        legal_seq = mmu_matmul_seq::type_id::create("legal_seq");
        if (!legal_seq.randomize() with { num_txns == 1; fixed_dim == n; })
            `uvm_fatal(get_type_name(), "legal_seq randomize failed")

        fork
            legal_seq.start(env.data_agt.sequencer);
            begin
                repeat (2) @(posedge vif.clk);   // let the driver present weights first
                write_dim(n);
                assert_start();
                wait_done();
                clear_start();
                wait_idle();
            end
        join

        `uvm_info(get_type_name(),
            $sformatf("legal %0dx%0d pass completed and handed to scoreboard", n, n), UVM_LOW)
    endtask

endclass : mmu_illegal_op_base_test


//==============================================================================
// TC-023 - Write to Read-Only STATUS_REG
//
// Attempt to write STATUS_REG (RO). The RAL model flags it at the model layer;
// a raw AXI write physically drives the same transaction to test hardware
// enforcement. axi_lite_slave keeps NO storage for STATUS_REG (read-through of
// live `done`), so the write cannot change its value. Confirm done unchanged
// (0 -> 0, IDLE), no output appears, then a legal pass proves no corruption.
//
// Coverage: cp_error_type = status_reg_write
// Assertions (positive mode): axi_awvalid_stable, no_spurious_done
// A1 should-fire add-on: the deliberate awvalid drop one cycle before awready
//   belongs to the TC-035 handshake-injection driver hook (flagged, not here).
//==============================================================================
class tc023_status_ro_write extends mmu_illegal_op_base_test;
    `uvm_component_utils(tc023_status_ro_write)

    function new(string name = "tc023_status_ro_write", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        bit done_before, done_after;
        axi_reg_write_seq wr;

        phase.raise_objection(this, "TC-023 running");

        done_before = status_done();   // IDLE => expect 0
        `uvm_info(get_type_name(), $sformatf("STATUS.done before illegal write = %0b", done_before), UVM_LOW)

        // Model-layer: RAL refuses to drive an RO field and reports it. A benign
        // RAL warning here is expected, not a failure.
        env.reg_model.STATUS_REG.write(status, 32'hDEAD_BEEF);
        `uvm_info(get_type_name(),
            $sformatf("RAL STATUS_REG.write returned status=%s (RO refusal expected)", status.name()), UVM_LOW)

        // Hardware: physically drive the write onto the bus.
        wr = axi_reg_write_seq::type_id::create("wr");
        if (!wr.randomize() with { wr_addr == 4'h8; wr_data == 32'hDEAD_BEEF; })
            `uvm_fatal(get_type_name(), "STATUS_REG raw write randomize failed")
        wr.start(env.axi_agt.sequencer);

        expect_no_done(12, "STATUS_REG RO write");

        done_after = status_done();
        if (done_after !== done_before)
            `uvm_error(get_type_name(),
                $sformatf("STATUS.done changed across illegal write: %0b -> %0b", done_before, done_after))
        else
            `uvm_info(get_type_name(),
                $sformatf("STATUS.done unchanged (%0b) - RO enforcement holds", done_after), UVM_LOW)

        run_legal_pass(4);   // internal state must be intact

        phase.drop_objection(this, "TC-023 done");
    endtask
endclass : tc023_status_ro_write


//==============================================================================
// TC-024 - START Asserted Before DIM_REG Written (dim=0)
//
// Skip writing DIM_REG (reset 0) and assert START. dim=0 is illegal; dim_legal=0
// so the FSM refuses the start and stays IDLE - no hang, no done, no output.
// Drop start, then a valid DIM + START must compute correctly.
//
// Coverage: cp_error_type = premature_start
// Assertions: no_spurious_done; FSM no-deadlock (returns to / stays IDLE)
//
// Relies on DIM_REG being at reset 0 at test start (tb_top resets once, each
// test is its own sim). If ever chained after other stimulus in one sim, write
// DIM=0 explicitly first.
//==============================================================================
class tc024_premature_start_dim0 extends mmu_illegal_op_base_test;
    `uvm_component_utils(tc024_premature_start_dim0)

    function new(string name = "tc024_premature_start_dim0", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "TC-024 running");

        `uvm_info(get_type_name(), "asserting START with DIM_REG unwritten (dim=0)", UVM_LOW)

        assert_start();                 // START with dim=0, no DIM write
        expect_no_done(30, "premature START, dim=0");
        clear_start();                  // leave a clean IDLE for recovery

        run_legal_pass(4);              // recovery must succeed

        phase.drop_objection(this, "TC-024 done");
    endtask
endclass : tc024_premature_start_dim0


//==============================================================================
// TC-025 - Double START (Second START Mid-Computation)
//
// Start a legal 4x4 computation, then assert START a second time while the
// first is mid-flight. The DUT must ignore it: the first computation completes,
// done asserts once (2N=8 cycles after its flow began, checked by the
// scoreboard latency_checker), and exactly one correct result is produced.
//
// NOTE on this design: START is LEVEL-HELD. Because start stays high for the
// whole pass, the FSM only samples it in IDLE/DONE, so a second CTRL_REG=1
// write mid-computation is a redundant assertion the FSM structurally ignores.
// The value of the test is confirming that second bus write completes and
// produces NO second done / NO extra result. Timing is off `start` + the known
// FSM latency (WEIGHT_LOAD + PE_CLEAR then ACTIVATION_FLOW), not flow_en.
//
// A2 should-fire add-on: driving the second START's awvalid without wvalid
//   belongs to the TC-035 handshake-injection hook; here it is a well-formed
//   write.
//==============================================================================
class tc025_double_start extends mmu_illegal_op_base_test;
    `uvm_component_utils(tc025_double_start)

    function new(string name = "tc025_double_start", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        mmu_matmul_seq legal_seq;

        phase.raise_objection(this, "TC-025 running");

        legal_seq = mmu_matmul_seq::type_id::create("legal_seq");
        if (!legal_seq.randomize() with { num_txns == 1; fixed_dim == 4; })
            `uvm_fatal(get_type_name(), "legal_seq randomize failed")

        fork
            legal_seq.start(env.data_agt.sequencer);
            begin
                repeat (2) @(posedge vif.clk);
                write_dim(4);
                assert_start();                       // first (legal) START

                // Land inside ACTIVATION_FLOW: after start latches, ~2 cycles
                // of WEIGHT_LOAD+PE_CLEAR, then the 2N flow window. A few extra
                // cycles here put the second write squarely in the flow.
                repeat (5) @(posedge vif.clk);
                `uvm_info(get_type_name(),
                    "asserting second START mid-computation (level-held; FSM must ignore)", UVM_LOW)
                assert_start();                       // second START - ignored

                wait_done();                          // first computation completes (once)
                clear_start();
                wait_idle();
            end
        join

        // With start now low the FSM cannot restart; a short window confirms no
        // phantom second done. The scoreboard also flags any second result.
        expect_no_done(6, "post-completion tail after double START");

        phase.drop_objection(this, "TC-025 done");
    endtask
endclass : tc025_double_start


//==============================================================================
// TC-026 - Invalid Dimension (DIM_REG > 4)
//
// Write an out-of-range dimension (5..7 - the 3-bit DIM_REG field is left
// unconstrained so the value reaches the DUT) and assert START. Legal range is
// 1..4, so dim_legal=0 and the FSM refuses the start: no output, no done. Drop
// start, then a legal dimension must compute correctly.
//
// Coverage: cp_error_type (invalid dimension); no_spurious_done.
//==============================================================================
class tc026_invalid_dim extends mmu_illegal_op_base_test;
    `uvm_component_utils(tc026_invalid_dim)

    // Which illegal dimension to drive (5..7).
    int unsigned bad_dim = 5;

    function new(string name = "tc026_invalid_dim", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "TC-026 running");

        `uvm_info(get_type_name(), $sformatf("driving invalid DIM_REG = %0d, then START", bad_dim), UVM_LOW)

        write_dim(bad_dim);
        assert_start();
        expect_no_done(30, $sformatf("invalid dim=%0d", bad_dim));
        clear_start();

        run_legal_pass(4);              // recovery must succeed

        phase.drop_objection(this, "TC-026 done");
    endtask
endclass : tc026_invalid_dim

`endif // MMU_ILLEGAL_OP_TESTS_SV