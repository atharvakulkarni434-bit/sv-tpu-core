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
//
// Convention (matches mmu_cat1_tests.sv):
//   - One `uvm_component_utils'd class per TC-xxx, named tc_xxx_<slug>_test
//   - All stimulus driven from main_phase, bracketed by raise/drop_objection
//     on `this`, matching mmu_base_test.sv's documented pattern
//   - Sequences are created, knobs set, then .start(env.data_agt.sequencer)
//   - dim travels inside data_txn (see data_agent.sv) via fixed_dim or
//     dim_sequence on mmu_back_to_back_seq — no RAL/DIM_REG writes needed
//     for these tests, same rationale as Category 1's header note.
//   - gap_cycles == 0 -> TC-011 (no_gap); gap_cycles == 1 -> TC-012
//     (one_cycle); dim_sequence == '{4,2,4} -> TC-013 (alternating dims)
//
//   ADDED (this pass): TC-036/TC-037 close cp_back_to_back's small_gap/
//   large_gap bins (mmu_coverage.sv's classify_gap()), which were
//   structurally unreachable before - TC-011/TC-012 only ever drove
//   gap_cycles 0 or 1, both of which classify as back_to_back (<=1 cycle).
//   gap_cycles == 5 -> TC-036 (small_gap, 2..10 cycles); gap_cycles == 15
//   -> TC-037 (large_gap, >10 cycles).
//==============================================================================

`ifndef MMU_CAT2_TESTS_SV
`define MMU_CAT2_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"
`include "mmu_sequences.sv"


//------------------------------------------------------------------------------
// TC-011 — 10+ Consecutive 4x4 Computations, No Gap
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-012 — Back-to-Back With One-Cycle Gap
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-013 — Back-to-Back With Alternating Dimensions
//
// Directed sequence: 4x4, immediately followed by 2x2, immediately followed
// by 4x4 again. dim_sequence drives the per-transaction override so dim
// changes transaction-to-transaction rather than being pinned once for the
// whole run (fixed_dim can't express that). fixed_dim is left at its default
// (0 / unconstrained) so dim_sequence is the only thing selecting dim here.
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-036 — Back-to-Back With Small Gap (coverage closure: cp_back_to_back's
// `small_gap` bin, classify_gap() in mmu_coverage.sv: 2..10 cycles). TC-011/
// TC-012 only ever drive gap_cycles 0 or 1, both of which classify as
// `back_to_back` (<=1 cycle) - nothing previously exercised a mid-size gap.
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-037 — Back-to-Back With Large Gap (coverage closure: cp_back_to_back's
// `large_gap` bin, classify_gap(): >10 cycles).
//------------------------------------------------------------------------------
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