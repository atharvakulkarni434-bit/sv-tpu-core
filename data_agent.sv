//==============================================================================
// File: data_agent.sv
// Project: sv-tpu-core 
// Date: 2026-07-08
//
// Description:
//   Data-plane agent. Drives int8 activation columns into the systolic array
//   with the per-row skew the weight-stationary dataflow requires, drives the
//   int8 weight matrix during WEIGHT_LOAD, and monitors the int32 results
//   draining to the output buffer. 
//
// Features:
//   - data_txn item carrying NxN activation + weight matrices and dim N
//   - Driver: weight load then skewed activation column feed
//   - Monitor: captures int32 results on done + result_valid
//   - UVM_ACTIVE/UVM_PASSIVE aware agent wrapper
//   - dim constrained to 1..N (DIM_REG legal range)
//==============================================================================

`ifndef DATA_AGENT_SV
`define DATA_AGENT_SV


// Transaction item — one full matrix-multiply payload: an NxN activation
// matrix and an NxN weight matrix for a given dimension N.

class data_txn extends uvm_sequence_item;

    localparam int N = 4;

    rand int unsigned            dim;                 // active N (1..4)
    rand logic signed [7:0]      activations [N][N];  // int8 A matrix
    rand logic signed [7:0]      weights     [N][N];  // int8 B matrix
    logic signed [31:0]          results     [N];      // int32 results captured back (spec A.9: N x32, the bottom row's accum_out bus)

    constraint c_dim { dim inside {[1:N]}; }

    `uvm_object_utils_begin(data_txn)
        `uvm_field_int(dim, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "data_txn");
        super.new(name);
    endfunction

endclass : data_txn



// Driver — feeds weights then skewed activation columns into the array.

class data_driver extends uvm_driver #(data_txn);
    `uvm_component_utils(data_driver)

    virtual mmu_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal("DATA_DRV", "virtual interface not set for data_driver")
    endfunction

    task run_phase(uvm_phase phase);
        drive_idle();
        wait (vif.rst_n === 1'b1);
        forever begin
            data_txn tr;
            seq_item_port.get_next_item(tr);
            drive_weights(tr);
            drive_activations(tr);
            seq_item_port.item_done();
        end
    endtask

    task drive_idle();
        for (int r = 0; r < 4; r++) vif.data_cb.activations[r] <= '0;
    endtask

    // Present the weight matrix while the controller is in WEIGHT_LOAD.
    task drive_weights(data_txn tr);
        @(vif.data_cb);
        for (int r = 0; r < tr.dim; r++)
            for (int c = 0; c < tr.dim; c++)
                vif.data_cb.weights[r][c] <= tr.weights[r][c];
    endtask

    // Feed activation columns one per cycle with the per-row skew that the
    // weight-stationary array needs (row r starts r cycles late). Row r's
    // column k is presented on local cycle (r + k), so the whole feed takes
    // 2*dim-1 cycles (matches the 2N-1 unpipelined term in spec C.2/C.6).
    task drive_activations(data_txn tr);
        int total_cycles = 2 * tr.dim - 1;
        for (int t = 0; t < total_cycles; t++) begin
            @(vif.data_cb);
            for (int r = 0; r < 4; r++) begin
                int k = t - r;
                if (r < tr.dim && k >= 0 && k < tr.dim)
                    vif.data_cb.activations[r] <= tr.activations[r][k];
                else
                    vif.data_cb.activations[r] <= '0;
            end
        end
    endtask

endclass : data_driver



// Monitor — samples the int32 results when the buffer signals valid.

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
            @(vif.mon_cb);
            // Week 1 stub: on done + result_valid, capture the result vector
            // and publish it for the scoreboard.
            if (vif.mon_cb.done && vif.mon_cb.result_valid) begin
                data_txn tr = data_txn::type_id::create("tr");
                tr.dim = vif.mon_cb.dim_n;
                for (int c = 0; c < 4; c++)
                    tr.results[c] = vif.mon_cb.results[c];
                ap.write(tr);
            end
        end
    endtask

endclass : data_monitor



// Agent — sequencer + driver + monitor. Active by default.

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