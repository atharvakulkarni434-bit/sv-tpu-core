//==============================================================================
// File: perf_sequences.sv
// Description: UVM sequences that deliberately drive stimulus for
// mmu_perf_checker.sv to measure. Generates weight/activation matrices for
// many computations, back-to-back, across every legal size, so the checker
// has real activity to time. Only the data plane — control-plane writes
// (DIM_REG/CTRL_REG) come from elsewhere.
//==============================================================================

`ifndef PERF_SEQUENCES_SV      
`define PERF_SEQUENCES_SV       

`include "uvm_macros.svh"       // gives us uvm_error, uvm_info, etc.
import uvm_pkg::*;               // gives us UVM's base classes
`include "data_agent.sv"         // pulls in data_txn — the transaction type this file builds


class perf_base_seq extends uvm_sequence #(data_txn);   // shared base — declares it produces data_txn objects
    `uvm_object_utils(perf_base_seq)   // required boilerplate — registers this class with UVM

    function new(string name = "perf_base_seq");
        super.new(name);   // required boilerplate — hands the name up to UVM's base class
    endfunction

    // builds, randomizes, and sends ONE computation of the given size
    virtual task send_op(input int unsigned n);
        data_txn tr;                          // will hold the transaction we're about to build
        tr = data_txn::type_id::create("tr");  // create a blank data_txn object

        start_item(tr);                        // tell the sequencer "a transaction is coming"

        // randomize every field EXCEPT dim, which we force to exactly n
        if (!tr.randomize() with { dim == n; })
            `uvm_error(get_type_name(),
                       $sformatf("data_txn randomize failed for dim=%0d", n))   // stop and flag if randomize somehow fails

        finish_item(tr);   // send the completed transaction — the driver picks it up from here
    endtask

endclass : perf_base_seq


// fires MANY computations back-to-back, sweeping every legal size, so the
// checker sees every dim+5 target (6,7,8,9) under real streaming conditions
class perf_backtoback_seq extends perf_base_seq;
    `uvm_object_utils(perf_backtoback_seq)

    rand int unsigned num_sweeps;                    // how many full 1-4 sweeps to run
    constraint c_sweeps { num_sweeps inside {[3:8]}; } // keep it within a reasonable range

    function new(string name = "perf_backtoback_seq");
        super.new(name);
        num_sweeps = 3;   // default value if nobody randomizes this — 3 sweeps = 12 ops total
    endfunction

    virtual task body();
        // print what we're about to do
        `uvm_info(get_type_name(),
                  $sformatf("back-to-back throughput: %0d sweeps of dims 1..4 (%0d ops)",
                            num_sweeps, num_sweeps * 4), UVM_LOW)

        // loop through every sweep...
        for (int s = 0; s < num_sweeps; s++)
            // ...and within each sweep, every legal size, 1 through 4
            for (int n = 1; n <= 4; n++)
                send_op(n);   // send one computation of size n
    endtask

endclass : perf_backtoback_seq


// every op runs at N=4 specifically — the longest, hardest latency target
// in the whole contract (dim+5=9), streamed back-to-back repeatedly
class perf_n4_stress_seq extends perf_base_seq;
    `uvm_object_utils(perf_n4_stress_seq)

    rand int unsigned num_ops;                     // how many N=4 ops to run
    constraint c_ops { num_ops inside {[10:32]}; }  // keep it within a reasonable range

    function new(string name = "perf_n4_stress_seq");
        super.new(name);
        num_ops = 16;     // default op count if nobody randomizes this
    endfunction

    virtual task body();
        // print what we're about to do
        `uvm_info(get_type_name(),
                  $sformatf("N=4 worst-case stress: %0d back-to-back ops (dim+5=9 each)",
                            num_ops), UVM_LOW)

        // just fire the same size (4) over and over, num_ops times
        for (int i = 0; i < num_ops; i++)
            send_op(4);
    endtask

endclass : perf_n4_stress_seq


// -----------------------------------------------------------------------------
// NOTE: these sequences only handle the DATA side. A full computation also
// needs a test/virtual sequence to write the control registers around each
// send_op() call — roughly: write DIM_REG, press CTRL_REG start, poll
// STATUS_REG until done. Kept separate on purpose, so these sequences stay
// pure data-plane and reusable, not tied to one specific control flow.
// -----------------------------------------------------------------------------

`endif // PERF_SEQUENCES_SV
