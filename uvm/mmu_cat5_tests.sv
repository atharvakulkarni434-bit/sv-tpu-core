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

        // sends the completed transaction — this is the line that actually
        // makes the driver pick it up and drive it onto the real AXI bus
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
        int sl = s.len();   // sl = how many characters are in the full string `s`
        int bl = sub.len(); // bl = how many characters are in the piece we're looking for

        if (bl == 0) return 1;   // an empty string always "appears" — nothing to search for
        if (bl > sl) return 0;   // if what we're looking for is longer than `s` itself, it can't fit — no match

        // slide a window of length bl across s, one position at a time,
        // and check if that window's text exactly matches sub
        for (int i = 0; i <= sl - bl; i++)
            // s.substr(i, i+bl-1) grabs bl characters starting at position i
            if (s.substr(i, i + bl - 1) == sub) return 1;   // found it — stop and say yes

        return 0;   // checked every possible position, never matched — say no
    endfunction

    // runs on every message in the test — only acts on the one we expect
    virtual function action_e catch();
        // check 4 things at once: is this an ERROR, from "SB_AXI" specifically,
        // AND does its text mention both "STATUS_REG" and "read-only"?
        // only if ALL FOUR are true do we treat this as the expected message
        if (get_severity() == UVM_ERROR &&
            get_id()       == "SB_AXI"  &&
            contains(get_message(), "STATUS_REG") &&
            contains(get_message(), "read-only")) begin

            // print a note explaining we're intentionally downgrading this one
            `uvm_info("TC023_CATCHER", "expected STATUS_REG write - demoting to INFO", UVM_LOW)

            // actually change this message's severity from ERROR to INFO,
            // so it no longer counts as a real failure
            set_severity(UVM_INFO);
        end

        // let this message (possibly just downgraded) continue on as normal —
        // every OTHER message that isn't this exact one is untouched
        return THROW;
    endfunction
endclass : tc_023_status_write_catcher


// TC-023 — write to the read-only STATUS_REG, then run one clean pass.
class tc_023_status_reg_write_test extends mmu_base_test;
    `uvm_component_utils(tc_023_status_reg_write_test)

    tc_023_status_write_catcher status_catcher;   // will hold our "ignore this error" helper

    function new(string name = "tc_023_status_reg_write_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // build_phase runs BEFORE the test's real steps — we install the
    // catcher here so it's already watching before the illegal write happens
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        status_catcher = tc_023_status_write_catcher::type_id::create("status_catcher");
        uvm_report_cb::add(null, status_catcher);   // null = attach to every reporter in the test
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_illegal_write_seq ill;   // will hold our raw-write sequence
        mmu_matmul_seq        seq;   // will hold our normal, legal computation sequence
        phase.raise_objection(this);   // tells UVM "keep the test alive, I'm not done yet"

        // --- illegal act: write STATUS_REG directly ---
        ill = mmu_illegal_write_seq::type_id::create("ill");   // create the sequence
        ill.addr  = 4'h8;                // target STATUS_REG
        ill.wdata = 32'h0000_0001;       // try to force done=1 — should be ignored
        ill.start(env.axi_agt.sequencer); // actually run it on the AXI sequencer

        // --- recovery check: one normal, legal 4x4 run ---
        seq = mmu_matmul_seq::type_id::create("seq");
        // randomize the sequence's settings, forcing dim=4 and exactly 1 transaction
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")   // stop hard if randomize fails
        run_matmul(seq);   // shared helper that drives one complete legal computation

        phase.drop_objection(this);   // tells UVM "okay, now I'm done, test can end"
    endtask
endclass : tc_023_status_reg_write_test


// TC-024 — press start with dim never written (stays 0, illegal).
class tc_024_premature_start_test extends mmu_base_test;
    `uvm_component_utils(tc_024_premature_start_test)

    function new(string name = "tc_024_premature_start_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        uvm_status_e   status;   // will hold whether each register write succeeded
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        // --- illegal act: press start with dim still at 0 (never written) ---
        reg_model.CTRL_REG.write(status, 1);   // write 1 (start) to CTRL_REG
        if (status != UVM_IS_OK)                // check the write itself actually went through
            `uvm_error(get_type_name(), "premature start write failed")
        reg_model.CTRL_REG.write(status, 0);    // put start back to 0

        // --- recovery check: one normal, legal run ---
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
        // grabs a shared global event other parts of the testbench use to
        // signal "the weight/activation data has been staged and is ready"
        uvm_event      stim_staged = uvm_event_pool::get_global("mmu_stim_staged");
        uvm_status_e   status;
        mmu_matmul_seq seq;
        data_txn       tr;    // will hold the actual transaction data once we get it
        uvm_object     obj;   // a generic holder used to receive the event's data
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")

        // fork = start this sequence running, join_none = don't wait for it
        // to finish before moving on to the next line — it runs in the background
        fork
            seq.start(env.data_agt.sequencer);
        join_none

        // pause here until the background sequence signals "data is ready"
        stim_staged.wait_ptrigger();
        obj = stim_staged.get_trigger_data();   // grab whatever data came with that signal
        stim_staged.reset();                     // reset the event so it can be reused later
        // cast the generic obj into the specific data_txn type we actually expect
        if (!$cast(tr, obj)) `uvm_fatal(get_type_name(), "bad stim_staged trigger data")

        // --- legal start #1 ---
        reg_model.DIM_REG.write(status, tr.dim);   // set the matrix size
        reg_model.CTRL_REG.write(status, 1);        // press start — this one is legal

        // --- illegal act: press start AGAIN, right now, mid-computation ---
        reg_model.CTRL_REG.write(status, 1);

        wait_for_pass_done();   // pause here until the FIRST computation actually finishes
        reg_model.CTRL_REG.write(status, 0);   // acknowledge done, release start

        wait_for_idle();          // pause until the FSM has fully settled back at IDLE
        pass_release.trigger();   // signal to the rest of the testbench "this pass is fully done"
        wait fork;                 // make sure the background data-sending task finished too

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

        // --- illegal act: set an out-of-range size, then press start ---
        reg_model.DIM_REG.write(status, 3'd5);   // 5 is too big — max legal size is 4
        reg_model.CTRL_REG.write(status, 1);      // start anyway — chip should refuse to run
        reg_model.CTRL_REG.write(status, 0);      // release start

        // --- recovery check: run_matmul sets its OWN legal dim (4) first,
        // so the earlier illegal "5" doesn't carry over into this clean pass ---
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_026_invalid_dim_test

`endif // MMU_CAT5_TESTS_SV
