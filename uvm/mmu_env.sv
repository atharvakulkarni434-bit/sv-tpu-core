//==============================================================================
// File: mmu_env.sv
// Description: the assembler. Builds and wires together everything the
// testbench needs — the two agents (AXI-Lite control + data plane), the
// real RAL register model, the scoreboard, coverage, and the virtual
// sequencer — into one complete UVM environment.
//==============================================================================

`ifndef MMU_ENV_SV
`define MMU_ENV_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "axi_agent.sv"       // defines axi_txn — most other files below need this type
`include "data_agent.sv"      // defines data_txn — same reason, order vs axi_agent.sv doesn't matter
`include "mmu_reg_model.sv"   // grouped with its adapter below, needs axi_txn to already exist
`include "mmu_reg_adapter.sv" // translates reg_model writes into axi_txn — needs axi_txn defined first
`include "mmu_scoreboard.sv"  // MUST come before mmu_coverage.sv — they share a macro declaration, only one file can declare it
`include "mmu_coverage.sv"    // comes after scoreboard on purpose — see note above
`include "mmu_sequences.sv"   // comes last — needs both agents' sequencer types already defined


class mmu_env extends uvm_env;
    `uvm_component_utils(mmu_env)

    // the two agents
    axi_agent      axi_agt;
    data_agent     data_agt;

    // the two analysis components — checking and tracking, respectively
    mmu_scoreboard scoreboard;
    mmu_coverage   coverage;

    // the register model (RAL) and its adapter, translating reg_model
    // writes into real axi_txn transactions
    mmu_reg_block  reg_model;
    mmu_reg_adapter reg_adapter;

    // carries the axi + data sub-sequencer handles and the vif, so
    // Category-3/4 reset virtual sequences can coordinate everything
    // from one central place
    mmu_virtual_sequencer v_sqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // create every component this env owns
        axi_agt    = axi_agent::type_id::create("axi_agt", this);
        data_agt   = data_agent::type_id::create("data_agt", this);
        scoreboard = mmu_scoreboard::type_id::create("scoreboard", this);
        coverage   = mmu_coverage::type_id::create("coverage", this);
        v_sqr      = mmu_virtual_sequencer::type_id::create("v_sqr", this);

        // build the RAL model once, then share it globally through
        // config_db so any test can reach it (reg_model.DIM_REG.write(...))
        reg_model = mmu_reg_block::type_id::create("reg_model");
        reg_model.build();
        uvm_config_db#(mmu_reg_block)::set(null, "*", "reg_model", reg_model);

        // build the adapter now — it gets bound to the actual sequencer
        // in connect_phase, once axi_agt.sequencer actually exists
        reg_adapter = mmu_reg_adapter::type_id::create("reg_adapter");
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // AXI monitor -> scoreboard: register/control writes get checked
        axi_agt.monitor.ap.connect(scoreboard.axi_imp);

        // AXI monitor -> coverage: tracks what error types actually got exercised
        axi_agt.monitor.ap.connect(coverage.axi_imp);

        // data monitor -> scoreboard: real computed results get checked
        // data monitor -> coverage: tracks which dims/patterns got tested
        data_agt.monitor.ap.connect(scoreboard.data_imp);
        data_agt.monitor.ap.connect(coverage.data_imp);

        // makes reg_model writes actually reach real hardware, not just memory
        reg_model.bus_map.set_sequencer(axi_agt.sequencer, reg_adapter);

        // off on purpose — avoids a second path fighting the scoreboard's own updates
        reg_model.bus_map.set_auto_predict(0);

        // gives the virtual sequencer access to the real sequencers
        if (axi_agt.get_is_active()  == UVM_ACTIVE) v_sqr.axi_sqr  = axi_agt.sequencer;
        if (data_agt.get_is_active() == UVM_ACTIVE) v_sqr.data_sqr = data_agt.sequencer;

        // gives the virtual sequencer access to the real interface too
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", v_sqr.vif))
            `uvm_fatal("MMU_ENV", "virtual interface not set for mmu_virtual_sequencer")

    endfunction

endclass : mmu_env

`endif // MMU_ENV_SV
