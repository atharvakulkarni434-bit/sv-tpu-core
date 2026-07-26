//==============================================================================
// File: mmu_sequences.sv
// Project: sv-tpu-core
// Date: 2026-07-24
//
// Description:
//   Data-plane sequence library. Carries the clean matrix-multiply stimulus,
//   the directed pattern sequences needed for Category 1 (basic functional
//   correctness) and Category 2 (back-to-back transaction sequencing), plus
//   weight_poison_seq, which violates the weight-stationary contract on
//   purpose by rewriting the weight matrix while partial sums are still
//   travelling down the columns.
//
// Features:
//   - mmu_base_seq: shared knobs and the dim/edge-value helpers
//   - mmu_matmul_seq: clean randomized passes across the legal dim range
//   - mmu_extreme_seq: int8 saturation corners (-128 / +127) for accumulator width
//   - mmu_zero_activation_seq: activations forced 0, weights random (TC-005)
//   - mmu_zero_weight_seq: weights forced 0, activations random (TC-006)
//   - mmu_uniform_extreme_seq: both matrices pinned to one uniform int8 value (TC-007/008)
//   - mmu_signed_mix_seq: random with a forced-negative quadrant (TC-009)
//   - mmu_identity_weight_seq: weights forced to identity, activations random (TC-010/016)
//   - mmu_back_to_back_seq: wraps a per-txn generator with a configurable
//     inter-transaction gap and optional per-transaction dim override list
//     (TC-011/012/013)
//   - weight_poison_seq: mid-feed weight corruption, guaranteed to differ
//   - Poison cycle is constrained past weight load, so WEIGHT_LOAD stays legal
//==============================================================================

`ifndef MMU_SEQUENCES_SV
`define MMU_SEQUENCES_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "data_agent.sv"


// Base sequence - knobs every data-plane sequence shares.

class mmu_base_seq extends uvm_sequence #(data_txn);
    `uvm_object_utils(mmu_base_seq)

    localparam int N = 4;

    // Number of matrix-multiply passes to issue.
    rand int unsigned num_txns;

    // Pin the dimension for directed runs; 0 leaves dim free to randomize.
    rand int unsigned fixed_dim;

    constraint c_num_txns  { soft num_txns inside {[1:10]}; }
    constraint c_fixed_dim { soft fixed_dim == 0; fixed_dim inside {[0:N]}; }

    function new(string name = "mmu_base_seq");
        super.new(name);
    endfunction

    // Apply the fixed_dim knob if the test set one.
    virtual function void apply_dim(data_txn tr);
        if (fixed_dim != 0) begin
            tr.poison_cycle = 0; // Fix: Clear poison_cycle before resizing dim
            if (!tr.randomize(dim) with { dim == fixed_dim; })
                `uvm_error(get_type_name(), $sformatf("could not pin dim to %0d", fixed_dim))
        end
    endfunction

endclass : mmu_base_seq



// Clean matrix multiply - the reference-model baseline.

class mmu_matmul_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_matmul_seq)

    function new(string name = "mmu_matmul_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "data_txn randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_matmul_seq



// int8 corner values - drives the accumulator toward its widest products so a
// too-narrow accumulator shows up as a mismatch rather than passing quietly.

class mmu_extreme_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_extreme_seq)

    function new(string name = "mmu_extreme_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (activations[i,j]) activations[i][j] inside {-128, -1, 0, 1, 127};
                    foreach (weights[i,j])     weights[i][j]     inside {-128, -1, 0, 1, 127};
                })
                `uvm_fatal(get_type_name(), "extreme-value randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_extreme_seq



// mmu_zero_activation_seq
//
// TC-005: activations pinned to all-zero, weights left constrained-random.
// Since 0 * weight = 0 for every entry regardless of weight, any nonzero
// output means either pe_clear failed to zero a stale accumulator, or the
// MAC path is not honoring a zero activation - this is C1's positive-mode
// exercise (zero_input_no_accumulate) at full array width.

class mmu_zero_activation_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_zero_activation_seq)

    function new(string name = "mmu_zero_activation_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (activations[i,j]) activations[i][j] == 8'sd0;
                })
                `uvm_fatal(get_type_name(), "zero-activation randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_zero_activation_seq



// mmu_zero_weight_seq
//
// TC-006: weights pinned to all-zero, activations left constrained-random.
// Any nonzero output here means the weight preload or MAC logic is broken -
// there is no "close but slightly wrong" for a zero weight matrix.

class mmu_zero_weight_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_zero_weight_seq)

    function new(string name = "mmu_zero_weight_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (weights[i,j]) weights[i][j] == 8'sd0;
                })
                `uvm_fatal(get_type_name(), "zero-weight randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_zero_weight_seq



// mmu_uniform_extreme_seq
//
// TC-007/TC-008: both matrices pinned uniformly to a single extreme int8
// value - not a per-element mix like mmu_extreme_seq. polarity selects
// which corner: POS -> +127/+127 (worst-case positive accumulation, spec
// Category 1 Rule for TC-007), NEG -> -128/-128 (negative*negative,
// worst-case positive-valued accumulation via signed cancellation, TC-008).

class mmu_uniform_extreme_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_uniform_extreme_seq)

    typedef enum { POS, NEG } polarity_e;

    // Test sets this before calling start(); no default guess is made since
    // TC-007 and TC-008 rely on different polarities and mixing them up would
    // silently change which corner gets exercised.
    polarity_e polarity;

    function new(string name = "mmu_uniform_extreme_seq");
        super.new(name);
    endfunction

    virtual task body();
        logic signed [7:0] fill_val = (polarity == POS) ? 8'sd127 : -8'sd128;

        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (activations[i,j]) activations[i][j] == local::fill_val;
                    foreach (weights[i,j])     weights[i][j]     == local::fill_val;
                })
                `uvm_fatal(get_type_name(), "uniform-extreme randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_uniform_extreme_seq



// mmu_signed_mix_seq
//
// TC-009: constrained-random values where at least one quadrant of each
// matrix is forced negative. Plain random generation could accidentally
// pass an all-positive-biased seed without ever exercising signed
// cancellation - this sequence guarantees the top-left quadrant of both A
// and B contains at least one strictly-negative entry every pass, so the
// signed MAC path is stressed on every transaction rather than by chance.

class mmu_signed_mix_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_signed_mix_seq)

    function new(string name = "mmu_signed_mix_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    activations[0][0] < 8'sd0;
                    weights[0][0]     < 8'sd0;
                })
                `uvm_fatal(get_type_name(), "signed-mix randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_signed_mix_seq



// mmu_identity_weight_seq
//
// TC-010 (and reused by TC-016 in Category 3): weights forced to the
// dim x dim identity matrix, activations left constrained-random. Since
// C = A * I = A, the output must equal the driven activations exactly -
// any deviation points at a weight-preload routing bug (a PE that latched
// its weight from the wrong row/column breaks the identity property even
// though the multiply logic itself is correct).

class mmu_identity_weight_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_identity_weight_seq)

    function new(string name = "mmu_identity_weight_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "identity-weight randomize failed")
            apply_dim(tr);
            set_identity(tr);
            finish_item(tr);
        end
    endtask

    // Overwrite the randomized weight matrix with an active-dim identity
    // matrix post-randomize, since "diagonal 1s elsewhere 0" isn't expressible
    // as a simple per-element inside{} constraint against a dynamic dim.
    virtual function void set_identity(data_txn tr);
        for (int r = 0; r < int'(tr.N); r++)
            for (int c = 0; c < int'(tr.N); c++)
                tr.weights[r][c] = 8'sd0;

        for (int i = 0; i < int'(tr.dim); i++)
            tr.weights[i][i] = 8'sd1;
    endfunction

endclass : mmu_identity_weight_seq



// mmu_back_to_back_seq
//
// TC-011/TC-012/TC-013: wraps repeated transactions with explicit control
// over the inter-transaction gap and, optionally, a per-transaction
// dimension override list - the two knobs mmu_matmul_seq's static
// fixed_dim can't express, since dimension needs to change transaction to
// transaction rather than once for the whole sequence run.
//
//   gap_cycles   == 0 -> next start_item issues immediately after the prior
//                        finish_item returns (TC-011, no_gap).
//   gap_cycles   == 1 -> one vif.data_cb wait inserted between transactions
//                        (TC-012, one_cycle).
//   dim_sequence      -> if non-empty, dim_sequence[i] overrides fixed_dim/
//                        random dim for transaction i, wrapping if num_txns
//                        exceeds dim_sequence.size() (TC-013, e.g. '{4,2,4}).
//                        Left empty, dim behaves like mmu_matmul_seq: pinned
//                        via fixed_dim, or freely random per transaction.
//
// Requires the same virtual interface the driver uses, fetched here only to
// synchronize the gap - this sequence does not drive pins directly.

class mmu_back_to_back_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_back_to_back_seq)

    // Cycles to wait between finish_item of txn i and start_item of txn i+1.
    // Only 0 and 1 are exercised by the current test plan (TC-011/TC-012);
    // larger values are accepted for the "multi" coverage bin if ever needed.
    int unsigned gap_cycles = 0;

    // Per-transaction dim override, applied in order and wrapped if shorter
    // than num_txns. Empty by default (no override).
    int unsigned dim_sequence[$];

    virtual mmu_if vif;

    function new(string name = "mmu_back_to_back_seq");
        super.new(name);
    endfunction

    // Sequences run on a sequencer, not a component, so the vif isn't
    // available via the driver's build_phase config_db lookup - it must be
    // looked up explicitly here before body() needs it for the gap wait.
    virtual task pre_body();
        super.pre_body();
        if (gap_cycles > 0)
            if (!uvm_config_db#(virtual mmu_if)::get(null, get_full_name(), "vif", vif))
                `uvm_fatal(get_type_name(),
                    "gap_cycles > 0 requires vif to be set in config_db at this sequence's full_name")
    endtask

    virtual task body();
        for (int unsigned i = 0; i < num_txns; i++) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "back-to-back randomize failed")
            apply_txn_dim(tr, i);
            finish_item(tr);

            // Gap is inserted after this transaction's finish_item and before
            // the next one's start_item - i.e. it sits in the inter-transaction
            // window the master plan defines the coverage bins against, not
            // inside the transaction itself.
            if (gap_cycles > 0 && i != num_txns - 1)
                repeat (gap_cycles) @(vif.data_cb);
        end
    endtask

    // Per-transaction dim resolution, in priority order:
    //   1. dim_sequence[i mod size]  - explicit directed sequence (TC-013)
    //   2. fixed_dim                 - static pin, same as mmu_matmul_seq
    //   3. leave random               - dim already randomized in body()
    virtual function void apply_txn_dim(data_txn tr, int unsigned idx);
        if (dim_sequence.size() > 0) begin
            int unsigned want_dim = dim_sequence[idx % dim_sequence.size()];
            if (!tr.randomize(dim) with { dim == local::want_dim; })
                `uvm_error(get_type_name(),
                    $sformatf("could not pin dim to %0d for txn %0d", want_dim, idx))
        end else begin
            apply_dim(tr);
        end
    endfunction

endclass : mmu_back_to_back_seq



// weight_poison_seq
//
// The array is weight-stationary: weights are captured during WEIGHT_LOAD and
// must hold constant for the whole pass. This sequence loads a clean matrix,
// lets the feed start, then rewrites the weights partway through - while
// partial sums from the earlier columns are still in flight down the array.
//
// The scoreboard samples the weights at start and predicts from those clean
// values, so a DUT that lets the new weights bleed into the in-flight
// accumulation produces a result the reference model will not match. That
// mismatch is the point of the test: a DUT that correctly holds its captured
// weights stays green here, and one that re-samples them does not.

class weight_poison_seq extends mmu_base_seq;
    `uvm_object_utils(weight_poison_seq)

    // Where in the 2*dim-1 feed window the corruption lands. Left unconstrained
    // the txn picks any legal cycle; pin it to target a specific wavefront.
    rand int unsigned fixed_poison_cycle;
    rand bit          use_fixed_cycle;

    constraint c_use_fixed { soft use_fixed_cycle == 1'b0; }

    function new(string name = "weight_poison_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);

            if (!tr.randomize() with { poison_en == 1'b1; })
                `uvm_fatal(get_type_name(), "poison randomize failed")

            apply_dim(tr);

            if (use_fixed_cycle) begin
                if (!tr.randomize(poison_cycle) with { poison_cycle == fixed_poison_cycle; })
                    `uvm_error(get_type_name(),
                        $sformatf("poison_cycle %0d is outside the feed window for dim=%0d",
                                  fixed_poison_cycle, tr.dim))
            end

            // Randomization can legitimately hand back a poison matrix equal to
            // the clean one, which would poison nothing and let the test pass
            // for the wrong reason. Force a difference inside the active dim.
            force_difference(tr);

            `uvm_info(get_type_name(),
                $sformatf("dim=%0d: poisoning weights on feed cycle %0d of %0d",
                          tr.dim, tr.poison_cycle, 2*tr.dim - 1),
                UVM_MEDIUM)

            finish_item(tr);
        end
    endtask

    // Guarantee the poison matrix actually differs somewhere the array reads.
    virtual function void force_difference(data_txn tr);
        bit differs = 0;

        for (int r = 0; r < int'(tr.dim) && !differs; r++)
            for (int c = 0; c < int'(tr.dim) && !differs; c++)
                if (tr.poison_weights[r][c] !== tr.weights[r][c])
                    differs = 1;

        if (!differs) begin
            // Flipping the MSB is the largest single-bit perturbation of an
            // int8 weight, so the corrupted product is maximally visible.
            tr.poison_weights[0][0] = tr.weights[0][0] ^ 8'sh80;
            `uvm_info(get_type_name(),
                "poison matrix matched the clean one - forced a difference at [0][0]",
                UVM_HIGH)
        end
    endfunction

endclass : weight_poison_seq

`endif // MMU_SEQUENCES_SV
