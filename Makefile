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

# 4. Where per-test logs land
LOGDIR ?= logs

# 5. ADDED (this pass) - coverage database location and closure threshold.
#    COVWORKDIR must match whatever -covworkdir/default xrun is actually
#    using (default is ./cov_work, matching every log seen so far - override
#    on the command line if your site sets -covworkdir explicitly elsewhere).
COVWORKDIR   ?= cov_work
COV_THRESHOLD ?= 90

# ==============================================================================
# Targets
# ==============================================================================

# The main simulation target.
# Runs xrun, tees output to logs/$(TEST).log, then determines pass/fail from
# the log rather than trusting xrun's raw exit code. This matters because
# negative tests (e.g. tc035a-g) deliberately trigger SVA assertion failures
# as part of a PASSING run - xrun exits non-zero for those even though the
# test is correct.
#
# A test is only a real PASS if BOTH of these hold:
#   1. The base test class printed "*** TEST PASSED ***"
#   2. The final UVM Report Summary shows "UVM_ERROR :    0"
# Checking (1) alone is not enough: a test's report_phase override can run
# its own post-check AFTER mmu_base_test.sv prints the PASSED banner (see
# tc035b, where a report_phase-level catcher-count check fired a UVM_ERROR
# after the banner already printed PASSED). Requiring UVM_ERROR : 0 as well
# catches that case instead of reporting a false PASS.
.PHONY: run
run:
	@mkdir -p $(LOGDIR)
	@echo "==================================================================="
	@echo "Running Test: $(TEST)"
	@echo "==================================================================="
	@xrun -f run.f \
	-uvm +incdir+uvm+rtl+tb+sva -64bit tb/mmu_dpi_bridge.c \
	$(PY_INCLUDES) $(PY_LDFLAGS) \
	-access +rwc \
	-coverage all \
	-covoverwrite \
	-covtest $(TEST) \
	-sv \
	+UVM_TESTNAME=$(TEST) \
	+UVM_VERBOSITY=$(VERBOSITY) \
	2>&1 | tee $(LOGDIR)/$(TEST).log; \
	echo ""; \
	has_pass_banner=0; has_fail_banner=0; err_count=-1; \
	grep -q '\*\*\* TEST PASSED' $(LOGDIR)/$(TEST).log && has_pass_banner=1; \
	grep -q '\*\*\* TEST FAILED' $(LOGDIR)/$(TEST).log && has_fail_banner=1; \
	err_line=$$(grep -E '^UVM_ERROR[[:space:]]*:' $(LOGDIR)/$(TEST).log | tail -1); \
	if [ -n "$$err_line" ]; then \
		err_count=$$(echo $$err_line | sed -E 's/^UVM_ERROR[[:space:]]*:[[:space:]]*([0-9]+).*/\1/'); \
	fi; \
	if [ $$has_pass_banner -eq 1 ] && [ $$has_fail_banner -eq 0 ] && [ "$$err_count" = "0" ]; then \
		echo "############################################################"; \
		echo "###                                                      ###"; \
		echo "###   PASS  -  $(TEST)"; \
		echo "###                                                      ###"; \
		echo "############################################################"; \
		res=0; \
	elif [ $$has_pass_banner -eq 1 ] && [ "$$err_count" != "0" ]; then \
		echo "############################################################"; \
		echo "###                                                      ###"; \
		echo "###   FAIL  -  $(TEST)"; \
		echo "###   TEST PASSED banner printed, but UVM_ERROR count"; \
		echo "###   is $$err_count (expected 0) - a post-banner check"; \
		echo "###   in report_phase likely flagged something."; \
		echo "###   See: $(LOGDIR)/$(TEST).log"; \
		echo "###                                                      ###"; \
		echo "############################################################"; \
		res=1; \
	elif [ $$has_fail_banner -eq 1 ]; then \
		echo "############################################################"; \
		echo "###                                                      ###"; \
		echo "###   FAIL  -  $(TEST)"; \
		echo "###   See: $(LOGDIR)/$(TEST).log"; \
		echo "###                                                      ###"; \
		echo "############################################################"; \
		res=1; \
	else \
		echo "############################################################"; \
		echo "###                                                      ###"; \
		echo "###   UNKNOWN  -  $(TEST)"; \
		echo "###   No PASS/FAIL banner found in log - sim may have"; \
		echo "###   crashed before report_phase. See: $(LOGDIR)/$(TEST).log"; \
		echo "###                                                      ###"; \
		echo "############################################################"; \
		res=1; \
	fi; \
	echo ""; \
	cov_line=$$(grep '\[MMU_COV\]' $(LOGDIR)/$(TEST).log | tail -1); \
	if [ -n "$$cov_line" ]; then \
		echo "-------------------------------------------------------------------"; \
		echo "  COVERAGE (this test only - NOT cumulative across the regression,"; \
		echo "  see 'make cov-summary' / 'make cov-check' for the real picture):"; \
		echo "$$cov_line" | grep -oE '[a-z_0-9]+=[0-9.]+%' | sed 's/^/    /'; \
		echo "-------------------------------------------------------------------"; \
	else \
		echo "  (no [MMU_COV] report_phase line found in this log - coverage"; \
		echo "   component may not have run, or test crashed before report_phase)"; \
	fi; \
	exit $$res

# ==============================================================================
# Category loop targets - run every concrete test in a category back-to-back.
# Each just re-invokes `make run TEST=...` per test, so all of run's existing
# flags/coverage/verbosity/pass-fail behavior apply unchanged to every test
# in the loop. Individual test failures don't halt the loop (the `-` prefix),
# but are tracked and reported in a summary banner at the end.
# ==============================================================================

# Category 1 - Functional / Random
.PHONY: run-cat1
run-cat1:
	@$(MAKE) --no-print-directory run-loop LIST="tc_001_full_random_test tc_002_3x3_subarray_test tc_003_2x2_subarray_test \
	          tc_004_1x1_scalar_test tc_005_zero_activation_test tc_006_zero_weight_test \
	          tc_007_max_int8_test tc_008_min_int8_test tc_009_signed_mix_test \
	          tc_010_identity_weights_test" LABEL="run-cat1"

# Category 2 - Back-to-back throughput
.PHONY: run-cat2
run-cat2:
	@$(MAKE) --no-print-directory run-loop LIST="tc_011_back_to_back_no_gap_test tc_012_back_to_back_one_cycle_gap_test \
	          tc_013_back_to_back_alternating_dims_test" LABEL="run-cat2"

# Category 3 - Weight Poison & Reset Stress
.PHONY: run-cat3
run-cat3:
	@$(MAKE) --no-print-directory run-loop LIST="mmu_wp_zero_test mmu_wp_max_test mmu_wp_identity_test mmu_wp_checker_test \
	          mmu_reset_wl_test mmu_reset_pclr_test mmu_reset_aflow_test" LABEL="run-cat3"

# Category 4 - Reset Behavior
.PHONY: run-cat4
run-cat4:
	@$(MAKE) --no-print-directory run-loop LIST="mmu_reset_idle_test mmu_reset_restart_test mmu_reset_done_test" LABEL="run-cat4"

# Category 5 - RAL / register + control-flow negative tests
# NOTE: tc_023_status_write_catcher is NOT a runnable test - it's the
# uvm_report_catcher support class (uvm_object_utils, not
# uvm_component_utils) that tc_023_status_reg_write_test registers in its own
# build_phase to demote the expected STATUS_REG read-only guard error.
# Passing it as +UVM_TESTNAME is a UVM_FATAL (INVTST: test not found).
# Confirmed via uvm/mmu_cat5_tests.sv - only tc_023_status_reg_write_test is
# a real test class here.
.PHONY: run-cat5
run-cat5:
	@$(MAKE) --no-print-directory run-loop LIST="tc_023_status_reg_write_test tc_024_premature_start_test \
	          tc_025_double_start_test tc_026_invalid_dim_test" LABEL="run-cat5"

# Category 6 - Latency & Throughput Performance
.PHONY: run-cat6
run-cat6:
	@$(MAKE) --no-print-directory run-loop LIST="tc_027_latency_n1_test tc_028_latency_n2_test tc_029_latency_n3_test \
	          tc_030_latency_n4_test tc_031_throughput_n4_test" LABEL="run-cat6"

# RAL / negative / force-injection tests (TC-032, TC-033, TC-035a-g)
# NOTE: tc035cd_force_done_timing_test (uvm/mmu_ral_and_negative_tests.sv) is
# deliberately excluded - it's an abstract base whose early_not_late bit must
# be set by a derived class before running; its two concrete subclasses
# (tc035c_done_early_test, tc035d_done_late_test) are run instead and cover
# both directions.
.PHONY: run-ral
run-ral:
	@$(MAKE) --no-print-directory run-loop LIST="tc032_ral_hw_reset_test tc033_ral_access_test \
	          tc035a_force_skip_weight_load_test tc035b_force_pe_clear_hold_test \
	          tc035c_done_early_test tc035d_done_late_test \
	          tc035e_force_done_in_idle_test tc035f_force_pe_accum_on_zero_test \
	          tc035g_force_extra_weight_load_stall_test" LABEL="run-ral"

# Everything above, back-to-back
.PHONY: run-all-cats
run-all-cats: run-cat1 run-cat2 run-cat3 run-cat4 run-cat5 run-cat6 run-ral

# ==============================================================================
# Internal loop engine - not meant to be called directly.
# Usage: make run-loop LIST="test1 test2 ..." LABEL="some-name"
# Runs each test via `make run`, tolerating individual failures, and prints
# a clear PASS/FAIL summary banner at the end covering the whole batch.
# ==============================================================================
.PHONY: run-loop
run-loop:
	@passed=""; failed=""; \
	for t in $(LIST); do \
		$(MAKE) --no-print-directory run TEST=$$t; \
		if [ $$? -eq 0 ]; then \
			passed="$$passed $$t"; \
		else \
			failed="$$failed $$t"; \
		fi; \
	done; \
	total=$$(echo $(LIST) | wc -w); \
	npassed=$$(echo $$passed | wc -w); \
	nfailed=$$(echo $$failed | wc -w); \
	echo ""; \
	echo "############################################################"; \
	echo "###"; \
	echo "###   $(LABEL) SUMMARY:  $$npassed / $$total passed"; \
	echo "###"; \
	if [ -n "$$failed" ]; then \
		echo "###   FAILED TESTS:"; \
		for t in $$failed; do echo "###     - $$t"; done; \
		echo "###"; \
	fi; \
	echo "############################################################"; \
	if [ $$nfailed -gt 0 ]; then exit 1; else exit 0; fi

# ==============================================================================
# ADDED (this pass) - coverage visibility targets.
#
# cov-summary: greps every [MMU_COV] report_phase line already sitting in
#   $(LOGDIR)/*.log and prints one aligned table, one row per test that's
#   been run so far. This is PER-TEST data (same number `run` already prints
#   under its own banner) just laid out side-by-side so you can eyeball which
#   tests are pulling their weight on which covergroup. It is NOT the real
#   cumulative regression number - two tests each individually at 60% on
#   cx_dim_x_weight could easily union to 90%+ if they hit different bins,
#   and this table can't show that. Use cov-check for the real number.
#
# cov-merge / cov-report / cov-check: use IMC to merge every test's UCD
#   (now correctly separated per-test thanks to -covtest above) into one
#   database and report against it - this is the real, bin-level, unioned
#   coverage the "run random until 90%" workflow actually needs to look at.
#
#   CAVEAT: the imc invocations below are written from general Cadence IMC
#   usage patterns, not verified against a specific IMC version here - run
#   `imc -help` (or check for existing IMC scripts elsewhere in this repo)
#   and adjust flags if these don't match your site's IMC install.
# ==============================================================================

.PHONY: cov-summary
cov-summary:
	@if [ -z "$$(ls $(LOGDIR)/*.log 2>/dev/null)" ]; then \
		echo "No logs found in $(LOGDIR)/ - run some tests first."; \
		exit 1; \
	fi; \
	printf "%-45s %8s %8s %8s %8s %8s %8s %8s %8s\n" \
		"TEST" "dim" "wpat" "apat" "dxw" "dxa" "err" "b2b" "rst"; \
	printf '%.0s-' $$(seq 1 130); echo ""; \
	for f in $(LOGDIR)/*.log; do \
		t=$$(basename $$f .log); \
		line=$$(grep '\[MMU_COV\]' $$f | tail -1); \
		if [ -z "$$line" ]; then \
			printf "%-45s %8s %8s %8s %8s %8s %8s %8s %8s\n" "$$t" "--" "--" "--" "--" "--" "--" "--" "--"; \
			continue; \
		fi; \
		get() { echo "$$line" | grep -oE "$$1=[0-9.]+" | sed -E 's/.*=//'; }; \
		printf "%-45s %7s%% %7s%% %7s%% %7s%% %7s%% %7s%% %7s%% %7s%%\n" \
			"$$t" \
			"$$(get cp_dim)" "$$(get cp_weight_pattern)" "$$(get cp_activation_pattern)" \
			"$$(get cx_dim_x_weight)" "$$(get cx_dim_x_act)" "$$(get cp_error_type)" \
			"$$(get cp_back_to_back)" "$$(get cp_reset_state)"; \
	done

.PHONY: cov-merge
cov-merge:
	@if [ -z "$$(find $(COVWORKDIR)/scope -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]; then \
		echo "No per-test coverage directories found under $(COVWORKDIR)/scope/ -"; \
		echo "run some tests with the -covtest-enabled 'run' target first."; \
		exit 1; \
	fi; \
	echo "Merging all per-test UCDs under $(COVWORKDIR)/scope/*/ ..."; \
	ucds=$$(echo $(COVWORKDIR)/scope/*/*.ucd); \
	printf 'merge -initial_model union -out merged.ucd %s\nexit\n' "$$ucds" > $(COVWORKDIR)/.imc_merge.tcl; \
	imc -exec $(COVWORKDIR)/.imc_merge.tcl; \
	echo "Merged database: $(COVWORKDIR)/merged.ucd"

.PHONY: cov-report
cov-report: cov-merge
	@printf 'load -run %s\nreport -summary -metrics functional -out %s\nexit\n' \
		"$(COVWORKDIR)/merged.ucd" "$(COVWORKDIR)/functional_summary.txt" > $(COVWORKDIR)/.imc_report.tcl; \
	imc -exec $(COVWORKDIR)/.imc_report.tcl; \
	echo ""; \
	echo "############################################################"; \
	echo "###   MERGED FUNCTIONAL COVERAGE SUMMARY"; \
	echo "###   (full bin-level detail: imc -gui -load $(COVWORKDIR)/merged.ucd)"; \
	echo "############################################################"; \
	cat $(COVWORKDIR)/functional_summary.txt

.PHONY: cov-check
cov-check: cov-report
	@echo ""; \
	below=""; \
	while read -r name pct; do \
		pct_int=$$(echo $$pct | sed 's/%//' | cut -d. -f1); \
		if [ -n "$$pct_int" ] && [ "$$pct_int" -lt "$(COV_THRESHOLD)" ] 2>/dev/null; then \
			below="$$below\n    - $$name: $$pct"; \
		fi; \
	done < <(grep -E '^(cg_|cp_|cx_)' $(COVWORKDIR)/functional_summary.txt); \
	if [ -n "$$below" ]; then \
		echo "############################################################"; \
		echo "###   COVERAGE CHECK: FAIL - below $(COV_THRESHOLD)% threshold:"; \
		echo -e "$$below"; \
		echo "###"; \
		echo "###   These need either directed tests targeting the specific"; \
		echo "###   missing bins (see: imc -gui -load $(COVWORKDIR)/merged.ucd)"; \
		echo "###   or an explicit, reviewed waiver if unreachable."; \
		echo "############################################################"; \
		exit 1; \
	else \
		echo "############################################################"; \
		echo "###   COVERAGE CHECK: PASS - all groups >= $(COV_THRESHOLD)%"; \
		echo "############################################################"; \
	fi

# ADDED (this pass) - one-shot entry point: run the full regression, then
# merge + check coverage against COV_THRESHOLD. This is the "run random
# until covergroups hit N%" loop as a single command; the actual closing of
# any gaps cov-check reports still needs directed tests added to the
# category lists above, this just tells you where those gaps are.
.PHONY: regress
regress: run-all-cats cov-check

# Cleanup target to remove Xcelium compilation artifacts
.PHONY: clean
clean:
	@echo "Cleaning up simulation files..."
	rm -rf xcelium.d xrun.history xrun.log waves.shm *.err