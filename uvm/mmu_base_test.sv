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
//
// BUG FIX (this pass): TC-011/TC-012 (num_txns==10, back-to-back) hung
// mid-run instead of completing. Root cause was a lost-wakeup deadlock
// between this file's run_matmul() and data_agent.sv's data_driver: nothing
// paced the driver to wait for run_matmul to finish releasing CTRL_REG and
// polling STATUS_REG back to idle for pass i before the driver staged and
// re-triggered mmu_stim_staged for pass i+1. When that re-trigger landed
// before run_matmul got back around to wait_ptrigger() for pass i+1,
// run_matmul's own stim_staged.reset() (called right after consuming pass
// i's trigger) could wipe the pending pass i+1 trigger, and run_matmul then
// blocked forever waiting for a trigger that had already fired and been
// erased. This only ever showed up for num_txns > 1 (every Category 1 test
// uses num_txns == 1 or 2 and happened not to lose the race), which is why
// it passed there and hung here.
//
// FIX: a second, symmetric uvm_event - mmu_pass_release - triggered here in
// run_matmul() immediately after wait_for_idle() confirms the previous pass
// has fully retired. data_agent.sv's data_driver now blocks on this event
// before staging every transaction after the first, which makes the two
// sides a proper ping-pong instead of two independently-paced loops.
//==============================================================================

`ifndef MMU_BASE_TEST_SV
`define MMU_BASE_TEST_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_env.sv"
// run_matmul() takes an mmu_base_seq handle, so the sequence library has to
// be visible here. Both files are `ifndef-guarded, and run.f already lists
// mmu_sequences.sv ahead of this file, so this include is a no-op at compile
// time - it just removes the ordering dependency on the test files, which
// used to include mmu_base_test.sv BEFORE mmu_sequences.sv.
`include "mmu_sequences.sv"

class mmu_base_test extends uvm_test;
    `uvm_component_utils(mmu_base_test)

    // Environment - every test built on this base gets the same one.
    mmu_env env;

    // Shared RAL model, fetched from config_db once env.build_phase has
    // published it (see mmu_env.sv: reg_model built + set() there). Derived
    // tests read/write registers through this handle, e.g.
    // reg_model.DIM_REG.write(status, 4).
    mmu_reg_block reg_model;

    // Upper bound on STATUS_REG polls before a stalled pass is declared an
    // error rather than left to tb_top's global watchdog. See poll_status().
    int unsigned max_status_polls = 500;

    // BUG FIX: the other half of the run_matmul <-> data_driver handshake.
    // Triggered once per pass, right after wait_for_idle() confirms the
    // previous pass has fully retired (CTRL_REG released, STATUS_REG.done
    // back to 0). data_agent.sv's data_driver waits on this before staging
    // transaction i+1, which is what actually prevents the deadlock
    // described in the file header - see that file's matching comment.
    uvm_event pass_release;

    function new(string name = "mmu_base_test", uvm_component parent = null);
        super.new(name, parent);
        pass_release = uvm_event_pool::get_global("mmu_pass_release");
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
    // wait_for_pass_done - blocks until the DUT has actually finished the
    // in-flight pass (STATUS_REG.done == 1), rather than returning as soon
    // as the data-plane sequence finishes submitting stimulus.
    //
    // WHY THIS IS NEEDED: data_driver::run_phase() (data_agent.sv) calls
    // seq_item_port.item_done() as soon as it has finished PUSHING the
    // weight load + activation rows into the DUT - that is, the instant
    // drive_activations() returns. It does not wait for PE_CLEAR to finish,
    // the rest of ACTIVATION_FLOW to drain (mmu_controller.sv's FSM stays
    // in ACTIVATION_FLOW until cnt == flow_last, well after the last row is
    // fed), DONE to assert, or output_buffer/deskew_capture to latch a
    // result. That means seq.start(env.data_agt.sequencer) on the test side
    // returns long before the DUT is actually done computing.
    //
    // Every test in mmu_cat1_tests.sv / mmu_cat2_tests.sv used to call
    // phase.drop_objection(this) immediately after seq.start() returned.
    // That let the phase - and the whole test - end before mmu_controller
    // ever reached DONE, so data_monitor::run_phase() (data_agent.sv) never
    // got past `while (!vif.mon_cb.done)` and never called ap.write(tr).
    // The scoreboard's write_data() was therefore never invoked, which is
    // exactly what SB_REPORT's "scoreboard checked zero passes" error means.
    //
    // Polling STATUS_REG.done through the RAL model (rather than needing a
    // raw vif handle in every test) keeps this fix self-contained here,
    // reusing the same reg_model handle every derived test already has.
    // STATUS_REG is marked volatile in mmu_reg_model.sv specifically so this
    // read always goes to the bus and is never satisfied from a stale
    // mirror value.
    //
    // Call this AFTER seq.start(...) returns and BEFORE phase.drop_objection.
    //--------------------------------------------------------------------
    virtual task wait_for_pass_done();
        poll_status(1'b1, "done");
    endtask

    //--------------------------------------------------------------------
    // wait_for_idle - the mirror image: block until STATUS_REG.done has
    // gone back low, i.e. the FSM has actually left DONE and returned to
    // IDLE. Needed between passes because mmu_controller.sv leaves DONE
    // only on `!start` - CTRL_REG.start is a level the FSM holds on, not a
    // self-clearing pulse - so the next pass's start write must not land
    // while the previous pass is still sitting in DONE.
    //--------------------------------------------------------------------
    virtual task wait_for_idle();
        poll_status(1'b0, "idle");
    endtask

    //--------------------------------------------------------------------
    // poll_status - shared, BOUNDED poll of STATUS_REG.done.
    //
    // The bound matters. An unbounded `do ... while` here turns any stuck
    // pass into a silent spin that is only ever caught by tb_top.sv's #1ms
    // watchdog, which reports the useless
    //     UVM_FATAL [TB_TOP] global timeout reached - simulation hung
    // a full millisecond of simulated time after the actual problem, with no
    // indication of which pass stalled or why. A pass is at most a few tens
    // of cycles, and each STATUS read is ~5, so max_status_polls is orders of
    // magnitude of headroom - if it trips, something is genuinely wrong and
    // saying so HERE, immediately and by name, is worth far more than the
    // watchdog firing later.
    //--------------------------------------------------------------------
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

    //--------------------------------------------------------------------
    // run_matmul - the one place that knows how to run a matrix-multiply
    // pass end to end. Every Category 1 / Category 2 test funnels through
    // it instead of hand-rolling its own register writes.
    //
    // ORDERING IS THE WHOLE POINT. The array is weight-stationary and
    // mmu_controller.sv enters WEIGHT_LOAD the cycle after it sees start,
    // so the required order per pass is:
    //
    //     1. data driver stages the weight matrix on the bus
    //     2. DIM_REG  <- this transaction's dim
    //     3. CTRL_REG <- 1        (start; FSM leaves IDLE)
    //     4. poll STATUS_REG until done
    //     5. CTRL_REG <- 0        (release; FSM leaves DONE)
    //     6. poll STATUS_REG until idle, then next pass
    //     7. release the driver to stage the NEXT transaction's weights
    //
    // The tests used to do 3 before 1, which meant WEIGHT_LOAD's first
    // edges latched an undriven ('x) weight bus. Step 1 is synchronised
    // through the mmu_stim_staged event that data_driver triggers - see
    // data_agent.sv - so there is no timing assumption here, just a
    // handshake.
    //
    // Step 2 is also new. mmu_cat1_tests.sv's header asserted that dim
    // "travels inside data_txn, not a RAL write" - but the DUT reads dim
    // from DIM_REG (mmu_controller.sv gates IDLE -> WEIGHT_LOAD on
    // dim_legal), so every test except TC-001 was leaving DIM_REG at its
    // reset value of 0 and the FSM would never have started at all. The
    // dim carried in data_txn is now what programs the register, so the
    // two can no longer disagree.
    //
    // Step 7 is the bug fix from this pass (see file header): without an
    // explicit release, data_driver's forever loop could stage and
    // re-trigger mmu_stim_staged for the NEXT transaction while this loop
    // was still mid-teardown (CTRL_REG release + wait_for_idle) for the
    // CURRENT one, and the reset() below could wipe that next trigger
    // before this loop ever got back around to waiting for it - a
    // lost-wakeup deadlock that only showed up for num_txns > 1.
    //
    // seq is forked because a sequence with num_txns > 1 must keep feeding
    // items while this task drives the register handshake for each pass.
    //--------------------------------------------------------------------
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
            // Persistent trigger: safe even if the driver staged the next
            // transaction before this loop got back around to waiting.
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

            // BUG FIX: only now - after CTRL_REG is released AND STATUS_REG
            // is confirmed back at idle - tell the driver it may stage the
            // next transaction. Note: only trigger() here, no reset(). The
            // CONSUMER (data_driver) is the one that calls reset(), after it
            // wakes up and consumes the trigger - exactly mirroring how
            // stim_staged already works the other direction (run_matmul, the
            // consumer there, calls reset() after wait_ptrigger(), not
            // data_driver right after trigger()). A trigger()-then-reset()
            // pair back-to-back with no intervening blocking statement in
            // the PRODUCER is its own race: nothing guarantees the consumer's
            // process actually resumes and observes the triggered state
            // before the producer's very next statement clears it. Let the
            // consumer own its own reset() instead, so there is no window.
            pass_release.trigger();
        end

        // Let the sequence (and the driver's trailing item_done) retire
        // before the caller drops its objection.
        wait fork;
    endtask

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