//==============================================================================
// File: mmu_cat7_tests.sv
// Project: sv-tpu-core
// Date: 2026-08-02
//
// Description:
//   Category 7 — Dimension-Swept Pattern Coverage Closure (TC-038 .. TC-049).
//   Closes cx_dim_x_weight and cx_dim_x_act's remaining scalar/small_dim
//   cross bins (mmu_coverage.sv). Every weight/activation pattern sequence
//   already existed and already worked at dim=4 (full); these tests just
//   run the same sequences with fixed_dim pinned to 1 (scalar) or 2
//   (small_dim) so classify_weight_pattern()/classify_activation_pattern()
//   sample the pattern at the array sizes the cross coverage still needed.
//   Nothing here is a bug fix - it's additive stimulus against existing
//   infrastructure (mmu_base_seq::fixed_dim).
//==============================================================================

`ifndef MMU_CAT7_TESTS_SV
`define MMU_CAT7_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"
`include "mmu_sequences.sv"

class tc_038_scalar_all_zero_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_038_scalar_all_zero_weight_test)

    function new(string name = "tc_038_scalar_all_zero_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_wp_zero_seq seq;
        phase.raise_objection(this);

        seq = mmu_wp_zero_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_038_scalar_all_zero_weight_test


class tc_039_small_dim_all_zero_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_039_small_dim_all_zero_weight_test)

    function new(string name = "tc_039_small_dim_all_zero_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_wp_zero_seq seq;
        phase.raise_objection(this);

        seq = mmu_wp_zero_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_039_small_dim_all_zero_weight_test


class tc_040_scalar_all_max_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_040_scalar_all_max_weight_test)

    function new(string name = "tc_040_scalar_all_max_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_wp_max_seq seq;
        phase.raise_objection(this);

        seq = mmu_wp_max_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_040_scalar_all_max_weight_test

class tc_041_small_dim_all_max_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_041_small_dim_all_max_weight_test)

    function new(string name = "tc_041_small_dim_all_max_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_wp_max_seq seq;
        phase.raise_objection(this);

        seq = mmu_wp_max_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_041_small_dim_all_max_weight_test

class tc_042_scalar_identity_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_042_scalar_identity_weight_test)

    function new(string name = "tc_042_scalar_identity_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_wp_identity_seq seq;
        phase.raise_objection(this);

        seq = mmu_wp_identity_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_042_scalar_identity_weight_test

class tc_043_small_dim_identity_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_043_small_dim_identity_weight_test)

    function new(string name = "tc_043_small_dim_identity_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_wp_identity_seq seq;
        phase.raise_objection(this);

        seq = mmu_wp_identity_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_043_small_dim_identity_weight_test


class tc_044_small_dim_checkerboard_weight_test extends mmu_base_test;
    `uvm_component_utils(tc_044_small_dim_checkerboard_weight_test)

    function new(string name = "tc_044_small_dim_checkerboard_weight_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_wp_checker_seq seq;
        phase.raise_objection(this);

        seq = mmu_wp_checker_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_044_small_dim_checkerboard_weight_test

class tc_045_scalar_all_negative_test extends mmu_base_test;
    `uvm_component_utils(tc_045_scalar_all_negative_test)

    function new(string name = "tc_045_scalar_all_negative_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_uniform_extreme_seq seq;
        phase.raise_objection(this);

        seq = mmu_uniform_extreme_seq::type_id::create("seq");
        seq.polarity = mmu_uniform_extreme_seq::NEG;
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_045_scalar_all_negative_test

class tc_046_small_dim_all_negative_test extends mmu_base_test;
    `uvm_component_utils(tc_046_small_dim_all_negative_test)

    function new(string name = "tc_046_small_dim_all_negative_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_uniform_extreme_seq seq;
        phase.raise_objection(this);

        seq = mmu_uniform_extreme_seq::type_id::create("seq");
        seq.polarity = mmu_uniform_extreme_seq::NEG;
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_046_small_dim_all_negative_test

class tc_047_scalar_all_zero_activation_test extends mmu_base_test;
    `uvm_component_utils(tc_047_scalar_all_zero_activation_test)

    function new(string name = "tc_047_scalar_all_zero_activation_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_zero_activation_seq seq;
        phase.raise_objection(this);

        seq = mmu_zero_activation_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_047_scalar_all_zero_activation_test

class tc_048_scalar_all_max_activation_test extends mmu_base_test;
    `uvm_component_utils(tc_048_scalar_all_max_activation_test)

    function new(string name = "tc_048_scalar_all_max_activation_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_max_activation_seq seq;
        phase.raise_objection(this);

        seq = mmu_max_activation_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_048_scalar_all_max_activation_test


class tc_049_small_dim_all_max_activation_test extends mmu_base_test;
    `uvm_component_utils(tc_049_small_dim_all_max_activation_test)

    function new(string name = "tc_049_small_dim_all_max_activation_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_max_activation_seq seq;
        phase.raise_objection(this);

        seq = mmu_max_activation_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_049_small_dim_all_max_activation_test

`endif // MMU_CAT7_TESTS_SV
