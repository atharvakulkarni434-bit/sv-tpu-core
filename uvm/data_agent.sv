//==============================================================================
// File: data_agent.sv
// Project: sv-tpu-core 
// Date: 2026-07-08
//
// Description:
//   Data-plane agent. Drives int8 activation columns into the systolic array,
//   one column per cycle during ACTIVATION_FLOW (spec A.1/A.6), drives the int8
//   weight matrix during WEIGHT_LOAD, and monitors the int32 results draining
//   to the output buffer.
//
//   The diagonal wavefront skew is applied in RTL by skew_buffer.sv, not here.
//   C.1 places the stagger on the design side, and skewing on both sides would
//   delay row r twice over.
//==============================================================================

`ifndef DATA_AGENT_SV
`define DATA_AGENT_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

class data_txn extends uvm_sequence_item;

    localparam int N = 4;
    
    rand int unsigned            dim;                 // active N (1..4)
    rand logic signed [7:0]      activations [N][N];  // int8 A matrix
    rand logic signed [7:0]      weights     [N][N];  // int8 B matrix

    logic signed [31:0]          results     [N][N];

    rand bit                     poison_en;              // corrupt weights mid-feed
    rand int unsigned            poison_cycle;           // activation column to corrupt on
    rand logic signed [7:0]      poison_weights [N][N];  // replacement matrix

    constraint c_dim { dim inside {[1:N]}; }

    constraint c_poison_cycle { poison_cycle inside {[0 : dim-1]}; }

    constraint c_poison_default { soft poison_en == 1'b0; }

    int unsigned latency;

    `uvm_object_utils_begin(data_txn)
        `uvm_field_int(dim, UVM_ALL_ON)
        `uvm_field_int(poison_en, UVM_ALL_ON)
        `uvm_field_int(poison_cycle, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "data_txn");
        super.new(name);
    endfunction

endclass : data_txn


class data_driver extends uvm_driver #(data_txn);
    `uvm_component_utils(data_driver)

    virtual mmu_if vif;
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
        stim_staged  = uvm_event_pool::get_global("mmu_stim_staged");
        pass_release = uvm_event_pool::get_global("mmu_pass_release");
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal("DATA_DRV", "virtual interface not set for data_driver")
    endfunction

    task run_phase(uvm_phase phase);
        bit first_txn = 1'b1;

        drive_idle();
        wait (vif.rst_n === 1'b1);
        @(vif.data_cb);
        forever begin
            data_txn tr;

            if (!first_txn) begin
                pass_release.wait_ptrigger();
                pass_release.reset();   // consumer owns reset() - see mmu_base_test.sv
            end
            first_txn = 1'b0;

            seq_item_port.get_next_item(tr);

            stage_weights(tr);
            stim_staged.trigger(tr);      // test may now program DIM_REG + start
            drive_activations(tr);

            do @(vif.data_cb); while (!vif.data_cb.done);

            seq_item_port.item_done();
        end
    endtask

    task drive_idle();
        for (int r = 0; r < 4; r++) vif.data_cb.activations[r] <= '0;
    endtask

    task stage_weights(data_txn tr);
        @(vif.data_cb);
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++)
                vif.data_cb.weights[r][c] <=
                    (r < int'(tr.dim) && c < int'(tr.dim)) ? tr.weights[r][c] : 8'sd0;
        @(vif.data_cb);   // let the value settle on the bus before start
    endtask

    task drive_activations(data_txn tr);
        do @(vif.data_cb); while (!vif.data_cb.flow_en);

        for (int k = 0; k < int'(tr.dim); k++) begin
            for (int c = 0; c < 4; c++)
                vif.data_cb.activations[c] <=
                    (c < int'(tr.dim)) ? tr.activations[k][c] : 8'sd0;

            if (tr.poison_en && k == int'(tr.poison_cycle)) begin
                for (int r = 0; r < 4; r++)
                    for (int c = 0; c < 4; c++)
                        vif.data_cb.weights[r][c] <=
                            (r < int'(tr.dim) && c < int'(tr.dim)) ? tr.poison_weights[r][c] : 8'sd0;
                `uvm_info("DATA_DRV",
                    $sformatf("poisoned weights on activation feed cycle %0d of %0d", k, tr.dim),
                    UVM_MEDIUM)
            end

            @(vif.data_cb);
        end

        drive_idle();
    endtask

endclass : data_driver


class data_monitor extends uvm_monitor;
    `uvm_component_utils(data_monitor)

    virtual mmu_if vif;
    uvm_analysis_port #(data_txn) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal("DATA_MON", "virtual interface not set for data_monitor")
    endfunction

    task run_phase(uvm_phase phase);
        wait (vif.rst_n === 1'b1);
        forever begin
            data_txn tr;
            int t;
            bit aborted = 1'b0;

            do @(vif.mon_cb); while (!vif.mon_cb.flow_en);

            tr = data_txn::type_id::create("tr");
            tr.dim = vif.mon_cb.dim_n;

            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tr.weights[r][c] = vif.mon_cb.weights[r][c];

            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tr.activations[r][c] = 8'sd0;

            fork
                begin : capture
                    t = 0;
                    while (!vif.mon_cb.done) begin
                        if (t >= 1 && t <= int'(tr.dim))
                            for (int c = 0; c < 4; c++)
                                if (c < int'(tr.dim))
                                    tr.activations[t-1][c] = vif.mon_cb.activations[c];
                        @(vif.mon_cb);
                        t++;
                    end

                    tr.latency = t;

                    for (int r = 0; r < 4; r++)
                        for (int c = 0; c < 4; c++)
                            tr.results[r][c] = vif.mon_cb.results[r][c];
                end
                begin : abort_on_reset
                    @(negedge vif.rst_n);
                    aborted = 1'b1;
                end
            join_any
            disable fork;

            if (!aborted)
                ap.write(tr);
            else
                wait (vif.rst_n === 1'b1);   // let reset finish before re-syncing
        end
    endtask

endclass : data_monitor


class data_agent extends uvm_agent;
    `uvm_component_utils(data_agent)

    uvm_sequencer #(data_txn) sequencer;
    data_driver               driver;
    data_monitor              monitor;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor = data_monitor::type_id::create("monitor", this);
        if (get_is_active() == UVM_ACTIVE) begin
            sequencer = uvm_sequencer#(data_txn)::type_id::create("sequencer", this);
            driver    = data_driver::type_id::create("driver", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass : data_agent

`endif // DATA_AGENT_SV
