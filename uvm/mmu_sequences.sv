//==============================================================================
// File: mmu_sequences.sv
// Project: sv-tpu-core
// Date: 2026-07-16
//
// Description:
//   Data-plane sequence library. Carries the clean matrix-multiply stimulus
//   plus weight_poison_seq, which violates the weight-stationary contract on
//   purpose by rewriting the weight matrix while partial sums are still
//   travelling down the columns.
//
// Features:
//   - mmu_base_seq: shared knobs and the dim/edge-value helpers
//   - mmu_matmul_seq: clean randomized passes across the legal dim range
//   - mmu_extreme_seq: int8 saturation corners (-128 / +127) for accumulator width
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
        if (fixed_dim != 0)
            if (!tr.randomize(dim) with { dim == fixed_dim; })
                `uvm_error(get_type_name(), $sformatf("could not pin dim to %0d", fixed_dim))
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
