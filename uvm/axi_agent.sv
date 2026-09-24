//==============================================================================
// File: axi_agent.sv
// Project: sv-tpu-core
// Date: 2026-07-25
//
// Description:
//   AXI-Lite master agent. Drives the three control registers (DIM_REG,
//   CTRL_REG, STATUS_REG) over the AXI-Lite channels.
//
// Features:
//   - axi_txn sequence item (WRITE/READ, constrained to the 3 legal offsets)
//   - Driver with AXI-Lite write/read handshake tasks
//   - Passive monitor publishing completed transactions via analysis port
//   - UVM_ACTIVE/UVM_PASSIVE aware agent wrapper
//   - Illegal-address constraint override hook for error-injection sequences
//==============================================================================

`ifndef AXI_AGENT_SV
`define AXI_AGENT_SV

`include "uvm_macros.svh"
import uvm_pkg::*;


class axi_txn extends uvm_sequence_item;

    typedef enum {WRITE, READ} rw_e;

    rand rw_e          rw;
    rand logic [3:0]   addr;    
    rand logic [31:0]  data;  
    rand logic [3:0]   strb;    
    logic      [1:0]   resp;    

    constraint c_addr { addr inside {4'h0, 4'h4, 4'h8}; }

    constraint c_strb { strb == 4'hF; }

    `uvm_object_utils_begin(axi_txn)
        `uvm_field_enum(rw_e, rw, UVM_ALL_ON)
        `uvm_field_int(addr, UVM_ALL_ON)
        `uvm_field_int(data, UVM_ALL_ON)
        `uvm_field_int(strb, UVM_ALL_ON)
        `uvm_field_int(resp, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axi_txn");
        super.new(name);
    endfunction

endclass : axi_txn

class axi_driver extends uvm_driver #(axi_txn);
    `uvm_component_utils(axi_driver)

    virtual mmu_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal("AXI_DRV", "virtual interface not set for axi_driver")
    endfunction

    task run_phase(uvm_phase phase);
        drive_idle();
        wait (vif.rst_n === 1'b1);
        @(vif.axi_cb);

        forever begin
            axi_txn tr;
            seq_item_port.get_next_item(tr);
            if (tr.rw == axi_txn::WRITE) drive_write(tr);
            else                           drive_read(tr);
            seq_item_port.item_done(tr);
        end
    endtask

    task drive_idle();
        vif.axi_cb.awvalid <= 1'b0;
        vif.axi_cb.wvalid  <= 1'b0;
        vif.axi_cb.bready  <= 1'b0;
        vif.axi_cb.arvalid <= 1'b0;
        vif.axi_cb.rready  <= 1'b0;
    endtask

    task drive_write(axi_txn req);
        @(vif.axi_cb);

        vif.axi_cb.awaddr  <= req.addr;
        vif.axi_cb.awvalid <= 1'b1;

        vif.axi_cb.wdata   <= req.data;
        vif.axi_cb.wstrb   <= req.strb;
        vif.axi_cb.wvalid  <= 1'b1;

        fork
            begin : aw_handshake
                do begin
                    @(vif.axi_cb);
                end while (!vif.axi_cb.awready);
                vif.axi_cb.awvalid <= 1'b0;
            end
            begin : w_handshake
                do begin
                    @(vif.axi_cb);
                end while (!vif.axi_cb.wready);
                vif.axi_cb.wvalid <= 1'b0;
            end
        join

        vif.axi_cb.bready <= 1'b1;
        do begin
            @(vif.axi_cb);
        end while (!vif.axi_cb.bvalid);

        req.resp = vif.axi_cb.bresp;
        vif.axi_cb.bready <= 1'b0;
    endtask
    task drive_read(axi_txn tr);
        @(vif.axi_cb);
        vif.axi_cb.araddr  <= tr.addr;
        vif.axi_cb.arvalid <= 1'b1;
        vif.axi_cb.rready  <= 1'b1;

        fork
            begin : ar_handshake
                do @(vif.axi_cb); while (!vif.axi_cb.arready);
                vif.axi_cb.arvalid <= 1'b0;
            end
            begin : r_handshake
                do @(vif.axi_cb); while (!vif.axi_cb.rvalid);
                tr.data = vif.axi_cb.rdata;
                tr.resp = vif.axi_cb.rresp;
                vif.axi_cb.rready <= 1'b0;
            end
        join
    endtask

endclass : axi_driver



class axi_monitor extends uvm_monitor;
    `uvm_component_utils(axi_monitor)

    virtual mmu_if vif;
    uvm_analysis_port #(axi_txn) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", vif))
            `uvm_fatal("AXI_MON", "virtual interface not set for axi_monitor")
    endfunction

    task run_phase(uvm_phase phase);
        wait (vif.rst_n === 1'b1);
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.bvalid && vif.mon_cb.bready) begin
                axi_txn tr = axi_txn::type_id::create("tr");
                tr.rw   = axi_txn::WRITE;
                tr.addr = vif.mon_cb.awaddr;
                tr.data = vif.mon_cb.wdata;
                tr.strb = vif.mon_cb.wstrb;
                tr.resp = vif.mon_cb.bresp;
                ap.write(tr);
            end
            if (vif.mon_cb.rvalid && vif.mon_cb.rready) begin
                axi_txn tr = axi_txn::type_id::create("tr");
                tr.rw   = axi_txn::READ;
                tr.addr = vif.mon_cb.araddr;
                tr.data = vif.mon_cb.rdata;
                tr.resp = vif.mon_cb.rresp;
                ap.write(tr);
            end
        end
    endtask

endclass : axi_monitor


class axi_agent extends uvm_agent;
    `uvm_component_utils(axi_agent)

    uvm_sequencer #(axi_txn) sequencer;
    axi_driver               driver;
    axi_monitor              monitor;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor = axi_monitor::type_id::create("monitor", this);
        if (get_is_active() == UVM_ACTIVE) begin
            sequencer = uvm_sequencer#(axi_txn)::type_id::create("sequencer", this);
            driver    = axi_driver::type_id::create("driver", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction

endclass : axi_agent

`endif // AXI_AGENT_SV
