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
//              already detects and classifies all 4 violations just from
//              bus traffic — this file only drives the bad transaction,
//              nothing checks anything here.
// =============================================================================

`ifndef MMU_CAT5_TESTS_SV
`define MMU_CAT5_TESTS_SV

`include "uvm_macros.svh"     // gives us uvm_error, uvm_fatal, uvm_info, etc.
import uvm_pkg::*;             // gives us the UVM base classes
`include "mmu_base_test.sv"    // shared test class every test below extends
`include "mmu_sequences.sv"    // shared "run a legal matmul" sequence, reused below


// One raw AXI write, sent directly, bypassing the register model — needed
// to write STATUS_REG on purpose, which the register model wouldn't allow.
class mmu_illegal_write_seq extends uvm_sequence #(axi_txn);
    `uvm_object_utils(mmu_illegal_write_seq)

    logic [3:0]  addr  = 4'h8;          // default target: STATUS_REG
    logic [31:0] wdata = 32'hDEAD_BEEF; // junk value, should be ignored

    function new(string name = "mmu_illegal_write_seq");
        super.new(name);
    endfunction

    virtual task body();
        axi_txn tr = axi_txn::type_id::create("tr");
        start_item(tr);
        tr.rw   = axi_txn::WRITE;
        tr.addr = addr;
        tr.data = wdata;
        tr.strb = 4'hF;
        finish_item(tr);
    endtask
endclass : mmu_illegal_write_seq


// Downgrades the scoreboard's expected STATUS_REG-write error to INFO for TC-023 only.
class tc_023_status_write_catcher extends uvm_report_catcher;
    `uvm_object_utils(tc_023_status_write_catcher)

    function new(string name = "tc_023_status_write_catcher");
        super.new(name);
    endfunction

    // manual substring search — avoids regex/tool-version issues
    protected function bit contains(string s, string sub);
        int sl = s.len(); int bl = sub.len();
        if (bl == 0) return 1;
        if (bl > sl) return 0;
        for (int i = 0; i <= sl - bl; i++)
            if (s.substr(i, i + bl - 1) == sub) return 1;
        return 0;
    endfunction

    // runs automatically on EVERY message in the test — only touches the one we expect
    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id()       == "SB_AXI"  &&
            contains(get_message(), "STATUS_REG") &&
            contains(get_message(), "read-only")) begin
            `uvm_info("TC023_CATCHER", "expected STATUS_REG write - demoting to INFO", UVM_LOW)
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass : tc_023_status_write_catcher


// TC-023 — write to the read-only STATUS_REG, then run one clean pass.
class tc_023_status_reg_write_test extends mmu_base_test;
    `uvm_component_utils(tc_023_status_reg_write_test)

    tc_023_status_write_catcher status_catcher;

    function new(string name = "tc_023_status_reg_write_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // register the catcher BEFORE the illegal write happens
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        status_catcher = tc_023_status_write_catcher::type_id::create("status_catcher");
        uvm_report_cb::add(null, status_catcher);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_illegal_write_seq ill;
        mmu_matmul_seq        seq;
        phase.raise_objection(this);

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

        phase.drop_objection(this);
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
        uvm_event      stim_staged = uvm_event_pool::get_global("mmu_stim_staged");
        uvm_status_e   status;
        mmu_matmul_seq seq;
        data_txn       tr;
        uvm_object     obj;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")

        // stage weight/activation data in the background
        fork
            seq.start(env.data_agt.sequencer);
        join_none

        stim_staged.wait_ptrigger();
        obj = stim_staged.get_trigger_data();
        stim_staged.reset();
        if (!$cast(tr, obj)) `uvm_fatal(get_type_name(), "bad stim_staged trigger data")

        // legal start #1
        reg_model.DIM_REG.write(status, tr.dim);
        reg_model.CTRL_REG.write(status, 1);

        // illegal: start #2, mid-computation
        reg_model.CTRL_REG.write(status, 1);

        wait_for_pass_done();          // wait for the FIRST run to finish
        reg_model.CTRL_REG.write(status, 0);

        wait_for_idle();
        pass_release.trigger();
        wait fork;

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

        // illegal: dim=5, then start
        reg_model.DIM_REG.write(status, 3'd5);
        reg_model.CTRL_REG.write(status, 1);
        reg_model.CTRL_REG.write(status, 0);

        // recovery check — run_matmul sets its OWN legal dim=4 first
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_026_invalid_dim_test

`endif // MMU_CAT5_TESTS_SV
