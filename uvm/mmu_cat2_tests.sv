//==============================================================================
// File: mmu_cat2_tests.sv
// Project: sv-tpu-core
// Date: 2026-07-24
//
// Description:
//   Category 2 — Back-to-Back Transaction Sequencing (TC-011 through TC-013).
//   Stresses consecutive computations with no gap, a one-cycle gap, and
//   alternating dimensions to catch accumulator leakage between transactions.
//   Every test in this file drives mmu_back_to_back_seq on
//   env.data_agt.sequencer; the scoreboard's golden-model comparison (per
//   transaction, independently) is what actually determines pass/fail — these
//   classes only own stimulus generation, gap timing, and per-transaction dim
//   overrides.
//==============================================================================

`ifndef MMU_CAT2_TESTS_SV
`define MMU_CAT2_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"
`include "mmu_sequences.sv"

class tc_011_back_to_back_no_gap_test extends mmu_base_test;
    `uvm_component_utils(tc_011_back_to_back_no_gap_test)

    function new(string name = "tc_011_back_to_back_no_gap_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_back_to_back_seq seq;
        phase.raise_objection(this);

        seq = mmu_back_to_back_seq::type_id::create("seq");
        seq.gap_cycles = 0;
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 10; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_011_back_to_back_no_gap_test

class tc_012_back_to_back_one_cycle_gap_test extends mmu_base_test;
    `uvm_component_utils(tc_012_back_to_back_one_cycle_gap_test)

    function new(string name = "tc_012_back_to_back_one_cycle_gap_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_back_to_back_seq seq;
        phase.raise_objection(this);

        seq = mmu_back_to_back_seq::type_id::create("seq");
        seq.gap_cycles = 1;
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 10; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_012_back_to_back_one_cycle_gap_test

class tc_013_back_to_back_alternating_dims_test extends mmu_base_test;
    `uvm_component_utils(tc_013_back_to_back_alternating_dims_test)

    function new(string name = "tc_013_back_to_back_alternating_dims_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_back_to_back_seq seq;
        phase.raise_objection(this);

        seq = mmu_back_to_back_seq::type_id::create("seq");
        seq.gap_cycles   = 0;
        seq.dim_sequence = '{4, 2, 4};
        if (!seq.randomize() with { num_txns == 3; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_013_back_to_back_alternating_dims_test

class tc_036_back_to_back_small_gap_test extends mmu_base_test;
    `uvm_component_utils(tc_036_back_to_back_small_gap_test)

    function new(string name = "tc_036_back_to_back_small_gap_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_back_to_back_seq seq;
        phase.raise_objection(this);

        seq = mmu_back_to_back_seq::type_id::create("seq");
        seq.gap_cycles = 5;   // classify_gap(): 2..10 cycles -> GAP_SMALL
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 10; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_036_back_to_back_small_gap_test

class tc_037_back_to_back_large_gap_test extends mmu_base_test;
    `uvm_component_utils(tc_037_back_to_back_large_gap_test)

    function new(string name = "tc_037_back_to_back_large_gap_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_back_to_back_seq seq;
        phase.raise_objection(this);

        seq = mmu_back_to_back_seq::type_id::create("seq");
        seq.gap_cycles = 15;  // classify_gap(): >10 cycles -> GAP_LARGE
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 10; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_037_back_to_back_large_gap_test

`endif // MMU_CAT2_TESTS_SV
