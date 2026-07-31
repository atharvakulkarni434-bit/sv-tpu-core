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

// UVM base classes (uvm_sequence_item, uvm_driver, ...) and the `uvm_* macros
// must be visible in this compilation unit before the classes below.
`include "uvm_macros.svh"
import uvm_pkg::*;


// Transaction item - one AXI-Lite read or write to a control register.

class axi_txn extends uvm_sequence_item;

    typedef enum {WRITE, READ} rw_e;

    rand rw_e          rw;
    rand logic [3:0]   addr;    // 0x0 DIM_REG, 0x4 CTRL_REG, 0x8 STATUS_REG
    rand logic [31:0]  data;    // write data / captured read data
    rand logic [3:0]   strb;    // write strobe (WRITE only; ignored on READ)
    logic      [1:0]   resp;    // AXI response (OKAY expected)

    // Only the three legal offsets by default; error-injection sequences
    // may override this constraint to drive illegal addresses.
    constraint c_addr { addr inside {4'h0, 4'h4, 4'h8}; }

    // Full-word writes by default; error-injection sequences may override
    // this to exercise partial-strobe behavior.
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


// Driver - turns axi_txn items into AXI-Lite handshakes on the interface.

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
        // Idle the master outputs out of reset.
        drive_idle();
        wait (vif.rst_n === 1'b1);
        // Resync to the clock: `wait` above can unblock in the same delta
        // cycle rst_n is released, which is the same edge every
        // always_ff @(posedge clk or negedge rst_n) block in the DUT is
        // also evaluating. Without this extra edge the driver can start
        // driving one cycle ahead of the DUT actually being out of reset.
        @(vif.axi_cb);

        forever begin
            axi_txn tr;
            seq_item_port.get_next_item(tr);
            //`uvm_info("AXI_DRV", $sformatf("TRACE: got item addr=%0h rw=%s", tr.addr, tr.rw.name()), UVM_LOW)
            if (tr.rw == axi_txn::WRITE) drive_write(tr);
            else                           drive_read(tr);
            //`uvm_info("AXI_DRV", "TRACE: item_done called", UVM_LOW)
            seq_item_port.item_done(tr);
        end
    endtask

    //  handshake tasks
    task drive_idle();
        vif.axi_cb.awvalid <= 1'b0;
        vif.axi_cb.wvalid  <= 1'b0;
        vif.axi_cb.bready  <= 1'b0;
        vif.axi_cb.arvalid <= 1'b0;
        vif.axi_cb.rready  <= 1'b0;
    endtask

    task drive_write(axi_txn req);
        // Register onto a clocking-block edge before driving anything, so
        // awvalid/wvalid change synchronously with axi_cb rather than
        // combinationally between edges (matches drive_read's leading @).
        @(vif.axi_cb);

        vif.axi_cb.awaddr  <= req.addr;
        vif.axi_cb.awvalid <= 1'b1;

        vif.axi_cb.wdata   <= req.data;
        vif.axi_cb.wstrb   <= req.strb;
        vif.axi_cb.wvalid  <= 1'b1;

        // AW and W channels handshake independently per AXI-Lite; wait for
        // each *ready separately so a slave that accepts them on different
        // cycles doesn't deadlock this task.
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

        // B channel (write response) handshake.
        vif.axi_cb.bready <= 1'b1;
        do begin
            @(vif.axi_cb);
        end while (!vif.axi_cb.bvalid);

        req.resp = vif.axi_cb.bresp;
        vif.axi_cb.bready <= 1'b0;
    endtask

    // DEADLOCK FIX. The old body waited out the AR handshake first and only
    // then started a fresh `do @(...); while (!rvalid)`:
    //
    //     do @(axi_cb); while (!arready);   // exits on the cycle arready is high
    //     arvalid <= 0;
    //     do @(axi_cb); while (!rvalid);    // ALWAYS burns an edge first
    //
    // axi_lite_slave.sv registers arready and rvalid from the same `if
    // (arvalid && !rvalid)` branch, so both rise on the SAME cycle. rready was
    // already parked high, so that cycle is also the R-channel transfer: the
    // slave sees rvalid && rready and drops rvalid on the next edge. By the
    // time the second loop takes its first sample, rvalid is gone - and it
    // never comes back, because the read has already completed. The driver
    // then blocks forever inside get_next_item, wait_for_pass_done() never
    // returns, and tb_top's #1ms watchdog fires:
    //     UVM_FATAL tb/tb_top.sv(162) global timeout reached - simulation hung
    // The log's giveaway is [AXI_DRV] count 5: the addr=8 READ logs "got item"
    // with no matching "item_done".
    //
    // Handling AR and R concurrently means whichever cycle each channel
    // completes on is caught, including the case where that is one and the
    // same cycle. This mirrors what drive_write already does for AW/W.
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



// Monitor - passively samples AXI transactions for the scoreboard/coverage.

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



// Agent - bundles sequencer + driver + monitor. Active by default.

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