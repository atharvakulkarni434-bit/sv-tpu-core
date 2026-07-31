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
//
// REV-2 ADDITIONS (Category 3 & 4 build-out — see sv-tpu-core_SpecDoc REV2 and
// the UVM Verification Test Plan):
//   - mmu_wp_prime_seq       : "dirty" priming pass (near-max weights) used to
//                              load large nonzero accumulator/weight state before
//                              a Category-3 pattern pass, so pe_clear/leakage bugs
//                              have something to leak (plan TC-014/016 wording:
//                              "run immediately after a prior computation that had
//                              large nonzero weight values").
//   - mmu_wp_pattern_base_seq: directed weight-pattern matmul (activations random,
//                              poison_en=0). Subclasses fill the stationary weight
//                              matrix with a specific pattern:
//                                * mmu_wp_zero_seq     (TC-014, all-zero)
//                                * mmu_wp_max_seq      (TC-015, all-127)
//                                * mmu_wp_identity_seq (TC-016, identity)
//                                * mmu_wp_checker_seq  (TC-017, ±127 checkerboard)
//   - mmu_recover_seq        : clean constrained-random pass used as the follow-on
//                              "recovery" computation after every reset event, the
//                              scoreboard-verified half of the Category-3/4 tests.
//   - mmu_virtual_sequencer  : holds the axi + data sub-sequencer handles and the
//                              vif, so the reset-oriented virtual sequences can
//                              drive the AXI-Lite control registers, stage data on
//                              the data plane, observe the FSM, and pulse reset all
//                              from one place.
//   - mmu_vseq_base + reset virtual sequences: reset-stress (TC-018/019/020, reset
//                              timed to WEIGHT_LOAD / PE_CLEAR / ACTIVATION_FLOW)
//                              and reset-behavior (TC-021 from IDLE, TC-022 reset
//                              then immediate restart, TC-034 reset while in DONE).
//
// SPEC ALIGNMENT NOTE (REV2): reset is asserted through a testbench-side hook
// (a global uvm_event honored by tb_top.sv) rather than by forcing rst_n through
// the virtual interface, which is not portable. WEIGHT_LOAD is N cycles and
// PE_CLEAR is one cycle per Spec A.5, so the phase-relative reset timing below is
// derived from those durations.
//==============================================================================

`ifndef MMU_SEQUENCES_SV
`define MMU_SEQUENCES_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "data_agent.sv"
// axi_txn / the AXI-Lite sequencer type are needed by the virtual sequencer and
// the reset virtual sequences, which drive DIM_REG/CTRL_REG/STATUS_REG directly.
`include "axi_agent.sv"


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



//==============================================================================
// CATEGORY 3 — DIRECTED WEIGHT-PATTERN DATA SEQUENCES (TC-014 .. TC-017)
//
// These are ordinary matmul passes (poison_en = 0) whose only twist is that the
// stationary weight matrix is forced to a specific directed pattern after
// randomization, exactly the way mmu_identity_weight_seq forces the identity.
// The scoreboard predicts from the same weights and the pass must MATCH the
// golden model — the "poison" in the category name refers to the class of
// silent accumulator-corruption bug these patterns surface, not to the mid-feed
// weight_poison_seq mechanism. Every Category-3 test runs one of these directly
// after mmu_wp_prime_seq so any pe_clear / leakage failure has large stale state
// to leak from.
//
// All four run at the full array dimension (DIM = N = 4) per the plan.
//==============================================================================

// mmu_wp_prime_seq — the "dirty" priming pass. Near-max-magnitude weights and
// random activations, so the PE weight registers and accumulators are left
// holding large nonzero values for the pattern pass that follows to expose.
class mmu_wp_prime_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_wp_prime_seq)

    function new(string name = "mmu_wp_prime_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    // Push weights toward the int8 extremes so the array is
                    // genuinely "dirty" before the pattern pass runs.
                    foreach (weights[i,j]) weights[i][j] inside {-128, -100, 100, 127};
                })
                `uvm_fatal(get_type_name(), "prime randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask
endclass : mmu_wp_prime_seq


// mmu_wp_pattern_base_seq — shared body for the four directed weight patterns.
// Subclasses override set_weights() to stamp their pattern over the active dim.
class mmu_wp_pattern_base_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_wp_pattern_base_seq)

    function new(string name = "mmu_wp_pattern_base_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "pattern randomize failed")
            apply_dim(tr);
            set_weights(tr);   // stamp the directed pattern post-randomize
            finish_item(tr);
        end
    endtask

    // Overridden per pattern. Default is a no-op (leaves random weights).
    virtual function void set_weights(data_txn tr);
    endfunction

    // Helper: zero the whole physical weight matrix before stamping a pattern,
    // so entries outside the active dim never carry random leftovers.
    protected function void clear_weights(data_txn tr);
        for (int r = 0; r < int'(tr.N); r++)
            for (int c = 0; c < int'(tr.N); c++)
                tr.weights[r][c] = 8'sd0;
    endfunction
endclass : mmu_wp_pattern_base_seq


// TC-014 — Weight Poison: All-Zero Weights. Every output must be exactly 0.
class mmu_wp_zero_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_zero_seq)
    function new(string name = "mmu_wp_zero_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);   // all zero across the whole array
    endfunction
endclass : mmu_wp_zero_seq


// TC-015 — Weight Poison: All-127 Weights (worst-case accumulation path).
class mmu_wp_max_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_max_seq)
    function new(string name = "mmu_wp_max_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);
        for (int r = 0; r < int'(tr.dim); r++)
            for (int c = 0; c < int'(tr.dim); c++)
                tr.weights[r][c] = 8'sd127;
    endfunction
endclass : mmu_wp_max_seq


// TC-016 — Weight Poison: Identity Matrix Weights. Output C must equal A.
class mmu_wp_identity_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_identity_seq)
    function new(string name = "mmu_wp_identity_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);
        for (int i = 0; i < int'(tr.dim); i++)
            tr.weights[i][i] = 8'sd1;
    endfunction
endclass : mmu_wp_identity_seq


// TC-017 — Weight Poison: Checkerboard ±127. B[i][j] = +127 if (i+j) even,
// -127 if (i+j) odd — stresses the signed-cancellation path.
class mmu_wp_checker_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_checker_seq)
    function new(string name = "mmu_wp_checker_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);
        for (int r = 0; r < int'(tr.dim); r++)
            for (int c = 0; c < int'(tr.dim); c++)
                tr.weights[r][c] = (((r + c) % 2) == 0) ? 8'sd127 : -8'sd127;
    endfunction
endclass : mmu_wp_checker_seq


// mmu_recover_seq — the clean, scoreboard-verified "recovery" pass every reset
// test ends on (and TC-022 restarts on). Plain constrained-random matmul; kept
// as its own type so the reset virtual sequences below only ever start
// sequences created in this file.
class mmu_recover_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_recover_seq)
    function new(string name = "mmu_recover_seq"); super.new(name); endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "recover randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask
endclass : mmu_recover_seq



//==============================================================================
// VIRTUAL SEQUENCER
//
// The reset virtual sequences need to drive the AXI-Lite control registers, push
// weight/activation matrices onto the data plane, watch the FSM observability
// taps (start / flow_en / done on mmu_if), and pulse reset — all coordinated in
// one place. A virtual sequencer that carries the two real sub-sequencers plus
// the virtual interface is the idiomatic home for that. mmu_env.sv builds it and
// wires these handles in connect_phase.
//==============================================================================
class mmu_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(mmu_virtual_sequencer)

    uvm_sequencer #(axi_txn)  axi_sqr;   // AXI-Lite control (DIM/CTRL/STATUS)
    uvm_sequencer #(data_txn) data_sqr;  // data plane (weights + activations)
    virtual mmu_if            vif;        // FSM observability + timing

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass : mmu_virtual_sequencer



//==============================================================================
// mmu_vseq_base — base for the reset-oriented virtual sequences.
//
// Provides the register-handshake, status-poll, FSM-observation and reset-pulse
// primitives the Category-3/4 virtual sequences are built from. Register access
// is done with raw axi_txn items on the AXI sequencer (no RAL adapter needed),
// exactly matching the AXI-Lite map in Spec B.2:
//   DIM_REG 0x0 (write N), CTRL_REG 0x4 (bit0 start), STATUS_REG 0x8 (bit0 done).
//
// Reset is requested through the global uvm_event "mmu_reset_req" and completion
// awaited on "mmu_reset_done"; tb_top.sv owns the actual synchronous rst_n pulse
// (see that file). The scoreboard listens on the same pair to clear its in-flight
// shadow state, so an aborted-then-restarted computation is not mis-flagged as a
// double start.
//==============================================================================
class mmu_vseq_base extends uvm_sequence #(uvm_sequence_item);
    `uvm_object_utils(mmu_vseq_base)
    `uvm_declare_p_sequencer(mmu_virtual_sequencer)

    localparam int      N          = 4;
    localparam bit [3:0] DIM_REG    = 4'h0;
    localparam bit [3:0] CTRL_REG   = 4'h4;
    localparam bit [3:0] STATUS_REG = 4'h8;

    // Spec A.5 FSM phase durations, used to time phase-relative resets.
    localparam int WEIGHT_LOAD_CYCLES = N;   // WEIGHT_LOAD runs N cycles
    localparam int PE_CLEAR_CYCLES     = 1;  // PE_CLEAR is exactly one cycle

    // Bounded poll guard, mirroring mmu_base_test::max_status_polls.
    int unsigned max_status_polls = 500;

    function new(string name = "mmu_vseq_base");
        super.new(name);
    endfunction

    // The register handshake polls STATUS_REG hard (up to max_status_polls
    // reads per wait), and the AXI driver returns a response for every read.
    // This sequence never calls get_response(), so with the default bounded
    // response queue those pile up and trip "Response queue overflow, response
    // was dropped" as a UVM_ERROR. The responses are unused, so make the queue
    // unbounded to silence it cleanly.
    virtual task pre_body();
        super.pre_body();
        set_response_queue_depth(-1);
    endtask

    //---- AXI-Lite register access via raw axi_txn items -------------------
    virtual task axi_write(bit [3:0] addr, bit [31:0] data);
        axi_txn t = axi_txn::type_id::create("t");
        start_item(t, -1, p_sequencer.axi_sqr);
        t.rw   = axi_txn::WRITE;
        t.addr = addr;
        t.data = data;
        finish_item(t, -1);
    endtask

    virtual task axi_read(bit [3:0] addr, output bit [31:0] data);
        axi_txn t = axi_txn::type_id::create("t");
        start_item(t, -1, p_sequencer.axi_sqr);
        t.rw   = axi_txn::READ;
        t.addr = addr;
        finish_item(t, -1);
        data = t.data;
    endtask

    virtual task write_dim(int unsigned d); axi_write(DIM_REG, d);  endtask
    virtual task write_start();             axi_write(CTRL_REG, 1); endtask
    virtual task write_stop();              axi_write(CTRL_REG, 0); endtask

    //---- Bounded STATUS_REG.done poll -------------------------------------
    // want=1 waits for done to assert, want=0 waits for it to clear.
    virtual task poll_status(bit want, string what);
        bit [31:0]   rdata;
        int unsigned polls = 0;
        forever begin
            axi_read(STATUS_REG, rdata);
            if (rdata[0] === want) return;
            polls++;
            if (polls >= max_status_polls) begin
                `uvm_error("MMU_VSEQ",
                    $sformatf("STATUS_REG.done never reached %0b after %0d polls while waiting for %s",
                              want, polls, what))
                return;
            end
        end
    endtask

    virtual task wait_for_done(); poll_status(1'b1, "done"); endtask
    virtual task wait_for_idle(); poll_status(1'b0, "idle"); endtask

    //---- FSM observation on the mmu_if taps -------------------------------
    virtual task step(int n = 1);
        repeat (n) @(p_sequencer.vif.mon_cb);
    endtask

    virtual task wait_start_high();
        do @(p_sequencer.vif.mon_cb); while (!p_sequencer.vif.mon_cb.start);
    endtask

    virtual task wait_flow_high();
        do @(p_sequencer.vif.mon_cb); while (!p_sequencer.vif.mon_cb.flow_en);
    endtask

    //---- Reset pulse (tb_top honors the request) --------------------------
    virtual task pulse_reset();
        uvm_event req  = uvm_event_pool::get_global("mmu_reset_req");
        uvm_event done = uvm_event_pool::get_global("mmu_reset_done");
        `uvm_info("MMU_VSEQ", "requesting synchronous reset pulse", UVM_MEDIUM)
        req.trigger();
        done.wait_trigger();   // block until tb_top has driven rst_n low then high
        req.reset();
        `uvm_info("MMU_VSEQ", "reset pulse complete", UVM_MEDIUM)
    endtask

    //---- One full, scoreboard-verified matmul pass ------------------------
    // Stages a data sequence (driver presents weights, waits flow_en, feeds
    // activations), then runs the DIM->START->poll(done)->STOP->poll(idle)
    // register handshake. Ordering mirrors mmu_base_test::run_matmul: weights
    // are staged before START so WEIGHT_LOAD latches real data, not 'x.
    virtual task run_pass(mmu_base_seq dseq, int unsigned dim);
        uvm_event pass_release = uvm_event_pool::get_global("mmu_pass_release");
        dseq.num_txns = 1;
        dseq.fixed_dim = dim;
        fork
            dseq.start(p_sequencer.data_sqr, this);
        join_none

        // Give the data driver a couple of cycles to place the weight matrix on
        // the bus before the FSM leaves IDLE and WEIGHT_LOAD samples it.
        step(2);

        write_dim(dim);
        write_start();
        wait_for_done();
        write_stop();
        wait_for_idle();

        // Release data_driver to stage the NEXT pass's transaction. The driver
        // gates every transaction after the very first on mmu_pass_release
        // (data_agent.sv, the Bug 9 fix); mmu_base_test::run_matmul triggers it
        // once per pass and the vseq path has to do the same, or the driver
        // parks on pass_release.wait_ptrigger() for pass 2 and the wait fork
        // below never returns (this is the weight-poison tests' hang). Trigger
        // only, no reset() - the driver, as consumer, owns reset(), mirroring
        // mmu_stim_staged.
        pass_release.trigger();

        wait fork;   // let the data sub-sequence and driver retire
    endtask

    // Start a pass but DO NOT poll it to completion — used when a reset is going
    // to abort it mid-flight. Returns once START has been observed.
    virtual task launch_pass(mmu_base_seq dseq, int unsigned dim);
        uvm_event pass_release = uvm_event_pool::get_global("mmu_pass_release");
        dseq.num_txns = 1;
        dseq.fixed_dim = dim;
        fork
            dseq.start(p_sequencer.data_sqr, this);
        join_none
        step(2);
        write_dim(dim);
        write_start();
        wait_start_high();

        // Used by the reset-in-DONE vseq (TC-034): this pass runs to completion
        // (the FSM parks in DONE with start held), so the data driver services
        // it normally and item_done()s it. Arm mmu_pass_release so the driver -
        // which then blocks on it before the next transaction - is free to
        // service the recovery pass that follows the reset. Trigger only; the
        // driver, as consumer, owns reset().
        pass_release.trigger();
    endtask

    // Drive the FSM into flight using AXI register writes ONLY - no data-plane
    // sequence. Used by the reset-stress vseqs, whose "dirty" pass is reset
    // mid-phase and thrown away: it needs no real weights, and starting a real
    // data sequence here would leave the data driver blocked mid-transaction
    // (it waits on `done`, which never asserts for an aborted pass) across the
    // reset - the wait fork in the recovery run_pass() would then hang on the
    // never-retiring dirty sequence. Register writes alone move the FSM through
    // IDLE -> WEIGHT_LOAD -> PE_CLEAR -> ACTIVATION_FLOW; the data driver stays
    // parked at get_next_item and picks up the recovery pass as its first real
    // transaction.
    virtual task launch_fsm_only(int unsigned dim);
        step(2);
        write_dim(dim);
        write_start();
        wait_start_high();
    endtask

endclass : mmu_vseq_base



//==============================================================================
// CATEGORY 3 — WEIGHT-POISON PATTERN VIRTUAL SEQUENCES (TC-014 .. TC-017)
//
// prime (dirty, large weights) -> pattern pass. Both are scoreboard-checked; the
// pattern pass is the one whose result the plan pins down (all-zero, C==A, etc.).
//==============================================================================
class mmu_wpat_vseq_base extends mmu_vseq_base;
    `uvm_object_utils(mmu_wpat_vseq_base)
    function new(string name = "mmu_wpat_vseq_base"); super.new(name); endfunction

    // Factory-overridable pattern-sequence maker.
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_pattern_base_seq::type_id::create("pat");
    endfunction

    virtual task body();
        mmu_wp_prime_seq prime = mmu_wp_prime_seq::type_id::create("prime");
        mmu_base_seq     pat   = make_pattern_seq();

        // Prime the array with large nonzero weight state...
        run_pass(prime, N);
        // ...then run the directed pattern immediately after (leakage stress).
        run_pass(pat, N);
    endtask
endclass : mmu_wpat_vseq_base

class mmu_wpat_zero_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_zero_vseq)
    function new(string name = "mmu_wpat_zero_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_zero_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_zero_vseq

class mmu_wpat_max_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_max_vseq)
    function new(string name = "mmu_wpat_max_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_max_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_max_vseq

class mmu_wpat_identity_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_identity_vseq)
    function new(string name = "mmu_wpat_identity_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_identity_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_identity_vseq

class mmu_wpat_checker_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_checker_vseq)
    function new(string name = "mmu_wpat_checker_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_checker_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_checker_vseq



//==============================================================================
// CATEGORY 3 — RESET-STRESS VIRTUAL SEQUENCES (TC-018 / TC-019 / TC-020)
//
// Launch a normal 4x4 computation, assert a synchronous reset while the FSM is
// in the targeted phase, then run a clean recovery computation the scoreboard
// verifies against the golden model. The aborted computation must produce no
// output; the recovery pass proves reset left no residue.
//
// Phase timing (from START, per Spec A.5): WEIGHT_LOAD spans N cycles, then one
// PE_CLEAR cycle, then ACTIVATION_FLOW (flow_en high).
//==============================================================================
class mmu_reset_stress_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_stress_vseq)

    typedef enum { PH_WEIGHT_LOAD, PH_PE_CLEAR, PH_ACTIVATION_FLOW } phase_e;
    phase_e target_phase = PH_ACTIVATION_FLOW;

    function new(string name = "mmu_reset_stress_vseq"); super.new(name); endfunction

    // Park the sequence inside the targeted FSM phase, referenced to START.
    virtual task wait_target_phase();
        wait_start_high();
        case (target_phase)
            PH_WEIGHT_LOAD:     step(1);                       // first WEIGHT_LOAD cycle
            PH_PE_CLEAR:        step(WEIGHT_LOAD_CYCLES);      // land on PE_CLEAR
            PH_ACTIVATION_FLOW: begin wait_flow_high(); step(2); end // mid-flow
            default:            step(1);
        endcase
    endtask

    virtual task body();
        mmu_recover_seq recover = mmu_recover_seq::type_id::create("recover");

        // Kick a throwaway pass into flight with register writes only (no data
        // sequence - see launch_fsm_only), drive into the target phase, then
        // reset it. No driver-serviced transaction is in flight, so the reset
        // leaves nothing to abort mid-drive and nothing for the recovery's
        // wait fork to hang on.
        launch_fsm_only(N);
        wait_target_phase();
        pulse_reset();

        // Recovery pass - the data driver's first real transaction, scoreboard-checked.
        run_pass(recover, N);
    endtask
endclass : mmu_reset_stress_vseq

class mmu_reset_wl_vseq extends mmu_reset_stress_vseq;
    `uvm_object_utils(mmu_reset_wl_vseq)
    function new(string name = "mmu_reset_wl_vseq");
        super.new(name); target_phase = PH_WEIGHT_LOAD;
    endfunction
endclass : mmu_reset_wl_vseq

class mmu_reset_pclr_vseq extends mmu_reset_stress_vseq;
    `uvm_object_utils(mmu_reset_pclr_vseq)
    function new(string name = "mmu_reset_pclr_vseq");
        super.new(name); target_phase = PH_PE_CLEAR;
    endfunction
endclass : mmu_reset_pclr_vseq

class mmu_reset_aflow_vseq extends mmu_reset_stress_vseq;
    `uvm_object_utils(mmu_reset_aflow_vseq)
    function new(string name = "mmu_reset_aflow_vseq");
        super.new(name); target_phase = PH_ACTIVATION_FLOW;
    endfunction
endclass : mmu_reset_aflow_vseq



//==============================================================================
// CATEGORY 4 — RESET-BEHAVIOR VIRTUAL SEQUENCES (TC-021 / TC-022 / TC-034)
//==============================================================================

// TC-021 — Synchronous Reset From IDLE. Pulse reset with no computation running,
// confirm all three registers read back their reset value of 0, then run a
// clean computation to prove the DUT is immediately usable.
class mmu_reset_idle_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_idle_vseq)
    function new(string name = "mmu_reset_idle_vseq"); super.new(name); endfunction

    virtual task check_reg_reset();
        bit [31:0] d;
        axi_read(DIM_REG,    d);
        if (d[2:0] !== 3'd0) `uvm_error("MMU_VSEQ", $sformatf("DIM_REG not 0 after reset: %0d",  d[2:0]))
        axi_read(CTRL_REG,   d);
        if (d[0]   !== 1'b0) `uvm_error("MMU_VSEQ", "CTRL_REG start not 0 after reset")
        axi_read(STATUS_REG, d);
        if (d[0]   !== 1'b0) `uvm_error("MMU_VSEQ", "STATUS_REG done not 0 after reset")
    endtask

    virtual task body();
        mmu_recover_seq clean = mmu_recover_seq::type_id::create("clean");
        pulse_reset();
        check_reg_reset();
        run_pass(clean, N);
    endtask
endclass : mmu_reset_idle_vseq


// TC-022 — Reset Then Immediate Restart. Complete a computation, reset, then
// start the next one with minimum recovery time (no extra idle cycles).
class mmu_reset_restart_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_restart_vseq)
    function new(string name = "mmu_reset_restart_vseq"); super.new(name); endfunction

    virtual task body();
        mmu_recover_seq first  = mmu_recover_seq::type_id::create("first");
        mmu_recover_seq restart = mmu_recover_seq::type_id::create("restart");
        run_pass(first, N);       // complete a full computation
        pulse_reset();            // one-cycle synchronous reset
        run_pass(restart, N);     // immediate restart, scoreboard-checked
    endtask
endclass : mmu_reset_restart_vseq


// TC-034 — Reset Asserted While FSM Is in DONE State. Run a pass to completion,
// leave START asserted so the FSM holds in DONE, reset there, confirm done
// deasserts, then run a clean computation.
class mmu_reset_done_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_done_vseq)
    function new(string name = "mmu_reset_done_vseq"); super.new(name); endfunction

    virtual task body();
        mmu_recover_seq dseq  = mmu_recover_seq::type_id::create("dseq");
        mmu_recover_seq clean = mmu_recover_seq::type_id::create("clean");
        bit [31:0]      d;

        // Drive a pass and stop at DONE — do NOT release START, so the FSM parks
        // in DONE with done asserted (Spec A.5: DONE holds until start drops).
        launch_pass(dseq, N);
        wait_for_done();

        // Reset while sitting in DONE, then confirm done did not survive it.
        pulse_reset();
        axi_read(STATUS_REG, d);
        if (d[0] !== 1'b0)
            `uvm_error("MMU_VSEQ", "STATUS_REG.done persisted after reset from DONE (TC-034)")

        // Release the stale START and run a clean, verified computation.
        write_stop();
        run_pass(clean, N);
    endtask
endclass : mmu_reset_done_vseq

`endif // MMU_SEQUENCES_SV