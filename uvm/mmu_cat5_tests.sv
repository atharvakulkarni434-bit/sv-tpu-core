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

`ifndef MMU_CAT5_TESTS_SV
`define MMU_CAT5_TESTS_SV

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
// catches that one specific error and downgrades it so it doesn't fail
// the test — everything else still works normally.
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
class tc_025_double_start_test extends mmu_base_test;
    `uvm_component_utils(tc_025_double_start_test)

    function new(string name = "tc_025_double_start_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        // grabs a handle to a shared, globally-named event — this is how
        // the data driver (running separately, in the background) tells
        // THIS test "the weight/activation data is fully staged and ready"
        uvm_event      stim_staged = uvm_event_pool::get_global("mmu_stim_staged");

        uvm_status_e   status;   // holds whether each register write actually succeeded
        mmu_matmul_seq seq;      // the sequence that streams weight/activation data
        data_txn       tr;       // will hold the real transaction data once we retrieve it
        uvm_object     obj;      // generic holder, needed to receive the event's attached data
        phase.raise_objection(this);   // "keep the test alive, I'm not done yet"

        // build the data sequence, forcing it to a legal 4x4, single-transaction run
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")

        // Start streaming the weight/activation data out, but DON'T wait for
        // it to finish — fork = launch it, join_none = keep going immediately.
        // We need this running in the background so we're free to write the
        // control registers on our own timeline, in parallel with it.
        fork
            seq.start(env.data_agt.sequencer);
        join_none

        // Pause here until the background data-streaming task signals it's
        // actually ready — this is the payoff of grabbing that event above.
        stim_staged.wait_ptrigger();

        // grab whatever data came attached to that trigger signal
        obj = stim_staged.get_trigger_data();
        stim_staged.reset();   // reset the event so it can be reused again later if needed

        // the trigger data comes back as a generic uvm_object — cast it into
        // the specific data_txn type we actually expect to receive
        if (!$cast(tr, obj)) `uvm_fatal(get_type_name(), "bad stim_staged trigger data")

        // --- legal start #1: the real, legitimate computation begins ---
        reg_model.DIM_REG.write(status, tr.dim);   // set the matrix size
        reg_model.CTRL_REG.write(status, 1);        // press start — this one is completely legal

        // --- illegal act: press start AGAIN, right now, while the first
        // computation from above is still actively running ---
        reg_model.CTRL_REG.write(status, 1);

        // wait here until that FIRST computation actually finishes —
        // the chip should have completely ignored the second start
        wait_for_pass_done();

        reg_model.CTRL_REG.write(status, 0);   // acknowledge done, release start

        wait_for_idle();          // wait until the FSM has fully settled back at IDLE
        pass_release.trigger();   // signal to the rest of the testbench "this pass is fully wrapped up"
        wait fork;                 // make sure the background data-streaming task also finished cleanly

        phase.drop_objection(this);   // "okay, now I'm done"
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
