//==============================================================================
// File: mmu_cat4_tests.sv
// Project: sv-tpu-core
// Date: 2026-07-30
//
// Description:
//   Category 4 - Reset Behavior tests (Spec REV2 status: IN PROGRESS). Every test
//   extends the single shared base test, mmu_base_test, and overrides only
//   get_vseq() to name the virtual sequence it runs; the base test's run_phase
//   starts that sequence on env.v_sqr under a phase objection. These drive ONLY
//   the Category-4 virtual sequences added to mmu_sequences.sv.
//
//     mmu_reset_idle_test    TC-021  reset from IDLE          -> mmu_reset_idle_vseq
//     mmu_reset_restart_test TC-022  reset then restart       -> mmu_reset_restart_vseq
//     mmu_reset_done_test    TC-034  reset while in DONE       -> mmu_reset_done_vseq
//
// Usage: +UVM_TESTNAME=mmu_reset_done_test (etc).
//==============================================================================

`ifndef MMU_CAT4_TESTS_SV
`define MMU_CAT4_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

// Pulls in mmu_base_test -> mmu_env -> mmu_sequences (virtual sequencer + all the
// Category-4 virtual sequences). All include-guarded, so order is safe.
`include "mmu_base_test.sv"


//==============================================================================
// Reset behavior tests (TC-021, TC-022, TC-034)
//==============================================================================
class mmu_reset_idle_test extends mmu_base_test;             // TC-021
    `uvm_component_utils(mmu_reset_idle_test)
    function new(string name = "mmu_reset_idle_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_reset_idle_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_reset_idle_test

class mmu_reset_restart_test extends mmu_base_test;          // TC-022
    `uvm_component_utils(mmu_reset_restart_test)
    function new(string name = "mmu_reset_restart_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_reset_restart_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_reset_restart_test

class mmu_reset_done_test extends mmu_base_test;             // TC-034
    `uvm_component_utils(mmu_reset_done_test)
    function new(string name = "mmu_reset_done_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_reset_done_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_reset_done_test

`endif // MMU_CAT4_TESTS_SV
