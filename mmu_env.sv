//==============================================================================
// File: mmu_env.sv
// Project: sv-tpu-core 
// Date: 2026-07-08
//
// Description:
//   Top-level UVM environment. Instantiates the two agents (AXI-Lite control +
//   data plane), the RAL register model, and the scoreboard/coverage, and wires
//   the analysis connections between them. 
//
// Features:
//   - Instantiates axi_agent + data_agent
//   - Builds and locks the RAL model, shares it via config_db
//   - Connects AXI + data monitors to scoreboard and coverage
//   - Guarded stubs (`ifndef) for scoreboard, coverage, reg_model
//   - Clean integration seam for the RAL adapter 
//==============================================================================

`ifndef MMU_ENV_SV
`define MMU_ENV_SV


`ifndef MMU_SCOREBOARD_SV
// Two different analysis-imp payload types (axi_txn, data_txn) cannot both
// bind to a plain `write()` on the same component (SV has no method
// overloading by argument type) — hence the suffixed imp declarations below.
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

`ifndef MMU_REG_MODEL_SV
// Minimal RAL block placeholder — real mmu_reg_model (VERIF) declares
// DIM_REG (RW), CTRL_REG (RW), STATUS_REG (RO)
class mmu_reg_model extends uvm_reg_block;
    `uvm_object_utils(mmu_reg_model)
    function new(string name = "mmu_reg_model"); super.new(name, UVM_NO_COVERAGE); endfunction
    virtual function void build(); endfunction
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

    // Register model + adapter (RAL -> AXI)
    mmu_reg_model  reg_model;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        axi_agt    = axi_agent::type_id::create("axi_agt", this);
        data_agt   = data_agent::type_id::create("data_agt", this);
        scoreboard = mmu_scoreboard::type_id::create("scoreboard", this);
        coverage   = mmu_coverage::type_id::create("coverage", this);

        // Build the RAL model once and share it via config_db so tests and the
        // adapter can reach it. Real build() defines the three registers.
        reg_model = mmu_reg_model::type_id::create("reg_model");
        reg_model.build();
        reg_model.lock_model();
        uvm_config_db#(mmu_reg_model)::set(this, "*", "reg_model", reg_model);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // AXI monitor -> scoreboard (register/control observations)
        axi_agt.monitor.ap.connect(scoreboard.axi_imp);

        // Data monitor -> scoreboard (result checking) and -> coverage
        data_agt.monitor.ap.connect(scoreboard.data_imp);
        data_agt.monitor.ap.connect(coverage.analysis_export);

       
    endfunction

endclass : mmu_env

`endif // MMU_ENV_SV