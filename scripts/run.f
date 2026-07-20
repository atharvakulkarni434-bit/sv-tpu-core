-uvm
-sv
-incdir uvm

// interface first
tb/mmu_if.sv

// RTL (DUT)
rtl/pe.sv
rtl/systolic_array.sv
rtl/skew_buffer.sv
rtl/axi_lite_slave.sv
rtl/mmu_controller.sv
rtl/output_buffer.sv
rtl/mmu_top.sv

// UVM env + tests
uvm/mmu_sequences.sv
uvm/mmu_illegal_op_tests.sv

// testbench top (runs run_test())
tb/tb_top.sv