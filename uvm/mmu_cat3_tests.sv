//==============================================================================
// File: mmu_cat3_tests.sv
// Project: sv-tpu-core
// Date: 2026-07-30
//
// Description:
//   Category 3 - Weight Poison & Reset Stress tests (Spec REV2 status: IN
//   PROGRESS). Every test extends the single shared base test, mmu_base_test,
//   and overrides only get_vseq() to name the virtual sequence it runs; the base
//   test's run_phase starts that sequence on env.v_sqr under a phase objection.
//   These drive ONLY the Category-3 virtual sequences added to mmu_sequences.sv.
//==============================================================================

`ifndef MMU_CAT3_TESTS_SV
`define MMU_CAT3_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"


class mmu_wp_zero_test extends mmu_base_test;                  // TC-014
    `uvm_component_utils(mmu_wp_zero_test)
    function new(string name = "mmu_wp_zero_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_wpat_zero_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_wp_zero_test

class mmu_wp_max_test extends mmu_base_test;                   // TC-015
    `uvm_component_utils(mmu_wp_max_test)
    function new(string name = "mmu_wp_max_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_wpat_max_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_wp_max_test

class mmu_wp_identity_test extends mmu_base_test;              // TC-016
    `uvm_component_utils(mmu_wp_identity_test)
    function new(string name = "mmu_wp_identity_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_wpat_identity_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_wp_identity_test

class mmu_wp_checker_test extends mmu_base_test;               // TC-017
    `uvm_component_utils(mmu_wp_checker_test)
    function new(string name = "mmu_wp_checker_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_wpat_checker_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_wp_checker_test

class mmu_reset_wl_test extends mmu_base_test;                // TC-018
    `uvm_component_utils(mmu_reset_wl_test)
    function new(string name = "mmu_reset_wl_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_reset_wl_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_reset_wl_test

class mmu_reset_pclr_test extends mmu_base_test;              // TC-019
    `uvm_component_utils(mmu_reset_pclr_test)
    function new(string name = "mmu_reset_pclr_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_reset_pclr_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_reset_pclr_test

class mmu_reset_aflow_test extends mmu_base_test;             // TC-020
    `uvm_component_utils(mmu_reset_aflow_test)
    function new(string name = "mmu_reset_aflow_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function mmu_vseq_base get_vseq();
        return mmu_reset_aflow_vseq::type_id::create("vseq");
    endfunction
endclass : mmu_reset_aflow_test

`endif // MMU_CAT3_TESTS_SV
