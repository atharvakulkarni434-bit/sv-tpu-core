//==============================================================================
// File: mmu_ral_and_negative_tests.sv
// Project: sv-tpu-core
// Date: 2026-07-28
//
// Description:
//   Two families of directed tests, both built on mmu_base_test:
//
//     1. RAL health-check tests (TC-032, TC-033) — run the UVM RAL
//        framework's built-in sequences (uvm_reg_hw_reset_seq /
//        uvm_reg_access_seq) against reg_model. Per the test plan (Section
//        3.7), these are the FIRST tests run in Phase 3 integration and
//        gate every other test in the regression: if either fails, the
//        register model or the AXI-Lite path has a fundamental bug that
//        would corrupt every subsequent result.
//
//     2. Assertion-validation tests (TC-035a..g) — deliberately force
//        internal DUT signals into illegal states via the backdoor HDL
//        access API (uvm_hdl_force / uvm_hdl_release) to confirm each
//        targeted SVA property actually fires when its property is
//        violated. Per master plan Rule (Section 4 preamble): an assertion
//        that has never fired could simply be miswritten or unbound rather
//        than genuinely passing, so each Mode-2 test here is the proof that
//        the corresponding property in mmu_controller_sva.sv / pe_sva.sv /
//        mmu_perf_checker.sv is alive and actually bound into the sim.
//
// WHY uvm_hdl_force/uvm_hdl_release AND NOT A DIRECT SV HIERARCHICAL FORCE:
//   uvm_hdl_force(path, value) / uvm_hdl_release(path) take a plain string
//   path and work from ordinary UVM component code with no cross-module
//   reference wired into the class - no virtual-interface-style handle to
//   dut internals needs to be threaded through mmu_env/mmu_base_test for
//   this. That's the standard "signal backdoor" mechanism industry UVM
//   environments use for exactly this kind of mutation/fault-injection
//   testing, and it's simulator-portable (works the same under VCS/Xcelium/
//   Questa) without needing per-force `bind`-level escape hatches. All HDL
//   paths below are rooted at "tb_top.dut" (see tb_top.sv/mmu_top.sv):
//     tb_top.dut.u_mmu_controller.state
//     tb_top.dut.u_mmu_controller.pe_clear
//     tb_top.dut.u_mmu_controller.done
//     tb_top.dut.u_mmu_controller.flow_en
//
// ASSUMPTION FLAGGED FOR TC-035f: systolic_array.sv (not available at the
// time this file was written) presumably instances PEs in a generate block
// named something like `u_systolic_array.pe_inst[row][col]`, each exposing
// pe.sv's `accum_out` register. The path below
//     tb_top.dut.u_systolic_array.pe_inst[1][2].accum_out
// is a best-guess pending confirmation against the actual generate/instance
// names in systolic_array.sv - update PE_1_2_ACCUM_PATH below (single
// localparam string) if the real names differ; nothing else in TC-035f
// needs to change.
//
// ASSUMPTION FLAGGED FOR ALL TC-035 (a/b/c/d/e/g): pe_sva.sv /
// mmu_controller_sva.sv / mmu_perf_checker.sv are not yet bound in
// tb_top.sv (see that file's header - all three `bind` lines are commented
// out pending their owners committing the actual files). These tests will
// compile and force/release signals correctly regardless, but the
// assertions they are meant to prove "fire" will not actually be live in
// simulation until those `bind` lines are uncommented. Until then, treat a
// clean run of TC-035x as "the force/release sequencing is correct" only -
// not yet as "property X actually fired," and don't sign off Phase 3 on
// these until the binds land.
//==============================================================================

`ifndef MMU_RAL_AND_NEGATIVE_TESTS_SV
`define MMU_RAL_AND_NEGATIVE_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"

//==============================================================================
// TC-032 — RAL Built-In: uvm_reg_hw_reset_seq
//
// No custom stimulus. Runs the UVM library's own uvm_reg_hw_reset_seq
// against reg_model immediately after the testbench's initial reset
// release (tb_top.sv asserts rst_n for 5 cycles at t=0, so by the time
// run_phase gets here the DUT has already seen its power-on reset - this
// sequence's job is to CONFIRM the register file came up at its spec'd
// reset values, not to assert reset itself).
//
// The sequence walks DIM_REG / CTRL_REG / STATUS_REG, reads each back via
// the RAL bus_map (mmu_reg_adapter -> axi_agt.sequencer -> DUT), and
// compares against the reset value declared in mmu_reg_model.sv
// (0x0 / 0x0 / 0x0 - see that file). Any mismatch is flagged internally by
// the RAL framework as a uvm_error - no custom scoreboard code needed for
// that part (test plan Section 3.7 / Section 7.4).
//
// On top of the library sequence, this test also confirms the "did this
// register walk accidentally trigger a computation" invariant from
// Section 7.4's RAL pass criterion: done must never assert and the FSM
// must stay in IDLE for the whole sequence. That's checked here directly
// against reg_model.STATUS_REG (not a raw vif poll) since a raw vif read
// would bypass the RAL model this test exists to validate.
//==============================================================================
class tc032_ral_hw_reset_test extends mmu_base_test;
    `uvm_component_utils(tc032_ral_hw_reset_test)

    function new(string name = "tc032_ral_hw_reset_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        uvm_reg_hw_reset_seq reset_seq;
        uvm_status_e         status;
        uvm_reg_data_t       rdata;

        phase.raise_objection(this);

        `uvm_info(get_type_name(),
            "running uvm_reg_hw_reset_seq against reg_model - confirms every register's reset value",
            UVM_LOW)

        reset_seq = uvm_reg_hw_reset_seq::type_id::create("reset_seq");
        reset_seq.model = reg_model;
        reset_seq.start(null);

        // Belt-and-suspenders check on top of the library sequence: reading
        // STATUS_REG.done through the RAL model itself (rather than a raw
        // vif poll) confirms the register walk didn't silently kick off a
        // computation via some path the library sequence doesn't check.
        reg_model.STATUS_REG.read(status, rdata);
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "STATUS_REG read did not complete UVM_IS_OK post-reset-seq")
        if (rdata[0] !== 1'b0)
            `uvm_error(get_type_name(),
                "STATUS_REG.done asserted after uvm_reg_hw_reset_seq - register walk should never trigger a computation")

        phase.drop_objection(this);
    endtask

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        // Tell the scoreboard not to expect data traffic for this RAL test
        uvm_config_db#(bit)::set(this, "env.scoreboard", "expect_data_traffic", 0);
    endfunction

endclass : tc032_ral_hw_reset_test


//==============================================================================
// TC-033 — RAL Built-In: uvm_reg_access_seq
//
// No custom stimulus. Runs the UVM library's own uvm_reg_access_seq, which
// walks every RW register (DIM_REG, CTRL_REG), writes a pattern value,
// reads it back, and verifies the round-trip internally. STATUS_REG is
// declared "RO" in mmu_reg_model.sv, so the library sequence automatically
// skips write attempts to it - no custom code needed to enforce that here
// (test plan Section 3.7 / Section 7.4).
//
// Must run AFTER TC-032 in any regression ordering (per test plan note:
// "Both must pass cleanly before any functional sequences are run") -
// that ordering is a run.f / regression-list concern, not something this
// class enforces itself.
//
// Same "did this accidentally trigger a computation" guard as TC-032: a
// CTRL_REG write during the access-seq walk is exactly the write pattern
// that could accidentally look like a real START assertion if written as
// 3'b1, so this is worth confirming explicitly rather than assuming the
// library sequence's own pattern never lands on a value that means
// something to the DUT.
//==============================================================================
class tc033_ral_access_test extends mmu_base_test;
    `uvm_component_utils(tc033_ral_access_test)

    function new(string name = "tc033_ral_access_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        uvm_reg_access_seq access_seq;
        uvm_status_e       status;
        uvm_reg_data_t     rdata;

        phase.raise_objection(this);

        `uvm_info(get_type_name(),
            "running uvm_reg_access_seq against reg_model - write/read-back on every RW field, RO fields skipped",
            UVM_LOW)

        access_seq = uvm_reg_access_seq::type_id::create("access_seq");
        access_seq.model = reg_model;
        access_seq.start(null);

        reg_model.STATUS_REG.read(status, rdata);
        if (status != UVM_IS_OK)
            `uvm_error(get_type_name(), "STATUS_REG read did not complete UVM_IS_OK post-access-seq")
        if (rdata[0] !== 1'b0)
            `uvm_error(get_type_name(),
                "STATUS_REG.done asserted after uvm_reg_access_seq - a CTRL_REG pattern write should never look like a real START to the FSM")

        phase.drop_objection(this);
    endtask

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        // Tell the scoreboard not to expect data traffic for this RAL test
        uvm_config_db#(bit)::set(this, "env.scoreboard", "expect_data_traffic", 0);
    endfunction

endclass : tc033_ral_access_test


//==============================================================================
// Shared FSM state encoding for the TC-035 series - mirrors mmu_controller.sv
// exactly (state_t there is logic [2:0], not an exported typedef, so the
// literal values are duplicated here rather than referenced by name).
//   IDLE=3'b000  WEIGHT_LOAD=3'b001  PE_CLEAR=3'b010
//   ACTIVATION_FLOW=3'b011  DONE=3'b100
//==============================================================================
class mmu_force_state_pkg;
    localparam logic [2:0] IDLE            = 3'b000;
    localparam logic [2:0] WEIGHT_LOAD     = 3'b001;
    localparam logic [2:0] PE_CLEAR        = 3'b010;
    localparam logic [2:0] ACTIVATION_FLOW = 3'b011;
    localparam logic [2:0] DONE            = 3'b100;
endclass


//==============================================================================
// TC-035a — Force IDLE -> PE_CLEAR while START is active. Validates B1
// (no_skip_weight_load).
//
// Sequencing: with the FSM sitting in IDLE, force start=1 and state=PE_CLEAR
// simultaneously to trigger B1's antecedent ((state==IDLE) && start), hold 
// it one cycle, release, and let the FSM's own next_state logic take
// back over. B1 fires the cycle after the forced illegal transition is
// observed. A clean legal 2x2 computation follows to confirm the DUT
// recovers once the force is released.
//==============================================================================
class tc035a_force_skip_weight_load_test extends mmu_base_test;
    `uvm_component_utils(tc035a_force_skip_weight_load_test)

    string state_path = "tb_top.dut.u_mmu_controller.state";
    string start_path = "tb_top.dut.u_mmu_controller.start";

    function new(string name = "tc035a_force_skip_weight_load_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq clean_seq;
        int unsigned   ok;

        phase.raise_objection(this);

        // Confirm the FSM is actually sitting in IDLE before forcing -
        // forcing from an unknown starting state would make it ambiguous
        // whether B1 fired because of THIS force or some other transition.
        wait_for_idle();

        `uvm_info(get_type_name(),
            $sformatf("forcing %s=1 and %s=PE_CLEAR from IDLE - B1 (no_skip_weight_load) must fire",
                      start_path, state_path), UVM_LOW)

        // Force start=1 AND force an illegal state transition away from IDLE 
        // to ensure B1's antecedent ((state==IDLE) && start) evaluates TRUE.
        ok  = uvm_hdl_force(start_path, 1'b1);
        ok &= uvm_hdl_force(state_path, mmu_force_state_pkg::PE_CLEAR);
        if (!ok)
            `uvm_fatal(get_type_name(), "uvm_hdl_force failed")

        // Hold the illegal state for exactly one clock so the violation is
        // observed on a real posedge, then release and let the RTL's own
        // sequential logic resume driving the signal.
        @(posedge tb_top.clk);
        ok  = uvm_hdl_release(state_path);
        ok &= uvm_hdl_release(start_path);
        if (!ok)
            `uvm_fatal(get_type_name(), "uvm_hdl_release failed")

        // Give the FSM a couple cycles to settle back to a sane state
        // before starting the follow-on clean computation.
        repeat (2) @(posedge tb_top.clk);

        // Follow-on clean computation - positive path, proves no residual
        // corruption from the forced illegal transition (Section 7.2 Step 4).
        clean_seq = mmu_matmul_seq::type_id::create("clean_seq");
        if (!clean_seq.randomize() with { num_txns == 1; fixed_dim == 2; })
            `uvm_fatal(get_type_name(), "clean_seq randomize failed")
        run_matmul(clean_seq);

        phase.drop_objection(this);
    endtask

endclass : tc035a_force_skip_weight_load_test


//==============================================================================
// TC-035b — Force pe_clear held for 2 cycles. Validates B2
// (pe_clear_one_cycle).
//
// Runs a real computation via run_matmul so the FSM naturally enters
// PE_CLEAR on its own; the moment pe_clear is observed asserted, force it
// to stay 1 for one additional cycle beyond its natural one-cycle pulse,
// then release and let the FSM continue. B2 must fire on that second
// forced cycle.
//==============================================================================
class tc035b_force_pe_clear_hold_test extends mmu_base_test;
    `uvm_component_utils(tc035b_force_pe_clear_hold_test)

    string pe_clear_path = "tb_top.dut.u_mmu_controller.pe_clear";

    function new(string name = "tc035b_force_pe_clear_hold_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Watches pe_clear via vif.mon_cb-adjacent hierarchical read and forces
    // an extra cycle the first time it rises. Forked alongside run_matmul
    // so it can react the instant PE_CLEAR is entered, without run_matmul
    // needing to know anything about this test's force logic.
    virtual task force_extra_pe_clear_cycle();
        bit  seen  = 0;
        int  value;

        forever begin
            @(posedge tb_top.clk);
            void'(uvm_hdl_read("tb_top.dut.u_mmu_controller.pe_clear", value));
            if (value == 1 && !seen) begin
                seen = 1;
                `uvm_info(get_type_name(),
                    "pe_clear rose - forcing it to stay asserted one extra cycle; B2 (pe_clear_one_cycle) must fire",
                    UVM_LOW)
                // Let the natural one-cycle pulse's own deassertion edge
                // pass, then immediately force it back to 1 for one more
                // cycle - this is the "held for 2 cycles" violation.
                @(posedge tb_top.clk);
                void'(uvm_hdl_force(pe_clear_path, 1'b1));
                @(posedge tb_top.clk);
                void'(uvm_hdl_release(pe_clear_path));
                return;
            end
        end
    endtask

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;

        phase.raise_objection(this);

        fork
            force_extra_pe_clear_cycle();
        join_none

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { num_txns == 1; fixed_dim == 4; })
            `uvm_fatal(get_type_name(), "seq randomize failed");
        run_matmul(seq);

        // Follow-on clean computation to confirm recovery.
        begin
            mmu_matmul_seq clean_seq = mmu_matmul_seq::type_id::create("clean_seq");
            if (!clean_seq.randomize() with { num_txns == 1; fixed_dim == 4; })
                `uvm_fatal(get_type_name(), "clean_seq randomize failed");
            run_matmul(clean_seq);
        end

        phase.drop_objection(this);
    endtask

endclass : tc035b_force_pe_clear_hold_test


//==============================================================================
// TC-035c / TC-035d — done forced one cycle early / one cycle late.
// Validates B3 (result_latency) and D1 (signal_level_latency). 
// Latency Contract: active_dim + N + 1 cycles (9 cycles for N=4, dim=4).
//
// early_not_late selects which of TC-035c (early, 1) / TC-035d (late, 0)
// this instance runs - set by the test before start(), or override in a
// derived class; no default is assumed since the two are opposite
// directions of the same violation and picking one silently would hide
// which case actually ran.
//==============================================================================
class tc035cd_force_done_timing_test extends mmu_base_test;
    `uvm_component_utils(tc035cd_force_done_timing_test)

    // Must be set explicitly before run_test() / start_of_simulation -
    // e.g. via +define, a plusarg, or a derived class's build_phase.
    bit early_not_late;

    string done_path    = "tb_top.dut.u_mmu_controller.done";
    string flow_en_path = "tb_top.dut.u_mmu_controller.flow_en";

    function new(string name = "tc035cd_force_done_timing_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // dim is fixed to 4 so the latency window is unambiguous.
    localparam int unsigned N_DIM = 4;

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        int            flow_en_val;

        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { num_txns == 1; fixed_dim == N_DIM; })
            `uvm_fatal(get_type_name(), "seq randomize failed");

        fork
            run_matmul(seq);
            begin
                // Wait for flow_en to rise, then count cycles from there.
                do begin
                    @(posedge tb_top.clk);
                    void'(uvm_hdl_read(flow_en_path, flow_en_val));
                end while (flow_en_val != 1);

                // Target Latency = active_dim + N_DIM + 1 = 9 cycles.
                if (early_not_late) begin
                    // TC-035c: force done=1 at cycle 8 instead of 9 (one cycle early).
                    repeat (N_DIM + N_DIM) @(posedge tb_top.clk);
                    `uvm_info(get_type_name(),
                        "forcing done=1 at cycle 8 (one cycle early) - B3/D1 must fire", UVM_LOW)
                    void'(uvm_hdl_force(done_path, 1'b1));
                    @(posedge tb_top.clk);
                    void'(uvm_hdl_release(done_path));
                end else begin
                    // TC-035d: suppress the natural done assertion at cycle
                    // 9 (force it to 0), release one cycle later so the
                    // RTL's own logic can assert it, now one cycle late.
                    repeat (N_DIM + N_DIM + 1) @(posedge tb_top.clk);
                    `uvm_info(get_type_name(),
                        "suppressing done at cycle 9, releasing one cycle later (one cycle late) - B3/D1 must fire",
                        UVM_LOW)
                    void'(uvm_hdl_force(done_path, 1'b0));
                    @(posedge tb_top.clk);
                    void'(uvm_hdl_release(done_path));
                end
            end
        join

        // Follow-on clean computation.
        begin
            mmu_matmul_seq clean_seq = mmu_matmul_seq::type_id::create("clean_seq");
            if (!clean_seq.randomize() with { num_txns == 1; fixed_dim == N_DIM; })
                `uvm_fatal(get_type_name(), "clean_seq randomize failed");
            run_matmul(clean_seq);
        end

        phase.drop_objection(this);
    endtask

endclass : tc035cd_force_done_timing_test


// Thin named wrappers so the regression list / run.f can select each
// direction explicitly instead of every caller needing to know to set
// early_not_late by hand.
class tc035c_done_early_test extends tc035cd_force_done_timing_test;
    `uvm_component_utils(tc035c_done_early_test)
    function new(string name = "tc035c_done_early_test", uvm_component parent = null);
        super.new(name, parent);
        early_not_late = 1'b1;
    endfunction
endclass : tc035c_done_early_test

class tc035d_done_late_test extends tc035cd_force_done_timing_test;
    `uvm_component_utils(tc035d_done_late_test)
    function new(string name = "tc035d_done_late_test", uvm_component parent = null);
        super.new(name, parent);
        early_not_late = 1'b0;
    endfunction
endclass : tc035d_done_late_test


//==============================================================================
// TC-035e — done forced while state == IDLE. Validates B4 (no_spurious_done).
//
// The simplest and fastest of the TC-035 series to implement - no
// computation needs to be in flight at all. With the DUT quiescent (IDLE,
// confirmed via wait_for_idle before forcing so there's no ambiguity about
// which state the FSM is actually in), force done=1 for one cycle and
// release. B4 must fire exactly once, on the forced cycle.
//==============================================================================
class tc035e_force_done_in_idle_test extends mmu_base_test;
    `uvm_component_utils(tc035e_force_done_in_idle_test)

    string done_path = "tb_top.dut.u_mmu_controller.done";

    function new(string name = "tc035e_force_done_in_idle_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        int ok;

        phase.raise_objection(this);

        wait_for_idle();

        `uvm_info(get_type_name(),
            "forcing done=1 while FSM is in IDLE - B4 (no_spurious_done) must fire",
            UVM_LOW)

        ok = uvm_hdl_force(done_path, 1'b1);
        if (!ok)
            `uvm_fatal(get_type_name(), $sformatf("uvm_hdl_force failed on path %s", done_path));

        @(posedge tb_top.clk);
        ok = uvm_hdl_release(done_path);
        if (!ok)
            `uvm_fatal(get_type_name(), $sformatf("uvm_hdl_release failed on path %s", done_path));

        // Follow-on clean computation confirms the forced spurious done
        // left no residual state corruption (e.g. no stale output_buffer
        // latch triggered by the fake done).
        begin
            mmu_matmul_seq clean_seq = mmu_matmul_seq::type_id::create("clean_seq");
            if (!clean_seq.randomize() with { num_txns == 1; fixed_dim == 2; })
                `uvm_fatal(get_type_name(), "clean_seq randomize failed");
            run_matmul(clean_seq);
        end

        phase.drop_objection(this);
    endtask

endclass : tc035e_force_done_in_idle_test


//==============================================================================
// TC-035f — PE accumulator forced to increment on a zero-activation cycle.
// Validates C1 (zero_input_no_accumulate), bound to pe.sv, one copy per PE
// instance (16x in this 4x4 array).
//
// NOTE (see file header): the exact hierarchical instance name for a given
// PE inside systolic_array.sv is not confirmed - PE_1_2_ACCUM_PATH below is
// the single place to fix if the real generate-block naming differs.
// Targets PE[1][2] specifically per the test plan's own example, using
// TC-005's all-zero-activation sequence so every PE (including [1][2]) is
// guaranteed to see activation_in==0 on every ACTIVATION_FLOW cycle -
// removing any timing guesswork about which cycle [1][2] happens to see a
// zero.
//==============================================================================
class tc035f_force_pe_accum_on_zero_test extends mmu_base_test;
    `uvm_component_utils(tc035f_force_pe_accum_on_zero_test)

    // FIX THIS PATH if systolic_array.sv's generate/instance names differ.
    localparam string PE_1_2_ACCUM_PATH = "tb_top.dut.u_systolic_array.pe_inst[1][2].accum_out";

    function new(string name = "tc035f_force_pe_accum_on_zero_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Bumps PE[1][2]'s accumulator by 1 the first time flow_en is observed
    // high, i.e. partway through the all-zero-activation pass driven by
    // main_phase below - guaranteed to land on a zero-activation cycle
    // since TC-005's sequence forces every activation to 0 for the whole
    // pass.
    virtual task force_accum_bump();
        int flow_en_val;
        int cur_val;

        do begin
            @(posedge tb_top.clk);
            void'(uvm_hdl_read("tb_top.dut.u_mmu_controller.flow_en", flow_en_val));
        end while (flow_en_val != 1);

        void'(uvm_hdl_read(PE_1_2_ACCUM_PATH, cur_val));
        `uvm_info(get_type_name(),
            $sformatf("forcing %s from %0d to %0d for one cycle during a zero-activation cycle - C1 must fire on PE[1][2] only",
                      PE_1_2_ACCUM_PATH, cur_val, cur_val + 1), UVM_LOW)

        void'(uvm_hdl_force(PE_1_2_ACCUM_PATH, cur_val + 1));
        @(posedge tb_top.clk);
        void'(uvm_hdl_release(PE_1_2_ACCUM_PATH));
    endtask

    virtual task main_phase(uvm_phase phase);
        mmu_zero_activation_seq seq;

        phase.raise_objection(this);

        seq = mmu_zero_activation_seq::type_id::create("seq");
        if (!seq.randomize() with { num_txns == 1; fixed_dim == 4; })
            `uvm_fatal(get_type_name(), "seq randomize failed");

        fork
            run_matmul(seq);
            force_accum_bump();
        join

        // Follow-on clean computation.
        begin
            mmu_matmul_seq clean_seq = mmu_matmul_seq::type_id::create("clean_seq");
            if (!clean_seq.randomize() with { num_txns == 1; fixed_dim == 4; })
                `uvm_fatal(get_type_name(), "clean_seq randomize failed");
            run_matmul(clean_seq);
        end

        phase.drop_objection(this);
    endtask

endclass : tc035f_force_pe_accum_on_zero_test


//==============================================================================
// TC-035g — extra WEIGHT_LOAD stall cycle in a back-to-back sequence.
// Validates D2 (back_to_back_throughput).
//
// Modeled on TC-011: two back-to-back 4x4 passes with no gap. After the
// first pass's done asserts and the second pass's START is pending, force
// the FSM to remain in WEIGHT_LOAD for one cycle longer than its natural
// N-cycle duration before letting it continue on to PE_CLEAR. D2 must fire
// on the cycle where flow_en (this project's activation_flow_start
// stand-in - see file header) is observed late relative to the expected
// window.
//==============================================================================
class tc035g_force_extra_weight_load_stall_test extends mmu_base_test;
    `uvm_component_utils(tc035g_force_extra_weight_load_stall_test)

    string state_path = "tb_top.dut.u_mmu_controller.state";

    function new(string name = "tc035g_force_extra_weight_load_stall_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // Watches for the SECOND entry into WEIGHT_LOAD in this test (the
    // back-to-back pass) and forces one extra cycle there. Distinguishing
    // "first" from "second" entry matters because forcing a stall on the
    // FIRST pass wouldn't be testing back-to-back throughput at all.
    virtual task force_extra_weight_load_stall();
        int state_val;
        int weight_load_entries = 0;
        bit was_weight_load     = 0;

        forever begin
            @(posedge tb_top.clk);
            void'(uvm_hdl_read(state_path, state_val));

            if (state_val == mmu_force_state_pkg::WEIGHT_LOAD && !was_weight_load) begin
                weight_load_entries++;
                was_weight_load = 1;

                if (weight_load_entries == 2) begin
                    `uvm_info(get_type_name(),
                        "second WEIGHT_LOAD entry (the back-to-back pass) - forcing FSM to hold WEIGHT_LOAD one extra cycle; D2 (back_to_back_throughput) must fire",
                        UVM_LOW)
                    void'(uvm_hdl_force(state_path, mmu_force_state_pkg::WEIGHT_LOAD));
                    @(posedge tb_top.clk);
                    void'(uvm_hdl_release(state_path));
                    return;
                end
            end else if (state_val != mmu_force_state_pkg::WEIGHT_LOAD) begin
                was_weight_load = 0;
            end
        end
    endtask

    virtual task main_phase(uvm_phase phase);
        mmu_back_to_back_seq seq;

        phase.raise_objection(this);

        seq = mmu_back_to_back_seq::type_id::create("seq");
        if (!seq.randomize() with { num_txns == 2; fixed_dim == 4; })
            `uvm_fatal(get_type_name(), "seq randomize failed");
        seq.gap_cycles = 0;

        fork
            run_matmul(seq);
            force_extra_weight_load_stall();
        join

        // Follow-on clean computation.
        begin
            mmu_matmul_seq clean_seq = mmu_matmul_seq::type_id::create("clean_seq");
            if (!clean_seq.randomize() with { num_txns == 1; fixed_dim == 4; })
                `uvm_fatal(get_type_name(), "clean_seq randomize failed");
            run_matmul(clean_seq);
        end

        phase.drop_objection(this);
    endtask

endclass : tc035g_force_extra_weight_load_stall_test

`endif // MMU_RAL_AND_NEGATIVE_TESTS_SV
