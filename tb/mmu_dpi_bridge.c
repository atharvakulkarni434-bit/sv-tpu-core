/* =============================================================================
 * mmu_dpi_bridge.c — DPI-C bridge: SystemVerilog -> Python (ref_model.py)
 *
 * The only file in this whole project written in plain C, not SystemVerilog.
 * Its job: let mmu_scoreboard.sv call the REAL Python golden model while the
 * simulation is actually running, instead of reimplementing the matmul math
 * a second time in SystemVerilog. If I hand-wrote the "expected answer"
 * logic in SV too, a bug in my understanding of the spec could exist in
 * BOTH the RTL and the checker at once, and I'd never catch it. A genuinely
 * separate, independently-written Python model closes that gap.
 *
 * Three functions, matching the 3 things an embedded interpreter needs:
 *   ref_model_init()   - start Python up, once
 *   ref_model_matmul()  - use it, repeatedly, once per result checked
 *   ref_model_final()   - shut it down cleanly, once, at the end
 * =============================================================================
 */

#include <Python.h>    // Python's own C API — lets plain C create/call Python objects
#include <stdio.h>     // fprintf — for error messages
#include <stdlib.h>    // getenv — reads the REF_MODEL_DIR env var
#include "svdpi.h"     // SystemVerilog's DPI header — the piece that lets SV call INTO this file

#define MMU_MAX_ELEMS 16   // 4x4 array — has to match MAX_ELEMS on the SV side, by hand

// Global state shared across all 3 functions — this is what makes ref_model_init()
// only need to run once: after the first call, these two variables persist.
static PyObject *g_matmul_flat = NULL;   // a global variable that will hold a reusable reference to Python's matmul_flat function, starting out empty until it gets filled in.
static int       g_initialized = 0;      // 0 = Python not running yet, 1 = it is


/* ---------------------------------------------------------------------------
 * ref_model_init — starts the embedded Python interpreter, imports
 * ref_model.py, and caches a reusable handle to its matmul_flat function.
 * Called once, from mmu_scoreboard.sv's build_phase.
 * ------------------------------------------------------------------------- */
int ref_model_init(void)
{
    PyObject *module = NULL;    // will hold the imported ref_model.py file itself, once we import it
    PyObject *sys_path = NULL;  // will hold Python's own list of folders it searches for modules
    PyObject *cwd = NULL;       // will hold "." (current folder) as a Python string, to add to sys_path
    const char *ref_dir;        // will hold the folder path where ref_model.py lives, if the user set REF_MODEL_DIR

    // Idempotent guard — if Python's already running from an earlier call,
    // there's nothing left to do; just report success immediately.
    if (g_initialized) return 0;

    // This is the actual moment an entire Python interpreter boots up,
    // living inside this C process.
    Py_Initialize();
    if (!Py_IsInitialized()) {
        fprintf(stderr, "[DPI] FATAL: Py_Initialize() failed\n");
        return 1;
    }

    // Python needs to know WHERE on disk to look for ref_model.py — this
    // is exactly the kind of environment-setup detail that's easy to
    // overlook and cause a "works on my machine" bug later.
    sys_path = PySys_GetObject("path");
    if (sys_path) {

        // Cover the common case: ref_model.py sits right next to wherever
        // the simulation is being run from.
        //check in the current folder im running from and see if refmodel is in it
        cwd = PyUnicode_FromString(".");
        if (cwd) { PyList_Append(sys_path, cwd); Py_DECREF(cwd); }

        // Also support an explicit override, for CI or a different layout.
        // Add ref_model_dir into python search list
        ref_dir = getenv("REF_MODEL_DIR");
        if (ref_dir) {
            PyObject *d = PyUnicode_FromString(ref_dir);
            if (d) { PyList_Append(sys_path, d); Py_DECREF(d); }
        }
    }

    // The actual import — this is the line that makes ref_model.py a real,
    // usable Python module from here on.
    module = PyImport_ImportModule("ref_model");
    if (!module) {
        fprintf(stderr, "[DPI] FATAL: cannot import ref_model.py.\n");
        fprintf(stderr, "[DPI]        Put it in the sim working directory, or\n");
        fprintf(stderr, "[DPI]        set REF_MODEL_DIR to the directory holding it.\n");
        PyErr_Print();   // print Python's own traceback — real debugging info, not just my own message
        return 2;
    }

    // Grab and CACHE the specific function I'll actually call, over and
    // over, every single time a result needs checking — this is the whole
    // reason g_matmul_flat exists as a global.
    g_matmul_flat = PyObject_GetAttrString(module, "matmul_flat");
    Py_DECREF(module);   // done with the module handle itself

    // Confirm we actually got back a real, callable function — not just
    // any attribute that happened to exist under that name.
    if (!g_matmul_flat || !PyCallable_Check(g_matmul_flat)) {
        fprintf(stderr, "[DPI] FATAL: ref_model.matmul_flat not found/callable\n");
        PyErr_Print();
        Py_XDECREF(g_matmul_flat);
        g_matmul_flat = NULL;
        return 3;
    }

    g_initialized = 1;   // from here on, every future call short-circuits at the top
    return 0;
}


/* ---------------------------------------------------------------------------
 * ref_model_matmul — the actual golden-model call. Called once per result
 * mmu_scoreboard.sv needs to check.
 *   act, wgt : n*n activation and weight values
 *   n        : active matrix size, 1..4
 *   result   : where the n*n correct answers get written back into
 * Returns 0 on success. Nonzero means Python itself rejected the input —
 * which is a meaningful signal too: the testbench fed the golden model
 * something the spec forbids.
 * ------------------------------------------------------------------------- */
int ref_model_matmul(const int *act, const int *wgt, int n, int *result)
{
    PyObject *py_act = NULL;   // will hold the activation values, converted into a Python list
    PyObject *py_wgt = NULL;   // will hold the weight values, converted into a Python list
    PyObject *py_args = NULL;  // will hold (py_act, py_wgt, n) packaged as one Python argument tuple
    PyObject *py_res = NULL;   // will hold whatever matmul_flat() actually returns

    int elems = n * n;   // how many total values are in the n×n matrix
    int i;               // loop counter, used to step through each element
    int rc = 1;           // return code — starts at 1 (a generic "failure" default), set to 0 only on real success

    // Defensive — make sure init actually ran, even if something upstream
    // forgot to call it explicitly first.
    if (!g_initialized && ref_model_init() != 0) return 10;

    //SystemVerilog always passes fixed 16-element arrays.
    // If n were somehow bigger than 4, reading n*n elements would read
    // PAST the end of those arrays
    if (n < 1 || n * n > MMU_MAX_ELEMS) {
        fprintf(stderr, "[DPI] ref_model_matmul: n=%d out of range (n*n must be <= %d)\n",
                n, MMU_MAX_ELEMS);
        return 5;
    }

    // Build two Python lists to carry the activation/weight data across
    // the C-to-Python boundary — Python doesn't understand raw C arrays.
    py_act = PyList_New(elems);
    py_wgt = PyList_New(elems);
    if (!py_act || !py_wgt) goto cleanup;

    // Copy every C int into the Python lists, converting each one into a
    // real Python integer object as we go.
    for (i = 0; i < elems; i++) {
        // PyList_SetItem takes ownership of the item — no separate cleanup needed for it
        PyList_SetItem(py_act, i, PyLong_FromLong((long)act[i]));
        PyList_SetItem(py_wgt, i, PyLong_FromLong((long)wgt[i]));
    }

    // Package everything into one argument tuple, matching exactly the
    // signature ref_model.py's matmul_flat function expects.
    py_args = Py_BuildValue("(OOi)", py_act, py_wgt, n);
    if (!py_args) goto cleanup;

    // THIS is the actual golden-model call — the one line where control
    // genuinely crosses from C into real, running Python code.
    py_res = PyObject_CallObject(g_matmul_flat, py_args);
    if (!py_res) {
        // Python raised a real exception — print its own traceback, since
        // that's far more useful for debugging than any message I'd write myself.
        fprintf(stderr, "[DPI] ref_model.matmul_flat raised an exception:\n");
        PyErr_Print();
        rc = 2;
        goto cleanup;
    }

    // Edge case I had to handle: for a 1x1 matrix, NumPy auto-squeezes and
    // returns one plain number instead of a list containing one number —
    // without this branch, that case would silently break.
    // Py int to C int
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
        goto cleanup;   // got the one value we need — skip the loop below entirely
    }
    // Normal case (n > 1): sanity-check the shape of what came back it should be a list
    else if (!PyList_Check(py_res) || PyList_Size(py_res) != elems) {
        fprintf(stderr, "[DPI] matmul_flat returned unexpected shape\n");
        rc = 3;
        goto cleanup;
    }

    // Copy every value out of the Python result list, back across the
    // boundary into the plain C array the SystemVerilog side expects.
    for (i = 0; i < elems; i++) {
        PyObject *item = PyList_GetItem(py_res, i);   // borrowed reference — no extra cleanup on this one
        long v = PyLong_AsLong(item);
        if (v == -1 && PyErr_Occurred()) { PyErr_Print(); rc = 4; goto cleanup; }
        result[i] = (int)v;
    }
    rc = 0;   // made it through everything — genuine success

cleanup:
    // every path through this function, success or failure, funnels
    // through here, so every Python object I created gets released exactly
    // once, no matter which branch got taken above.
    Py_XDECREF(py_res);
    Py_XDECREF(py_args);   // also releases py_act/py_wgt, since they live inside the tuple
    if (!py_args) { Py_XDECREF(py_act); Py_XDECREF(py_wgt); }   // unless the tuple itself never got built
    return rc;
}


/* ---------------------------------------------------------------------------
 * ref_model_final — shuts the embedded Python interpreter down cleanly.
 * Called once, from mmu_scoreboard.sv's final_phase, at the very end.
 * ------------------------------------------------------------------------- */
void ref_model_final(void)
{
    if (!g_initialized) return;   // nothing to shut down if it was never started

    Py_XDECREF(g_matmul_flat);    // release our cached function handle
    g_matmul_flat = NULL;
    Py_Finalize();                 // shut the entire Python interpreter down
    g_initialized = 0;
}
