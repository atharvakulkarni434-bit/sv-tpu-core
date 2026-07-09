"""
ref_model.py — Golden reference model for sv-tpu-core

The single source of truth for the UVM scoreboard (mmu_scoreboard.sv).
Computes an NxN weight-stationary matrix multiply in int8 x int8 -> int32,
matching the arithmetic of the RTL exactly:

    C[row][col] = sum over k of ( A[row][k] * B[k][col] )

where A is the activation matrix, B is the weight matrix, inputs are signed
int8 (-128..127), and the accumulator is signed int32. No saturation, no
rounding — the spec (A.2, Part D Proof 1) guarantees the int32 accumulator
never overflows for N <= 4, so plain integer arithmetic is exact.

Usage from the scoreboard side (via DPI or a file/socket bridge, whichever
the team picks at integration):

    from ref_model import matmul_int8, DIM_MAX
    expected = matmul_int8(activations, weights, n)

Everything here is pure Python + numpy. No RTL assumptions beyond the spec.
"""

from __future__ import annotations
import numpy as np


# ── constants locked by the spec (A.2 / A.3) ────────────────────────────────
INT8_MIN = -128
INT8_MAX = 127
INT32_MIN = -(2 ** 31)
INT32_MAX = (2 ** 31) - 1
DIM_MAX = 4          # physical array is 4x4; DIM_REG selects active N (1..4)


# ── input validation ─────────────────────────────────────────────────────────
def _check_int8(mat: np.ndarray, name: str) -> None:
    """Every element must be a legal signed int8. Catches TB bugs early."""
    if mat.dtype != np.int64 and not np.issubdtype(mat.dtype, np.integer):
        raise TypeError(f"{name} must be an integer array, got dtype {mat.dtype}")
    if mat.min() < INT8_MIN or mat.max() > INT8_MAX:
        raise ValueError(
            f"{name} has a value outside int8 range [{INT8_MIN}, {INT8_MAX}]: "
            f"min={mat.min()}, max={mat.max()}"
        )


def _check_square(mat: np.ndarray, n: int, name: str) -> None:
    if mat.shape != (n, n):
        raise ValueError(f"{name} must be shape ({n}, {n}), got {mat.shape}")


# ── the golden model ─────────────────────────────────────────────────────────
def matmul_int8(activations, weights, n: int) -> np.ndarray:
    """
    Compute the NxN int8 x int8 -> int32 matrix multiply.

    Parameters
    ----------
    activations : array-like, shape (n, n)
        The activation matrix A. Row r flows into row r of the array.
        Each element is a signed int8.
    weights : array-like, shape (n, n)
        The weight matrix B, held stationary in the PEs.
        Each element is a signed int8.
    n : int
        Active dimension from DIM_REG. Must be 1..DIM_MAX.

    Returns
    -------
    np.ndarray, shape (n, n), dtype int64 (values fit in int32)
        The result matrix C, where C[r][c] = sum_k A[r][k] * B[k][c].

    Raises
    ------
    ValueError / TypeError on any spec violation (illegal N, wrong shape,
    out-of-range element, or — should never happen for N<=4 — int32 overflow).
    """
    if not (1 <= n <= DIM_MAX):
        raise ValueError(f"n (DIM_REG) must be in 1..{DIM_MAX}, got {n}")

    # int64 accumulation internally so we can *detect* an int32 overflow rather
    # than silently wrap. For N<=4 with int8 inputs this never trips, but the
    # check documents the contract and guards an 8x8 future build.
    A = np.asarray(activations, dtype=np.int64)
    B = np.asarray(weights, dtype=np.int64)

    _check_square(A, n, "activations")
    _check_square(B, n, "weights")
    _check_int8(A, "activations")
    _check_int8(B, "weights")

    C = A @ B  # exact integer matmul, shape (n, n), dtype int64

    if C.min() < INT32_MIN or C.max() > INT32_MAX:
        # Per Proof 1 this is mathematically impossible for N<=4; if it ever
        # fires, either N was too large or an input escaped the int8 check.
        raise OverflowError(
            f"accumulator exceeded int32 range: min={C.min()}, max={C.max()}. "
            f"This should be impossible for N<={DIM_MAX} with int8 inputs."
        )
    return C


# ── convenience wrappers the scoreboard may prefer ──────────────────────────
def matmul_flat(activations_flat, weights_flat, n: int) -> list[int]:
    """
    Same computation but flat-in / flat-out, row-major — convenient when the
    scoreboard passes and receives 1-D arrays over a DPI/file bridge.

    activations_flat, weights_flat : length n*n, row-major.
    Returns a length n*n row-major list of int results.
    """
    A = np.asarray(activations_flat, dtype=np.int64).reshape(n, n)
    B = np.asarray(weights_flat, dtype=np.int64).reshape(n, n)
    C = matmul_int8(A, B, n)
    return C.flatten().tolist()


def expected_latency(n: int) -> int:
    """
    The 2N cycle contract (spec C.6, pipelined PE). Provided here so the
    scoreboard's latency_checker and the golden model agree on one formula.
    """
    if not (1 <= n <= DIM_MAX):
        raise ValueError(f"n must be in 1..{DIM_MAX}, got {n}")
    return 2 * n


# ── self-test / hand-verification against the spec's 2x2 example ────────────
def _selftest() -> None:
    # 1) Hand-computed 2x2, matches what you'd verify manually on paper.
    #    A = [[1, 2], [3, 4]]   B = [[5, 6], [7, 8]]
    #    C[0][0] = 1*5 + 2*7 = 19     C[0][1] = 1*6 + 2*8 = 22
    #    C[1][0] = 3*5 + 4*7 = 43     C[1][1] = 3*6 + 4*8 = 50
    A = np.array([[1, 2], [3, 4]], dtype=np.int64)
    B = np.array([[5, 6], [7, 8]], dtype=np.int64)
    expected = np.array([[19, 22], [43, 50]], dtype=np.int64)
    got = matmul_int8(A, B, 2)
    assert np.array_equal(got, expected), f"2x2 hand check failed: {got}"

    # 2) Identity weight -> result equals activations (weight_poison_seq case).
    A = np.array([[7, -3, 42, -100],
                  [1, 2, 3, 4],
                  [-5, -6, -7, -8],
                  [10, 20, 30, 40]], dtype=np.int64)
    I = np.eye(4, dtype=np.int64)
    assert np.array_equal(matmul_int8(A, I, 4), A), "identity check failed"

    # 3) All-zero weight -> zero result (weight_poison_seq case).
    Z = np.zeros((4, 4), dtype=np.int64)
    assert np.array_equal(matmul_int8(A, Z, 4), Z), "all-zero check failed"

    # 4) Worst-case magnitude stays within int32 (Proof 1 sanity).
    hi = np.full((4, 4), 127, dtype=np.int64)
    lo = np.full((4, 4), -128, dtype=np.int64)
    worst = matmul_int8(lo, hi, 4)  # 4 * (-128 * 127) = -65024 per element
    assert worst.min() == 4 * (-128 * 127), f"worst-case wrong: {worst.min()}"
    assert worst.min() >= INT32_MIN, "worst case underflowed int32"

    # 5) Latency formula.
    assert [expected_latency(n) for n in range(1, 5)] == [2, 4, 6, 8]

    # 6) Illegal inputs are rejected.
    for bad in (0, 5):
        try:
            matmul_int8(np.zeros((2, 2), np.int64), np.zeros((2, 2), np.int64), bad)
            assert False, f"n={bad} should have raised"
        except ValueError:
            pass
    try:
        matmul_int8(np.array([[200]], np.int64), np.array([[1]], np.int64), 1)
        assert False, "out-of-range int8 should have raised"
    except ValueError:
        pass

    print("ref_model.py — all self-tests passed.")


if __name__ == "__main__":
    _selftest()