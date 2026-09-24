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
//==============================================================================

`ifndef MMU_CAT1_TESTS_SV
`define MMU_CAT1_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"
`include "mmu_sequences.sv"

class tc_001_full_random_test extends mmu_base_test;
    `uvm_component_utils(tc_001_full_random_test)

    function new(string name = "tc_001_full_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")

        run_matmul(seq);

        phase.drop_objection(this);
    endtask

endclass : tc_001_full_random_test

class tc_002_3x3_subarray_test extends mmu_base_test;
    `uvm_component_utils(tc_002_3x3_subarray_test)

    function new(string name = "tc_002_3x3_subarray_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 3; num_txns == 500; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_002_3x3_subarray_test


class tc_003_2x2_subarray_test extends mmu_base_test;
    `uvm_component_utils(tc_003_2x2_subarray_test)

    function new(string name = "tc_003_2x2_subarray_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 500; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_003_2x2_subarray_test


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
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_004_1x1_scalar_test


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
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_005_zero_activation_test


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
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_006_zero_weight_test


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
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_007_max_int8_test

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
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_008_min_int8_test


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
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_009_signed_mix_test


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
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_010_identity_weights_test

`endif // MMU_CAT1_TESTS_SV
