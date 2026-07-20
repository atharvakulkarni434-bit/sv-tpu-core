//==============================================================================
// File: perf_sequences.sv
// Project: sv-tpu-core
// Layer: Perf - Stimulus (Jad)
// Date: 2026-07-14
//
// Description:
//   UVM sequences that deliberately drive throughput measurement for the
//   performance checker (mmu_perf_checker.sv). They generate the DATA-PLANE
//   payloads (int8 weight + activation matrices) for many computations with no
//   gaps, across every legal dimension, plus an N=4 worst-case stress run.
//
//   These run on the DATA sequencer (data_txn items, driven by data_agent's
//   data_driver). The CONTROL-PLANE trigger for each computation - the
//   DIM_REG / CTRL_REG.start writes and STATUS_REG polling - comes from the
//   AXI/RAL side, exactly as the two-agent split in mmu_env.sv intends. In the
//   integrated environment a test (or a virtual sequence) interleaves a RAL
//   write of DIM_REG + CTRL_REG.start with each data_txn below. This file owns
//   the payloads and the back-to-back cadence; it does not reach across into
//   the AXI agent. See the integration note at the bottom of this file.
//
//   Payload VALUES are randomized: the perf layer cares about cycle counts, not
//   arithmetic, and functional correctness of these same payloads is checked
//   independently by the scoreboard against ref_model.py. Only `dim` is
//   directed, so each sequence exercises the intended matrix size.
//
// Features:
//   - perf_base_seq         : shared send_op(n) helper (build + randomize + send)
//   - perf_backtoback_seq   : >=10 back-to-back ops sweeping dims 1..4
//   - perf_n4_stress_seq    : many N=4 ops for worst-case (2N=8) timing
//==============================================================================

`ifndef PERF_SEQUENCES_SV
`define PERF_SEQUENCES_SV

// UVM base classes + macros, and the data_txn transaction type this file
// builds. data_agent.sv carries its own include guard, so pulling it in here
// is safe even when mmu_env.sv / mmu_sequences.sv already included it.
`include "uvm_macros.svh"
import uvm_pkg::*;
`include "data_agent.sv"


// -----------------------------------------------------------------------------
// perf_base_seq - common machinery. Every perf sequence extends this to get
// send_op(): create a data_txn, force the dimension, randomize the int8
// matrices, and drive it back-to-back (no inter-item delay).
// -----------------------------------------------------------------------------
class perf_base_seq extends uvm_sequence #(data_txn);
    `uvm_object_utils(perf_base_seq)

    function new(string name = "perf_base_seq");
        super.new(name);
    endfunction

    // Build + randomize + send one computation of the given active dimension.
    // Values are unconstrained int8 (data_txn already randomizes the signed
    // [7:0] activation/weight matrices); only `dim` is directed here.
    virtual task send_op(input int unsigned n);
        data_txn tr;
        tr = data_txn::type_id::create("tr");
        start_item(tr);
        if (!tr.randomize() with { dim == n; })
            `uvm_error(get_type_name(),
                       $sformatf("data_txn randomize failed for dim=%0d", n))
        finish_item(tr);
    endtask

endclass : perf_base_seq


// -----------------------------------------------------------------------------
// perf_backtoback_seq - the throughput workhorse. Fires NUM_OPS computations
// back-to-back with no idle cycles introduced by the sequence, sweeping every
// legal dimension so mmu_perf_checker sees each 2N contract (2,4,6,8) under
// streaming conditions. Default 12 ops (3 sweeps of 1..4) satisfies the ">=10
// back-to-back" requirement in the plan.
// -----------------------------------------------------------------------------
class perf_backtoback_seq extends perf_base_seq;
    `uvm_object_utils(perf_backtoback_seq)

    // Number of full 1..4 sweeps. 3 sweeps = 12 ops (>= 10). Randomizable so a
    // test can dial the stream length up without editing this file.
    rand int unsigned num_sweeps;
    constraint c_sweeps { num_sweeps inside {[3:8]}; }

    function new(string name = "perf_backtoback_seq");
        super.new(name);
        num_sweeps = 3;   // default when not randomized by the test
    endfunction

    virtual task body();
        `uvm_info(get_type_name(),
                  $sformatf("back-to-back throughput: %0d sweeps of dims 1..4 (%0d ops)",
                            num_sweeps, num_sweeps * 4), UVM_LOW)
        for (int s = 0; s < num_sweeps; s++)
            for (int n = 1; n <= 4; n++)
                send_op(n);
    endtask

endclass : perf_backtoback_seq


// -----------------------------------------------------------------------------
// perf_n4_stress_seq - worst-case timing. All ops at N=4 (the 2N=8 corner, the
// longest and most important latency in the contract), streamed back-to-back so
// the perf checker exercises the worst-case initiation interval repeatedly.
// -----------------------------------------------------------------------------
class perf_n4_stress_seq extends perf_base_seq;
    `uvm_object_utils(perf_n4_stress_seq)

    rand int unsigned num_ops;
    constraint c_ops { num_ops inside {[10:32]}; }

    function new(string name = "perf_n4_stress_seq");
        super.new(name);
        num_ops = 16;     // default when not randomized by the test
    endfunction

    virtual task body();
        `uvm_info(get_type_name(),
                  $sformatf("N=4 worst-case stress: %0d back-to-back ops (2N=8 each)",
                            num_ops), UVM_LOW)
        for (int i = 0; i < num_ops; i++)
            send_op(4);
    endtask

endclass : perf_n4_stress_seq


// =============================================================================
// INTEGRATION NOTE (for the Phase 3 wire-up, not needed to compile):
//   A full computation needs both agents. In the integrated test/virtual
//   sequence, per data_txn `tr` sent above, drive the control side via the RAL
//   model (grabbed from config_db) roughly as:
//
//       reg_model.DIM_REG.write(status, tr.dim);      // set active N
//       reg_model.CTRL_REG.write(status, 1);          // start bit -> triggers op
//       // ... data_driver presents weights then skewed activations ...
//       do reg_model.STATUS_REG.read(status, val);    // poll done
//       while (val[0] != 1'b1);
//
//   Keep that coordination in the test/virtual-sequence layer so these perf
//   sequences stay pure data-plane and reusable. mmu_env.sv has no virtual
//   sequencer yet; adding one is a separate integration task, not part of the
//   Week 3 "compile clean" goal.
// =============================================================================

`endif // PERF_SEQUENCES_SV