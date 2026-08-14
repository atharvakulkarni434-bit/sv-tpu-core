/* =============================================================================
 * mmu_dpi_bridge.c — DPI-C bridge: SystemVerilog -> Python (ref_model.py)
 *
 * Lets mmu_scoreboard.sv call the REAL Python golden model while the sim is
 * running, instead of reimplementing the matmul math a second time in
 * SystemVerilog. If we hand-wrote the "expected answer" logic in SV too, a
 * misunderstanding of the spec could exist in BOTH the RTL and the checker —
 * a separate, independently-written Python model avoids that trap.
 *
 * Three functions exposed to SystemVerilog:
 *   ref_model_init()   - starts Python, imports ref_model.py. Call once.
 *   ref_model_matmul()  - the actual golden-model call.
 *   ref_model_final()   - shuts Python down cleanly. Call once, at the end.
 * =============================================================================
 */

#include <Python.h>    // gives C access to Python's own internal API
#include <stdio.h>     // for fprintf — printing error messages
#include <stdlib.h>    // for getenv — reading the REF_MODEL_DIR env var
#include "svdpi.h"     // SystemVerilog's DPI header — lets SV call this file

#define MMU_MAX_ELEMS 16   // 4x4 array — must match the SV side

// shared state across all 3 functions in this file
static PyObject *g_matmul_flat = NULL;   // cached handle to Python's matmul_flat function
static int       g_initialized = 0;      // 0 = Python not started yet, 1 = it is


/* ---------------------------------------------------------------------------
 * ref_model_init — boots Python, imports ref_model.py, caches matmul_flat.
 * Returns 0 on success, nonzero on failure.
 * ------------------------------------------------------------------------- */
int ref_model_init(void)
{
    // temporary handles used while setting things up
    PyObject *module = NULL;
    PyObject *sys_path = NULL;
    PyObject *cwd = NULL;
    const char *ref_dir;

    // already started once — nothing new to do, Python is already ready
    if (g_initialized) return 0;

    // actually boot up the embedded Python interpreter
    Py_Initialize();
    if (!Py_IsInitialized()) {
        fprintf(stderr, "[DPI] FATAL: Py_Initialize() failed\n");
        return 1;
    }

    // make sure Python can actually FIND ref_model.py on disk
    sys_path = PySys_GetObject("path");   // Python's own list of search folders
    if (sys_path) {

        // add the current working directory to that search list
        cwd = PyUnicode_FromString(".");
        if (cwd) { PyList_Append(sys_path, cwd); Py_DECREF(cwd); }

        // also add REF_MODEL_DIR, if the user set that env var
        ref_dir = getenv("REF_MODEL_DIR");
        if (ref_dir) {
            PyObject *d = PyUnicode_FromString(ref_dir);
            if (d) { PyList_Append(sys_path, d); Py_DECREF(d); }
        }
    }

    // actually import ref_model.py as a real Python module
    module = PyImport_ImportModule("ref_model");
    if (!module) {
        fprintf(stderr, "[DPI] FATAL: cannot import ref_model.py.\n");
        fprintf(stderr, "[DPI]        Put it in the sim working directory, or\n");
        fprintf(stderr, "[DPI]        set REF_MODEL_DIR to the directory holding it.\n");
        PyErr_Print();
        return 2;
    }

    // grab a reusable handle to the one function we'll call, over and over
    g_matmul_flat = PyObject_GetAttrString(module, "matmul_flat");
    Py_DECREF(module);   // done with the module handle itself

    // confirm we actually got back a real, callable function
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
 *   act, wgt : n*n activation and weight values
 *   n        : active matrix size, 1..4
 *   result   : where we write the n*n correct answers back into
 * Returns 0 on success. Nonzero means Python rejected the input.
 * ------------------------------------------------------------------------- */
int ref_model_matmul(const int *act, const int *wgt, int n, int *result)
{
    PyObject *py_act = NULL, *py_wgt = NULL, *py_args = NULL, *py_res = NULL;
    int elems = n * n;
    int i, rc = 1;

    // make sure Python is actually running before using it
    if (!g_initialized && ref_model_init() != 0) return 10;

    // safety check: SV always passes fixed 16-element arrays — reading
    // n*n elements with n>4 would read PAST the end (undefined behavior
    // in C). Catch this ourselves, don't just trust Python to reject it.
    if (n < 1 || n * n > MMU_MAX_ELEMS) {
        fprintf(stderr, "[DPI] ref_model_matmul: n=%d out of range (n*n must be <= %d)\n",
                n, MMU_MAX_ELEMS);
        return 5;
    }

    // build two Python lists to hold the activation/weight values
    py_act = PyList_New(elems);
    py_wgt = PyList_New(elems);
    if (!py_act || !py_wgt) goto cleanup;

    // copy every C int into the Python lists
    for (i = 0; i < elems; i++) {
        // PyList_SetItem takes ownership — no extra cleanup needed on the item
        PyList_SetItem(py_act, i, PyLong_FromLong((long)act[i]));
        PyList_SetItem(py_wgt, i, PyLong_FromLong((long)wgt[i]));
    }

    // package (activations, weights, n) into one Python argument tuple
    py_args = Py_BuildValue("(OOi)", py_act, py_wgt, n);
    if (!py_args) goto cleanup;

    // THE ACTUAL CALL — run ref_model.py's matmul_flat function right now
    py_res = PyObject_CallObject(g_matmul_flat, py_args);
    if (!py_res) {
        // Python raised an exception — print it and bail out
        fprintf(stderr, "[DPI] ref_model.matmul_flat raised an exception:\n");
        PyErr_Print();
        rc = 2;
        goto cleanup;
    }

    // special case: for a 1x1 matrix, NumPy sometimes returns one plain
    // number instead of a list containing one number
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
        goto cleanup;   // got our one value, skip the loop below
    }
    // normal case: confirm the result is a list of the right size
    else if (!PyList_Check(py_res) || PyList_Size(py_res) != elems) {
        fprintf(stderr, "[DPI] matmul_flat returned unexpected shape\n");
        rc = 3;
        goto cleanup;
    }

    // copy every value out of the Python result list into our C array
    for (i = 0; i < elems; i++) {
        PyObject *item = PyList_GetItem(py_res, i);   // borrowed, no extra cleanup
        long v = PyLong_AsLong(item);
        if (v == -1 && PyErr_Occurred()) { PyErr_Print(); rc = 4; goto cleanup; }
        result[i] = (int)v;
    }
    rc = 0;   // everything succeeded

cleanup:
    // release every Python object we made, whether we succeeded or bailed early
    Py_XDECREF(py_res);
    Py_XDECREF(py_args);   // also releases py_act/py_wgt, since they're inside the tuple
    if (!py_args) { Py_XDECREF(py_act); Py_XDECREF(py_wgt); }   // unless the tuple was never built
    return rc;
}


/* ---------------------------------------------------------------------------
 * ref_model_final — shuts down the embedded Python interpreter cleanly.
 * Call once, at the very end of the whole simulation.
 * ------------------------------------------------------------------------- */
void ref_model_final(void)
{
    if (!g_initialized) return;   // nothing to shut down if never started

    Py_XDECREF(g_matmul_flat);    // release our cached function handle
    g_matmul_flat = NULL;
    Py_Finalize();                 // shut the whole Python interpreter down
    g_initialized = 0;
}
