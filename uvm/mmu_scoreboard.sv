// =============================================================================
// mmu_scoreboard.sv — Scoreboard driven by the Python golden model (ref_model.py)
//
// Satisfies Key Rule 4: "Scoreboard must be driven by Python golden model —
// never hand-compute outputs." There is NO matmul math in this file. Expected
// values come from ref_model.py at simulation time, via a DPI-C bridge
// (mmu_dpi_bridge.c) that embeds the Python interpreter.
//
// -----------------------------------------------------------------------------
// STATUS
//   TESTED:     mmu_dpi_bridge.c calling ref_model.py, standalone in C
//               (2x2 -> 19,22,43,50; worst case -> -65024; identity
//               passthrough; illegal N=5 correctly raises ValueError).
//   NOT TESTED: this file's DPI import linkage. Never compiled — no Xcelium
//               was available. Open-array passing across DPI is the most
//               likely thing to need adjusting. Expect to iterate.
// -----------------------------------------------------------------------------
//
// RUN (from a directory where ref_model.py is importable, or set REF_MODEL_DIR):
//
//   xrun -sv -dpi dpi/mmu_dpi_bridge.c \
//        uvm/mmu_scoreboard.sv tb/mmu_scoreboard_smoke_tb.sv \
//        $(python3-config --includes) \
//        -Wcxx,$(python3-config --ldflags --embed)
//
// Requires on the sim host: python3, numpy, and Python dev headers.
// Note this makes `make regress` depend on Python + numpy — check against
// Key Rule 11 ("make regress must work from a cold clone") with the team.
// =============================================================================

`timescale 1ns/1ps

package mmu_scoreboard_pkg;

    localparam int MAX_ELEMS = 16;

    // -------------------------------------------------------------------
    // DPI-C imports — these are implemented in mmu_dpi_bridge.c
    // -------------------------------------------------------------------

    // Boot the embedded Python interpreter and import ref_model.py.
    // Returns 0 on success. Call once, before any matmul call.
    import "DPI-C" function int ref_model_init();

    // Call ref_model.matmul_flat(act, wgt, n).
    //   act, wgt : n*n signed ints (int8-range values, already sign-correct)
    //   result   : n*n int32 results written back
    // Returns 0 on success; nonzero if Python raised (illegal N, out-of-range
    // input, overflow) — those exceptions are themselves meaningful failures.
    // Fixed-size arrays (not open arrays). A fixed-size unpacked array of int
    // maps directly to a plain C `int*`, which is what mmu_dpi_bridge.c expects.
    // Open arrays (int foo []) would arrive as an opaque svOpenArrayHandle and
    // require svGetArrElemPtr1 to read — more fragile, tool-version-sensitive.
    // Always MAX_ELEMS long; only the first n*n entries are read/written.
    import "DPI-C" function int ref_model_matmul(
        input  int act    [16],
        input  int wgt    [16],
        input  int n,
        output int result [16]
    );

    // Shut down the interpreter. Call once at end of simulation.
    import "DPI-C" function void ref_model_final();

endpackage : mmu_scoreboard_pkg


module mmu_scoreboard;
    import mmu_scoreboard_pkg::*;

    int pass_count = 0;
    int fail_count = 0;
    bit initialized = 0;

    // -------------------------------------------------------------------
    // init — must be called once before any check_result.
    // -------------------------------------------------------------------
    task automatic init();
        int rc;
        begin
            if (initialized) return;
            rc = ref_model_init();
            if (rc != 0) begin
                $fatal(1, "[SCOREBOARD] ref_model_init() failed with rc=%0d. Is ref_model.py on the path?", rc);
            end
            initialized = 1;
            $display("[SCOREBOARD] Python golden model (ref_model.py) loaded via DPI.");
        end
    endtask

    // -------------------------------------------------------------------
    // check_result — asks ref_model.py for the expected answer, compares.
    //
    // NOTE the key difference from the SV-native version: there is NO matmul
    // math anywhere in this file. The expected values come straight out of
    // Python. If ref_model.py changes, this scoreboard follows automatically —
    // there is exactly one implementation of the golden math in the project.
    // -------------------------------------------------------------------
    task automatic check_result(
        input string name,
        input int    act     [16],   // first n*n entries valid, row-major
        input int    wgt     [16],   // first n*n entries valid, row-major
        input int    n,
        input int    dut_out [16]    // first n*n entries valid, row-major
    );
        int exp [16];
        int rc;
        bit ok;
        int idx;
        begin
            if (!initialized) init();

            rc = ref_model_matmul(act, wgt, n, exp);

            if (rc != 0) begin
                // Python raised. Either the TB fed illegal stimulus (which the
                // golden model correctly rejected — see ref_model.py's
                // validation), or something is genuinely broken.
                fail_count++;
                $display("  FAIL  %-42s (ref_model.py raised, rc=%0d -- see traceback above)", name, rc);
                return;
            end

            ok = 1;
            for (idx = 0; idx < n*n; idx++)
                if (dut_out[idx] !== exp[idx]) ok = 0;

            if (ok) begin
                pass_count++;
                $display("  PASS  %-42s (N=%0d matches ref_model.py)", name, n);
            end else begin
                fail_count++;
                $display("  FAIL  %-42s (N=%0d MISMATCH vs ref_model.py)", name, n);
                for (idx = 0; idx < n*n; idx++)
                    if (dut_out[idx] !== exp[idx])
                        $display("        idx=%0d dut=%0d exp=%0d", idx, dut_out[idx], exp[idx]);
            end
        end
    endtask

    // -------------------------------------------------------------------
    // finish — tear down Python. Call once at end of simulation.
    // -------------------------------------------------------------------
    task automatic finish_up();
        begin
            if (initialized) begin
                ref_model_final();
                initialized = 0;
            end
        end
    endtask

endmodule : mmu_scoreboard