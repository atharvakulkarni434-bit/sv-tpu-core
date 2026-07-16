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
//
// Features:
//   - data_txn item carrying NxN activation + weight matrices and dim N
//   - Driver: weight load, then N unskewed columns gated on flow_en
//   - Monitor: captures stimulus, results, and the C.6 latency window
//   - UVM_ACTIVE/UVM_PASSIVE aware agent wrapper
//   - dim constrained to 1..N (DIM_REG legal range, spec B.4)
//==============================================================================

`ifndef DATA_AGENT_SV
`define DATA_AGENT_SV

// UVM base classes and the `uvm_* macros must be visible in this compilation
// unit before the classes below.
`include "uvm_macros.svh"
import uvm_pkg::*;


// Transaction item - one full matrix-multiply payload: an NxN activation
// matrix and an NxN weight matrix for a given dimension N.

class data_txn extends uvm_sequence_item;

    localparam int N = 4;

    rand int unsigned            dim;                 // active N (1..4)
    rand logic signed [7:0]      activations [N][N];  // int8 A matrix
    rand logic signed [7:0]      weights     [N][N];  // int8 B matrix
    logic signed [31:0]          results     [N];      // int32 results captured back (spec A.9: N x32, the bottom row's accum_out bus)

    // Weight-poisoning hooks (driven by weight_poison_seq in mmu_sequences.sv).
    // The array is weight-stationary, so a weight change after WEIGHT_LOAD is a
    // protocol violation the DUT must either reject or visibly corrupt - either
    // way the scoreboard's clean-weight prediction should no longer match.
    rand bit                     poison_en;              // corrupt weights mid-feed
    rand int unsigned            poison_cycle;           // activation column to corrupt on
    rand logic signed [7:0]      poison_weights [N][N];  // replacement matrix

    constraint c_dim { dim inside {[1:N]}; }

    // Poison lands on one of the dim activation columns, never during
    // WEIGHT_LOAD - the point is to mutate weights the array has already
    // latched and is mid-way through computing on.
    constraint c_poison_cycle { poison_cycle inside {[0 : dim-1]}; }

    // Off unless a sequence asks for it, so existing sequences are unaffected.
    constraint c_poison_default { soft poison_en == 1'b0; }

    // C.6 observation: cycles from the first ACTIVATION_FLOW cycle (flow_en
    // high) to done. Filled in by the monitor; checked by the latency_checker
    // in mmu_scoreboard.sv against the locked 2N contract.
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



// Driver - feeds weights then skewed activation columns into the array.

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
    // Feed one unskewed activation column per cycle, exactly as A.1/A.6
    // describe ("activations flow in from the left, one column per cycle", col
    // 1 through col N). The diagonal wavefront is applied in RTL by
    // skew_buffer.sv, not here - C.1 places the stagger on the design side. A
    // driver that also skewed would delay row r twice over.
    task drive_activations(data_txn tr);
        // The controller owns phase sequencing (spec A.5): weights latch during
        // WEIGHT_LOAD, accumulators zero during PE_CLEAR, and only then does
        // ACTIVATION_FLOW open. Feeding before flow_en would push columns into
        // an array that is still clearing - and would put the first activation
        // on a different cycle than the one C.6 measures from.
        do @(vif.data_cb); while (!vif.data_cb.flow_en);

        // N columns over N cycles. flow_en stays high for the full 2N window
        // while the wavefront drains; the bus idles at zero for the remainder.
        for (int k = 0; k < tr.dim; k++) begin
            for (int r = 0; r < 4; r++)
                vif.data_cb.activations[r] <= (r < tr.dim) ? tr.activations[r][k] : '0;

            // Weight poisoning: overwrite the stationary weights partway
            // through the feed, while partial sums are still in flight.
            if (tr.poison_en && k == tr.poison_cycle) begin
                for (int r = 0; r < tr.dim; r++)
                    for (int c = 0; c < tr.dim; c++)
                        vif.data_cb.weights[r][c] <= tr.poison_weights[r][c];
                `uvm_info("DATA_DRV",
                    $sformatf("poisoned weights on activation column %0d of %0d", k, tr.dim),
                    UVM_MEDIUM)
            end

            @(vif.data_cb);
        end

        drive_idle();
    endtask

endclass : data_driver



// Monitor - samples the int32 results when the buffer signals valid.

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

    // Capture a whole pass - stimulus and result - so the scoreboard can run a
    // reference model instead of only eyeballing the result vector. The bus
    // carries unskewed columns (skew_buffer.sv applies the wavefront inside the
    // DUT), so column k is simply what sits on the bus at flow cycle k.
    task run_phase(uvm_phase phase);
        wait (vif.rst_n === 1'b1);
        forever begin
            data_txn tr;
            int t;

            // A pass opens when the controller sees the CTRL_REG start bit.
            do @(vif.mon_cb); while (!vif.mon_cb.start);

            tr = data_txn::type_id::create("tr");
            tr.dim = vif.mon_cb.dim_n;

            // Weights are stationary and held from WEIGHT_LOAD onward, so
            // sampling once at start captures the matrix the array computes on.
            // A weight_poison_seq run mutates them after this point - by design,
            // the scoreboard predicts from these clean values and the mismatch
            // is the test's signal.
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tr.weights[r][c] = vif.mon_cb.weights[r][c];

            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++)
                    tr.activations[r][c] = '0;

            // C.6 measures from the first ACTIVATION_FLOW cycle, so the latency
            // count and the column index share flow_en as their origin.
            do @(vif.mon_cb); while (!vif.mon_cb.flow_en);

            // Sample the feed until the array reports done, counting cycles as
            // we go. Sitting at the first flow_en cycle with t=0 means the exit
            // count is exactly (done cycle - first flow cycle) - the C.6 window.
            // Only the first dim cycles carry columns; the rest of the window is
            // the wavefront draining, with the bus idle.
            t = 0;
            while (!vif.mon_cb.done) begin
                if (t < int'(tr.dim))
                    for (int r = 0; r < 4; r++)
                        if (r < int'(tr.dim))
                            tr.activations[r][t] = vif.mon_cb.activations[r];
                @(vif.mon_cb);
                t++;
            end
            tr.latency = t;

            for (int c = 0; c < 4; c++)
                tr.results[c] = vif.mon_cb.results[c];

            ap.write(tr);
        end
    endtask

endclass : data_monitor



// Agent - sequencer + driver + monitor. Active by default.

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
