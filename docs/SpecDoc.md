# sv-tpu-core — Specification Document, REV 3 (As-Built, Complete)

**Systolic Array Matrix-Multiply Unit — 4×4 physical, DiP dataflow, weight-stationary, int8×int8→int32**

Owner: Atharva Kulkarni (verification lead) · Contributors: Jad Kahla, Samarth Gupta
Revision date: 2026-08-03 · Supersedes: SpecDoc REV 2 (2026-07-29), SpecDoc v1.0 (Phase 1, Jul 1–8 2026)
Architecture reference: Abdelmaksoud, Agwa & Prodromakis, *"DiP: A Scalable, Energy-Efficient Systolic Array for Matrix Multiplication Acceleration,"* arXiv:2412.09709v3.

---

## 0. How to read this document

Four parts, same skeleton as REV 2 and v1.0:

- **Part A — Design Spec:** dimensions, dataflow, and timing of the hardware as built.
- **Part B — Register (RAL) Spec:** the three control registers.
- **Part C — Performance Spec:** the ratified latency contract and measured throughput.
- **Part D — Formal Verification Spec:** the three JasperGold proofs and their status.

### 0.1 Status legend

| Marker | Meaning |
|---|---|
| DONE | Implemented, exercised in regression, matches this document. |
| NEW | Added after REV 2; part of the completed design. |
| RATIFIED | A formerly-open decision that has been made and locked. |
| REMOVED | Physically present in the repo but no longer part of the design. |

### 0.2 Completion status (all REV 2 open items closed)

| Item | Status | Detail |
|---|---|---|
| UVM Cat 1 — Basic Functional Correctness | DONE | `mmu_cat1_tests.sv`, TC-001–010. |
| UVM Cat 2 — Back-to-Back Sequencing | DONE | `mmu_cat2_tests.sv`, TC-011–013. |
| UVM Cat 3 — Weight Poison & Reset Stress | DONE | `mmu_cat3_tests.sv`, TC-014–020. *(was IN PROGRESS)* |
| UVM Cat 4 — Reset Behavior | DONE | `mmu_cat4_tests.sv`, TC-021/022/034. *(was IN PROGRESS)* |
| UVM Cat 5 — Illegal Operation / Error Injection | DONE | `mmu_cat5_tests.sv`, TC-023–026. |
| UVM Cat 6 — Latency & Throughput | DONE | `mmu_cat6_tests.sv`, TC-027–031, asserts the ratified `dim+5`. *(contract was OPEN)* |
| UVM Cat 7 — Dimension-Swept Pattern Coverage Closure | NEW / DONE | `mmu_cat7_tests.sv`, TC-038–049. |
| RAL Built-In (TC-032, TC-033) | DONE | `mmu_ral_and_negative_tests.sv`. |
| TC-035 Force-Injection Series a–g | DONE | Including TC-035g (D2 target) and TC-035f (C1 target). *(g was "no target")* |
| A1 — `axi_awvalid_stable` | DONE | `awvalid && !awready ⊢ awvalid && $stable(awaddr)`. |
| A2 — `axi_wvalid_stable` | DONE | Corrected: channel-independent stability, not simultaneity (D.2). |
| B1–B4 (`mmu_controller_sva.sv`) | DONE | B3 asserts the ratified `active_dim + 5`. |
| C1 — `zero_input_no_accumulate` (`pe_sva.sv`) | DONE | Bound per-PE (16 instances at N=4). *(was NOT STARTED)* |
| D1 / D2 (`mmu_perf_checker.sv`) | DONE | D1 latency defaults to `dim+5`; D2 throughput implemented. *(D1 was stale-2N; D2 unwritten)* |
| Formal Proof 1 — Overflow | DONE — PROVEN | 4/4 assertions proven. |
| Formal Proof 2 — AXI Compliance | DONE — PROVEN | 4/4 assertions proven (corrected A2). |
| Formal Proof 3 — 2×2 Functional | DONE — PROVEN | 13/13 assertions, 21/21 covers; exhaustive over 2^64; latency-agnostic. |

---

## Part A — Design Spec (as built)

### A.1 What the design does

Computes `C = A × B` for signed int8 operands, accumulating in int32. It is a systolic array: a grid of small multiply-accumulate cells (PEs) passing data to neighbors each cycle. Weights load once and stay stationary; what DiP changes is how activations move and how results are read back (A.2, A.5).

### A.2 Architecture: DiP (Diagonal-Input, Permuted weight-stationary)

Implemented in `rtl/pe.sv` and `rtl/systolic_array.sv`, per arXiv:2412.09709v3 §III-A/III-B. Concretely, as wired in `systolic_array.sv`:

- **Row 0 is the only external entry point.** A full row of A (all N elements) is fed in parallel to `PE[0][0..N-1]` every active cycle.
- **Diagonal downward propagation.** For `row > 0`: `PE[row][col].activation_in = PE[row-1][(col+1) mod N].activation_out`. Each hop is one registered pipeline cycle.
- **Weight permutation (DiP Algorithm 1).** `permuted[row][col] = weights[(row+col) mod N][col]`, applied combinationally inside `systolic_array.sv`. Upstream logic and every testbench sequence continue to hand the module the natural, unpermuted matrix — permutation is entirely internal.
- **Vertical accumulator chain, unchanged.** `PE[row][col].accum_in = PE[row-1][col].accum_out`; row 0's `accum_in` ties to 0; partial sums drain out the bottom row.

`pe.sv` needed **zero structural changes** for DiP — it still holds exactly three registers (weight, one activation pipeline stage, one accumulator) and has no notion of which physical neighbor feeds it. The entire dataflow change lives in `systolic_array.sv`'s interconnect.

### A.3 Locked design decisions

| Decision | Value | Status |
|---|---|---|
| Architecture | Weight-stationary systolic array, DiP diagonal dataflow | Locked (pivoted from v1.0 horizontal flow) |
| Physical array size | 4×4 PEs (16), parameterizable to N×N at elaboration | Unchanged |
| Active runtime dimension | `DIM_REG` selects N = 1–4 | Unchanged |
| Activation / weight type | int8 signed (−128…127) | Unchanged |
| Accumulator type | int32 signed | Unchanged (see A.10) |
| Control interface | AXI-Lite slave, 3 registers | Unchanged |
| `skew_buffer.sv` | REMOVED from instantiation | Replaced by `deskew_capture.sv` (A.4) |

### A.4 Module list and boundaries

DUT boundary is `mmu_top.sv`.

| Module | Role | Status |
|---|---|---|
| `mmu_top.sv` | Top wrapper; DUT boundary for UVM and formal. | Instance list updated |
| `axi_lite_slave.sv` | Decodes the three AXI-Lite registers (Part B). | Unchanged |
| `mmu_controller.sv` | 5-state sequencer FSM; sizes the DiP capture window; exposes `fsm_state`. | Timing + observability |
| `systolic_array.sv` | N×N PE grid; diagonal interconnect + internal weight permutation. | Rewired for DiP |
| `pe.sv` | One PE — weight reg, activation pipeline reg, accumulator. | Unchanged internally |
| `deskew_capture.sv` | Snapshots the array's raw bottom accumulator row into a finished N×N result at the correct per-row cycle. | NEW — replaces `skew_buffer.sv` |
| `output_buffer.sv` | Holds int32 results; combinationally valid the same cycle `done` asserts, latched thereafter. | Bug fix applied |
| `skew_buffer.sv` | Formerly staggered activations pre-array (v1.0). | REMOVED — file present, not instantiated |
| `mmu_if.sv` | SV interface bundle connecting DUT to testbench (carries `fsm_state` tap). | Updated |

**`output_buffer.sv` note (carried from REV 2):** an earlier version gated its capture register directly on the registered `done`, adding a spurious extra cycle of latency on top of `deskew_capture`'s already-correct timing. Fixed by splitting into a combinational passthrough (valid the same cycle `done` is high) plus a held register for subsequent cycles.

### A.5 Controller FSM and capture timing

Five states, unchanged. `ACTIVATION_FLOW` duration and `DONE` trigger are sized for DiP's capture timing.

| State | What happens | Leaves when |
|---|---|---|
| IDLE | Idle. | `CTRL_REG.start` written (=1) with a legal dimension. |
| WEIGHT_LOAD | Weights loaded (permuted internally), held stationary. | After exactly N cycles (`WEIGHT_LOAD_CYCLES = N`). |
| PE_CLEAR | `pe_clear` asserted for exactly one cycle; zeros every PE accumulator. | After one cycle. |
| ACTIVATION_FLOW | Full rows of A flow into row 0 each cycle; `deskew_capture` snapshots each output row as it settles. | Internal counter `cnt` reaches `flow_last = active_dim + N`. |
| DONE | `STATUS_REG.done` set; results valid in output buffer. | `start` de-asserted / next run begins. |

As-built sizing (`mmu_controller.sv`): `flow_last = dim_q + N`; `cnt` runs `0..flow_last` inclusive; `DONE` is one register stage later. Combined with `deskew_capture`'s per-row capture (below), this produces the ratified **`active_dim + 5`** flow-en-to-done latency at the N = 4 build (Part C).

### A.6 `pe_clear` — highest-risk control signal

Unchanged: `pe_clear` must assert for **exactly one cycle**, only in `PE_CLEAR`, fanned to all 16 PEs. Any mistiming leaks accumulator state across runs as a silent wrong-answer bug — the failure mode Category 3 (weight-poison / reset stress) is built to catch, now complete.

### A.7 Capture timing detail (`deskew_capture.sv`)

Output row `r` settles into the bottom accumulator row at `flow_cycle == N + r` (relative to the first `flow_en` cycle); the capture counter's one-cycle offset accounts for the activation-feed pipeline delay. `deskew_capture` snapshots `accum_bottom_row` into `result_matrix[r][*]` at that cycle, gated to `target_row < dim_n` so inactive rows never capture. This per-row settling math, plus the controller's `flow_last = dim+N` sizing and the one-cycle `DONE` register stage, is exactly what yields the module-level `active_dim + 5` contract.

### A.8 Definition of done (design)

- A started computation drives IDLE → WEIGHT_LOAD → PE_CLEAR → ACTIVATION_FLOW → DONE without stalling.
- `pe_clear` asserts for exactly one cycle in `PE_CLEAR` and zeros all accumulators.
- For any N = 1–4, the output buffer holds the correct int32 `C = A×B` (permutation and diagonal routing are internal; the external contract A in / B in / C out is unchanged).
- `STATUS_REG.done` reads 1 only when results are valid.
- Back-to-back computations produce correct results with no accumulator leakage, and a mid-computation reset returns the FSM to IDLE cleanly — **now verified** by Categories 3 and 4 (complete).

### A.9 Signal map — `systolic_array.sv` (DiP row-based interface)

| Port | Dir | Width | Meaning |
|---|---|---|---|
| `activations` | in | N×8 | One full row of A, fed to row 0 in parallel every active cycle. |
| `weights` | in | N×N×8 | Natural (unpermuted) weight matrix; permutation `(row+col) mod N` applied internally. |
| `load_weight` | in | 1 | Fanned to all PEs. |
| `pe_clear` | in | 1 | Fanned to all PEs. |
| `flow_en` | in | 1 | Gates the row-0 external entry each cycle. |
| `accum_bottom_row` | out | N×32 | Raw, still-accumulating bottom accumulator row; `deskew_capture.sv` turns this into the finished result. |

`pe.sv`, `mmu_controller.sv` (except the added `fsm_state` observability output), and `axi_lite_slave.sv` port lists are unchanged.

### A.10 Accumulator overflow bound

Worst-case single MAC product magnitude is `128 × 127 = 16,256` (int8 signed range reaches −128). Accumulated over N = 4 terms, `4 × 16,256 = 65,024` — trivially within int32 (~2.1 billion). The all-`−128` corner (`128 × 128 = 16,384`, ×4 = `65,536`) also fits with enormous headroom. Overflow impossibility is formally proven (Proof 1).

---

## Part B — Register (RAL) Spec

DiP is entirely internal to the datapath; the AXI-Lite control surface was untouched by the architecture change.

### B.1 Register map

| Register | Offset | Direction | Width | Reset | Purpose |
|---|---|---|---|---|---|
| `DIM_REG` | `0x0` | R/W | 3-bit | `0x0` | Matrix dimension N (1–4) for the next computation. |
| `CTRL_REG` | `0x4` | R/W | 1-bit | `0x0` | Bit 0 = `start`. Triggers weight load then activation flow. |
| `STATUS_REG` | `0x8` | RO | 1-bit | `0x0` | Bit 0 = `done`. Poll before reading the output buffer. |

### B.2 Locked register rules

- `STATUS_REG` is strictly read-only; a write must not change its value (formally proven, Proof 2).
- `DIM_REG` accepts only N = 1–4; 0 and 5–7 are illegal stimulus (Category 5). The design produces no spurious result.
- Writing `start = 1` while the FSM is not IDLE is illegal (premature/double start); no spurious output.
- `done` reads 1 only when the output buffer genuinely holds valid results.
- All three registers reset to 0.

---

## Part C — Performance Spec (RATIFIED)

### C.1 Latency contract — RATIFIED 2026-07-30

```
latency (cycles) = active_dim + 5
```

measured at the built physical size N = 4, for every legal `active_dim`:

| dim | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| Ratified latency (cycles, flow_en → done) | 6 | 7 | 8 | 9 |

This supersedes two earlier candidates: `2N` (an unverified v1.0 assumption inherited from the horizontal-flow design) and `active_dim + N + 1` (a structural re-derivation that only coincidentally matches at `dim = N = 4`). The team ran the as-built RTL for `dim = 1..4` and confirmed `active_dim + 5` in every case.

**Build-specific, not parametric in N.** `+5` reflects this 4×4 build's pipeline depth (weight-load/PE-clear sequencing, array fill, and `deskew_capture`'s one-cycle capture lag). If the design is elaborated at a different physical N, the `+5` constant is not guaranteed; re-measurement or first-principles re-derivation is required.

**Why not `2N`:** under DiP, output row `r` settles on the bottom accumulator at flow cycle `N + r`; `deskew_capture`'s one-cycle lag captures the last row on the following cycle — a structurally tight window. A `2N` window only coincides with correct sizing at `dim = N − 1` (unreachable here) and truncates the capture window for legal dims. `2N` was never re-derivable from the DiP RTL (Bug 7, closed).

### C.2 Where the contract is enforced (all reconciled)

| Artifact | Role | State |
|---|---|---|
| `rtl/mmu_controller.sv` | `flow_last = dim + N` sizing; header states `dim+5`. | Ratified |
| `sva/mmu_controller_sva.sv` (B3) | `p_result_latency` seeds `cnt = active_dim + 5`, asserts `done` at `flow_en + (active_dim+5)`. | Ratified |
| `perf/mmu_perf_checker.sv` (D1) | `exp_latency(n)` defaults to `n + 5`. `+LAT_SPEC_2N` plusarg produces the old `2N` on demand (expected to fail; **not** part of the regression contract). | Ratified |
| `uvm/mmu_cat6_tests.sv` (`mmu_latency_checker`) | Transaction-level check, defaults to `dim+5`, kept bit-for-bit consistent with D1. | Ratified |
| `uvm/mmu_scoreboard.sv` | **Measures** latency into `data_txn.latency` and logs it; does **not** assert (the transaction-level assertion lives in `mmu_cat6_tests.sv`). | By design |

Note on the two-checker reconciliation: REV 2 recommended re-adding the removed latency checker *inside the scoreboard*. As built, the transaction-level assertion instead lives in `mmu_cat6_tests.sv`'s `mmu_latency_checker`, paired with the signal-level D1 in `mmu_perf_checker.sv` as intentional defense-in-depth. The scoreboard retains only the *measurement*. There is no remaining disagreement between checkers.

### C.3 Throughput

Back-to-back initiation interval is measured flow-start to flow-start by both `mmu_perf_checker.sv` (D2, signal level) and the Category 6 throughput path. Zero-bubble (theoretical-max) back-to-back throughput is the expected result; any extra stall beyond the natural `WEIGHT_LOAD` phase fires D2. See `docs/perf_report.md` for the measured actual-vs-expected table.

### C.4 Open follow-up (non-blocking)

`+5` is confirmed empirically, not yet derived from first principles against the pipeline's true minimum achievable depth. Whether it can be reduced by further optimization is a future design question, independent of what is asserted today.

---

## Part D — Formal Verification Spec

Tool: Cadence JasperGold (run exclusively through JasperGold, never Xcelium for the `formal/` directory). Owner: Atharva.

### D.1 Proof 1 — Accumulator Overflow Impossibility

| Field | Value |
|---|---|
| Bound to | `formal/pe_formal.sv` → `pe.sv` |
| TCL | `formal/pe_overflow.tcl` |
| Result | **PROVEN** (4/4 assertions, unbounded) |
| Evidence | `formal/results/pe_overflow_report.txt` |
| Bound | Worst-case product `128 × 127 = 16,256`; 4-term max `65,024` — far below int32. |

Bound to `pe.sv`, which was structurally unchanged by the DiP rewrite, so the proof is unaffected by the interconnect change. Note: the tcl disables the tool's automatic multiplier blackboxing (`-bbox_mul -1`) — see BUGS.md Bug 1.

### D.2 Proof 2 — AXI-Lite Protocol Compliance

| Field | Value |
|---|---|
| Bound to | `formal/axi_formal.sv` → `axi_lite_slave.sv` |
| TCL | `formal/axi_compliance.tcl` |
| Result | **PROVEN** (4/4 assertions, unbounded) |
| Evidence | `formal/results/axi_compliance_report.txt` |

**A2 correction (carried from REV 2, confirmed in code):** `sva/axi_lite_sva.sv` now checks write-data channel *stability*, not awvalid/wvalid *simultaneity*:

```
A1: awvalid && !awready |=> awvalid && $stable(awaddr)
A2: wvalid  && !wready  |=> wvalid  && $stable(wdata)
```

AXI-Lite's write-address and write-data channels are independent; any plan or property language describing A2 as a "simultaneous assertion requirement" describes the old, incorrect version and is superseded.

### D.3 Proof 3 — 2×2 Functional Correctness

| Field | Value |
|---|---|
| Bound to | `formal/mmu_formal.sv` → `mmu_top.sv` (DIM_REG = 2) |
| TCL | `formal/twobytwo_correct.tcl` |
| Result | **PROVEN** — 13/13 assertions, 21/21 covers |
| Evidence | `formal/results/twobytwo_correct_FINALREPORT.txt`, `PROOF3_TIMELINE.md`, `CompletedProof3_Screenshot.jpg` |

Two properties of this proof:

- **State space:** exhaustive over `2^64` (four int8 activations + four int8 weights = 64 free bits). *(v1.0/early-plan language saying `2^32` is corrected.)*
- **Deliberately latency-agnostic:** checks the *value* of results on whichever cycle `done` asserts; it never asserts a cycle count. Proof 3's PROVEN status therefore holds regardless of the latency contract and must not be cited as evidence for it.

### D.4 C1 — `zero_input_no_accumulate` (COMPLETE)

`sva/pe_sva.sv` exists and binds C1 to every PE instance (16 at N = 4): when `activation_in == 0`, the accumulator must not change. This backs the Category 1 zero-activation exercises (TC-005/010/014) and is the target of the TC-035f force-injection test. *(REV 2 marked this NOT STARTED.)*

### D.5 Formal vs. simulation assertions

The `sva/` assertions check properties on the specific inputs the UVM sequences generate. The JasperGold proofs make no assumption about which inputs arrive — they exhaustively explore reachable states and either prove universally or return a counterexample. This is why overflow guarantees, protocol invariants, and small-N functional equivalence are proven formally rather than only inferred from coverage.

---

## Appendix — Revision change log (REV 2 → REV 3)

| # | Change | Section |
|---|---|---|
| 1 | Latency contract RATIFIED: `active_dim + 5` (6/7/8/9 at N=4); `2N` and `active_dim + N + 1` retired. | Part C, 0.2 |
| 2 | `perf/mmu_perf_checker.sv` D1 reconciled to `dim+5` default; `2N` demoted to `+LAT_SPEC_2N` opt-in. | C.2 |
| 3 | Two-checker reconciliation resolved: transaction-level assertion lives in `mmu_cat6_tests.sv`; scoreboard measures only. | C.2 |
| 4 | Categories 3 and 4 marked DONE (TC-014–020, TC-021/022/034). | 0.2 |
| 5 | C1 / `pe_sva.sv` marked DONE (was NOT STARTED). | 0.2, D.4 |
| 6 | D2 (throughput SVA) and TC-035g marked DONE (was not written). | 0.2 |
| 7 | New Category 7 (TC-038–049) documented. | 0.2 |
| 8 | `mmu_controller.sv` `fsm_state` observability output documented (no behavior change). | A.4, A.5 |
| 9 | `docs/perf_report.md` populated with the ratified expected column. | C.3 |
| 10 | Proof statuses updated to PROVEN with assertion/cover counts. | Part D |

## Glossary

| Term | Meaning |
|---|---|
| Systolic array | Grid of small multiply-add cells passing data to neighbors each cycle instead of round-tripping to memory. |
| PE | Processing element — one grid cell, one MAC per cycle. |
| Weight-stationary | Weights load once and stay fixed; activations flow past. |
| DiP | Diagonal-input, Permuted weight-stationary — this project's dataflow. |
| MAC | Multiply-accumulate: `total = total + (a × b)`. |
| RAL | Register Abstraction Layer — address registers by name, not raw bus transactions. |
| FSM | Finite State Machine — the controller stepping IDLE → … → DONE. |
| SVA | SystemVerilog Assertions — properties checked each cycle in simulation. |
| DUT | Design Under Test — `mmu_top.sv`. |
| `pe_clear` | Signal that zeros every PE accumulator for exactly one cycle before a run. |
| `deskew_capture` | Module that snapshots the raw bottom accumulator row into a finished result matrix at the correct per-row cycle. |
| Latency | Cycles from activation flow starting until the result is ready. RATIFIED at `active_dim + 5`. |
