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

`include "uvm_macros.svh"    
import uvm_pkg::*;               
`include "data_agent.sv"       


class perf_base_seq extends uvm_sequence #(data_txn);   
    `uvm_object_utils(perf_base_seq)   
    function new(string name = "perf_base_seq");
        super.new(name);   
    endfunction

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


class perf_backtoback_seq extends perf_base_seq;
    `uvm_object_utils(perf_backtoback_seq)

    rand int unsigned num_sweeps;                   
    constraint c_sweeps { num_sweeps inside {[3:8]}; } 

    function new(string name = "perf_backtoback_seq");
        super.new(name);
        num_sweeps = 3;   
    endfunction

    virtual task body();
        `uvm_info(get_type_name(),
                  $sformatf("back-to-back throughput: %0d sweeps of dims 1..4 (%0d ops)",
                            num_sweeps, num_sweeps * 4), UVM_LOW)

        for (int s = 0; s < num_sweeps; s++)
            // ...and within each sweep, every legal size, 1 through 4
            for (int n = 1; n <= 4; n++)
                send_op(n);   // send one computation of size n
    endtask

endclass : perf_backtoback_seq


class perf_n4_stress_seq extends perf_base_seq;
    `uvm_object_utils(perf_n4_stress_seq)

    rand int unsigned num_ops;                     
    constraint c_ops { num_ops inside {[10:32]}; }  

    function new(string name = "perf_n4_stress_seq");
        super.new(name);
        num_ops = 16;     
    endfunction

    virtual task body();
        `uvm_info(get_type_name(),
                  $sformatf("N=4 worst-case stress: %0d back-to-back ops (dim+5=9 each)",
                            num_ops), UVM_LOW)

        for (int i = 0; i < num_ops; i++)
            send_op(4);
    endtask

endclass : perf_n4_stress_seq



`endif 
