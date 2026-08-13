// =============================================================================
// File:        mmu_cat5_tests.sv
// Description: Category 5 — illegal operation tests (TC-023 to TC-026).
//              Each test does ONE illegal thing:
//                TC-023: writes the read-only STATUS_REG
//                TC-024: presses start with no matrix size set
//                TC-025: presses start a second time mid-computation
//                TC-026: sets an out-of-range matrix size (5, max is 4)
//              After the illegal thing, each test runs ONE normal legal
//              computation, to prove nothing got corrupted. The scoreboard
//              already catches all 4 violations just by watching the bus —
//              this file only has to drive the bad transaction, nothing
//              checks anything here.
// =============================================================================

`ifndef MMU_CAT5_TESTS_SV               // if this file hasn't been pulled in yet
`define MMU_CAT5_TESTS_SV               // mark it as pulled in, so it can't double-include

`include "uvm_macros.svh"     // gives us uvm_error, uvm_fatal, etc.
import uvm_pkg::*;             // gives us UVM's base classes
`include "mmu_base_test.sv"    // the shared test class we build on top of
`include "mmu_sequences.sv"    // the shared "run a legal matmul" helper


// Sends one raw write straight to the bus, skipping the register model.
// We need this to write STATUS_REG on purpose, since it's read-only.
class mmu_illegal_write_seq extends uvm_sequence #(axi_txn);
    `uvm_object_utils(mmu_illegal_write_seq)   // required boilerplate — registers this class with UVM

    logic [3:0]  addr  = 4'h8;          // which register address to write to (0x8 = STATUS_REG)
    logic [31:0] wdata = 32'hDEAD_BEEF; // the value to write — meaningless, chip should ignore it

    function new(string name = "mmu_illegal_write_seq");
        super.new(name);   // required boilerplate — hands the name up to UVM's base class
    endfunction

    virtual task body();
        // create one blank transaction object to fill in and send
        axi_txn tr = axi_txn::type_id::create("tr");

        // tells the sequencer "a transaction is coming, get ready to receive it"
        start_item(tr);

        tr.rw   = axi_txn::WRITE;   // this transaction is a WRITE, not a READ
        tr.addr = addr;              // fill in the address (0x8, STATUS_REG)
        tr.data = wdata;             // fill in the value being written
        tr.strb = 4'hF;              // "all 4 bytes count" — the normal setting for any full write

        // sends the completed transaction — this is what actually makes the
        // driver pick it up and drive it onto the real AXI bus
        finish_item(tr);
    endtask
endclass : mmu_illegal_write_seq


// TC-023's write is EXPECTED to trigger a scoreboard error. This class
// catches that one error and downgrades it so it doesn't fail the test.
// (STATUS_REG violations get an unconditional uvm_error in the scoreboard,
// unlike DIM_REG/CTRL_REG violations, which are just silently counted —
// TC-023 is the only test that needs a catcher because of that.)
class tc_023_status_write_catcher extends uvm_report_catcher;
    `uvm_object_utils(tc_023_status_write_catcher)

    function new(string name = "tc_023_status_write_catcher");
        super.new(name);
    endfunction

    // checks if `sub` appears anywhere inside `s`
    protected function bit contains(string s, string sub);
        int sl = s.len();   // how many characters are in the full string `s`
        int bl = sub.len(); // how many characters are in the piece we're looking for

        if (bl == 0) return 1;   // an empty search string always counts as "found"
        if (bl > sl) return 0;   // if what we're looking for is longer than s, it can't fit

        // slide a window of length bl across s, one position at a time,
        // checking if that window matches sub
        for (int i = 0; i <= sl - bl; i++)
            if (s.substr(i, i + bl - 1) == sub) return 1;   // cut out a piece and compare it

        return 0;   // checked every position, never matched
    endfunction

    // runs automatically on every message in the test — only acts on the one we expect
    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id()       == "SB_AXI"  &&
            contains(get_message(), "STATUS_REG") &&
            contains(get_message(), "read-only")) begin
            `uvm_info("TC023_CATCHER", "expected STATUS_REG write - demoting to INFO", UVM_LOW)
            set_severity(UVM_INFO);   // downgrade so it doesn't count as a real failure
        end
        return THROW;   // let the message continue on normally either way
    endfunction
endclass : tc_023_status_write_catcher


// TC-023 — write to the read-only STATUS_REG, then run one clean pass.
class tc_023_status_reg_write_test extends mmu_base_test;
    `uvm_component_utils(tc_023_status_reg_write_test)

    tc_023_status_write_catcher status_catcher;   // holds our "ignore this error" helper

    function new(string name = "tc_023_status_reg_write_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // creates the catcher and starts it watching BEFORE the illegal write happens
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        status_catcher = tc_023_status_write_catcher::type_id::create("status_catcher");
        uvm_report_cb::add(null, status_catcher);   // null = attach to every reporter in the test
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_illegal_write_seq ill;
        mmu_matmul_seq        seq;
        phase.raise_objection(this);   // "keep the test alive, I'm not done yet"

        // illegal: write STATUS_REG directly
        ill = mmu_illegal_write_seq::type_id::create("ill");
        ill.addr  = 4'h8;
        ill.wdata = 32'h0000_0001;
        ill.start(env.axi_agt.sequencer);

        // recovery check: one normal legal 4x4 run
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);   // "okay, now I'm done"
    endtask
endclass : tc_023_status_reg_write_test


// TC-024 — press start with dim never written (stays 0, illegal).
// (No catcher needed here — this violation is just silently counted by the
// scoreboard, not raised as a uvm_error, so there's nothing to downgrade.)
class tc_024_premature_start_test extends mmu_base_test;
    `uvm_component_utils(tc_024_premature_start_test)

    function new(string name = "tc_024_premature_start_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        uvm_status_e   status;
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        // illegal: start, dim still 0
        reg_model.CTRL_REG.write(status, 1);
        if (status != UVM_IS_OK) `uvm_error(get_type_name(), "premature start write failed")
        reg_model.CTRL_REG.write(status, 0);

        // recovery check
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_024_premature_start_test


// TC-025 — press start a second time while the first run is still going (illegal, ignored).
//
// THE PROBLEM this test solves: we need real weight/activation data to be
// mid-stream (not fully sent, not not-started) when we press start a second
// time — otherwise there's no real computation for the second start to
// interrupt. That's why this test can't just do things one-at-a-time; the
// data-sending and register-writing have to overlap in time.
class tc_025_double_start_test extends mmu_base_test;
    `uvm_component_utils(tc_025_double_start_test)

    function new(string name = "tc_025_double_start_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        // A shared "doorbell" — some OTHER piece of code (the data driver,
        // in data_agent.sv) will ring it once the data is actually ready.
        // We need this because writing the control registers too early
        // (before data is staged) would start a run with incomplete data —
        // and guessing a fixed delay instead would make the test flaky.
        uvm_event      stim_staged = uvm_event_pool::get_global("mmu_stim_staged");

        uvm_status_e   status;   // holds whether each register write actually succeeded
        mmu_matmul_seq seq;      // the sequence that streams weight/activation data
        data_txn       tr;       // will hold the real matrix data, once we get it
        uvm_object     obj;      // a generic box the doorbell's data arrives in
        phase.raise_objection(this);   // "keep the test alive, I'm not done yet"

        // Build a normal legal 4x4 data sequence — same as any other test.
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")

        // Launch the data-streaming task in the background (fork/join_none),
        // instead of waiting for it to fully finish, so we're free to write
        // the control registers on our own timeline while it's still going.
        fork
            seq.start(env.data_agt.sequencer);
        join_none

        // Pause here — not for a fixed amount of time, but until the
        // data driver actually rings the doorbell saying it's ready.
        stim_staged.wait_ptrigger();

        // grab the data attached to the trigger — comes back as a generic object
        obj = stim_staged.get_trigger_data();

        // done with this firing — reset so the event can be used again later
        stim_staged.reset();

        // convert obj into a data_txn (what we know it actually is); stop hard if that fails
        if (!$cast(tr, obj)) `uvm_fatal(get_type_name(), "bad stim_staged trigger data")

        // --- legal start #1: begin the real, legitimate computation ---
        reg_model.DIM_REG.write(status, tr.dim);
        reg_model.CTRL_REG.write(status, 1);

        // --- THE actual illegal act: press start again, right now, while
        // the computation above is still running. The chip must ignore this. ---
        reg_model.CTRL_REG.write(status, 1);

        // Wait for the FIRST (legal) computation to finish on its own.
        wait_for_pass_done();
        reg_model.CTRL_REG.write(status, 0);   // acknowledge done

        wait_for_idle();          // wait for the FSM to settle back at IDLE
        pass_release.trigger();   // tell the rest of the testbench this pass is over
        wait fork;                 // make sure the background data task finished too

        phase.drop_objection(this);
    endtask
endclass : tc_025_double_start_test


// TC-026 — set dim=5 (fits in 3 bits, but exceeds N=4), then start.
class tc_026_invalid_dim_test extends mmu_base_test;
    `uvm_component_utils(tc_026_invalid_dim_test)

    function new(string name = "tc_026_invalid_dim_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        uvm_status_e   status;
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        // illegal: set an out-of-range size, then press start
        reg_model.DIM_REG.write(status, 3'd5);   // 5 is too big — max legal size is 4
        reg_model.CTRL_REG.write(status, 1);      // start anyway — chip should refuse to run
        reg_model.CTRL_REG.write(status, 0);      // release start

        // recovery check — run_matmul sets its OWN legal dim (4) before it
        // starts, so the earlier illegal "5" doesn't carry over into this pass
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_026_invalid_dim_test

`endif // MMU_CAT5_TESTS_SV
