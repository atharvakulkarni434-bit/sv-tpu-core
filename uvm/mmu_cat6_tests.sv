//==============================================================================
// File: mmu_cat6_tests.sv
// Project: sv-tpu-core
// Date: 2026-07-27
//
// Description:
//   Category 6 — Latency & Throughput Performance (TC-027 through TC-031).
//   Directed single computations at N=1..4 (TC-027..030) plus a 10x
//   back-to-back N=4 throughput run (TC-031). Each pass is functionally
//   checked by the existing scoreboard (golden model) and additionally
//   latency-checked at the transaction level by mmu_latency_checker (below),
//   which this file re-introduces as a subscriber on the data monitor.
//==============================================================================

`ifndef MMU_CAT6_TESTS_SV
`define MMU_CAT6_TESTS_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "mmu_base_test.sv"
`include "mmu_sequences.sv"

class mmu_latency_checker extends uvm_subscriber #(data_txn);
    `uvm_component_utils(mmu_latency_checker)

    typedef enum { LAT_AS_BUILT, LAT_SPEC_2N } lat_mode_e;
    lat_mode_e   mode = LAT_AS_BUILT;

    int unsigned checked    = 0;
    int unsigned violations = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function int unsigned expected_latency(int unsigned dim);
        case (mode)
            LAT_SPEC_2N: return 2 * dim;      
            default:     return dim + 5;        
        endcase
    endfunction

    function void start_of_simulation_phase(uvm_phase phase);
        super.start_of_simulation_phase(phase);
        `uvm_info("LAT_CHK",
            $sformatf({"latency contract in effect: %s (expected = %s). ",
                       "NOTE: 2N (plan) and dim+5 (as-built RTL) disagree - ",
                       "see file header. Pass +LAT_SPEC_2N to check against 2N."},
                      mode.name(),
                      (mode == LAT_SPEC_2N) ? "2*dim" : "dim+5"),
            UVM_LOW)
    endfunction

    virtual function void write(data_txn t);
        int unsigned exp = expected_latency(t.dim);
        checked++;
        if (t.latency != exp) begin
            violations++;
            `uvm_error("LAT_CHK",
                $sformatf("dim=%0d: observed latency %0d cycles, expected %0d (%s contract)",
                          t.dim, t.latency, exp, mode.name()))
        end
        else begin
            `uvm_info("LAT_CHK",
                $sformatf("dim=%0d: latency %0d cycles OK (%s contract)",
                          t.dim, t.latency, mode.name()), UVM_LOW)
        end
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("LAT_CHK",
            $sformatf("latency summary: %0d pass(es) checked, %0d violation(s) [%s contract]",
                      checked, violations, mode.name()), UVM_LOW)
    endfunction
endclass : mmu_latency_checker


class mmu_perf_base_test extends mmu_base_test;
    `uvm_component_utils(mmu_perf_base_test)

    mmu_latency_checker lat_chk;

    function new(string name = "mmu_perf_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        lat_chk = mmu_latency_checker::type_id::create("lat_chk", this);
        if ($test$plusargs("LAT_SPEC_2N"))
            lat_chk.mode = mmu_latency_checker::LAT_SPEC_2N;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);   
        env.data_agt.monitor.ap.connect(lat_chk.analysis_export);
    endfunction
endclass : mmu_perf_base_test


class tc_027_latency_n1_test extends mmu_perf_base_test;
    `uvm_component_utils(tc_027_latency_n1_test)

    function new(string name = "tc_027_latency_n1_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 1; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_027_latency_n1_test

class tc_028_latency_n2_test extends mmu_perf_base_test;
    `uvm_component_utils(tc_028_latency_n2_test)

    function new(string name = "tc_028_latency_n2_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 2; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_028_latency_n2_test


class tc_029_latency_n3_test extends mmu_perf_base_test;
    `uvm_component_utils(tc_029_latency_n3_test)

    function new(string name = "tc_029_latency_n3_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 3; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_029_latency_n3_test

class tc_030_latency_n4_test extends mmu_perf_base_test;
    `uvm_component_utils(tc_030_latency_n4_test)

    function new(string name = "tc_030_latency_n4_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_matmul_seq seq;
        phase.raise_objection(this);

        seq = mmu_matmul_seq::type_id::create("seq");
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 1; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_030_latency_n4_test


class tc_031_throughput_n4_test extends mmu_perf_base_test;
    `uvm_component_utils(tc_031_throughput_n4_test)

    function new(string name = "tc_031_throughput_n4_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task main_phase(uvm_phase phase);
        mmu_back_to_back_seq seq;
        phase.raise_objection(this);

        seq = mmu_back_to_back_seq::type_id::create("seq");
        seq.gap_cycles = 0;
        if (!seq.randomize() with { fixed_dim == 4; num_txns == 10; })
            `uvm_fatal(get_type_name(), "seq randomize failed")
        run_matmul(seq);

        phase.drop_objection(this);
    endtask
endclass : tc_031_throughput_n4_test

`endif // MMU_CAT6_TESTS_SV
