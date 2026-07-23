//==============================================================================
// File: mmu_base_test.sv
// Project: sv-tpu-core
// Date: 2026-07-23
//
// Description:
//   Base UVM test for sv-tpu-core. Builds mmu_env, fetches the shared RAL
//   model (mmu_reg_block) that mmu_env.sv publishes via config_db, and
//   provides the common bring-up sequence every directed/random test needs:
//   reset the DUT's register view, then hand control to a virtual sequence
//   hook that derived tests override.
//
// Why a base test at all (not just extending mmu_env directly per test):
//   - One place to raise objections/set the UVM phase timeout, so every
//     test gets the same watchdog behavior instead of each test remembering
//     to do it.
//   - One place to grab reg_model from config_db and sanity-check it exists,
//     instead of every test repeating the same uvm_fatal-on-missing-vif-style
//     boilerplate.
//   - Directed tests (weight_poison, dim error-injection, etc.) become thin:
//     override run_phase's body or reg_model-driven sequence, inherit
//     everything else.
//
// Usage:
//   class my_test extends mmu_base_test;
//       `uvm_component_utils(my_test)
//       function new(string name = "my_test", uvm_component parent);
//           super.new(name, parent);
//       endfunction
//       virtual task main_phase(uvm_phase phase);
//           phase.raise_objection(this);
//           // reg_model is already built/connected here - just use it:
//           reg_model.DIM_REG.write(status, 3'd2);
//           ...
//           phase.drop_objection(this);
//       endtask
//   endclass
//
// Features:
//   - Instantiates mmu_env (env)
//   - Fetches the real mmu_reg_block built by mmu_env::build_phase via
//     uvm_config_db, fatals immediately if it's not there (env miswired)
//   - Default UVM_TIMEOUT set generously; override set_type_override or
//     the timeout in a derived test's build_phase if a directed test needs
//     something tighter/looser
//   - end_of_elaboration_phase prints the topology - cheap sanity check
//     that the env came up with the agents/scoreboard we expect
//   - report_phase prints a one-line PASS/FAIL banner keyed off UVM's own
//     error/fatal counters, so CI log-scraping has one consistent string
//     across every test built on this base
//==============================================================================

`ifndef MMU_BASE_TEST_SV
`define MMU_BASE_TEST_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_env.sv"

class mmu_base_test extends uvm_test;
    `uvm_component_utils(mmu_base_test)

    // Environment - every test built on this base gets the same one.
    mmu_env env;

    // Shared RAL model, fetched from config_db once env.build_phase has
    // published it (see mmu_env.sv: reg_model built + set() there). Derived
    // tests read/write registers through this handle, e.g.
    // reg_model.DIM_REG.write(status, 4).
    mmu_reg_block reg_model;

    function new(string name = "mmu_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //--------------------------------------------------------------------
    // build_phase - construct the env, then pull the RAL model handle that
    // mmu_env::build_phase already built and published via config_db. Order
    // matters: env must be created (which runs its own build_phase and does
    // the uvm_config_db#(mmu_reg_block)::set(...)) before this class's own
    // build_phase can successfully get() it back out - both happen within
    // this same build_phase call because uvm_component::create() recurses
    // into the child's build_phase in classic (non-UVM-1.2-only) flows only
    // if invoked via the phase mechanism; to avoid relying on that ordering
    // subtlety, the get() is done in connect_phase instead, after the whole
    // build_phase tree is guaranteed complete.
    //--------------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        env = mmu_env::type_id::create("env", this);

        // Generous default so a directed test that's slow (e.g. many back
        // to back matmul passes) doesn't spuriously time out. Derived tests
        // needing a tighter watchdog for a hang-detection test can override
        // this in their own build_phase after calling super.build_phase().
        uvm_top.set_timeout(1ms, 0);
    endfunction

    //--------------------------------------------------------------------
    // connect_phase - safe point to fetch reg_model: mmu_env's own
    // build_phase (which does the config_db::set) has unconditionally
    // completed by now, regardless of component creation order.
    //--------------------------------------------------------------------
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (!uvm_config_db#(mmu_reg_block)::get(this, "", "reg_model", reg_model))
            `uvm_fatal("MMU_BASE_TEST",
                "reg_model not found in config_db - check mmu_env::build_phase set() path")
    endfunction

    //--------------------------------------------------------------------
    // end_of_elaboration_phase - print the topology once per run. Cheap
    // sanity check: if an agent/scoreboard silently failed to build, this
    // printout is usually the first thing that looks wrong in the log.
    //--------------------------------------------------------------------
    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        `uvm_info("MMU_BASE_TEST", "topology:", UVM_LOW)
        print();
    endfunction

    //--------------------------------------------------------------------
    // run_phase - base test itself runs no stimulus (num_txns effectively
    // 0). It exists to be extended, not run standalone in regression - see
    // header. A bare mmu_base_test just builds the env, prints topology,
    // and exits cleanly, which is a reasonable smoke check on its own
    // (confirms the whole env/vif/reg_model wiring elaborates without a
    // uvm_fatal) even before any real sequence runs.
    //--------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        // Intentionally empty. Derived tests override run_phase (or, more
        // commonly, just main_phase) to drive reg_model / start sequences
        // on env.axi_agt.sequencer and env.data_agt.sequencer.
    endtask

    //--------------------------------------------------------------------
    // report_phase - one consistent PASS/FAIL banner across every test
    // built on this base, keyed off UVM's own severity counters so it
    // can't drift out of sync with what actually happened.
    //--------------------------------------------------------------------
    virtual function void report_phase(uvm_phase phase);
        uvm_report_server svr;
        int unsigned n_errors, n_fatals;

        super.report_phase(phase);

        svr      = uvm_report_server::get_server();
        n_errors = svr.get_severity_count(UVM_ERROR);
        n_fatals = svr.get_severity_count(UVM_FATAL);

        if (n_errors == 0 && n_fatals == 0)
            `uvm_info("MMU_BASE_TEST",
                $sformatf("*** TEST PASSED (%s) ***", get_type_name()), UVM_NONE)
        else
            `uvm_error("MMU_BASE_TEST",
                $sformatf("*** TEST FAILED (%s): %0d error(s), %0d fatal(s) ***",
                          get_type_name(), n_errors, n_fatals))
    endfunction

endclass : mmu_base_test

`endif // MMU_BASE_TEST_SV
