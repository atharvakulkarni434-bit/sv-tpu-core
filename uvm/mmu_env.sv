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
//   - Guarded stub (`ifndef) for scoreboard only — the RAL model, adapter,
//     and coverage are no longer stubbed; the real files are included
//     directly
//   - Clean integration seam for the RAL adapter
//
// CHANGE (this pass): mmu_coverage is no longer a local stub / uvm_subscriber.
// mmu_coverage.sv now defines the real class (uvm_component with its own
// axi_imp/data_imp analysis imps, mirroring mmu_scoreboard.sv's pattern), so
// the old inline stub here and its single
//     data_agt.monitor.ap.connect(coverage.analysis_export);
// connect are both replaced: the stub class is removed, mmu_coverage.sv is
// `included, and connect_phase now makes two explicit connects
// (axi_imp + data_imp) instead of one. See mmu_coverage.sv's header
// "INTEGRATION STATUS" note for the full rationale.
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

// Real scoreboard. Declares `uvm_analysis_imp_decl(_axi)/(_data) inside its
// own `ifndef MMU_SCOREBOARD_SV guard — mmu_coverage.sv (included below)
// checks that same guard before re-declaring the same suffixes, so exactly
// one of the two files ends up declaring them regardless of include order,
// as long as mmu_scoreboard.sv is included first (it is, both here and in
// run.f — see that file's ordering comment).
`include "mmu_scoreboard.sv"

// Real coverage model — replaces the old inline `ifndef MMU_COVERAGE_SV
// uvm_subscriber stub that used to live directly in this file. mmu_coverage
// now owns its own axi_imp/data_imp analysis imps (same pattern as
// mmu_scoreboard above) instead of a single analysis_export.
`include "mmu_coverage.sv"

// ADDED (combine from the stub mmu_env.sv): virtual-sequencer support for the
// Category-3/4 tests. mmu_sequences.sv defines mmu_virtual_sequencer (built +
// wired below) plus the reset/pattern virtual sequences those tests run. Nothing
// in the golden env above is changed by this include — it only makes the
// virtual sequencer type visible. mmu_sequences.sv re-`includes axi_agent.sv /
// data_agent.sv, both already guarded above.
`include "mmu_sequences.sv"


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

    // ADDED (from stub mmu_env.sv): virtual sequencer - carries the axi + data
    // sub-sequencer handles and the vif so the Category-3/4 reset virtual
    // sequences can orchestrate control writes, data-plane stimulus, FSM
    // observation, and reset from one place.
    mmu_virtual_sequencer v_sqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        axi_agt    = axi_agent::type_id::create("axi_agt", this);
        data_agt   = data_agent::type_id::create("data_agt", this);
        scoreboard = mmu_scoreboard::type_id::create("scoreboard", this);
        coverage   = mmu_coverage::type_id::create("coverage", this);

        // ADDED (from stub mmu_env.sv): build the virtual sequencer; its handles
        // are wired to the real sub-sequencers + vif in connect_phase.
        v_sqr      = mmu_virtual_sequencer::type_id::create("v_sqr", this);

        // Build the real RAL model once and share it via config_db so tests
        // can reach it (reg_model.DIM_REG.write(...) etc.). build() and
        // lock_model() both already happen inside mmu_reg_block::build() in
        // mmu_reg_model.sv, so this is just create + build.
        reg_model = mmu_reg_block::type_id::create("reg_model");
        reg_model.build();
        uvm_config_db#(mmu_reg_block)::set(null, "*", "reg_model", reg_model);

        // Adapter translates RAL intent <-> axi_txn. Built here so it's ready
        // to bind to the map in connect_phase, once axi_agt.sequencer exists.
        reg_adapter = mmu_reg_adapter::type_id::create("reg_adapter");
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // AXI monitor -> scoreboard (register/control observations)
        axi_agt.monitor.ap.connect(scoreboard.axi_imp);

        // AXI monitor -> coverage (cp_error_type, per mmu_coverage.sv's
        // write_axi()). Real component now, so this is a plain imp connect
        // rather than routing through a subscriber's analysis_export.
        axi_agt.monitor.ap.connect(coverage.axi_imp);

        // Data monitor -> scoreboard (result checking) and -> coverage
        // (cp_dim / cp_weight_pattern / cp_activation_pattern / both
        // crosses, per mmu_coverage.sv's write_data()).
        data_agt.monitor.ap.connect(scoreboard.data_imp);
        data_agt.monitor.ap.connect(coverage.data_imp);

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

        // ADDED (from stub mmu_env.sv): wire the virtual sequencer to the real
        // sub-sequencers and the vif so the Category-3/4 virtual sequences can
        // run on it. Only meaningful when the agents are active.
        if (axi_agt.get_is_active()  == UVM_ACTIVE) v_sqr.axi_sqr  = axi_agt.sequencer;
        if (data_agt.get_is_active() == UVM_ACTIVE) v_sqr.data_sqr = data_agt.sequencer;
        if (!uvm_config_db#(virtual mmu_if)::get(this, "", "vif", v_sqr.vif))
            `uvm_fatal("MMU_ENV", "virtual interface not set for mmu_virtual_sequencer")

    endfunction

endclass : mmu_env

`endif // MMU_ENV_SV
