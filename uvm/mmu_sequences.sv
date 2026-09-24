`ifndef MMU_SEQUENCES_SV
`define MMU_SEQUENCES_SV

`include "uvm_macros.svh"
import uvm_pkg::*;

`include "data_agent.sv"
`include "axi_agent.sv"


class mmu_base_seq extends uvm_sequence #(data_txn);
    `uvm_object_utils(mmu_base_seq)

    localparam int N = 4;

    rand int unsigned num_txns;

    rand int unsigned fixed_dim;

    constraint c_num_txns  { soft num_txns inside {[1:10]}; }
    constraint c_fixed_dim { soft fixed_dim == 0; fixed_dim inside {[0:N]}; }

    function new(string name = "mmu_base_seq");
        super.new(name);
    endfunction

    virtual function void apply_dim(data_txn tr);
        if (fixed_dim != 0) begin
            tr.poison_cycle = 0; 
            if (!tr.randomize(dim) with { dim == fixed_dim; })
                `uvm_error(get_type_name(), $sformatf("could not pin dim to %0d", fixed_dim))
        end
    endfunction

endclass : mmu_base_seq


class mmu_matmul_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_matmul_seq)

    function new(string name = "mmu_matmul_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "data_txn randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_matmul_seq


class mmu_extreme_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_extreme_seq)

    function new(string name = "mmu_extreme_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (activations[i,j]) activations[i][j] inside {-128, -1, 0, 1, 127};
                    foreach (weights[i,j])     weights[i][j]     inside {-128, -1, 0, 1, 127};
                })
                `uvm_fatal(get_type_name(), "extreme-value randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_extreme_seq


class mmu_zero_activation_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_zero_activation_seq)

    function new(string name = "mmu_zero_activation_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (activations[i,j]) activations[i][j] == 8'sd0;
                })
                `uvm_fatal(get_type_name(), "zero-activation randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_zero_activation_seq



class mmu_max_activation_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_max_activation_seq)

    function new(string name = "mmu_max_activation_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (activations[i,j]) activations[i][j] == 8'sd127;
                })
                `uvm_fatal(get_type_name(), "max-activation randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_max_activation_seq


class mmu_zero_weight_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_zero_weight_seq)

    function new(string name = "mmu_zero_weight_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (weights[i,j]) weights[i][j] == 8'sd0;
                })
                `uvm_fatal(get_type_name(), "zero-weight randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_zero_weight_seq


class mmu_uniform_extreme_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_uniform_extreme_seq)

    typedef enum { POS, NEG } polarity_e;

    polarity_e polarity;

    function new(string name = "mmu_uniform_extreme_seq");
        super.new(name);
    endfunction

    virtual task body();
        logic signed [7:0] fill_val = (polarity == POS) ? 8'sd127 : -8'sd128;

        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    foreach (activations[i,j]) activations[i][j] == local::fill_val;
                    foreach (weights[i,j])     weights[i][j]     == local::fill_val;
                })
                `uvm_fatal(get_type_name(), "uniform-extreme randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_uniform_extreme_seq


class mmu_signed_mix_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_signed_mix_seq)

    function new(string name = "mmu_signed_mix_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    activations[0][0] < 8'sd0;
                    weights[0][0]     < 8'sd0;
                })
                `uvm_fatal(get_type_name(), "signed-mix randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask

endclass : mmu_signed_mix_seq


class mmu_identity_weight_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_identity_weight_seq)

    function new(string name = "mmu_identity_weight_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "identity-weight randomize failed")
            apply_dim(tr);
            set_identity(tr);
            finish_item(tr);
        end
    endtask


    virtual function void set_identity(data_txn tr);
        for (int r = 0; r < int'(tr.N); r++)
            for (int c = 0; c < int'(tr.N); c++)
                tr.weights[r][c] = 8'sd0;

        for (int i = 0; i < int'(tr.dim); i++)
            tr.weights[i][i] = 8'sd1;
    endfunction

endclass : mmu_identity_weight_seq



class mmu_back_to_back_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_back_to_back_seq)

    int unsigned gap_cycles = 0;

    int unsigned dim_sequence[$];

    virtual mmu_if vif;

    function new(string name = "mmu_back_to_back_seq");
        super.new(name);
    endfunction


    virtual task pre_body();
        super.pre_body();
        if (gap_cycles > 0)
            if (!uvm_config_db#(virtual mmu_if)::get(null, get_full_name(), "vif", vif))
                `uvm_fatal(get_type_name(),
                    "gap_cycles > 0 requires vif to be set in config_db at this sequence's full_name")
    endtask

    virtual task body();
        for (int unsigned i = 0; i < num_txns; i++) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "back-to-back randomize failed")
            apply_txn_dim(tr, i);
            finish_item(tr);

            if (gap_cycles > 0 && i != num_txns - 1)
                repeat (gap_cycles) @(vif.data_cb);
        end
    endtask

    virtual function void apply_txn_dim(data_txn tr, int unsigned idx);
        if (dim_sequence.size() > 0) begin
            int unsigned want_dim = dim_sequence[idx % dim_sequence.size()];
            if (!tr.randomize(dim) with { dim == local::want_dim; })
                `uvm_error(get_type_name(),
                    $sformatf("could not pin dim to %0d for txn %0d", want_dim, idx))
        end else begin
            apply_dim(tr);
        end
    endfunction

endclass : mmu_back_to_back_seq


class weight_poison_seq extends mmu_base_seq;
    `uvm_object_utils(weight_poison_seq)


    rand int unsigned fixed_poison_cycle;
    rand bit          use_fixed_cycle;

    constraint c_use_fixed { soft use_fixed_cycle == 1'b0; }

    function new(string name = "weight_poison_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);

            if (!tr.randomize() with { poison_en == 1'b1; })
                `uvm_fatal(get_type_name(), "poison randomize failed")

            apply_dim(tr);

            if (use_fixed_cycle) begin
                if (!tr.randomize(poison_cycle) with { poison_cycle == fixed_poison_cycle; })
                    `uvm_error(get_type_name(),
                        $sformatf("poison_cycle %0d is outside the feed window for dim=%0d",
                                  fixed_poison_cycle, tr.dim))
            end

            force_difference(tr);

            `uvm_info(get_type_name(),
                $sformatf("dim=%0d: poisoning weights on feed cycle %0d of %0d",
                          tr.dim, tr.poison_cycle, 2*tr.dim - 1),
                UVM_MEDIUM)

            finish_item(tr);
        end
    endtask


    virtual function void force_difference(data_txn tr);
        bit differs = 0;

        for (int r = 0; r < int'(tr.dim) && !differs; r++)
            for (int c = 0; c < int'(tr.dim) && !differs; c++)
                if (tr.poison_weights[r][c] !== tr.weights[r][c])
                    differs = 1;

        if (!differs) begin
            
            tr.poison_weights[0][0] = tr.weights[0][0] ^ 8'sh80;
            `uvm_info(get_type_name(),
                "poison matrix matched the clean one - forced a difference at [0][0]",
                UVM_HIGH)
        end
    endfunction

endclass : weight_poison_seq


class mmu_wp_prime_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_wp_prime_seq)

    function new(string name = "mmu_wp_prime_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with {
                    poison_en == 1'b0;
                    // Push weights toward the int8 extremes so the array is
                    // genuinely "dirty" before the pattern pass runs.
                    foreach (weights[i,j]) weights[i][j] inside {-128, -100, 100, 127};
                })
                `uvm_fatal(get_type_name(), "prime randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask
endclass : mmu_wp_prime_seq


class mmu_wp_pattern_base_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_wp_pattern_base_seq)

    function new(string name = "mmu_wp_pattern_base_seq");
        super.new(name);
    endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "pattern randomize failed")
            apply_dim(tr);
            set_weights(tr);   // stamp the directed pattern post-randomize
            finish_item(tr);
        end
    endtask

    virtual function void set_weights(data_txn tr);
    endfunction

    protected function void clear_weights(data_txn tr);
        for (int r = 0; r < int'(tr.N); r++)
            for (int c = 0; c < int'(tr.N); c++)
                tr.weights[r][c] = 8'sd0;
    endfunction
endclass : mmu_wp_pattern_base_seq



class mmu_wp_zero_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_zero_seq)
    function new(string name = "mmu_wp_zero_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);   
    endfunction
endclass : mmu_wp_zero_seq


class mmu_wp_max_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_max_seq)
    function new(string name = "mmu_wp_max_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);
        for (int r = 0; r < int'(tr.dim); r++)
            for (int c = 0; c < int'(tr.dim); c++)
                tr.weights[r][c] = 8'sd127;
    endfunction
endclass : mmu_wp_max_seq


class mmu_wp_identity_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_identity_seq)
    function new(string name = "mmu_wp_identity_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);
        for (int i = 0; i < int'(tr.dim); i++)
            tr.weights[i][i] = 8'sd1;
    endfunction
endclass : mmu_wp_identity_seq


class mmu_wp_checker_seq extends mmu_wp_pattern_base_seq;
    `uvm_object_utils(mmu_wp_checker_seq)
    function new(string name = "mmu_wp_checker_seq"); super.new(name); endfunction

    virtual function void set_weights(data_txn tr);
        clear_weights(tr);
        for (int r = 0; r < int'(tr.dim); r++)
            for (int c = 0; c < int'(tr.dim); c++)
                tr.weights[r][c] = (((r + c) % 2) == 0) ? 8'sd127 : -8'sd127;
    endfunction
endclass : mmu_wp_checker_seq


class mmu_recover_seq extends mmu_base_seq;
    `uvm_object_utils(mmu_recover_seq)
    function new(string name = "mmu_recover_seq"); super.new(name); endfunction

    virtual task body();
        repeat (num_txns) begin
            data_txn tr = data_txn::type_id::create("tr");
            start_item(tr);
            if (!tr.randomize() with { poison_en == 1'b0; })
                `uvm_fatal(get_type_name(), "recover randomize failed")
            apply_dim(tr);
            finish_item(tr);
        end
    endtask
endclass : mmu_recover_seq



class mmu_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(mmu_virtual_sequencer)

    uvm_sequencer #(axi_txn)  axi_sqr;  
    uvm_sequencer #(data_txn) data_sqr;  
    virtual mmu_if            vif;      

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass : mmu_virtual_sequencer


class mmu_vseq_base extends uvm_sequence #(uvm_sequence_item);
    `uvm_object_utils(mmu_vseq_base)
    `uvm_declare_p_sequencer(mmu_virtual_sequencer)

    localparam int      N          = 4;
    localparam bit [3:0] DIM_REG    = 4'h0;
    localparam bit [3:0] CTRL_REG   = 4'h4;
    localparam bit [3:0] STATUS_REG = 4'h8;

   
    localparam int WEIGHT_LOAD_CYCLES = N;   
    localparam int PE_CLEAR_CYCLES     = 1;  

    int unsigned max_status_polls = 500;

    function new(string name = "mmu_vseq_base");
        super.new(name);
    endfunction

    virtual task pre_body();
        super.pre_body();
        set_response_queue_depth(-1);
    endtask

    virtual task axi_write(bit [3:0] addr, bit [31:0] data);
        axi_txn t = axi_txn::type_id::create("t");
        start_item(t, -1, p_sequencer.axi_sqr);
        t.rw   = axi_txn::WRITE;
        t.addr = addr;
        t.data = data;
        finish_item(t, -1);
    endtask

    virtual task axi_read(bit [3:0] addr, output bit [31:0] data);
        axi_txn t = axi_txn::type_id::create("t");
        start_item(t, -1, p_sequencer.axi_sqr);
        t.rw   = axi_txn::READ;
        t.addr = addr;
        finish_item(t, -1);
        data = t.data;
    endtask

    virtual task write_dim(int unsigned d); axi_write(DIM_REG, d);  endtask
    virtual task write_start();             axi_write(CTRL_REG, 1); endtask
    virtual task write_stop();              axi_write(CTRL_REG, 0); endtask

    virtual task poll_status(bit want, string what);
        bit [31:0]   rdata;
        int unsigned polls = 0;
        forever begin
            axi_read(STATUS_REG, rdata);
            if (rdata[0] === want) return;
            polls++;
            if (polls >= max_status_polls) begin
                `uvm_error("MMU_VSEQ",
                    $sformatf("STATUS_REG.done never reached %0b after %0d polls while waiting for %s",
                              want, polls, what))
                return;
            end
        end
    endtask

    virtual task wait_for_done(); poll_status(1'b1, "done"); endtask
    virtual task wait_for_idle(); poll_status(1'b0, "idle"); endtask

    virtual task step(int n = 1);
        repeat (n) @(p_sequencer.vif.mon_cb);
    endtask

    virtual task wait_start_high();
        do @(p_sequencer.vif.mon_cb); while (!p_sequencer.vif.mon_cb.start);
    endtask

    virtual task wait_flow_high();
        do @(p_sequencer.vif.mon_cb); while (!p_sequencer.vif.mon_cb.flow_en);
    endtask

    virtual task pulse_reset();
        uvm_event req  = uvm_event_pool::get_global("mmu_reset_req");
        uvm_event done = uvm_event_pool::get_global("mmu_reset_done");
        `uvm_info("MMU_VSEQ", "requesting synchronous reset pulse", UVM_MEDIUM)
        req.trigger();
        done.wait_trigger();   // block until tb_top has driven rst_n low then high
        req.reset();
        `uvm_info("MMU_VSEQ", "reset pulse complete", UVM_MEDIUM)
    endtask


    virtual task run_pass(mmu_base_seq dseq, int unsigned dim);
        uvm_event pass_release = uvm_event_pool::get_global("mmu_pass_release");
        dseq.num_txns = 1;
        dseq.fixed_dim = dim;
        fork
            dseq.start(p_sequencer.data_sqr, this);
        join_none

        step(2);

        write_dim(dim);
        write_start();
        wait_for_done();
        write_stop();
        wait_for_idle();

        pass_release.trigger();

        wait fork;   
    endtask

    virtual task launch_pass(mmu_base_seq dseq, int unsigned dim);
        uvm_event pass_release = uvm_event_pool::get_global("mmu_pass_release");
        dseq.num_txns = 1;
        dseq.fixed_dim = dim;
        fork
            dseq.start(p_sequencer.data_sqr, this);
        join_none
        step(2);
        write_dim(dim);
        write_start();
        wait_for_done();

        pass_release.trigger();
        wait fork;
    endtask

    virtual task launch_fsm_only(int unsigned dim);
        step(2);
        write_dim(dim);
        write_start();
        wait_start_high();
    endtask

endclass : mmu_vseq_base


class mmu_wpat_vseq_base extends mmu_vseq_base;
    `uvm_object_utils(mmu_wpat_vseq_base)
    function new(string name = "mmu_wpat_vseq_base"); super.new(name); endfunction

    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_pattern_base_seq::type_id::create("pat");
    endfunction

    virtual task body();
        mmu_wp_prime_seq prime = mmu_wp_prime_seq::type_id::create("prime");
        mmu_base_seq     pat   = make_pattern_seq();

        run_pass(prime, N);
        run_pass(pat, N);
    endtask
endclass : mmu_wpat_vseq_base

class mmu_wpat_zero_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_zero_vseq)
    function new(string name = "mmu_wpat_zero_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_zero_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_zero_vseq

class mmu_wpat_max_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_max_vseq)
    function new(string name = "mmu_wpat_max_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_max_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_max_vseq

class mmu_wpat_identity_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_identity_vseq)
    function new(string name = "mmu_wpat_identity_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_identity_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_identity_vseq

class mmu_wpat_checker_vseq extends mmu_wpat_vseq_base;
    `uvm_object_utils(mmu_wpat_checker_vseq)
    function new(string name = "mmu_wpat_checker_vseq"); super.new(name); endfunction
    virtual function mmu_base_seq make_pattern_seq();
        return mmu_wp_checker_seq::type_id::create("pat");
    endfunction
endclass : mmu_wpat_checker_vseq


class mmu_reset_stress_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_stress_vseq)

    typedef enum { PH_WEIGHT_LOAD, PH_PE_CLEAR, PH_ACTIVATION_FLOW } phase_e;
    phase_e target_phase = PH_ACTIVATION_FLOW;

    function new(string name = "mmu_reset_stress_vseq"); super.new(name); endfunction

    virtual task wait_target_phase();
        case (target_phase)
            PH_WEIGHT_LOAD:     step(1);                       // first WEIGHT_LOAD cycle
            PH_PE_CLEAR:        step(WEIGHT_LOAD_CYCLES);      // land on PE_CLEAR
            PH_ACTIVATION_FLOW: begin wait_flow_high(); step(2); end // mid-flow
            default:            step(1);
        endcase
    endtask

    virtual task body();
        mmu_recover_seq recover = mmu_recover_seq::type_id::create("recover");

        
        launch_fsm_only(N);
        wait_target_phase();
        pulse_reset();

        run_pass(recover, N);
    endtask
endclass : mmu_reset_stress_vseq

class mmu_reset_wl_vseq extends mmu_reset_stress_vseq;
    `uvm_object_utils(mmu_reset_wl_vseq)
    function new(string name = "mmu_reset_wl_vseq");
        super.new(name); target_phase = PH_WEIGHT_LOAD;
    endfunction
endclass : mmu_reset_wl_vseq

class mmu_reset_pclr_vseq extends mmu_reset_stress_vseq;
    `uvm_object_utils(mmu_reset_pclr_vseq)
    function new(string name = "mmu_reset_pclr_vseq");
        super.new(name); target_phase = PH_PE_CLEAR;
    endfunction
endclass : mmu_reset_pclr_vseq

class mmu_reset_aflow_vseq extends mmu_reset_stress_vseq;
    `uvm_object_utils(mmu_reset_aflow_vseq)
    function new(string name = "mmu_reset_aflow_vseq");
        super.new(name); target_phase = PH_ACTIVATION_FLOW;
    endfunction
endclass : mmu_reset_aflow_vseq


class mmu_reset_idle_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_idle_vseq)
    function new(string name = "mmu_reset_idle_vseq"); super.new(name); endfunction

    virtual task check_reg_reset();
        bit [31:0] d;
        axi_read(DIM_REG,    d);
        if (d[2:0] !== 3'd0) `uvm_error("MMU_VSEQ", $sformatf("DIM_REG not 0 after reset: %0d",  d[2:0]))
        axi_read(CTRL_REG,   d);
        if (d[0]   !== 1'b0) `uvm_error("MMU_VSEQ", "CTRL_REG start not 0 after reset")
        axi_read(STATUS_REG, d);
        if (d[0]   !== 1'b0) `uvm_error("MMU_VSEQ", "STATUS_REG done not 0 after reset")
    endtask

    virtual task body();
        mmu_recover_seq clean = mmu_recover_seq::type_id::create("clean");
        pulse_reset();
        check_reg_reset();
        run_pass(clean, N);
    endtask
endclass : mmu_reset_idle_vseq

class mmu_reset_restart_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_restart_vseq)
    function new(string name = "mmu_reset_restart_vseq"); super.new(name); endfunction

    virtual task body();
        mmu_recover_seq first  = mmu_recover_seq::type_id::create("first");
        mmu_recover_seq restart = mmu_recover_seq::type_id::create("restart");
        run_pass(first, N);      
        pulse_reset();           
        run_pass(restart, N);    
    endtask
endclass : mmu_reset_restart_vseq

class mmu_reset_done_vseq extends mmu_vseq_base;
    `uvm_object_utils(mmu_reset_done_vseq)
    function new(string name = "mmu_reset_done_vseq"); super.new(name); endfunction

    virtual task body();
        mmu_recover_seq dseq  = mmu_recover_seq::type_id::create("dseq");
        mmu_recover_seq clean = mmu_recover_seq::type_id::create("clean");
        bit [31:0]      d;

        launch_pass(dseq, N);

        pulse_reset();
        axi_read(STATUS_REG, d);
        if (d[0] !== 1'b0)
            `uvm_error("MMU_VSEQ", "STATUS_REG.done persisted after reset from DONE (TC-034)")

        write_stop();
        run_pass(clean, N);
    endtask
endclass : mmu_reset_done_vseq

`endif 
