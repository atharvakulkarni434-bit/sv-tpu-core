/* =============================================================================
 * mmu_dpi_bridge.c — DPI-C bridge: SystemVerilog -> Python (ref_model.py)
 *
 * Lets mmu_scoreboard.sv call the ACTUAL Python golden model at simulation
 * time, rather than reimplementing the math in SystemVerilog. This satisfies
 * a strict reading of Key Rule 4: "Scoreboard must be driven by Python golden
 * model — never hand-compute outputs."
 *
 * Exposes three functions to SystemVerilog:
 *   ref_model_init()    - start the embedded Python interpreter, import
 *                         ref_model.py. Call once before any matmul.
 *   ref_model_matmul()  - call ref_model.matmul_flat(act, wgt, n) and write
 *                         the n*n int32 results back into the SV array.
 *                         Returns 0 on success, nonzero on error.
 *   ref_model_final()   - shut the interpreter down. Call once at the end.
 *
 * Build (Xcelium will typically compile this for you via -dpi; see notes in
 * mmu_scoreboard_dpi.sv for the xrun command line).
 *
 * IMPORTANT: ref_model.py must be importable — either in the working
 * directory when the simulation runs, or on PYTHONPATH. ref_model_init()
 * explicitly adds "." and the REF_MODEL_DIR env var (if set) to sys.path.
 * =============================================================================
 */

#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include "svdpi.h"

/* Must match MAX_ELEMS in mmu_scoreboard_pkg (4x4 physical array). */
#define MMU_MAX_ELEMS 16

static PyObject *g_matmul_flat = NULL;   /* cached handle to matmul_flat */
static int       g_initialized = 0;

/* ---------------------------------------------------------------------------
 * ref_model_init — boot Python, import ref_model, cache matmul_flat.
 * Returns 0 on success, nonzero on failure.
 * ------------------------------------------------------------------------- */
int ref_model_init(void)
{
    PyObject *module = NULL;
    PyObject *sys_path = NULL;
    PyObject *cwd = NULL;
    const char *ref_dir;

    if (g_initialized) return 0;   /* idempotent */

    Py_Initialize();
    if (!Py_IsInitialized()) {
        fprintf(stderr, "[DPI] FATAL: Py_Initialize() failed\n");
        return 1;
    }

    /* Make sure ref_model.py can be found: add "." and $REF_MODEL_DIR */
    sys_path = PySys_GetObject("path");        /* borrowed ref */
    if (sys_path) {
        cwd = PyUnicode_FromString(".");
        if (cwd) { PyList_Append(sys_path, cwd); Py_DECREF(cwd); }

        ref_dir = getenv("REF_MODEL_DIR");
        if (ref_dir) {
            PyObject *d = PyUnicode_FromString(ref_dir);
            if (d) { PyList_Append(sys_path, d); Py_DECREF(d); }
        }
    }

    module = PyImport_ImportModule("ref_model");
    if (!module) {
        fprintf(stderr, "[DPI] FATAL: cannot import ref_model.py.\n");
        fprintf(stderr, "[DPI]        Put it in the sim working directory, or\n");
        fprintf(stderr, "[DPI]        set REF_MODEL_DIR to the directory holding it.\n");
        PyErr_Print();
        return 2;
    }

    g_matmul_flat = PyObject_GetAttrString(module, "matmul_flat");
    Py_DECREF(module);

    if (!g_matmul_flat || !PyCallable_Check(g_matmul_flat)) {
        fprintf(stderr, "[DPI] FATAL: ref_model.matmul_flat not found/callable\n");
        PyErr_Print();
        Py_XDECREF(g_matmul_flat);
        g_matmul_flat = NULL;
        return 3;
    }

    g_initialized = 1;
    return 0;
}

/* ---------------------------------------------------------------------------
 * ref_model_matmul — the actual golden-model call.
 *
 *   act, wgt : arrays of n*n signed ints (each already sign-correct int8 range)
 *   n        : active dimension, 1..4
 *   result   : caller-allocated array of at least n*n ints; filled on success
 *
 * Returns 0 on success. Nonzero means Python raised (illegal N, out-of-range
 * input, overflow) — ref_model.py's own validation fired, which is itself a
 * meaningful check: the TB fed the golden model something the spec forbids.
 * ------------------------------------------------------------------------- */
int ref_model_matmul(const int *act, const int *wgt, int n, int *result)
{
    PyObject *py_act = NULL, *py_wgt = NULL, *py_args = NULL, *py_res = NULL;
    int elems = n * n;
    int i, rc = 1;

    if (!g_initialized && ref_model_init() != 0) return 10;

    /* Bounds guard: SV passes fixed-size int[16] arrays. Reading n*n elements
     * with n > 4 would run past the end. ref_model.py rejects n>4 today, but
     * do not rely on that — this is C, an out-of-bounds read is undefined
     * behavior, not a clean exception. Fail fast instead. */
    if (n < 1 || n * n > MMU_MAX_ELEMS) {
        fprintf(stderr, "[DPI] ref_model_matmul: n=%d out of range (n*n must be <= %d)\n",
                n, MMU_MAX_ELEMS);
        return 5;
    }

    py_act = PyList_New(elems);
    py_wgt = PyList_New(elems);
    if (!py_act || !py_wgt) goto cleanup;

    for (i = 0; i < elems; i++) {
        /* PyList_SetItem steals the reference — no DECREF on the item */
        PyList_SetItem(py_act, i, PyLong_FromLong((long)act[i]));
        PyList_SetItem(py_wgt, i, PyLong_FromLong((long)wgt[i]));
    }

    py_args = Py_BuildValue("(OOi)", py_act, py_wgt, n);
    if (!py_args) goto cleanup;

    py_res = PyObject_CallObject(g_matmul_flat, py_args);
    if (!py_res) {
        fprintf(stderr, "[DPI] ref_model.matmul_flat raised an exception:\n");
        PyErr_Print();      /* prints e.g. ValueError: n must be in 1..4 */
        rc = 2;
        goto cleanup;
    }

    /* Handle NumPy 1x1 auto-squeeze returning a scalar instead of a list */
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
        goto cleanup; /* We have our 1 value, skip the loop */
    }
    /* Standard check for n > 1 matrices */
    else if (!PyList_Check(py_res) || PyList_Size(py_res) != elems) {
        fprintf(stderr, "[DPI] matmul_flat returned unexpected shape\n");
        rc = 3;
        goto cleanup;
    }

    for (i = 0; i < elems; i++) {
        PyObject *item = PyList_GetItem(py_res, i);   /* borrowed */
        long v = PyLong_AsLong(item);
        if (v == -1 && PyErr_Occurred()) { PyErr_Print(); rc = 4; goto cleanup; }
        result[i] = (int)v;
    }
    rc = 0;

cleanup:
    Py_XDECREF(py_res);
    Py_XDECREF(py_args);   /* also releases py_act/py_wgt via the tuple */
    if (!py_args) { Py_XDECREF(py_act); Py_XDECREF(py_wgt); }
    return rc;
}

/* ---------------------------------------------------------------------------
 * ref_model_final — tear down the interpreter at end of simulation.
 * ------------------------------------------------------------------------- */
void ref_model_final(void)
{
    if (!g_initialized) return;
    Py_XDECREF(g_matmul_flat);
    g_matmul_flat = NULL;
    Py_Finalize();
    g_initialized = 0;
}