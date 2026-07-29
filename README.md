# sv-tpu-core

**A parameterized, formally-verified 4×4 systolic array matrix-multiply unit (int8×int8→int32) implementing the DiP (Diagonal-input, Permuted weight-stationary) dataflow.**

[![Regression](https://img.shields.io/badge/UVM_regression-passing-brightgreen)]()
[![Formal](https://img.shields.io/badge/formal_proofs-3%2F3_proven-brightgreen)]()
[![Latency](https://img.shields.io/badge/latency_contract-locked-brightgreen)]()

Owner: Atharva Kulkarni (verification lead)
Architecture reference: Abdelmaksoud, Agwa & Prodromakis, *"DiP: A Scalable, Energy-Efficient Systolic Array for Matrix Multiplication Acceleration,"* arXiv:2412.09709v3.

---

## Overview

`sv-tpu-core` is a weight-stationary systolic array that computes `C = A × B` for signed int8 operands, accumulating in int32. The array is physically 4×4 (16 PEs) but runtime-parameterized down to any active dimension N = 1–4 via a control register, and structurally parameterizable to larger N×N grids at elaboration time.

The design implements the **DiP dataflow**: rather than trickling activations in one column at a time and draining results through a matched horizontal pipeline, a full row of matrix A is fed into row 0 every active cycle, activations propagate **diagonally** downward through the array, and weights are **permuted** internally — `permuted[row][col] = weights[(row+col) mod N][col]` — so that a numerically correct product falls out of a physically simpler, more scalable interconnect. Upstream logic (and every testbench sequence) still hands the DUT the natural, unpermuted weight matrix; the permutation is entirely internal to `systolic_array.sv` and invisible at the module boundary.

This project went through one full architectural pivot mid-development — the original horizontal-flow design (locked in an early spec) was replaced with DiP once the team evaluated it for scalability — and this README, along with the spec doc it's derived from, documents that pivot rather than hiding it. The latency contract that pivot implied (`active_dim + N + 1` cycles, not the naively-assumed `2N`) was independently re-derived from three separate sources — the controller RTL, its bound SVA, and a dedicated scoreboard checker — before being locked as the project's single source of truth.

## Why this project is a useful verification portfolio piece

This isn't a toy DUT with a rubber-stamped testplan. It's a small design that was deliberately used to exercise the **full width of a modern verification methodology**, end to end:

- **UVM-based dynamic verification** across 6 functional categories (basic correctness, back-to-back sequencing, reset/poison stress, error injection, and latency/throughput), built on a full agent/sequencer/scoreboard/coverage environment.
- **A Register Abstraction Layer (RAL)** model generated against the AXI-Lite control surface, exercised by both built-in UVM RAL sequences and hand-written negative tests.
- **SystemVerilog Assertions (SVA)** bound at both the protocol level (AXI-Lite) and the microarchitecture level (controller FSM, per-PE datapath invariants).
- **Formal property verification** in Cadence JasperGold — not simulation-based "formal-lite," but full unbounded and bounded proofs, including an overflow-impossibility proof and an exhaustive 2×2 functional-equivalence proof against a reference model.
- **A live architecture change managed under verification, not before it** — the DiP rewrite happened after the original testbench and formal proofs existed, and the verification plan had to be re-derived (not just re-run) against the new dataflow: new port semantics, a new latency formula, a corrected protocol property, and a corrected numerical bound all had to be independently re-proven.
- **A documented change-control and reconciliation process** — when two independently-owned checkers (a scoreboard latency checker and a signal-level SVA checker) disagreed about the correct latency contract, that disagreement was tracked explicitly, root-caused to the cycle, and resolved with a single coordinated PR touching every dependent artifact (spec, checker, scoreboard, performance report, README) rather than patched around locally.

If you're evaluating this for a verification role: the interesting engineering here isn't "did the multiply come out right" — it's the discipline around a **live spec-vs-RTL divergence**, the **traceability from formal proof scope to what it does and doesn't claim**, and the **honesty of the documentation trail** when reality departed from the original plan.

---

## Architecture

### Dataflow: DiP (Diagonal-input, Permuted weight-stationary)

| Aspect | Behavior |
|---|---|
| Weight loading | Weights loaded once per computation, held stationary for its duration (unchanged principle from any weight-stationary design). |
| Activation entry | **Row 0 only.** A full row of matrix A (N elements) is fed in parallel to `PE[0][0..N-1]` every active cycle. |
| Activation propagation | Diagonal, not horizontal: for `row > 0`, `PE[row][col].activation_in = PE[row-1][(col+1) mod N].activation_out`. Each hop is one registered pipeline cycle. |
| Weight permutation | `permuted[row][col] = weights[(row+col) mod N][col]`, applied combinationally inside `systolic_array.sv`. Fully internal — the external weight port still takes the natural, unpermuted matrix. |
| Accumulation | Vertical chain, unchanged from a conventional weight-stationary array: `PE[row][col].accum_in = PE[row-1][col].accum_out`, row 0 ties to 0, partial sums drain out the bottom row. |
| Result capture | `deskew_capture.sv` snapshots the array's raw, still-accumulating bottom row into a finished N×N result matrix at the correct per-output-row cycle. |

The per-PE logic (`pe.sv`) required **zero structural changes** to support DiP — it holds exactly three registers (weight, one activation pipeline stage, one accumulator) and has no notion of which physical neighbor feeds it. The entire dataflow rewrite lives in `systolic_array.sv`'s interconnect, which is the cleanest possible boundary for an architecture change of this scope.

### Module map

| Module | Role |
|---|---|
| `mmu_top.sv` | Top-level wrapper; DUT boundary for both UVM and formal. |
| `axi_lite_slave.sv` | AXI-Lite control interface; decodes the three control/status registers. |
| `mmu_controller.sv` | 5-state sequencer FSM (`IDLE → WEIGHT_LOAD → PE_CLEAR → ACTIVATION_FLOW → DONE`) driving the DiP capture window. |
| `systolic_array.sv` | N×N PE grid; owns the diagonal interconnect and weight permutation. |
| `pe.sv` | Single processing element — weight register, activation pipeline register, accumulator. Structurally dataflow-agnostic. |
| `deskew_capture.sv` | Captures the array's raw output-side accumulator row into a finished, correctly-ordered result matrix. |
| `output_buffer.sv` | Holds int32 results combinationally-valid the same cycle `done` asserts, latched for subsequent cycles. |
| `mmu_if.sv` | SystemVerilog interface bundling the DUT/testbench connection. |

### Controller FSM

| State | What happens | Exit condition |
|---|---|---|
| `IDLE` | Idle. | `CTRL_REG.start` written with a legal dimension. |
| `WEIGHT_LOAD` | Weights loaded into PEs (permuted internally), held stationary. | Exactly N cycles. |
| `PE_CLEAR` | `pe_clear` asserted for exactly one cycle; zeros every PE accumulator. | One cycle. |
| `ACTIVATION_FLOW` | Full rows of A flow into row 0 each cycle; `deskew_capture` snapshots each output row as it settles. | Internal counter reaches `active_dim + N`. |
| `DONE` | `STATUS_REG.done` set; results valid in output buffer. | `start` de-asserted / next run begins. |

`pe_clear` remains the single highest-risk control signal in the design: it must fan out to all 16 PEs and assert for **exactly** one cycle, in `PE_CLEAR` only. Any mistiming leaks accumulator state across runs as a silent wrong-answer bug — this is the specific failure mode Category 3 (weight-poison / reset stress) is built to catch.

### Datapath parameters

| Parameter | Value |
|---|---|
| Physical array size | 4×4 PEs (16 total), parameterizable to other N×N at elaboration. |
| Active runtime dimension | 1–4, set via `DIM_REG`. |
| Activation / weight datatype | int8, signed (−128…127). |
| Accumulator datatype | int32, signed. |
| Worst-case MAC product | 128 × 127 = 16,256 (magnitude bound uses int8's full signed range, not just its positive half). |
| Worst-case 4-term accumulation | 4 × 16,256 = 65,024 — well within int32 range; formally proven never to overflow (see Proof 1). |

---

## Latency Contract

Latency is **locked** at:

```
latency (cycles) = active_dim + N + 1
```

equivalently `dim + 5` at the array's physical size N = 4. This value is independently corroborated by three sources that would have no reason to agree by coincidence: the controller RTL's own cycle-counter sizing, the controller-bound SVA property, and direct per-transaction measurement in the scoreboard.

| dim | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| Measured latency (cycles) | 6 | 7 | 8 | 9 |

**Why it isn't `2N`:** an earlier design phase assumed a horizontal-flow pipeline whose natural latency was 2N. Under DiP, `ACTIVATION_FLOW` is sized as `active_dim + N` cycles because output row `r` settles on the bottom accumulator at flow cycle `N + r`, and `deskew_capture`'s one-cycle capture lag means the last row is captured on the final flow cycle — a structurally tight window, not an off-by-one. Forcing a `2N` window would only coincide with correct sizing at `dim = N`; for `dim < N` it truncates the capture window and drops data. `2N` was never re-derivable from the DiP RTL — it was an artifact of the superseded architecture.

Every artifact that depends on this number — the controller sizing, the controller SVA, the signal-level performance checker, the scoreboard's transaction-level latency checker, and the generated performance report — is reconciled against this single formula. There is no remaining disagreement between checkers.

---

## Verification Status

### UVM functional categories

| Category | Scope | Status |
|---|---|---|
| 1 — Basic Functional Correctness | TC-001–TC-010 | ✅ Complete |
| 2 — Back-to-Back Sequencing | TC-011–TC-013 | ✅ Complete |
| 3 — Weight Poison & Reset Stress | Accumulator-leak and poison-pattern stress across consecutive runs | ✅ Complete |
| 4 — Reset Behavior | TC-021, TC-022, TC-034 — mid-computation and boundary reset | ✅ Complete |
| 5 — Illegal Operation / Error Injection | TC-023–TC-026 — illegal `DIM_REG`, premature/double `start` | ✅ Complete |
| 6 — Latency & Throughput Performance | Cycle-accurate latency and back-to-back throughput vs. the locked contract | ✅ Complete |

### RAL and negative testing

- RAL built-in sequences (TC-032, TC-033) — register reset values, read/write access policy.
- TC-035 force-injection series (a–g) — directed error injection against every locked register rule, including the back-to-back throughput SVA (TC-035g) and the zero-activation accumulator invariant (TC-035f).

### SVA coverage

| Property | File | Checks |
|---|---|---|
| A1 — `axi_awvalid_stable` | `axi_lite_sva.sv` | Write-address channel stability once `awvalid` asserts. |
| A2 — `axi_wvalid_with_awvalid` | `axi_lite_sva.sv` | Write-data channel (`wdata`/`wvalid`) stability, checked the same way as A1 — **not** a same-cycle simultaneity requirement with `awvalid`, which AXI-Lite's independent write-address/write-data channels never required. |
| B1–B4 | `mmu_controller_sva.sv` | Controller FSM legality, including B3's result-latency property matching the locked `active_dim + N + 1` formula. |
| C1 — `zero_input_no_accumulate` | `pe_sva.sv` | Per-PE invariant: zero activation input must never perturb the accumulator. Bound to every PE instance. |
| D1 — latency checker | `mmu_perf_checker.sv` | Signal-level assertion of the locked latency formula. |
| D2 — back-to-back throughput | `mmu_perf_checker.sv` | Signal-level assertion on sustained back-to-back computation throughput. |

The scoreboard's transaction-level `latency_checker` (`mmu_scoreboard.sv`) and the signal-level D1/D2 SVA checkers are maintained as intentional defense-in-depth against the same contract — both are kept in sync as a matter of process, not merged into one, so that a regression in either RTL sizing or assertion logic is independently caught.

### Formal verification (Cadence JasperGold)

| Proof | Bound to | Result | Notes |
|---|---|---|---|
| 1 — Accumulator Overflow Impossibility | `pe.sv` | **PROVEN** | Full state space, corrected bound (128×127 worst-case product). Unaffected by the DiP interconnect rewrite since `pe.sv` is structurally unchanged. |
| 2 — AXI-Lite Protocol Compliance | `axi_lite_slave.sv` | **PROVEN** | Includes the corrected A2 property (independent write-address/write-data channel timing, not simultaneity). |
| 3 — 2×2 Functional Correctness | `mmu_top.sv` (DIM_REG = 2) | **PROVEN** | Exhaustive over the 2^64 input space (4 int8 activations + 4 int8 weights). Deliberately latency-agnostic — checks result *value* on whichever cycle `done` asserts, and is valid independent of the latency contract in the section above. |

Formal proofs make no assumption about which inputs a testbench happens to generate; JasperGold exhaustively explores all reachable states and either proves a property universally or returns a counterexample. This is why overflow guarantees, protocol invariants, and small-N functional equivalence are proven formally here rather than only inferred from simulation coverage.

All 3 formal proofs returned PROVEN across an unbounded state-space; true for all input combinations possible within the scope of the design. View the /formal/results folder for detailed information.

---

## Register Interface (AXI-Lite)

| Register | Offset | Direction | Width | Reset | Purpose |
|---|---|---|---|---|---|
| `DIM_REG` | `0x0` | R/W | 3-bit | `0x0` | Matrix dimension N (1–4) for the next computation. |
| `CTRL_REG` | `0x4` | R/W | 1-bit | `0x0` | Bit 0 = `start`. Triggers weight load then activation flow. |
| `STATUS_REG` | `0x8` | RO | 1-bit | `0x0` | Bit 0 = `done`. Poll before reading the output buffer. |

**Locked rules:**
- `STATUS_REG` is strictly read-only; a write must not change its value (formally proven, Proof 2).
- `DIM_REG` only accepts N in 1–4; 0 and 5–7 are illegal stimulus exercised by Category 5.
- Writing `start = 1` while the FSM is not `IDLE` is illegal (premature/double start); the design produces no spurious output.
- `done` reads 1 only when the output buffer genuinely holds valid results.
- All three registers reset to 0.

---

## Repository Layout

```
rtl/
  mmu_top.sv
  axi_lite_slave.sv
  mmu_controller.sv
  systolic_array.sv
  pe.sv
  deskew_capture.sv
  output_buffer.sv
  mmu_if.sv
sva/
  axi_lite_sva.sv
  mmu_controller_sva.sv
  pe_sva.sv
perf/
  mmu_perf_checker.sv
tb/
  mmu_cat1_tests.sv
  mmu_cat2_tests.sv
  mmu_cat3_tests.sv
  mmu_cat4_tests.sv
  mmu_cat5_tests.sv
  mmu_cat6_tests.sv
  mmu_ral_and_negative_tests.sv
  mmu_sequences.sv
  mmu_scoreboard.sv
formal/
  pe_formal.sv
  pe_overflow.tcl
  axi_formal.sv
  axi_compliance.tcl
  mmu_formal.sv
  twobytwo_correct.tcl
  results/
docs/
  SpecDoc.pdf
  perf_report.md
```

## Running Verification

```bash
# UVM regression (all categories)
make regress

# Single category
make regress CATEGORY=cat6

# Formal proofs (JasperGold only — never Xcelium for the formal/ directory)
make formal PROOF=pe_overflow
make formal PROOF=axi_compliance
make formal PROOF=twobytwo_correct
```

---

## Glossary

| Term | Meaning |
|---|---|
| Systolic array | Grid of small multiply-add units passing data to neighbors each cycle instead of round-tripping to memory. |
| PE | Processing element — one grid cell, one multiply-accumulate per cycle. |
| Weight-stationary | Weights load once and stay fixed; activations flow past them. |
| DiP | Diagonal-input, Permuted weight-stationary — this project's dataflow. Row 0 fed externally each cycle; data moves diagonally; weights permuted by `(row+col) mod N` before loading. |
| MAC | Multiply-accumulate: `total = total + (a × b)`. |
| RAL | Register Abstraction Layer — lets UVM tests address registers by name instead of raw bus transactions. |
| FSM | Finite State Machine — here, the controller stepping `IDLE → … → DONE`. |
| SVA | SystemVerilog Assertions — properties checked every cycle during simulation. |
| DUT | Design Under Test — `mmu_top.sv`. |
