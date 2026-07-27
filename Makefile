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

# The main simulation target
run:
	@echo "==================================================================="
	@echo "Running Test: $(TEST)"
	@echo "==================================================================="
	xrun -f run.f \
	-uvm +incdir+uvm+rtl+tb -64bit tb/mmu_dpi_bridge.c \
	$(PY_INCLUDES) $(PY_LDFLAGS) \
	-access +rwc \
	-coverage all \
	-covoverwrite \
	-sv \
	+UVM_TESTNAME=$(TEST) \
	+UVM_VERBOSITY=$(VERBOSITY)

# Cleanup target to remove Xcelium compilation artifacts
clean:
	@echo "Cleaning up simulation files..."
	rm -rf xcelium.d xrun.history xrun.log waves.shm *.err
