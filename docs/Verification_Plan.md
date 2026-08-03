# sv-tpu-core — UVM Verification Test Plan, REV 2 (As-Built)

**Parameterized, weight-stationary systolic array MMU — DiP dataflow, int8×int8→int32**
Verification Lead: Atharva Kulkarni · Revision date: 2026-08-03 · Supersedes: Verification Test Plan v1.0 (2026-07-01, Phase 1)

Document scope: test cases, mutation-based assertion validation, SVA reference, and functional coverage plan — reconciled against the completed repository.

---

## What changed since v1.0 (Phase 1 plan)

The v1.0 plan was written in Phase 1, before the DiP architecture pivot and before the latency contract was measured. This revision reconciles it to the as-built RTL, assertions, and UVM tests. The substantive corrections:

1. **Latency contract: `2N` → `active_dim + 5`.** Every "2N=…" figure (Category 6, TC-001/002/003/004/011/013/022/025/030/031, and the B3/D1 property text) is corrected to the ratified `active_dim + 5` (6/7/8/9 for N = 1..4). See the Latency Contract note in §3.6 and the SVA reference. `active_dim + N + 1` (an intermediate candidate) is also retired.
2. **Dataflow description: horizontal → DiP.** Stimulus and coverage language describing a left-edge, row-staggered activation feed is replaced with DiP: a full row of A fed into row 0 each cycle, diagonal propagation, internal weight permutation. The DUT is a DiP array (arXiv:2412.09709v3), not the Phase-1 horizontal-flow design.
3. **A2 property corrected: simultaneity → stability.** A2 is `axi_wvalid_stable` (`wvalid && !wready |=> wvalid && $stable(wdata)`), not `awvalid |-> wvalid`. The write-address and write-data channels are independent in AXI-Lite; the negative stimulus is "drop wvalid before wready," not "awvalid without wvalid."
4. **Proof 3 state space: `2^32` → `2^64`** (four int8 activations + four int8 weights).
5. **Two-checker location.** The transaction-level latency assertion is `mmu_latency_checker` in `uvm/mmu_cat6_tests.sv`; the scoreboard only *measures* latency. It is paired with the signal-level D1 in `mmu_perf_checker.sv` as defense-in-depth.
6. **New Category 7 — Dimension-Swept Pattern Coverage Closure (TC-038–049)** is documented.
7. **`perf_report.md` exists** and is referenced accordingly.

---

## 1. Overview

This plan verifies `sv-tpu-core`, a parameterized weight-stationary systolic array MMU implementing the DiP (Diagonal-input, Permuted weight-stationary) dataflow. It enumerates functional and structural test cases across **seven categories**, the TC-035 mutation-based negative tests that validate the assertion suite itself, a reference for all **9 SVA** properties bound into the design, and **8 functional coverage groups** used to measure closure.

Each test case specifies stimulus, expected behavior, scoreboard check, the assertions it exercises, and the coverage bins it targets. Where a test is paired with a JasperGold proof, that context is called out.

### 1.1 Categories at a glance

| Category | Focus | Tests |
|---|---|---|
| 1 — Basic Functional Correctness | Core matmul correctness across dimensions, value extremes, and weight/activation patterns vs a Python golden model. | TC-001–010 |
| 2 — Back-to-Back Sequencing | Consecutive computations (no gap / one-cycle gap / alternating dims) to catch accumulator leakage. | TC-011–013 |
| 3 — Weight Poison & Reset Stress | Directed weight patterns + reset timed to each FSM state, probing silent corruption and recovery. | TC-014–020 |
| 4 — Reset Behavior | Synchronous reset from IDLE, after a computation, and from DONE. | TC-021/022/034 |
| 5 — Illegal Operation / Error Injection | Illegal register writes, premature/double START, out-of-range dims — safe degradation. | TC-023–026 |
| 6 — Latency & Throughput Performance | Cycle-accurate latency vs the ratified `active_dim + 5` contract, and back-to-back throughput, dual-checked. | TC-027–031 |
| 7 — Dimension-Swept Pattern Coverage Closure | Re-runs existing pattern sequences at scalar/small dims to close remaining cross-coverage bins. | TC-038–049 |
| RAL Built-In | UVM RAL reset/access sequences as a register-model health gate. | TC-032/033 |

---

## 2. Test case index

| ID | Category | Title |
|---|---|---|
| TC-001 | Cat 1 | Full 4×4 Random Matrix Multiply |
| TC-002 | Cat 1 | 3×3 Subarray |
| TC-003 | Cat 1 | 2×2 Subarray |
| TC-004 | Cat 1 | 1×1 Scalar MAC |
| TC-005 | Cat 1 | All-Zero Activation Matrix |
| TC-006 | Cat 1 | All-Zero Weight Matrix |
| TC-007 | Cat 1 | Max int8 Values (Worst-Case Accumulation) |
| TC-008 | Cat 1 | Min int8 Values (Negative Accumulation) |
| TC-009 | Cat 1 | Mixed Positive and Negative Values |
| TC-010 | Cat 1 | Identity Matrix as Weights |
| TC-011 | Cat 2 | 10+ Consecutive 4×4, No Gap |
| TC-012 | Cat 2 | Back-to-Back With One-Cycle Gap |
| TC-013 | Cat 2 | Back-to-Back With Alternating Dimensions |
| TC-014 | Cat 3 | Weight Poison: All-Zero Weights |
| TC-015 | Cat 3 | Weight Poison: All-127 Weights |
| TC-016 | Cat 3 | Weight Poison: Identity Weights |
| TC-017 | Cat 3 | Weight Poison: Checkerboard Pattern |
| TC-018 | Cat 3 | Reset Stress: Reset During WEIGHT_LOAD |
| TC-019 | Cat 3 | Reset Stress: Reset During PE_CLEAR |
| TC-020 | Cat 3 | Reset Stress: Reset During ACTIVATION_FLOW |
| TC-021 | Cat 4 | Synchronous Reset From IDLE |
| TC-022 | Cat 4 | Reset Then Immediate Restart |
| TC-034 | Cat 4 | Reset Asserted While FSM Is in DONE |
| TC-023 | Cat 5 | Write to Read-Only STATUS_REG |
| TC-024 | Cat 5 | START Before DIM_REG Written (dim=0) |
| TC-025 | Cat 5 | Double START (Second START Mid-Computation) |
| TC-026 | Cat 5 | Invalid Dimension (DIM_REG > 4) |
| TC-027 | Cat 6 | Single N=1 Latency Verification |
| TC-028 | Cat 6 | Single N=2 Latency Verification |
| TC-029 | Cat 6 | Single N=3 Latency Verification |
| TC-030 | Cat 6 | Single N=4 Latency Verification |
| TC-031 | Cat 6 | Back-to-Back Throughput at N=4 |
| TC-032 | RAL | RAL Built-In: `uvm_reg_hw_reset_seq` |
| TC-033 | RAL | RAL Built-In: `uvm_reg_access_seq` |
| TC-035a–g | Negative | Force-injection assertion validation (see §4) |
| TC-038–049 | Cat 7 | Dimension-swept pattern coverage closure (see §3.7) |

---

## 3. Detailed test cases

Throughout: the DUT's external contract is A (activations) in, B (weights) in, C = A×B out. DiP's diagonal routing and internal weight permutation (`permuted[row][col] = weights[(row+col) mod N][col]`) are invisible at the module boundary — sequences always drive the natural, unpermuted matrices. "Latency" means cycles from the first `ACTIVATION_FLOW` (flow_en) cycle to `done`, and the ratified contract is **`active_dim + 5`** (6/7/8/9 for N = 1..4).

### 3.1 Category 1 — Basic Functional Correctness

**TC-001 — Full 4×4 Random Matrix Multiply.** Constrained-random int8 A and B; `DIM_REG=4`; `start` asserted. Under DiP, a full row of A is fed into row 0 each active cycle (no per-row left-edge stagger). Expected: FSM IDLE→WEIGHT_LOAD→PE_CLEAR→ACTIVATION_FLOW→DONE; `done` asserts `active_dim + 5 = 9` cycles after flow begins; output buffer holds 16 int32 results. Scoreboard: Python golden model, element-wise `!==`. Assertions: B1, B2, B3 (`dim+5`), B4. Coverage: `cp_dim=full`, random weight/activation patterns.

**TC-002 — 3×3 Subarray.** `DIM_REG=3`. Done at `3+5 = 8` cycles. 9 int32 results; the 4th row/column of the physical array must not contribute. Assertions: B3 (8 for N=3), B2. Coverage: `cp_dim=small(3)`.

**TC-003 — 2×2 Subarray.** Directed first (hand-verifiable), then constrained-random. `DIM_REG=2`. Done at `2+5 = 7` cycles. This scenario is the target of JasperGold Proof 3 — formal correctness exhaustive over the **2^64** int8 input space (four activations + four weights). The simulation test exercises the same scenario at specific seeds. Assertions: B3 (7 for N=2). Coverage: `cp_dim=small(2)`.

**TC-004 — 1×1 Scalar MAC.** Directed (e.g. A=5, B=3 → 15). `DIM_REG=1`. Done at `1+5 = 6` cycles. Single int32 result = A×B. Assertions: B3 (6 for N=1 — tightest case). Coverage: `cp_dim=scalar(1)`.

**TC-005 — All-Zero Activation Matrix.** Activations = 0, random weights, `DIM_REG=4`. All 16 outputs exactly 0 (no leakage; `pe_clear` worked). Assertions: C1 (`zero_input_no_accumulate`, `pe_sva.sv`) — accumulator must not change when `activation_in==0`. Coverage: `cp_activation_pattern=all_zero`, `cx_dim_x_act=full×all_zero`.

**TC-006 — All-Zero Weight Matrix.** Weights = 0, random activations, `DIM_REG=4`. All 16 outputs exactly 0. Assertions: C1 indirectly (0×anything=0). Coverage: `cp_weight_pattern=all_zero`.

**TC-007 — Max int8 (Worst-Case Accumulation).** Activations = weights = 127, `DIM_REG=4`; each PE accumulates `4×(127×127)=64,516`. No overflow (int32 max ~2.1 B). This is the scenario Proof 1 proves can never overflow; note the true worst-case *magnitude* product is `128×127=16,256` (mixed-sign), exercised at the corner by TC-008. Assertions: overflow impossibility is formal (Proof 1); this test confirms under simulation. Coverage: `cp_weight_pattern=all_max`, `cp_activation_pattern=all_max`.

**TC-008 — Min int8 (Negative Accumulation).** Activations = weights = −128, `DIM_REG=4`; each PE accumulates `4×((−128)×(−128))=4×16,384=65,536` (positive). Signed arithmetic must produce positive int32. Coverage: `cp_weight_pattern=all_negative`, `cp_activation_pattern=all_negative`.

**TC-009 — Mixed Positive/Negative.** Constrained-random with ≥1 quadrant negative in each matrix, `DIM_REG=4`. Stresses signed MAC (all-positive random could mask a sign bug). Scoreboard is primary.

**TC-010 — Identity Weights.** B = identity, A random, `DIM_REG=4`. Output C must equal A exactly — a sensitive PE-wiring / weight-preload test (and, under DiP, a check that internal permutation restores the natural mapping). Assertions: B1 (weight preload must complete). Coverage: identity pattern bin.

### 3.2 Category 2 — Back-to-Back Sequencing

**TC-011 — 10+ Consecutive 4×4, No Gap.** Random A/B per transaction; `DIM_REG=4`; re-assert `start` immediately after each `done`. Each result independent and correct; the primary accumulator-leakage detector. Assertions: B2 on every transaction; B3 (`dim+5 = 9`) on every transaction. Coverage: `cp_back_to_back=no_gap`.

**TC-012 — One-Cycle Gap.** As TC-011 with one idle cycle between `done` and next `start`. Identical results; catches hidden minimum-recovery dependence. Assertions: B2; B4 (no `done` re-assert during the gap). Coverage: `cp_back_to_back=one_cycle`.

**TC-013 — Alternating Dimensions.** Directed 4×4 → 2×2 → 4×4, `DIM_REG` rewritten each time, random values. The 2×2 must not be contaminated by the prior 4×4's accumulators — PEs [0][0],[0][1],[1][0],[1][1] must be cleanly zeroed. Assertions: B2 (critical — PEs reused across dims); B3 must match each N (9, 7, 9). Coverage: `cp_back_to_back` × mixed `cp_dim`.

### 3.3 Category 3 — Weight Poison & Reset Stress (`uvm/mmu_cat3_tests.sv`, COMPLETE)

Each poison test runs a prime pass then a directed-pattern pass; each reset-stress test times reset to an FSM phase then verifies a clean recovery pass.

**TC-014 — All-Zero Weights** (`mmu_wp_zero_test`). Run after a large-nonzero-weight computation — the hardest accumulator-leakage-via-weight-path case. All 16 outputs must be exactly 0. Assertions: C1. Coverage: `cp_weight_pattern=all_zero`.

**TC-015 — All-127 Weights** (`mmu_wp_max_test`). Every output = Σ(activation×127); stresses large repeated accumulation. Scoreboard primary; overflow is formal (Proof 1). Coverage: `all_max`.

**TC-016 — Identity Weights** (`mmu_wp_identity_test`). Run after large nonzero weights; C == A confirms weight-preload routing (and DiP permutation) is exact. Assertions: B1. Coverage: identity.

**TC-017 — Checkerboard Weights** (`mmu_wp_checker_test`). B[i][j] = +127 if (i+j) even else −127. Stresses signed cancellation of large ± partial products. Scoreboard primary. Coverage: checkerboard.

**TC-018 — Reset During WEIGHT_LOAD** (`mmu_reset_wl_test`). Reset mid-preload; FSM returns to IDLE; next computation's `pe_clear` must zero all accumulators; result depends solely on new inputs. Assertions: B4, B2 post-reset. Coverage: `cp_reset_state=weight_load`.

**TC-019 — Reset During PE_CLEAR** (`mmu_reset_pclr_test`). Reset in the single `pe_clear` cycle — tightest window. FSM to IDLE; next computation clean regardless of partial zeroing. Assertions: B2, B4. Coverage: `cp_reset_state=pe_clear_state`.

**TC-020 — Reset During ACTIVATION_FLOW** (`mmu_reset_aflow_test`). Reset mid-flow with large in-flight accumulators — highest-yield leakage surface. FSM to IDLE; partials discarded; next computation clean. Assertions: B4, B2. Coverage: `cp_reset_state=activation_flow`.

### 3.4 Category 4 — Reset Behavior (`uvm/mmu_cat4_tests.sv`, COMPLETE)

**TC-021 — Reset From IDLE** (`mmu_reset_idle_test`). Reset while idle; FSM stays IDLE; all registers/accumulators at reset values. Scoreboard: `uvm_reg_hw_reset_seq` walks all registers. Assertions: B4, B1 (no illegal transition). Coverage: `cp_reset_state=idle`.

**TC-022 — Reset Then Immediate Restart** (`mmu_reset_restart_test`). Complete a 4×4, reset one cycle, then write `DIM_REG`+`start` on the next cycle — minimum recovery. New result correct and independent. Assertions: B2, B3 (`dim+5 = 9` on the first post-reset computation), B4. Coverage: reset-recovery.

**TC-034 — Reset While in DONE** (`mmu_reset_done_test`). Let `done` assert and hold, then reset one cycle in DONE. `done` must deassert (must not persist); FSM to IDLE; a clean post-reset computation must be correct. Assertions: B4, B2, B3 (9). Coverage: `cp_reset_state=done_state` (the bin only TC-034 fills).

### 3.5 Category 5 — Illegal Operation / Error Injection (`uvm/mmu_cat5_tests.sv`)

**TC-023 — Write to Read-Only STATUS_REG** (`tc_023_status_reg_write_test`). RAL flags the write; the AXI driver still physically drives it. DUT ignores it; `STATUS_REG` unchanged; no FSM transition, no output. Follow-on legal computation verified. (The test registers a `uvm_report_catcher` support class to demote the expected read-only-guard error.) Assertions: A1; B4. Coverage: `cp_error_type=status_reg_write`.

**TC-024 — START Before DIM_REG (dim=0)** (`tc_024_premature_start_test`). `DIM_REG=0` (illegal). FSM stays IDLE (the controller's `dim_legal` gate blocks the transition); no hang, no output. Follow-on legal computation succeeds. Assertions: B4; no-deadlock. Coverage: `cp_error_type=premature_start`.

**TC-025 — Double START Mid-Computation** (`tc_025_double_start_test`). Assert a second `start` during ACTIVATION_FLOW; DUT ignores it; first computation completes at its own `dim+5` latency; output is the first computation's only. Assertions: B4 (one `done` per computation); B3 unaffected. Coverage: `cp_error_type=double_start`.

**TC-026 — Invalid Dimension (DIM_REG > 4)** (`tc_026_invalid_dim_test`). Write `DIM_REG=5/6/7`; `start`. Per the `dim_legal` gate, the DUT does not begin a run for an illegal dimension — no out-of-bounds PE access, no hang, no output. Follow-on legal transaction succeeds. Assertions: B4; no-deadlock. Coverage: `cp_error_type=invalid_dim`.

### 3.6 Category 6 — Latency & Throughput Performance (`uvm/mmu_cat6_tests.sv`)

> **Latency Contract — RATIFIED 2026-07-30: `active_dim + 5`.** v1.0 stated `2N` (pipelined), which was never re-derivable from the as-built DiP RTL. Measured latency is `dim + 5`, confirmed for N = 1..4:
>
> | dim | 1 | 2 | 3 | 4 |
> |---|---|---|---|---|
> | latency (cycles) | 6 | 7 | 8 | 9 |
>
> `mmu_latency_checker` (below) defaults to `LAT_AS_BUILT` (`dim+5`) and is the sole regression contract. A `+LAT_SPEC_2N` plusarg can produce the retired `2N` number on demand; it is expected to fail and is not part of the regression. Latency depends only on `dim`, not operand values.

**TC-027 — N=1 Latency** (`tc_027_latency_n1_test`). `DIM_REG=1`. `done` exactly **6** cycles after flow begins — tightest case. `mmu_latency_checker` asserts `observed==6`; `mmu_perf_checker.sv` (D1) fires at signal level simultaneously; both must agree. Assertions: B3, D1. Coverage: `cp_dim=scalar`.

**TC-028 — N=2 Latency** (`tc_028_latency_n2_test`). `done` at **7** cycles. Same dimension as Proof 3 — complementary formal/simulation coverage. Assertions: B3, D1.

**TC-029 — N=3 Latency** (`tc_029_latency_n3_test`). `done` at **8** cycles.

**TC-030 — N=4 Latency** (`tc_030_latency_n4_test`). `done` at **9** cycles — worst case; catches any pipeline miscount or ACTIVATION_FLOW→DONE off-by-one. Assertions: B3, D1, B2.

**TC-031 — Back-to-Back Throughput at N=4** (`tc_031_throughput_n4_test`). 10+ consecutive N=4, zero gap. Each computation completes in `dim+5 = 9`; back-to-back initiation interval matches theoretical max (no bubble beyond the natural `WEIGHT_LOAD` phase). Scoreboard: functional (golden model per transaction) + performance (`perf_sequences.sv` / D2). Measured actual-vs-expected recorded in `docs/perf_report.md`. Assertions: D2; B2; B3 per transaction.

### 3.7 Category 7 — Dimension-Swept Pattern Coverage Closure (`uvm/mmu_cat7_tests.sv`, NEW 2026-08-02)

Additive stimulus, **not** bug fixes: every weight/activation pattern sequence already worked at `dim=4`; these tests re-run the same sequences with `mmu_base_seq::fixed_dim` pinned to 1 (scalar) or 2 (small) so the cross-coverage bins in `mmu_coverage.sv` sample each pattern at the array sizes they still needed. All use the standard positive scoreboard path.

| TC | Bin closed | Sequence / dim |
|---|---|---|
| TC-038 | `cx_dim_x_weight` scalar,all_zero | `mmu_wp_zero_seq`, dim=1 |
| TC-039 | small,all_zero | `mmu_wp_zero_seq`, dim=2 |
| TC-040 | scalar,all_max | `mmu_wp_max_seq`, dim=1 |
| TC-041 | small,all_max | `mmu_wp_max_seq`, dim=2 |
| TC-042 | scalar,identity | `mmu_wp_identity_seq`, dim=1 |
| TC-043 | small,identity | `mmu_wp_identity_seq`, dim=2 |
| TC-044 | small,checkerboard | `mmu_wp_checker_seq`, dim=2 |
| TC-045 | scalar,all_negative (weight ∩ act) | `mmu_uniform_extreme_seq(NEG)`, dim=1 |
| TC-046 | small,all_negative (weight ∩ act) | `mmu_uniform_extreme_seq(NEG)`, dim=2 |
| TC-047 | `cx_dim_x_act` scalar,all_zero | `mmu_zero_activation_seq`, dim=1 |
| TC-048 | scalar,all_max | `mmu_max_activation_seq`, dim=1 |
| TC-049 | small,all_max | `mmu_max_activation_seq`, dim=2 |

**Waived bin:** `cx_dim_x_weight` scalar,checkerboard is structurally dead and waived in `mmu_coverage.sv` — `classify_weight_pattern()` checks `is_max` before `is_check`, and a 1×1 checkerboard cell is bitwise identical to all-max, so `PAT_CHECK` can never be returned for dim=1.

### 3.8 RAL Built-In Sequences (`uvm/mmu_ral_and_negative_tests.sv`)

**TC-032 — `uvm_reg_hw_reset_seq`** (`tc032_ral_hw_reset_test`). After a reset cycle, walks every register and reads back; each must return its defined reset value (all 0). No computation; FSM stays IDLE. RAL model checks internally. First test in integration — a gate for everything after it. Assertions: B4; A1.

**TC-033 — `uvm_reg_access_seq`** (`tc033_ral_access_test`). Writes a pattern to each RW field (`DIM_REG`, `CTRL_REG`), reads back, verifies round-trip; `STATUS_REG` auto-skipped for writes (RO). A `CTRL_REG` write must not trigger a computation. Assertions: A1; A2; B4.

---

## 4. Negative testing — assertion validation via force injection (TC-035a–g)

The TC-035 series forces internal signals into illegal states with `force`/`release` to confirm each assertion fires when its property is violated (an assertion that never fires may be miswritten or unbound). Each variant is followed by a clean legal computation. The two concrete done-timing subclasses derive from a shared base (`tc035cd_force_done_timing_test`), which is abstract and not run directly.

| Sub-test | Test class | Signal forced | Fires |
|---|---|---|---|
| TC-035a | `tc035a_force_skip_weight_load_test` | FSM IDLE→PE_CLEAR, skipping WEIGHT_LOAD | B1 |
| TC-035b | `tc035b_force_pe_clear_hold_test` | `pe_clear` held for 2 cycles | B2 |
| TC-035c | `tc035c_done_early_test` | `done` forced one cycle **early** (at `dim+4`) | B3, D1 |
| TC-035d | `tc035d_done_late_test` | `done` suppressed until one cycle **late** (`dim+6`) | B3, D1 |
| TC-035e | `tc035e_force_done_in_idle_test` | `done` forced while `state==IDLE` | B4 |
| TC-035f | `tc035f_force_pe_accum_on_zero_test` | one PE's accumulator forced to increment on a zero-activation cycle | C1 (that PE only) |
| TC-035g | `tc035g_force_extra_weight_load_stall_test` | extra WEIGHT_LOAD stall cycle in a back-to-back sequence | D2 |

Note TC-035c/d target the **ratified** contract: "early/late" is ±1 cycle around `dim+5`, not `2N`. TC-035f is surgical — C1 must fire on the forced PE (e.g. `pe_inst[1][2]`) and only that PE, validating that `bind` created independent per-instance assertions.

---

## 5. SVA assertion reference

Nine properties: AXI-Lite protocol (A), controller FSM/timing (B), per-PE datapath (C), top-level performance (D). "Exercised by" lists positive-mode tests expected to pass without firing; "Targeted by" lists the TC-035 mutation that fires it.

**A1 — `axi_awvalid_stable`** · `axi_lite_sva.sv`
`awvalid && !awready |=> awvalid && $stable(awaddr)`
Once the write-address channel valid asserts, `awvalid` and `awaddr` must stay stable until `awready`. Exercised by: TC-001–010, TC-032/033. Targeted by: TC-023 + TC-035 (drop `awvalid`/mutate `awaddr` before `awready`).

**A2 — `axi_wvalid_stable`** · `axi_lite_sva.sv`  *(corrected — was `axi_wvalid_with_awvalid`)*
`wvalid && !wready |=> wvalid && $stable(wdata)`
Once the write-data channel valid asserts, `wvalid` and `wdata` must stay stable until `wready`. AXI-Lite write-address and write-data channels are **independent**; this is a stability property, not a same-cycle simultaneity requirement. Exercised by: TC-001–010, TC-032/033. Targeted by: TC-025 + TC-035 (drop `wvalid` / mutate `wdata` before `wready`).

**B1 — `no_skip_weight_load`** · `mmu_controller_sva.sv`
`(state==IDLE) && start && dim_legal |=> (state==WEIGHT_LOAD)`
FSM must enter WEIGHT_LOAD first after a legal START — the `dim_legal` guard prevents false firing during negative dim tests. Exercised by: TC-001–013, TC-022, TC-034. Targeted by: TC-035a.

**B2 — `pe_clear_one_cycle`** · `mmu_controller_sva.sv`
`$rose(pe_clear) |=> !pe_clear`
`pe_clear` asserts for exactly one cycle; a longer pulse both violates the `active_dim + 5` latency contract and risks accumulator corruption. Exercised by: TC-001–013, TC-018–020. Targeted by: TC-035b.

**B3 — `result_latency`** · `mmu_controller_sva.sv`  *(corrected to `dim+5`)*
On `$rose(flow_en)`, with an internal counter seeded at `active_dim + 5`, `done` must assert exactly `active_dim + 5` cycles later — not `dim+4`, not `dim+6`. This is the ratified contract, checked at the controller level and mirrored at the transaction level by `mmu_latency_checker` (§7.3). Exercised by: TC-027–031, TC-011. Targeted by: TC-035c, TC-035d.

**B4 — `no_spurious_done`** · `mmu_controller_sva.sv`
`(state==IDLE) |-> !done`
`done` must never assert in IDLE. Exercised by: TC-021/022/024/032/033 and every inter-transaction IDLE window. Targeted by: TC-035e. Highest trigger count in the project.

**C1 — `zero_input_no_accumulate`** · `pe_sva.sv` (×N×N)  *(now implemented)*
`(activation_in == 0) |-> (acc == $past(acc))`
When a PE's activation input is zero, its accumulator must not change. Bound to every PE instance (16 at N=4). Exercised by: TC-005, TC-010, TC-014. Targeted by: TC-035f.

**D1 — `signal_level_latency`** · `mmu_perf_checker.sv`  *(corrected to `dim+5`, default)*
Jad's signal-level counterpart to B3, bound at `mmu_top`. `exp_latency(n)` defaults to `n + 5`; `+LAT_SPEC_2N` selects the retired `2N` on demand. A pipeline-register bug between controller-internal `done` and top-level `done` passes B3 but fails D1. Exercised by: TC-027–031. Targeted by: TC-035c/d.

**D2 — `back_to_back_throughput`** · `mmu_perf_checker.sv`  *(now implemented)*
After `done` with a pending START, the next `flow_en` rise must occur within exactly the `WEIGHT_LOAD` interval — any extra stall is a throughput bug. Exercised by: TC-011, TC-013, TC-031. Targeted by: TC-035g.

---

## 6. Functional coverage plan

8 covergroups (two crosses) measure closure; all bins target ≥90%.

- **`cp_dim`** — {scalar=1}, {small=2,3}, {full=4}. Hit by TC-004/002/003/001 and constrained-random.
- **`cp_weight_pattern`** — all_zero, all_max(127), all_negative(−128), identity, checkerboard, random. Hit by TC-005/007/008/016/017 and the poison sequences; random by TC-001–004.
- **`cp_activation_pattern`** — all_zero, all_max, all_negative, random. Under DiP the activation path is the diagonal row-0 feed (not a per-row stagger); pattern coverage still matters for the feed and PE input wiring. Hit by TC-005/007/008 and random Cat 1.
- **`cx_dim_x_weight`** — 3 dims × 6 weight patterns = 18 bins. Scalar/small corners closed by Category 7 (TC-038–046); scalar,checkerboard waived (§3.7).
- **`cx_dim_x_act`** — 3 dims × 4 activation patterns = 12 bins. Scalar/small corners closed by Category 7 (TC-045/046/047/048/049).
- **`cp_back_to_back`** — no_gap={0}, one_cycle={1}, multi={2..10}. Hit by TC-011/012 and randomized-gap sequences.
- **`cp_error_type`** — status_reg_write, premature_start, double_start, invalid_dim. Hit by TC-023–026.
- **`cp_reset_state`** — idle, weight_load, pe_clear, activation_flow, done. Hit by TC-021/018/019/020/034. Sampled off the controller's `fsm_state` observability output.

---

## 7. Scoreboard architecture & pass criteria

Four checking paths, dispatched by a `check_type_e` tag ({POSITIVE, NEGATIVE, PERFORMANCE, RAL}) carried on each transaction so paths never interfere.

### 7.1 Path 1 — Positive (Cat 1, 2, 3, 4, 7)
Input capture via TLM FIFO (A, B keyed by transaction ID) → output capture after `done` → golden-model call over a DPI-C bridge to `ref_model.py` (`np.matmul` with explicit int32 cast) → element-wise `!==` comparison (4-state, so any X/Z fails) → pass declaration. No tolerance; int32 arithmetic is exact. On mismatch, logs coordinates, expected/observed, full A/B, transaction ID, test name/seed, FSM state, and `done` cycle.

### 7.2 Path 2 — Negative (Cat 5)
No golden-model call for the illegal window; the expected output is the *absence* of output. A forked monitor watches the output buffer and `done` for a conservative window; any `done` during it fails. Then a register-integrity read-back, then a mandatory follow-on legal computation checked via Path 1 (proves the illegal op left no residual corruption).

### 7.3 Path 3 — Performance (Cat 6)
Runs alongside Path 1 (output still checked) and additionally verifies cycle count against the ratified **`active_dim + 5`** contract, at two levels:

- **Transaction level — `mmu_latency_checker` (`uvm/mmu_cat6_tests.sv`):** consumes `data_txn.latency` (filled by the data monitor) and compares against `exp_latency = dim + 5` (default `LAT_AS_BUILT`), erroring on mismatch. *(This is where the checker lives as-built; the scoreboard itself only measures and logs latency, it does not assert — see the note in `mmu_scoreboard.sv`.)*
- **Signal level — D1 (`mmu_perf_checker.sv`):** asserts the same `dim+5` at the top-level interface.

Both are kept bit-for-bit consistent as defense-in-depth. A disagreement between them is a priority-one investigation (a controller-to-top-level path discrepancy). Throughput (TC-031): actual vs `1 / (dim+5 + WEIGHT_LOAD)`; any bubble beyond `WEIGHT_LOAD` is flagged and written to `docs/perf_report.md`.

### 7.4 Path 4 — RAL (TC-032, TC-033)
The RAL model is the checker (reset values, RW round-trip, RO enforcement). The scoreboard adds a spurious-computation guard: `done` must never assert and the FSM must stay IDLE throughout.

### 7.5 Summary

| Path | Tests | Pass condition |
|---|---|---|
| Positive | Cat 1, 2, 3, 4, 7 | All N×N outputs match the golden model exactly; no X/Z. |
| Negative | Cat 5 | No spurious `done`; registers unchanged; follow-on transaction correct. |
| Performance | Cat 6 | Output correct + transaction latency == `dim+5` + D1 no violations + checkers agree. |
| RAL | TC-032/033 | All register fields correct + no spurious computation triggered. |

### 7.6 Global rule
A single `uvm_error` on any path fails the regression. `make` category targets exit nonzero on any error; there is no "mostly passing."

---

## 8. Assertion exercise mapping — summary

| ID | Assertion | File | Mode-1 tests | Mode-2 test | Frequency |
|---|---|---|---|---|---|
| A1 | `axi_awvalid_stable` | `axi_lite_sva.sv` | TC-001–010, TC-032/033 | TC-023 + TC-035 | Per AXI write |
| A2 | `axi_wvalid_stable` | `axi_lite_sva.sv` | TC-001–010, TC-032/033 | TC-025 + TC-035 | Per AXI write |
| B1 | `no_skip_weight_load` | `mmu_controller_sva.sv` | TC-001–013, TC-022, TC-034 | TC-035a | Per START |
| B2 | `pe_clear_one_cycle` | `mmu_controller_sva.sv` | TC-001–013, TC-018–020 | TC-035b | Per computation |
| B3 | `result_latency` (`dim+5`) | `mmu_controller_sva.sv` | TC-027–031, TC-011 | TC-035c/d | Per computation |
| B4 | `no_spurious_done` | `mmu_controller_sva.sv` | TC-021/022/024/032/033 | TC-035e | Every IDLE cycle |
| C1 | `zero_input_no_accumulate` | `pe_sva.sv` (×16) | TC-005/010/014 | TC-035f | Per zero-activation cycle × PEs |
| D1 | `signal_level_latency` (`dim+5`) | `mmu_perf_checker.sv` | TC-027–031 | TC-035c/d | Per computation |
| D2 | `back_to_back_throughput` | `mmu_perf_checker.sv` | TC-011/013/031 | TC-035g | Per back-to-back boundary |

Files: `axi_lite_sva.sv`→`axi_lite_slave.sv` (A1,A2); `mmu_controller_sva.sv`→`mmu_controller.sv` (B1–B4); `pe_sva.sv`→`pe.sv` all N×N (C1); `mmu_perf_checker.sv`→`mmu_top.sv` (D1,D2).
