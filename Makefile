# ==============================================================================
# Makefile for SV-TPU-Core UVM Simulation
# ==============================================================================

# 1. Default test (if you just type 'make run' with no arguments)
TEST ?= tc_001_full_random_test

# 2. Dynamically fetch Python configuration flags
PY_INCLUDES := $(shell python3-config --includes)
PY_LDFLAGS  := $(shell python3-config --ldflags --embed)

# 3. Default UVM Verbosity
VERBOSITY ?= UVM_LOW

# ==============================================================================
# Targets
# ==============================================================================

# The main simulation target — runs a single test.
# Usage: make run TEST=tc_003_2x2_subarray_test
run:
	@echo "==================================================================="
	@echo "Running Test: $(TEST)"
	@echo "==================================================================="
	xrun -f run.f \
	-uvm +incdir+uvm+rtl+tb+sva -64bit tb/mmu_dpi_bridge.c \
	$(PY_INCLUDES) $(PY_LDFLAGS) \
	-access +rwc \
	-coverage all \
	-covoverwrite \
	-sv \
	+UVM_TESTNAME=$(TEST) \
	+UVM_VERBOSITY=$(VERBOSITY)

# ==============================================================================
# All known tests, flattened into one list (single source of truth).
# Category targets below are built FROM this list via filtering, so adding a
# test here automatically makes it available to `make test NAME=...` and
# keeps it in exactly one category loop.
# ==============================================================================

CAT1_TESTS := tc_001_full_random_test tc_002_3x3_subarray_test tc_003_2x2_subarray_test \
              tc_004_1x1_scalar_test tc_005_zero_activation_test tc_006_zero_weight_test \
              tc_007_max_int8_test tc_008_min_int8_test tc_009_signed_mix_test \
              tc_010_identity_weights_test

CAT2_TESTS := tc_011_back_to_back_no_gap_test tc_012_back_to_back_one_cycle_gap_test \
              tc_013_back_to_back_alternating_dims_test

CAT3_TESTS := mmu_wp_zero_test mmu_wp_max_test mmu_wp_identity_test mmu_wp_checker_test \
              mmu_reset_wl_test mmu_reset_pclr_test mmu_reset_aflow_test

CAT4_TESTS := mmu_reset_idle_test mmu_reset_restart_test mmu_reset_done_test

# NOTE: tc_023_status_write_catcher and tc_023_status_reg_write_test both
# exist in uvm/mmu_cat5_tests.sv under the same TC number — looks like a
# leftover duplicate, not confirmed intentional. Both are included below
# since both are real compiled classes; worth checking uvm/mmu_cat5_tests.sv
# before relying on this long-term.
CAT5_TESTS := tc_023_status_write_catcher tc_023_status_reg_write_test tc_024_premature_start_test \
              tc_025_double_start_test tc_026_invalid_dim_test

CAT6_TESTS := tc_027_latency_n1_test tc_028_latency_n2_test tc_029_latency_n3_test \
              tc_030_latency_n4_test tc_031_throughput_n4_test

# NOTE: tc035cd_force_done_timing_test (uvm/mmu_ral_and_negative_tests.sv) is
# deliberately excluded — it's an abstract base whose early_not_late bit must
# be set by a derived class before running; its two concrete subclasses
# (tc035c_done_early_test, tc035d_done_late_test) are run instead and cover
# both directions.
RAL_TESTS  := tc032_ral_hw_reset_test tc033_ral_access_test \
              tc035a_force_skip_weight_load_test tc035b_force_pe_clear_hold_test \
              tc035c_done_early_test tc035d_done_late_test \
              tc035e_force_done_in_idle_test tc035f_force_pe_accum_on_zero_test \
              tc035g_force_extra_weight_load_stall_test

ALL_TESTS := $(CAT1_TESTS) $(CAT2_TESTS) $(CAT3_TESTS) $(CAT4_TESTS) $(CAT5_TESTS) $(CAT6_TESTS) $(RAL_TESTS)

# ==============================================================================
# Category loop targets — run every concrete test in a category back-to-back.
# Each just re-invokes `make run TEST=...` per test, so all of run's existing
# flags/coverage/verbosity behavior apply unchanged to every test in the loop.
# ==============================================================================

.PHONY: run-cat1
run-cat1:
	@for t in $(CAT1_TESTS); do $(MAKE) run TEST=$$t; done

.PHONY: run-cat2
run-cat2:
	@for t in $(CAT2_TESTS); do $(MAKE) run TEST=$$t; done

.PHONY: run-cat3
run-cat3:
	@for t in $(CAT3_TESTS); do $(MAKE) run TEST=$$t; done

.PHONY: run-cat4
run-cat4:
	@for t in $(CAT4_TESTS); do $(MAKE) run TEST=$$t; done

.PHONY: run-cat5
run-cat5:
	@for t in $(CAT5_TESTS); do $(MAKE) run TEST=$$t; done

.PHONY: run-cat6
run-cat6:
	@for t in $(CAT6_TESTS); do $(MAKE) run TEST=$$t; done

.PHONY: run-ral
run-ral:
	@for t in $(RAL_TESTS); do $(MAKE) run TEST=$$t; done

# Everything above, back-to-back
.PHONY: run-all-cats
run-all-cats: run-cat1 run-cat2 run-cat3 run-cat4 run-cat5 run-cat6 run-ral

# ==============================================================================
# Individual-test convenience targets
# ==============================================================================

# Run one test by name, with validation against the known test list.
# Usage: make test NAME=tc_023_status_reg_write_test
.PHONY: test
test:
ifeq ($(NAME),)
	$(error NAME is not set. Usage: make test NAME=<test_name>)
endif
	@if ! echo "$(ALL_TESTS)" | tr ' ' '\n' | grep -qx "$(NAME)"; then \
		echo "WARNING: '$(NAME)' is not in the known ALL_TESTS list — running it anyway."; \
	fi
	@$(MAKE) run TEST=$(NAME)

# List every known individual test name (handy for tab-completion/reference)
.PHONY: list-tests
list-tests:
	@for t in $(ALL_TESTS); do echo $$t; done

# Cleanup target to remove Xcelium compilation artifacts
clean:
	@echo "Cleaning up simulation files..."
	rm -rf xcelium.d xrun.history xrun.log waves.shm *.err
