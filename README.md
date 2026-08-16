# sv-tpu-core

**A parameterized, formally-verified 4×4 systolic array matrix-multiply unit (int8×int8→int32) implementing the DiP (Diagonal-input, Permuted weight-stationary) dataflow.**

[![Regression](https://img.shields.io/badge/UVM_regression-passing-brightgreen)]()
[![Formal](https://img.shields.io/badge/formal_proofs-3%2F3_proven-brightgreen)]()
[![Latency](https://img.shields.io/badge/latency_contract-locked-brightgreen)]()

Owner: Atharva Kulkarni (verification lead), Jad Kahla (RTL and Verification Engineer), and Samarth Gupta

Architecture reference: Abdelmaksoud, Agwa & Prodromakis, *"DiP: A Scalable, Energy-Efficient Systolic Array for Matrix Multiplication Acceleration,"* arXiv:2412.09709v3.

---

## Overview

`sv-tpu-core` is a weight-stationary systolic array that computes `C = A × B` for signed int8 operands, accumulating in int32. The array is physically 4×4 (16 PEs) but runtime-parameterized down to any active dimension N = 1–4 via a control register, and structurally parameterizable to larger N×N grids at elaboration time.

The design implements the **DiP dataflow**: rather than trickling activations in one column at a time and draining results through a matched horizontal pipeline, a full row of matrix A is fed into row 0 every active cycle, activations propagate **diagonally** downward through the array, and weights are **permuted** internally — `permuted[row][col] = weights[(row+col) mod N][col]` — so that a numerically correct product falls out of a physically simpler, more scalable interconnect. Upstream logic (and every testbench sequence) still hands the DUT the natural, unpermuted weight matrix; the permutation is entirely internal to `systolic_array.sv` and invisible at the module boundary.

This project went through one full architectural pivot mid-development — the original horizontal-flow design (locked in an early spec) was replaced with DiP once the team evaluated it for scalability — and this README, along with the spec doc it's derived from, documents that pivot rather than hiding it. The latency contract implied by that pivot went through two candidate formulas (`2N`, then `active_dim + N + 1`) before the team measured the as-built RTL directly against N = 1–4 and ratified the actual contract: **`active_dim + 5` cycles**, independently confirmed across the controller RTL, its bound SVA, and the UVM latency checker, and locked as the project's single source of truth (see "Latency Contract" below).

## Why this project is a useful verification portfolio piece

This isn't a toy DUT with a rubber-stamped testplan. It's a small design that was deliberately used to exercise the **full width of a modern verification methodology**, end to end:

- **UVM-based dynamic verification** across seven functional categories (basic correctness, back-to-back sequencing, reset/poison stress, error injection, latency/throughput, and dimension-swept coverage closure), built on a full agent/sequencer/scoreboard/coverage environment.
- **A Register Abstraction Layer (RAL)** model generated against the AXI-Lite control surface, exercised by both built-in UVM RAL sequences and hand-written negative tests.
- **SystemVerilog Assertions (SVA)** bound at both the protocol level (AXI-Lite) and the microarchitecture level (controller FSM, per-PE datapath invariants).
- **Formal property verification** in Cadence JasperGold — not simulation-based "formal-lite," but full unbounded and bounded proofs, including an overflow-impossibility proof and an exhaustive 2×2 functional-equivalence proof against a reference model.
- **A live architecture change managed under verification, not before it** — the DiP rewrite happened after the original testbench and formal proofs existed, and the verification plan had to be re-derived (not just re-run) against the new dataflow: new port semantics, a new latency formula, a corrected protocol property, and a corrected numerical bound all had to be independently re-proven.
- **A documented change-control and reconciliation process** — when two independently-owned checkers disagreed about the correct latency contract, that disagreement was tracked explicitly, root-caused to the cycle, and resolved with a single coordinated change touching every dependent artifact (spec, checkers, scoreboard, performance report, README) rather than patched around locally.

If you're evaluating this for a verification role: the interesting engineering here isn't "did the multiply come out right" — it's the discipline around a **live spec-vs-RTL divergence**, the **traceability from formal proof scope to what it does and doesn't claim**, and the **honesty of the documentation trail** when reality departed from the original plan.

---

## Architecture

### Dataflow: DiP (Diagonal-input, Permuted weight-stationary)

| Aspect | Behavior |
|---|---|
| Weight loading | Weights loaded once per computation, held stationary for its duration. |
| Activation entry | **Row 0 only.** A full row of matrix A (N elements) is fed in parallel to `PE[0][0..N-1]` every active cycle. |
| Activation propagation | Diagonal: for `row > 0`, `PE[row][col].activation_in = PE[row-1][(col+1) mod N].activation_out`. Each hop is one registered pipeline cycle. |
| Weight permutation | `permuted[row][col] = weights[(row+col) mod N][col]`, applied combinationally inside `systolic_array.sv`. The external weight port takes the natural, unpermuted matrix. |
| Accumulation | Vertical chain: `PE[row][col].accum_in = PE[row-1][col].accum_out`; row 0 ties to 0; partial sums drain out the bottom row. |
| Result capture | `deskew_capture.sv` snapshots the array's raw, still-accumulating bottom row into a finished N×N result matrix at the correct per-output-row cycle. |

The per-PE logic (`pe.sv`) required **zero structural changes** to support DiP — it holds exactly three registers (weight, one activation pipeline stage, one accumulator) and has no notion of which physical neighbor feeds it. The entire dataflow rewrite lives in `systolic_array.sv`'s interconnect.

### Module map

| Module | Role |
|---|---|
| `rtl/mmu_top.sv` | Top-level wrapper; DUT boundary for both UVM and formal. |
| `rtl/axi_lite_slave.sv` | AXI-Lite control interface; decodes the three control/status registers. |
| `rtl/mmu_controller.sv` | 5-state sequencer FSM driving the DiP capture window; exposes `fsm_state` for reset-state coverage. |
| `rtl/systolic_array.sv` | N×N PE grid; owns the diagonal interconnect and weight permutation. |
| `rtl/pe.sv` | Single processing element — weight register, activation pipeline register, accumulator. |
| `rtl/deskew_capture.sv` | Captures the array's output-side accumulator row into a finished, correctly-ordered result matrix. |
| `rtl/output_buffer.sv` | Holds int32 results, combinationally valid the same cycle `done` asserts, latched for subsequent cycles. |
| `rtl/skew_buffer.sv` | **Present but not instantiated** — its input-side staggering role is subsumed by DiP's diagonal interconnect. |
| `tb/mmu_if.sv` | SystemVerilog interface bundling the DUT/testbench connection (carries the `fsm_state` tap). |

### Controller FSM

| State | What happens | Exit condition |
|---|---|---|
| `IDLE` | Idle. | `CTRL_REG.start` written with a legal dimension. |
| `WEIGHT_LOAD` | Weights loaded into PEs (permuted internally), held stationary. | Exactly N cycles. |
| `PE_CLEAR` | `pe_clear` asserted for exactly one cycle; zeros every PE accumulator. | One cycle. |
| `ACTIVATION_FLOW` | Full rows of A flow into row 0 each cycle; `deskew_capture` snapshots each output row as it settles. | Internal counter reaches `active_dim + N`. |
| `DONE` | `STATUS_REG.done` set; results valid in output buffer. | `start` de-asserted / next run begins. |

`pe_clear` remains the single highest-risk control signal: it must fan out to all 16 PEs and assert for **exactly** one cycle, in `PE_CLEAR` only. Any mistiming leaks accumulator state across runs as a silent wrong-answer bug — the failure mode Category 3 (weight-poison / reset stress) is built to catch.

### Datapath parameters

| Parameter | Value |
|---|---|
| Physical array size | 4×4 PEs (16 total), parameterizable to other N×N at elaboration. |
| Active runtime dimension | 1–4, set via `DIM_REG`. |
| Activation / weight datatype | int8, signed (−128…127). |
| Accumulator datatype | int32, signed. |
| Worst-case MAC product | 128 × 127 = 16,256 (magnitude bound uses int8's full signed range). |
| Worst-case 4-term accumulation | 65,024 — well within int32; formally proven never to overflow (Proof 1). |

---

## Latency Contract

**RATIFIED 2026-07-30.** Latency is **locked** at:

```
latency (cycles) = active_dim + 5
```

measured, at the array's built physical size N = 4, for every legal `active_dim` (1..4). This superseded two earlier candidates: `2N` (an unverified early-design assumption) and `active_dim + N + 1` (a plausible re-derivation never measured against the RTL). The team ran the design for `active_dim` = 1 through 4 and confirmed the true, as-built latency is `active_dim + 5` in every case.

| dim | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| Ratified latency (cycles) | 6 | 7 | 8 | 9 |

**This formula is specific to the N = 4 build verified here, not parametric in `N`.** The `+5` reflects this build's pipeline depth (weight-load/PE-clear sequencing, array fill, and `deskew_capture`'s one-cycle capture lag). If the design is elaborated at a different physical `N`, re-measurement (or a first-principles re-derivation) is required.

Every artifact that depends on this number — the controller RTL comments, the controller SVA (B3), the signal-level performance checker (`perf/mmu_perf_checker.sv`, D1), and the UVM transaction-level latency checker (`uvm/mmu_cat6_tests.sv`, `mmu_latency_checker`) — is reconciled against this single formula. The scoreboard measures latency into `data_txn.latency` but does not assert on it; the assertion lives in the two checkers above, kept in sync as defense-in-depth. There is no remaining disagreement between checkers. `perf/mmu_perf_checker.sv` defaults to `dim+5`; a `+LAT_SPEC_2N` plusarg can produce the retired `2N` on demand (expected to fail; not part of the regression). See `docs/perf_report.md` and BUGS.md Bug 7.

---

## Verification Status

### UVM functional categories

| Category | Scope | Status |
|---|---|---|
| 1 — Basic Functional Correctness | TC-001–010 | ✅ Complete |
| 2 — Back-to-Back Sequencing | TC-011–013 | ✅ Complete |
| 3 — Weight Poison & Reset Stress | TC-014–020 | ✅ Complete |
| 4 — Reset Behavior | TC-021/022/034 | ✅ Complete |
| 5 — Illegal Operation / Error Injection | TC-023–026 | ✅ Complete |
| 6 — Latency & Throughput Performance | TC-027–031 (vs. `dim+5`) | ✅ Complete |
| 7 — Dimension-Swept Pattern Coverage Closure | TC-038–049 | ✅ Complete |

### RAL and negative testing

- RAL built-in sequences (TC-032, TC-033) — register reset values, read/write access policy.
- TC-035 force-injection series (a–g) — directed error injection against every locked register rule, including the back-to-back throughput SVA (TC-035g) and the zero-activation accumulator invariant (TC-035f).

### SVA coverage

| Property | File | Checks |
|---|---|---|
| A1 — `axi_awvalid_stable` | `sva/axi_lite_sva.sv` | Write-address channel stability once `awvalid` asserts. |
| A2 — `axi_wvalid_stable` | `sva/axi_lite_sva.sv` | Write-data channel (`wvalid`/`wdata`) stability until `wready` — **not** a same-cycle simultaneity requirement with `awvalid`. |
| B1–B4 | `sva/mmu_controller_sva.sv` | Controller FSM legality, including B3's latency property matching the ratified `active_dim + 5`. |
| C1 — `zero_input_no_accumulate` | `sva/pe_sva.sv` | Per-PE invariant: zero activation must never perturb the accumulator. Bound to every PE instance. |
| D1 — latency checker | `perf/mmu_perf_checker.sv` | Signal-level assertion of the `active_dim + 5` contract. |
| D2 — back-to-back throughput | `perf/mmu_perf_checker.sv` | Signal-level assertion on sustained back-to-back throughput. |

### Formal verification (Cadence JasperGold)

| Proof | Bound to | Result | Notes |
|---|---|---|---|
| 1 — Accumulator Overflow Impossibility | `pe.sv` | **PROVEN** (4/4) | Full state space, corrected bound (128×127). Unaffected by the DiP rewrite since `pe.sv` is structurally unchanged. |
| 2 — AXI-Lite Protocol Compliance | `axi_lite_slave.sv` | **PROVEN** (4/4) | Includes the corrected A2 property (channel-independent stability). |
| 3 — 2×2 Functional Correctness | `mmu_top.sv` (DIM_REG = 2) | **PROVEN** (13 assertions / 21 covers) | Exhaustive over the 2^64 input space. Latency-agnostic — checks result *value* on whichever cycle `done` asserts. |

All 3 formal proofs returned PROVEN. See `formal/results/` for detailed reports.

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
- Writing `start = 1` while the FSM is not `IDLE` is illegal (premature/double start); no spurious output.
- `done` reads 1 only when the output buffer genuinely holds valid results.
- All three registers reset to 0.

---

## Repository Layout

```
rtl/
  mmu_top.sv           axi_lite_slave.sv    mmu_controller.sv
  systolic_array.sv    pe.sv                deskew_capture.sv
  output_buffer.sv     skew_buffer.sv (present, not instantiated)
sva/
  axi_lite_sva.sv      mmu_controller_sva.sv    pe_sva.sv
perf/
  mmu_perf_checker.sv  perf_sequences.sv
uvm/
  mmu_cat1_tests.sv .. mmu_cat7_tests.sv
  mmu_ral_and_negative_tests.sv
  mmu_sequences.sv     mmu_base_test.sv     mmu_env.sv
  mmu_scoreboard.sv    mmu_coverage.sv
  axi_agent.sv         data_agent.sv
  mmu_reg_model.sv     mmu_reg_adapter.sv
tb/
  tb_top.sv            mmu_if.sv            pe_smoke_tb.sv
  ref_model.py         mmu_dpi_bridge.c
formal/
  pe_formal.sv         pe_overflow.tcl
  axi_formal.sv        axi_compliance.tcl
  mmu_formal.sv        twobytwo_correct.tcl
  results/
docs/
  sv-tpu-core_SpecDoc_REV3.md
  FULL_UVMVerification_PLAN_REV2.md
  perf_report.md
scripts/
  cov_check.py
Makefile   run.f   BUGS.md   setup_env.sh
```

## Running Verification

Simulation (Xcelium):

```bash
# Full regression: every category back-to-back, then coverage merge + check
make regress

# A single category (cat1..cat7), or the RAL/negative group
make run-cat6
make run-ral

# A single test by UVM test name
make run TEST=tc_030_latency_n4_test

# Coverage
make cov-summary      # per-test [MMU_COV] lines
make cov-check        # merged cumulative coverage vs threshold
```

Formal (Cadence JasperGold only — never Xcelium for the `formal/` directory). There is no `make` target for formal; run the tcl scripts in JasperGold:

```bash
jg -batch formal/pe_overflow.tcl        # Proof 1 — overflow impossibility
jg -batch formal/axi_compliance.tcl     # Proof 2 — AXI-Lite compliance
jg -batch formal/twobytwo_correct.tcl   # Proof 3 — 2×2 functional correctness
```

---

## Glossary

| Term | Meaning |
|---|---|
| Systolic array | Grid of small multiply-add units passing data to neighbors each cycle instead of round-tripping to memory. |
| PE | Processing element — one grid cell, one multiply-accumulate per cycle. |
| Weight-stationary | Weights load once and stay fixed; activations flow past them. |
| DiP | Diagonal-input, Permuted weight-stationary — this project's dataflow. |
| MAC | Multiply-accumulate: `total = total + (a × b)`. |
| RAL | Register Abstraction Layer — lets UVM tests address registers by name instead of raw bus transactions. |
| FSM | Finite State Machine — here, the controller stepping `IDLE → … → DONE`. |
| SVA | SystemVerilog Assertions — properties checked every cycle during simulation. |
| DUT | Design Under Test — `mmu_top.sv`. |
