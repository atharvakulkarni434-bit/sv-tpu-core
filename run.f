// ==============================================================================
// run.f — Xcelium compile filelist for sv-tpu-core UVM simulation
//
// Usage:
//   xrun -f run.f -dpi <flags for mmu_dpi_bridge.c, see that file's header>
//
// Order matters for the RTL block (Xcelium elaborates bottom-up; leaf modules
// first avoids relying on auto-search). The uvm/ block relies on `include
// guards (MMU_ENV_SV, MMU_SCOREBOARD_SV, etc.) so mmu_env.sv's own
// `include "mmu_reg_model.sv"` etc. won't double-compile against these
// explicit listings.
//
// NOT included here (see repo gaps): sva/*.sv (axi_lite_sva.sv,
// mmu_controller_sva.sv, pe_sva.sv) and mmu_perf_checker.sv — none exist yet;
// tb_top.sv's bind statements for them stay commented until they land.
// ==============================================================================

// ---- UVM library ----
// (Xcelium typically pulls this in via -uvmhome or an installed UVM_HOME;
//  add -uvmhome $UVM_HOME here or on the command line if not already set)

// ---- RTL: leaf-first ----
rtl/pe.sv
rtl/systolic_array.sv
rtl/deskew_capture.sv
rtl/output_buffer.sv
rtl/axi_lite_slave.sv
rtl/mmu_controller.sv
rtl/mmu_top.sv

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

// ---- TB top (instantiates DUT + mmu_if, starts run_test()) ----
tb/tb_top.sv
