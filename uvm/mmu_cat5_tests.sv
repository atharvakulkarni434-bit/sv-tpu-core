//==============================================================================
// File: mmu_cat5_tests.sv
// Project: sv-tpu-core
// Date: 2026-07-27
//
// Description:
//   Category 5 — Illegal Operation / Error Injection (TC-023 through TC-026).
//   Drives protocol and sequencing violations — an illegal write to the
//   read-only STATUS_REG, a premature START with DIM_REG never written
//   (dim=0), a double START mid-computation, and an out-of-range DIM_REG
//   value — to confirm the DUT degrades safely and no illegal operation
//   produces or corrupts a result. See FULL_UVMVerification_PLAN Section 3.5.
//
//   The scoreboard (mmu_scoreboard.sv::write_axi) and the coverage model
//   (mmu_coverage.sv::write_axi) already CLASSIFY every one of these off the
//   observed AXI-Lite bus traffic:
//       STATUS_REG write            -> status_reg_write  (TC-023)
//       START, DIM_REG never written -> premature_start  (TC-024)
//       START while a pass in flight -> double_start      (TC-025)
//       DIM_REG written outside 1..4 -> invalid_dim        (TC-026)
//   So each test here only has to DRIVE the illegal bus transaction in the
//   right order; the analysis components do the checking and the coverage
//   sampling. Every test then runs a clean legal computation through
//   run_matmul() as the "follow-on clean transaction" (test plan 7.2, Step 4)
//   that proves the illegal op left no residual state corruption.
//
// Convention (matches mmu_cat1_tests.sv / mmu_cat2_tests.sv):
//   - One `uvm_component_utils'd class per TC-xxx, named tc_xxx_<slug>_test
//   - All stimulus driven from main_phase, bracketed by raise/drop_objection
//   - The LEGAL follow-on computation funnels through run_matmul(), same as
//     Category 1/2. The ILLEGAL bus op is driven either through the RAL model
//     (legal address, illegal data/timing) or, for the STATUS_REG write,
//     through a raw axi_txn on env.axi_agt.sequencer so the AXI driver
//     physically drives it onto the bus (test plan TC-023 wording).
//   - Unlike Category 1/2, these tests DO use the RAL / register write path
//     directly (DIM_REG / CTRL_REG / STATUS_REG writes) — that is the whole
//     point of error injection, per Category 1's header note.
//
// INTEGRATION NOTE (TC-023): mmu_scoreboard.sv::write_axi() raises a hard
// uvm_error on ANY observed STATUS_REG write ("register is read-only (B.4)"),
// because in every OTHER test such a write never legitimately reaches the bus.
// TC-023's whole purpose is to physically drive exactly that write so the DUT's
// read-only behavior is exercised (and the cp_error_type = status_reg_write bin
// is hit). For TC-023 that scoreboard guard is therefore expected stimulus, not
// a DUT fault. Rather than editing the shared scoreboard, TC-023 registers a
// uvm_report_catcher (tc_023_status_write_catcher, below) that recognizes that
// one specific message and demotes it from UVM_ERROR to UVM_INFO, so it no
// longer fails report_phase. The genuine TC-023 checks are untouched: the
// negative check (no spurious output during the illegal-write window) and the
// follow-on legal computation matching the golden model both still run and
// still count. If the team prefers a scoreboard-side flag (e.g.
// expect_status_write) later, this catcher can be removed.
//==============================================================================
 
`ifndef MMU_CAT5_TESTS_SV
`define MMU_CAT5_TESTS_SV
 
`include "uvm_macros.svh"
import uvm_pkg::*;
 
`include "mmu_base_test.sv"
`include "mmu_sequences.sv"
 
 
//------------------------------------------------------------------------------
// Helper: drive one raw AXI-Lite write straight onto the bus, bypassing the
// RAL model. Used by TC-023 to physically write the read-only STATUS_REG.
// addr 0x8 is already in axi_txn's legal-offset constraint set, so no
// constraint override is needed — only the DATA / target register is illegal,
// not the address itself.
//------------------------------------------------------------------------------
class mmu_illegal_write_seq extends uvm_sequence #(axi_txn);
    `uvm_object_utils(mmu_illegal_write_seq)
 
    logic [3:0]  addr  = 4'h8;          // default: STATUS_REG
    logic [31:0] wdata = 32'hDEAD_BEEF; // arbitrary payload the DUT must ignore
 
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
 
 
//------------------------------------------------------------------------------
// Report catcher for TC-023. mmu_scoreboard.sv::write_axi() raises a hard
// UVM_ERROR ("[SB_AXI] write to STATUS_REG - register is read-only (B.4)") on
// ANY observed STATUS_REG write, because in every other test a STATUS_REG
// write never legitimately reaches the bus. TC-023 deliberately drives exactly
// that write to prove the DUT ignores it, so for THIS test that scoreboard
// guard is expected stimulus, not a DUT fault. This catcher recognizes that
// one specific message and demotes it to UVM_INFO so report_phase's PASS/FAIL
// banner (which keys off the UVM_ERROR count) is not tripped by it. The real
// TC-023 checks are unaffected: the negative check (no spurious output while
// the illegal write is outstanding) and the follow-on legal computation
// matching the golden model both still run and still count.
//------------------------------------------------------------------------------
class tc_023_status_write_catcher extends uvm_report_catcher;
    `uvm_object_utils(tc_023_status_write_catcher)
 
    function new(string name = "tc_023_status_write_catcher");
        super.new(name);
    endfunction
 
    // Plain substring test — avoids any regex/glob API ambiguity across UVM
    // builds. Returns 1 iff sub occurs anywhere in s.
    protected function bit contains(string s, string sub);
        int sl = s.len();
        int bl = sub.len();
        if (bl == 0) return 1;
        if (bl > sl) return 0;
        for (int i = 0; i <= sl - bl; i++)
            if (s.substr(i, i + bl - 1) == sub) return 1;
        return 0;
    endfunction
 
    virtual function action_e catch();
        if (get_severity() == UVM_ERROR &&
            get_id()       == "SB_AXI"  &&
            contains(get_message(), "STATUS_REG") &&
            contains(get_message(), "read-only")) begin
            `uvm_info("TC023_CATCHER",
                "expected STATUS_REG write seen (TC-023 error injection) - demoting scoreboard read-only guard to INFO",
                UVM_LOW)
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass : tc_023_status_write_catcher
 
 
//------------------------------------------------------------------------------
// TC-023 — Write to Read-Only STATUS_REG
//
// Physically drive a WRITE to STATUS_REG (0x8). The DUT must ignore it
// completely (STATUS_REG has no storage element in axi_lite_slave.sv, so the
// write can't corrupt it). A clean 4x4 computation then confirms internal
// state was untouched. The scoreboard's read-only guard error is expected here
// and is demoted by tc_023_status_write_catcher (registered in build_phase).
//------------------------------------------------------------------------------
class tc_023_status_reg_write_test extends mmu_base_test;
    `uvm_component_utils(tc_023_status_reg_write_test)
 
    tc_023_status_write_catcher status_catcher;
 
    function new(string name = "tc_023_status_reg_write_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
 
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        // Register the catcher before any reports are issued. null context =
        // applies to all reporters (only this test runs per xrun invocation),
        // and the catcher's id/message filter keeps it from touching anything
        // other than the expected STATUS_REG read-only guard.
        status_catcher = tc_023_status_write_catcher::type_id::create("status_catcher");
        uvm_report_cb::add(null, status_catcher);
    endfunction
 
    virtual task main_phase(uvm_phase phase);
        mmu_illegal_write_seq ill;
        mmu_matmul_seq        seq;
        phase.raise_objection(this);
 
        // --- illegal op: physically write the read-only STATUS_REG ---
        ill = mmu_illegal_write_seq::type_id::create("ill");
        ill.addr  = 4'h8;              // STATUS_REG
        ill.wdata = 32'h0000_0001;     // try to force done=1; must be ignored
        ill.start(env.axi_agt.sequencer);
 
        // --- follow-on clean transaction: proves no residual corruption ---
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);
 
        phase.drop_objection(this);
    endtask
endclass : tc_023_status_reg_write_test
 
 
//------------------------------------------------------------------------------
// TC-024 — START Asserted Before DIM_REG Written (dim=0)
//
// Never write DIM_REG (it holds its reset value of 0) and assert CTRL_REG
// start immediately. dim=0 is illegal — no valid N=0 computation exists. The
// FSM must not leave IDLE / must not deadlock and must produce no result.
// Scoreboard classifies this as premature_start; a legal follow-on confirms
// recovery.
//------------------------------------------------------------------------------
class tc_024_premature_start_test extends mmu_base_test;
    `uvm_component_utils(tc_024_premature_start_test)
 
    function new(string name = "tc_024_premature_start_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
 
    virtual task main_phase(uvm_phase phase);
        uvm_status_e   status;
        mmu_matmul_seq seq;
        phase.raise_objection(this);
 
        // --- illegal op: START with DIM_REG left at its reset value (0) ---
        // Deliberately do NOT write DIM_REG first.
        reg_model.CTRL_REG.write(status, 1);   // premature start (dim=0)
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "premature CTRL_REG start write did not complete UVM_IS_OK")
        reg_model.CTRL_REG.write(status, 0);   // release start
 
        // --- follow-on clean transaction with a valid DIM_REG + START ---
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);
 
        phase.drop_objection(this);
    endtask
endclass : tc_024_premature_start_test
 
 
//------------------------------------------------------------------------------
// TC-025 — Double START (Second START Mid-Computation)
//
// Begin a legal 4x4 computation, then assert CTRL_REG start a SECOND time
// while the first is still in flight. The DUT must ignore the second start:
// the first computation runs to completion, done asserts exactly dim+5=9
// cycles (ratified contract) after its own activation flow began, and the
// output buffer holds only the first computation's result. No duplication,
// no corruption, no early termination.
//
// This test hand-rolls the register handshake (rather than calling
// run_matmul) because the second start has to be injected BETWEEN the first
// start and done. The ordering mirrors run_matmul()'s documented sequence
// exactly (see mmu_base_test.sv); the only addition is the second CTRL_REG
// write. That second write is itself a multi-cycle AXI-Lite handshake, so it
// lands well inside the dim+5=9-cycle activation window — i.e. genuinely
// mid-computation — which is exactly what TC-025 requires. The scoreboard's
// per-pass golden-model check plus its spurious-output check (results_seen
// vs legal_starts) together verify the first result is correct and that the
// double start added no extra output.
//------------------------------------------------------------------------------
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
 
        // Stage the weight matrix on the data plane (same handshake run_matmul
        // uses) before touching the control registers.
        fork
            seq.start(env.data_agt.sequencer);
        join_none
 
        stim_staged.wait_ptrigger();
        obj = stim_staged.get_trigger_data();
        stim_staged.reset();
        if (!$cast(tr, obj))
            `uvm_fatal(get_type_name(), "mmu_stim_staged carried something other than a data_txn")
 
        reg_model.DIM_REG.write(status, tr.dim);   // legal dim = 4
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "DIM_REG write did not complete UVM_IS_OK")
 
        reg_model.CTRL_REG.write(status, 1);       // FIRST (legal) start
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "first CTRL_REG start write did not complete UVM_IS_OK")
 
        // Second START while the first computation is still running. The DUT
        // must ignore it entirely.
        reg_model.CTRL_REG.write(status, 1);       // SECOND start (double)
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "second (double) CTRL_REG start write did not complete UVM_IS_OK")
 
        wait_for_pass_done();                       // done for the FIRST pass
 
        reg_model.CTRL_REG.write(status, 0);       // release start
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "CTRL_REG release write did not complete UVM_IS_OK")
 
        wait_for_idle();
        pass_release.trigger();
        wait fork;
 
        phase.drop_objection(this);
    endtask
endclass : tc_025_double_start_test
 
 
//------------------------------------------------------------------------------
// TC-026 — Invalid Dimension (DIM_REG > 4)
//
// Write DIM_REG = 5 (a value the 3-bit field can hold but that exceeds the
// physical 4x4 array), then assert CTRL_REG start. The DUT must clamp or
// ignore — no crash, no hang, no out-of-bounds PE access — and must not
// produce a spurious result. Scoreboard classifies the out-of-range DIM_REG
// write as invalid_dim; a legal 4x4 follow-on confirms recovery.
//------------------------------------------------------------------------------
class tc_026_invalid_dim_test extends mmu_base_test;
    `uvm_component_utils(tc_026_invalid_dim_test)
 
    function new(string name = "tc_026_invalid_dim_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
 
    virtual task main_phase(uvm_phase phase);
        uvm_status_e   status;
        mmu_matmul_seq seq;
        phase.raise_objection(this);
 
        // --- illegal op: out-of-range DIM_REG, then START ---
        reg_model.DIM_REG.write(status, 3'd5);   // 5 > 4: illegal dimension
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "illegal DIM_REG write did not complete UVM_IS_OK")
 
        reg_model.CTRL_REG.write(status, 1);     // start against illegal dim
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "CTRL_REG start write did not complete UVM_IS_OK")
        reg_model.CTRL_REG.write(status, 0);     // release start
 
        // --- follow-on clean transaction with a legal dim ---
        // run_matmul overwrites DIM_REG with a legal value (4) before its own
        // start, so the illegal 5 does not linger into the legal pass.
        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);
 
        phase.drop_objection(this);
    endtask
endclass : tc_026_invalid_dim_test
 
`endif // MMU_CAT5_TESTS_SV