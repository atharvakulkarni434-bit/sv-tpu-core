//==============================================================================
// File: mmu_env.sv
// Project: sv-tpu-core
// Date: 2026-07-17
//
// Description:
//   Top-level UVM environment. Instantiates the two agents (AXI-Lite control +
//   data plane), the REAL RAL register model + adapter, and the
//   scoreboard/coverage, and wires the analysis connections between them.
//
// Features:
//   - Instantiates axi_agent + data_agent
//   - Builds and locks the real mmu_reg_block (mmu_reg_model.sv), shares it
//     via config_db
//   - Instantiates mmu_reg_adapter and binds it to bus_map, wired to the
//     AXI sequencer so reg_model.DIM_REG.write(...) etc. actually drive the bus
//   - Connects AXI + data monitors to scoreboard and coverage
//   - Guarded stubs (`ifndef) for scoreboard/coverage only — the RAL model and
//     adapter are no longer stubbed; the real files are included directly
//   - Clean integration seam for the RAL adapter
//==============================================================================

`ifndef MMU_ENV_SV
`define MMU_ENV_SV

// UVM base classes and the `uvm_* macros must be visible in this compilation
// unit before the classes below.
`include "uvm_macros.svh"
import uvm_pkg::*;

// Bring in the agent classes this env instantiates (axi_txn / data_txn types,
// axi_agent / data_agent). Include guards make this safe if also compiled
// directly on the command line.
`include "axi_agent.sv"
`include "data_agent.sv"

// Real RAL model + adapter. These replace the old inline placeholder stub —
// mmu_reg_model.sv defines DIM_REG (RW)/CTRL_REG (RW)/STATUS_REG (RO) exactly
// per spec B.2/B.3/B.4, and mmu_reg_adapter.sv now matches axi_agent.sv's
// actual axi_txn type (see that file's header for what changed).
`include "mmu_reg_model.sv"
`include "mmu_reg_adapter.sv"


`ifndef MMU_SCOREBOARD_SV
// Two different analysis-imp payload types (axi_txn, data_txn) cannot both
// bind to a plain `write()` on the same component (SV has no method
// overloading by argument type) - hence the suffixed imp declarations below.
`uvm_analysis_imp_decl(_axi)
`uvm_analysis_imp_decl(_data)

class mmu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(mmu_scoreboard)
    uvm_analysis_imp_axi  #(axi_txn,  mmu_scoreboard) axi_imp;
    uvm_analysis_imp_data #(data_txn, mmu_scoreboard) data_imp;
    function new(string name, uvm_component parent);
        super.new(name, parent);
        axi_imp  = new("axi_imp",  this);
        data_imp = new("data_imp", this);
    endfunction

    virtual function void write_axi(axi_txn t);  endfunction
    virtual function void write_data(data_txn t); endfunction
endclass
`endif

`ifndef MMU_COVERAGE_SV
class mmu_coverage extends uvm_subscriber #(data_txn);
    `uvm_component_utils(mmu_coverage)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    virtual function void write(data_txn t); endfunction
endclass
`endif


class mmu_env extends uvm_env;
    `uvm_component_utils(mmu_env)

    // Agents
    axi_agent      axi_agt;
    data_agent     data_agt;

    // Analysis components
    mmu_scoreboard scoreboard;
    mmu_coverage   coverage;

    // Register model + adapter (RAL -> AXI). Real mmu_reg_block, not a stub.
    mmu_reg_block  reg_model;
    mmu_reg_adapter reg_adapter;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        axi_agt    = axi_agent::type_id::create("axi_agt", this);
        data_agt   = data_agent::type_id::create("data_agt", this);
        scoreboard = mmu_scoreboard::type_id::create("scoreboard", this);
        coverage   = mmu_coverage::type_id::create("coverage", this);

        // Build the real RAL model once and share it via config_db so tests
        // can reach it (reg_model.DIM_REG.write(...) etc.). build() and
        // lock_model() both already happen inside mmu_reg_block::build() in
        // mmu_reg_model.sv, so this is just create + build.
        reg_model = mmu_reg_block::type_id::create("reg_model");
        reg_model.build();
        uvm_config_db#(mmu_reg_block)::set(this, "*", "reg_model", reg_model);

        // Adapter translates RAL intent <-> axi_txn. Built here so it's ready
        // to bind to the map in connect_phase, once axi_agt.sequencer exists.
        reg_adapter = mmu_reg_adapter::type_id::create("reg_adapter");
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // AXI monitor -> scoreboard (register/control observations)
        axi_agt.monitor.ap.connect(scoreboard.axi_imp);

        // Data monitor -> scoreboard (result checking) and -> coverage
        data_agt.monitor.ap.connect(coverage.analysis_export);
        data_agt.monitor.ap.connect(scoreboard.data_imp);

        // Bind the RAL bus_map to the AXI sequencer via the adapter. This is
        // what makes reg_model.DIM_REG.write(...) actually generate an axi_txn
        // and drive it through axi_driver onto the interface, rather than only
        // updating the in-memory mirror.
        reg_model.bus_map.set_sequencer(axi_agt.sequencer, reg_adapter);

        // Auto-predict off: the AXI monitor already publishes completed
        // axi_txn's to the scoreboard for B.4 checking, and mirror updates on
        // a passive-predictor double-path would race that. If a teammate
        // wants automatic mirror updates from bus activity later, add a
        // uvm_reg_predictor#(axi_txn) here and connect it to axi_agt.monitor.ap
        // instead of flipping this to 1.
        reg_model.bus_map.set_auto_predict(0);

    endfunction

endclass : mmu_env

`endif // MMU_ENV_SV
