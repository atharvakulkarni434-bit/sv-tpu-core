//==============================================================================
// File: mmu_cat1_tests.sv
// Project: sv-tpu-core
// Date: 2026-07-24
//
// Description:
//   Category 1 — Basic Functional Correctness (TC-001 through TC-010).
//   Validates core matrix-multiply correctness across array dimensions,
//   value extremes, and weight/activation patterns. Every test in this file
//   drives data-plane sequences on env.data_agt.sequencer; the scoreboard's
//   golden-model comparison (once wired) is what actually determines
//   pass/fail — these classes only own stimulus generation, dimension
//   pinning, and the knobs each directed sequence exposes.
//
// Convention (applies to every test in this file and mmu_cat2_tests.sv):
//   - One `uvm_component_utils'd class per TC-xxx, named tc_xxx_<slug>_test
//   - All stimulus driven from main_phase, bracketed by raise/drop_objection
//     on `this`, matching the pattern documented in mmu_base_test.sv's header
//   - Sequences are created, knobs set, then .start(env.data_agt.sequencer)
//   - reg_model/DIM_REG writes are NOT used to select dim for the data-plane
//     agent — dim travels inside data_txn (see data_agent.sv), so fixed_dim
//     on the sequence is the mechanism, not a RAL write. Category 5 tests
//     (illegal DIM_REG values) are the ones that actually exercise the RAL
//     write path for dim; these tests stay on the clean data-plane path.
//   - num_txns defaults are directed per test plan intent: single-shot
//     directed tests use 1; tests whose plan explicitly calls for volume
//     (e.g. constrained-random coverage closure) use a small repeat count
//     so regression stays fast while still sampling the coverage bin.
//==============================================================================

`ifndef MMU_CAT1_TESTS_SV
`define MMU_CAT1_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"
`include "mmu_sequences.sv"


//------------------------------------------------------------------------------
// TC-001 — Full 4x4 Random Matrix Multiply
//------------------------------------------------------------------------------
class tc_001_full_random_test extends mmu_base_test;
    `uvm_component_utils(tc_001_full_random_test)

    function new(string name = "tc_001_full_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
    mmu_matmul_seq seq;
    uvm_status_e   status;
    phase.raise_objection(this);

    `uvm_info(get_type_name(), "TRACE: entered main_phase, about to write DIM_REG", UVM_LOW)
    reg_model.DIM_REG.write(status, 4);
    `uvm_info(get_type_name(), $sformatf("TRACE: DIM_REG.write returned, status=%s", status.name()), UVM_LOW)

    `uvm_info(get_type_name(), "TRACE: about to write CTRL_REG", UVM_LOW)
    reg_model.CTRL_REG.write(status, 1);
    `uvm_info(get_type_name(), $sformatf("TRACE: CTRL_REG.write returned, status=%s", status.name()), UVM_LOW)

    seq = mmu_matmul_seq::type_id::create("seq");
    if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
        `uvm_fatal(get_type_name(), "seq randomize failed")

    `uvm_info(get_type_name(), "TRACE: about to call seq.start on data_agt.sequencer", UVM_LOW)
    seq.start(env.data_agt.sequencer);
    `uvm_info(get_type_name(), "TRACE: seq.start returned", UVM_LOW)

    // seq.start() only blocks until stimulus has been PUSHED in - it
    // returns well before the DUT reaches DONE. Wait for STATUS_REG.done
    // so the data monitor has time to publish the result to the
    // scoreboard before this phase's objection drops (see
    // mmu_base_test.sv::wait_for_pass_done for the full explanation).
    wait_for_pass_done();

    phase.drop_objection(this);
endtask

endclass : tc_001_full_random_test


//------------------------------------------------------------------------------
// TC-002 — 3x3 Subarray
//------------------------------------------------------------------------------
class tc_002_3x3_subarray_test extends mmu_base_test;
    `uvm_component_utils(tc_002_3x3_subarray_test)

    function new(string name = "tc_002_3x3_subarray_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 3; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_002_3x3_subarray_test


//------------------------------------------------------------------------------
// TC-003 — 2x2 Subarray
//
// Test plan calls for a directed hand-verifiable pass first, then
// constrained-random. First transaction is pinned via fixed_dim only
// (values stay random); a directed all-known-value pass isn't expressible
// through the current sequence knobs without adding a fully-directed
// single-value sequence, so both passes here are randomized at dim=2 — the
// hand-verifiable directed check is left as a TODO if the team wants a
// dedicated directed-value sequence added later.
//------------------------------------------------------------------------------
class tc_003_2x2_subarray_test extends mmu_base_test;
    `uvm_component_utils(tc_003_2x2_subarray_test)

    function new(string name = "tc_003_2x2_subarray_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 2; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_003_2x2_subarray_test


//------------------------------------------------------------------------------
// TC-004 — 1x1 Scalar MAC
//------------------------------------------------------------------------------
class tc_004_1x1_scalar_test extends mmu_base_test;
    `uvm_component_utils(tc_004_1x1_scalar_test)

    function new(string name = "tc_004_1x1_scalar_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_004_1x1_scalar_test


//------------------------------------------------------------------------------
// TC-005 — All-Zero Activation Matrix
//------------------------------------------------------------------------------
class tc_005_zero_activation_test extends mmu_base_test;
    `uvm_component_utils(tc_005_zero_activation_test)

    function new(string name = "tc_005_zero_activation_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_zero_activation_seq seq;
        phase.raise_objection(this);

        seq = mmu_zero_activation_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_005_zero_activation_test


//------------------------------------------------------------------------------
// TC-006 — All-Zero Weight Matrix
//------------------------------------------------------------------------------
class tc_006_zero_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_006_zero_weight_test)

    function new(string name = "tc_006_zero_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_zero_weight_seq seq;
        phase.raise_objection(this);

        seq = mmu_zero_weight_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_006_zero_weight_test


//------------------------------------------------------------------------------
// TC-007 — Max int8 Values (Worst-Case Accumulation)
//------------------------------------------------------------------------------
class tc_007_max_int8_test extends mmu_base_test;
    `uvm_component_utils(tc_007_max_int8_test)

    function new(string name = "tc_007_max_int8_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_uniform_extreme_seq seq;
        phase.raise_objection(this);

        seq = mmu_uniform_extreme_seq::type_id::create("seq");
        seq.polarity = mmu_uniform_extreme_seq::POS;
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_007_max_int8_test


//------------------------------------------------------------------------------
// TC-008 — Min int8 Values (Negative Accumulation)
//------------------------------------------------------------------------------
class tc_008_min_int8_test extends mmu_base_test;
    `uvm_component_utils(tc_008_min_int8_test)

    function new(string name = "tc_008_min_int8_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_uniform_extreme_seq seq;
        phase.raise_objection(this);

        seq = mmu_uniform_extreme_seq::type_id::create("seq");
        seq.polarity = mmu_uniform_extreme_seq::NEG;
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_008_min_int8_test


//------------------------------------------------------------------------------
// TC-009 — Mixed Positive and Negative Values
//------------------------------------------------------------------------------
class tc_009_signed_mix_test extends mmu_base_test;
    `uvm_component_utils(tc_009_signed_mix_test)

    function new(string name = "tc_009_signed_mix_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_signed_mix_seq seq;
        phase.raise_objection(this);

        seq = mmu_signed_mix_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_009_signed_mix_test


//------------------------------------------------------------------------------
// TC-010 — Identity Matrix as Weights
//------------------------------------------------------------------------------
class tc_010_identity_weights_test extends mmu_base_test;
    `uvm_component_utils(tc_010_identity_weights_test)

    function new(string name = "tc_010_identity_weights_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_identity_weight_seq seq;
        phase.raise_objection(this);

        seq = mmu_identity_weight_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        seq.start(env.data_agt.sequencer);
        wait_for_pass_done();

        phase.drop_objection(this);
    endtask
endclass : tc_010_identity_weights_test

`endif // MMU_CAT1_TESTS_SV