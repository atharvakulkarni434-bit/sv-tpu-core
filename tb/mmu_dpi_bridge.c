/* =============================================================================
 * mmu_dpi_bridge.c — DPI-C bridge: SystemVerilog -> Python (ref_model.py)
 *
 * This lets mmu_scoreboard.sv call the ACTUAL Python golden model while the
 * simulation is running, instead of reimplementing the matmul math a second
 * time in SystemVerilog. If we hand-wrote the "expected answer" logic in SV
 * too, a misunderstanding of the spec could exist in BOTH the RTL and the
 * checker — using a genuinely separate, independently-written Python model
 * avoids that trap.
 *
 * Three functions get exposed to SystemVerilog:
 *   ref_model_init()   - starts up the embedded Python interpreter and
 *                         imports ref_model.py. Call once, before anything else.
 *   ref_model_matmul()  - the actual golden-model call: hands Python the
 *                         activation/weight data, gets back the real answer.
 *   ref_model_final()   - shuts the interpreter down cleanly at the end.
 *
 * IMPORTANT: ref_model.py has to be findable — either sitting in the working
 * directory, or on PYTHONPATH. ref_model_init() explicitly adds "." and the
 * REF_MODEL_DIR environment variable (if set) to Python's search path.
 * =============================================================================
 */

#include <Python.h>    // gives C access to Python's own internal API
#include <stdio.h>     // for fprintf — printing error messages
#include <stdlib.h>    // for getenv — reading the REF_MODEL_DIR env var
#include "svdpi.h"     // SystemVerilog's DPI header — what lets SV call this file

// Must match MAX_ELEMS on the SystemVerilog side (4x4 physical array = 16).
#define MMU_MAX_ELEMS 16

// Two pieces of GLOBAL state, shared across all 3 functions in this file.
static PyObject *g_matmul_flat = NULL;   // cached handle to Python's matmul_flat function
static int       g_initialized = 0;      // 0 = Python not started yet, 1 = it is


/* ---------------------------------------------------------------------------
 * ref_model_init — boots up Python, imports ref_model.py, and grabs a
 * reusable handle to its matmul_flat function so we don't have to look it
 * up again every single time we need to check a result.
 * Returns 0 on success, nonzero on failure.
 * ------------------------------------------------------------------------- */
int ref_model_init(void)
{
    PyObject *module = NULL;
    PyObject *sys_path = NULL;
    PyObject *cwd = NULL;
    const char *ref_dir;

    // if we already started Python once, don't do it again — just succeed
    if (g_initialized) return 0;

    // start the embedded Python interpreter running inside this C process
    Py_Initialize();
    if (!Py_IsInitialized()) {
        fprintf(stderr, "[DPI] FATAL: Py_Initialize() failed\n");
        return 1;
    }

    // make sure Python can actually FIND ref_model.py — add the current
    // directory, and REF_MODEL_DIR (if the user set it) to Python's search path
    sys_path = PySys_GetObject("path");
    if (sys_path) {
        cwd = PyUnicode_FromString(".");
        if (cwd) { PyList_Append(sys_path, cwd); Py_DECREF(cwd); }

        ref_dir = getenv("REF_MODEL_DIR");
        if (ref_dir) {
            PyObject *d = PyUnicode_FromString(ref_dir);
            if (d) { PyList_Append(sys_path, d); Py_DECREF(d); }
        }
    }

    // actually import the ref_model.py file as a Python module
    module = PyImport_ImportModule("ref_model");
    if (!module) {
        fprintf(stderr, "[DPI] FATAL: cannot import ref_model.py.\n");
        fprintf(stderr, "[DPI]        Put it in the sim working directory, or\n");
        fprintf(stderr, "[DPI]        set REF_MODEL_DIR to the directory holding it.\n");
        PyErr_Print();
        return 2;
    }

    // grab a handle to the specific function inside that module we'll call
    g_matmul_flat = PyObject_GetAttrString(module, "matmul_flat");
    Py_DECREF(module);   // done with the module handle itself, release it

    // confirm we actually got a real, callable function back
    if (!g_matmul_flat || !PyCallable_Check(g_matmul_flat)) {
        fprintf(stderr, "[DPI] FATAL: ref_model.matmul_flat not found/callable\n");
        PyErr_Print();
        Py_XDECREF(g_matmul_flat);
        g_matmul_flat = NULL;
        return 3;
    }

    g_initialized = 1;   // mark Python as fully ready for use
    return 0;
}


/* ---------------------------------------------------------------------------
 * ref_model_matmul — the actual golden-model call.
 *
 *   act, wgt : the activation and weight values, n*n of them each
 *   n        : the active matrix size, 1 through 4
 *   result   : where we write the n*n correct answers back into
 *
 * Returns 0 on success. Nonzero means Python itself rejected the input
 * (illegal size, out-of-range values, overflow) — which is a meaningful
 * signal too: it means the testbench fed the golden model something the
 * spec says should never happen.
 * ------------------------------------------------------------------------- */
int ref_model_matmul(const int *act, const int *wgt, int n, int *result)
{
    PyObject *py_act = NULL, *py_wgt = NULL, *py_args = NULL, *py_res = NULL;
    int elems = n * n;
    int i, rc = 1;

    // make sure Python is actually running before we try to use it
    if (!g_initialized && ref_model_init() != 0) return 10;

    // Safety check: SystemVerilog always passes fixed-size 16-element
    // arrays. If n were somehow bigger than 4, reading n*n elements would
    // read PAST the end of those arrays — undefined behavior in C, not a
    // clean error. Catch this explicitly, don't just trust Python to reject it.
    if (n < 1 || n * n > MMU_MAX_ELEMS) {
        fprintf(stderr, "[DPI] ref_model_matmul: n=%d out of range (n*n must be <= %d)\n",
                n, MMU_MAX_ELEMS);
        return 5;
    }

    // build two Python lists to hold the activation/weight values
    py_act = PyList_New(elems);
    py_wgt = PyList_New(elems);
    if (!py_act || !py_wgt) goto cleanup;

    // copy every C int into the Python lists, one at a time
    for (i = 0; i < elems; i++) {
        // PyList_SetItem takes ownership of the item — no extra cleanup needed for it
        PyList_SetItem(py_act, i, PyLong_FromLong((long)act[i]));
        PyList_SetItem(py_wgt, i, PyLong_FromLong((long)wgt[i]));
    }

    // package (activations, weights, n) into a single Python argument tuple
    py_args = Py_BuildValue("(OOi)", py_act, py_wgt, n);
    if (!py_args) goto cleanup;

    // THE ACTUAL CALL — run ref_model.py's matmul_flat function, right now
    py_res = PyObject_CallObject(g_matmul_flat, py_args);
    if (!py_res) {
        // Python itself raised an exception — print what it says and bail out
        fprintf(stderr, "[DPI] ref_model.matmul_flat raised an exception:\n");
        PyErr_Print();
        rc = 2;
        goto cleanup;
    }

    // Special case: for a 1x1 matrix, NumPy sometimes returns a single
    // number instead of a list of one number — handle that separately
    if (elems == 1 && !PyList_Check(py_res)) {
        long v = PyLong_AsLong(py_res);
        if (v == -1 && PyErr_Occurred()) {
            fprintf(stderr, "[DPI] Failed to cast 1x1 scalar to integer\n");
            PyErr_Print();
            rc = 4;
            goto cleanup;
        }
        result[0] = (int)v;
        rc = 0;
        goto cleanup;   // got our one value, skip the normal loop below
    }
    // Normal case: confirm the result is actually a list of the right size
    else if (!PyList_Check(py_res) || PyList_Size(py_res) != elems) {
        fprintf(stderr, "[DPI] matmul_flat returned unexpected shape\n");
        rc = 3;
        goto cleanup;
    }

    // copy every value out of the Python result list, back into our C array
    for (i = 0; i < elems; i++) {
        PyObject *item = PyList_GetItem(py_res, i);   // borrowed reference, no extra cleanup
        long v = PyLong_AsLong(item);
        if (v == -1 && PyErr_Occurred()) { PyErr_Print(); rc = 4; goto cleanup; }
        result[i] = (int)v;
    }
    rc = 0;   // everything succeeded

cleanup:
    // release every Python object we created, whether we succeeded or bailed early
    Py_XDECREF(py_res);
    Py_XDECREF(py_args);   // this also releases py_act/py_wgt, since they're inside the tuple
    if (!py_args) { Py_XDECREF(py_act); Py_XDECREF(py_wgt); }   // unless the tuple was never built
    return rc;
}


/* ---------------------------------------------------------------------------
 * ref_model_final — shuts down the embedded Python interpreter cleanly.
 * Call this once, at the very end of the whole simulation.
 * ------------------------------------------------------------------------- */
void ref_model_final(void)
{
    if (!g_initialized) return;   // nothing to shut down if it was never started

    Py_XDECREF(g_matmul_flat);    // release our cached function handle
    g_matmul_flat = NULL;
    Py_Finalize();                 // shut the whole Python interpreter down
    g_initialized = 0;
}
