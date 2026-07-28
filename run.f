// ==============================================================================
// run.f — Xcelium compile filelist for sv-tpu-core UVM simulation
// ==============================================================================

// ---- UVM library ----

// ---- RTL: leaf-first ----
rtl/pe.sv
rtl/systolic_array.sv
rtl/deskew_capture.sv
rtl/output_buffer.sv
rtl/axi_lite_slave.sv
rtl/mmu_controller.sv
rtl/mmu_top.sv

// ---- SVA (New Additions) ----
sva/axi_lite_sva.sv
sva/mmu_controller_sva.sv

// ---- TB infrastructure ----
tb/mmu_if.sv

// ---- UVM: agents + RAL before env, env before tests ----
uvm/axi_agent.sv
uvm/data_agent.sv
uvm/mmu_reg_model.sv
uvm/mmu_reg_adapter.sv
uvm/mmu_scoreboard.sv
uvm/mmu_env.sv
uvm/mmu_sequences.sv
uvm/mmu_base_test.sv
uvm/mmu_cat1_tests.sv
uvm/mmu_cat2_tests.sv
uvm/mmu_ral_and_negative_tests.sv

// ---- TB top (instantiates DUT + mmu_if, starts run_test()) ----
tb/tb_top.sv
