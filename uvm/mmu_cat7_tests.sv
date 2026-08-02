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
//
//   NOT included here: scalar,checkerboard (cx_dim_x_weight) - waived in
//   mmu_coverage.sv as structurally dead (classify_weight_pattern() checks
//   is_max before is_check, and a 1x1 checkerboard cell is bitwise
//   identical to all-max, so PAT_CHECK can never be returned for dim=1).
//
//   Bin -> test map:
//     cx_dim_x_weight
//       scalar,all_zero        -> TC-038  mmu_wp_zero_seq,      fixed_dim=1
//       small_dim,all_zero     -> TC-039  mmu_wp_zero_seq,      fixed_dim=2
//       scalar,all_max         -> TC-040  mmu_wp_max_seq,       fixed_dim=1
//       small_dim,all_max      -> TC-041  mmu_wp_max_seq,       fixed_dim=2
//       scalar,identity        -> TC-042  mmu_wp_identity_seq,  fixed_dim=1
//       small_dim,identity     -> TC-043  mmu_wp_identity_seq,  fixed_dim=2
//       small_dim,checkerboard -> TC-044  mmu_wp_checker_seq,   fixed_dim=2
//       scalar,all_negative    -> TC-045  mmu_uniform_extreme_seq(NEG), dim=1
//       small_dim,all_negative -> TC-046  mmu_uniform_extreme_seq(NEG), dim=2
//     cx_dim_x_act
//       scalar,all_zero        -> TC-047  mmu_zero_activation_seq, fixed_dim=1
//       scalar,all_negative    -> TC-045  (same run as above; pins both
//                                          matrices to -128, closes both
//                                          crosses' all_negative in one shot)
//       small_dim,all_negative -> TC-046  (same run as TC-046 above)
//       scalar,all_max         -> TC-048  mmu_max_activation_seq,  fixed_dim=1
//       small_dim,all_max      -> TC-049  mmu_max_activation_seq,  fixed_dim=2
//
//   mmu_max_activation_seq is new (added to mmu_sequences.sv this pass) -
//   no prior sequence pinned activations to all-127 while leaving weights
//   random; it mirrors mmu_zero_activation_seq/mmu_wp_max_seq's structure.
//
// Convention (matches mmu_cat1_tests.sv / mmu_cat2_tests.sv):
//   - One `uvm_component_utils'd class per TC-xxx, named tc_xxx_<slug>_test
//   - All stimulus driven from main_phase, bracketed by raise/drop_objection
//     on `this`
//   - Sequences created, knobs set via randomize() with { fixed_dim == N; },
//     then run_matmul(seq) owns the register handshake
//   - num_txns == 1: each test is a single directed sample of one pattern at
//     one dimension, matching Category 1's directed-test convention
//
// Usage: +UVM_TESTNAME=tc_038_scalar_all_zero_weight_test (etc).
//==============================================================================

`ifndef MMU_CAT7_TESTS_SV
`define MMU_CAT7_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"
`include "mmu_sequences.sv"


//------------------------------------------------------------------------------
// TC-038 — Scalar (dim=1) All-Zero Weights
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-039 — Small-Dim (dim=2) All-Zero Weights
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-040 — Scalar (dim=1) All-Max (127) Weights
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-041 — Small-Dim (dim=2) All-Max (127) Weights
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-042 — Scalar (dim=1) Identity Weights
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-043 — Small-Dim (dim=2) Identity Weights
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-044 — Small-Dim (dim=2) Checkerboard Weights
//
// NOTE: scalar,checkerboard is intentionally NOT tested here - it's waived
// in mmu_coverage.sv as structurally unreachable at dim=1 (checkerboard and
// all-max collapse to the same single cell, and is_max is checked first in
// classify_weight_pattern()). small_dim (dim=2) has no such collision, so
// this bin is genuinely closeable and this test closes it.
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-045 — Scalar (dim=1) All-Negative (-128) Weights AND Activations
//
// mmu_uniform_extreme_seq(NEG) pins BOTH matrices to -128 uniformly, so one
// run closes cx_dim_x_weight's scalar,all_negative AND cx_dim_x_act's
// scalar,all_negative in the same transaction - there is no dedicated
// weight-only or activation-only all_negative sequence in the codebase, and
// this existing sequence already does exactly what both crosses need.
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-046 — Small-Dim (dim=2) All-Negative (-128) Weights AND Activations
//
// Same rationale as TC-045, at dim=2: closes both cx_dim_x_weight's and
// cx_dim_x_act's small_dim,all_negative bins in one run.
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-047 — Scalar (dim=1) All-Zero Activations
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-048 — Scalar (dim=1) All-Max (127) Activations
//
// Uses mmu_max_activation_seq (new this pass, see mmu_sequences.sv) - no
// prior sequence pinned activations to all-127 with weights left random.
//------------------------------------------------------------------------------
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


//------------------------------------------------------------------------------
// TC-049 — Small-Dim (dim=2) All-Max (127) Activations
//------------------------------------------------------------------------------
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