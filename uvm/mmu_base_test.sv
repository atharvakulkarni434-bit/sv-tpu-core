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
//==============================================================================

`ifndef MMU_BASE_TEST_SV
`define MMU_BASE_TEST_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_sequences.sv"

class mmu_base_test extends uvm_test;
    `uvm_component_utils(mmu_base_test)

    mmu_env env;

    mmu_reg_block reg_model;

    int unsigned max_status_polls = 500;
    
    uvm_event pass_release;

    function new(string name = "mmu_base_test", uvm_component parent = null);
        super.new(name, parent);
        pass_release = uvm_event_pool::get_global("mmu_pass_release");
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        env = mmu_env::type_id::create("env", this);
        uvm_top.set_timeout(1ms, 0);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        if (!uvm_config_db#(mmu_reg_block)::get(this, "", "reg_model", reg_model))
            `uvm_fatal("MMU_BASE_TEST",
                "reg_model not found in config_db - check mmu_env::build_phase set() path")
    endfunction

    virtual function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        `uvm_info("MMU_BASE_TEST", "topology:", UVM_LOW)
        print();
    endfunction

    virtual task wait_for_pass_done();
        poll_status(1'b1, "done");
    endtask

    virtual task wait_for_idle();
        poll_status(1'b0, "idle");
    endtask

    virtual task poll_status(bit want, string what);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        int unsigned   polls = 0;

        forever begin
            reg_model.STATUS_REG.read(status, rdata);
            if (status != UVM_IS_OK)
                `uvm_error("MMU_BASE_TEST",
                    $sformatf("STATUS_REG read did not complete UVM_IS_OK while polling for %s",
                              what))
            if (rdata[0] === want) return;

            polls++;
            if (polls >= max_status_polls) begin
                `uvm_error("MMU_BASE_TEST",
                    $sformatf({"STATUS_REG.done never reached %0b after %0d polls - the pass is ",
                               "stuck. Most likely causes: DIM_REG does not hold a legal 1..4 (the ",
                               "FSM will not leave IDLE), CTRL_REG.start was never written, or ",
                               "start was never released after the previous pass."},
                              want, polls))
                return;
            end
        end
    endtask

    virtual task run_matmul(mmu_base_seq seq);
        uvm_event    stim_staged = uvm_event_pool::get_global("mmu_stim_staged");
        uvm_status_e status;
        int unsigned n_passes    = seq.num_txns;
        data_txn     tr;
        uvm_object   obj;

        if (n_passes == 0) begin
            `uvm_warning("MMU_BASE_TEST", "run_matmul called with num_txns == 0 - nothing to do")
            return;
        end

        fork
            seq.start(env.data_agt.sequencer);
        join_none

        repeat (n_passes) begin
            stim_staged.wait_ptrigger();
            obj = stim_staged.get_trigger_data();
            stim_staged.reset();

            if (!$cast(tr, obj))
                `uvm_fatal("MMU_BASE_TEST",
                    "mmu_stim_staged carried something other than a data_txn")

            reg_model.DIM_REG.write(status, tr.dim);
            if (status != UVM_IS_OK)
                `uvm_error("MMU_BASE_TEST", "DIM_REG write did not complete UVM_IS_OK")

            reg_model.CTRL_REG.write(status, 1);
            if (status != UVM_IS_OK)
                `uvm_error("MMU_BASE_TEST", "CTRL_REG start write did not complete UVM_IS_OK")

            wait_for_pass_done();

            reg_model.CTRL_REG.write(status, 0);
            if (status != UVM_IS_OK)
                `uvm_error("MMU_BASE_TEST", "CTRL_REG release write did not complete UVM_IS_OK")

            wait_for_idle();

            pass_release.trigger();
        end

        wait fork;
    endtask

    virtual function mmu_vseq_base get_vseq();
        return null;
    endfunction

    virtual task run_phase(uvm_phase phase);
        mmu_vseq_base vseq = get_vseq();
        if (vseq == null) return;   // no-op smoke run, as before

        phase.raise_objection(this, get_type_name());
        `uvm_info("MMU_BASE_TEST",
            $sformatf("starting virtual sequence %s", vseq.get_type_name()), UVM_LOW)
        vseq.start(env.v_sqr);
        phase.drop_objection(this, get_type_name());
    endtask

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
