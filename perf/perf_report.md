# sv-tpu-core — Performance Report

**Latency contract: RATIFIED 2026-07-30 — `latency = active_dim + 5` cycles (flow_en → done), measured at the N = 4 build.**

This report records the as-built latency and back-to-back throughput of `sv-tpu-core` against the ratified contract. It is the deliverable referenced by the spec (Part C) and the verification plan (§3.6, §7.3). Latency depends only on `active_dim`, not on operand values.

## Latency — actual vs expected

Expected column = ratified contract `active_dim + 5`. Actual column = measured (`data_txn.latency`, first `ACTIVATION_FLOW` cycle to `done`), cross-checked by `mmu_latency_checker` (`uvm/mmu_cat6_tests.sv`, transaction level) and D1 (`perf/mmu_perf_checker.sv`, signal level).

| active_dim | Expected (`dim+5`) | Actual | Test | Status |
|---|---|---|---|---|
| 1 | 6 | 6 | TC-027 (`tc_027_latency_n1_test`) | PASS |
| 2 | 7 | 7 | TC-028 (`tc_028_latency_n2_test`) | PASS |
| 3 | 8 | 8 | TC-029 (`tc_029_latency_n3_test`) | PASS |
| 4 | 9 | 9 | TC-030 (`tc_030_latency_n4_test`) | PASS |

No deviation between actual and expected at any dimension. The two independent checkers (transaction-level and signal-level) agree on every run.

### Why `dim + 5` (and why not `2N`)

`2N` was inherited from the superseded v1.0 horizontal-flow design and was never re-derivable from the DiP RTL. Under DiP:

- Output row `r` settles on the bottom accumulator at flow cycle `N + r`.
- `deskew_capture.sv` captures with a one-cycle offset for the activation-feed pipeline delay.
- `mmu_controller.sv` sizes `ACTIVATION_FLOW` as `flow_last = active_dim + N`, and `DONE` is one register stage later.

Together these produce `active_dim + 5` at the N = 4 build. The `+5` constant reflects this build's pipeline depth (weight-load/PE-clear sequencing + array fill + capture lag) and is **not** parametric in N — re-measure before trusting it at any other physical N. `active_dim + N + 1`, an intermediate candidate, only coincides with `dim+5` at `dim = N = 4` and is also retired (BUGS.md Bug 7, closed).

## Throughput — back-to-back at N = 4 (TC-031)

Back-to-back initiation interval measured flow-start to flow-start by `perf_sequences.sv` and asserted by D2 (`back_to_back_throughput`).

| Metric | Value |
|---|---|
| Per-computation latency (N=4) | 9 cycles (`dim+5`) |
| Natural inter-op overhead | `WEIGHT_LOAD` (N) + `PE_CLEAR` (1) |
| Back-to-back initiation interval | Theoretical max — zero bubble beyond the natural `WEIGHT_LOAD`/`PE_CLEAR` sequencing |
| D2 violations | 0 |

Any stall beyond the natural `WEIGHT_LOAD` phase fires D2 and would be logged here with the offending cycle and cross-referenced to BUGS.md. None observed.

## Contract selection (for reproducibility)

- `mmu_latency_checker.mode` defaults to `LAT_AS_BUILT` → expected `dim + 5` (the ratified regression contract).
- `perf/mmu_perf_checker.sv::exp_latency(n)` defaults to `n + 5`.
- `+LAT_SPEC_2N` (plusarg) switches both to the retired `2N` for demonstration only; it is expected to fail and is **not** part of the regression contract.

## Pass/fail statement

**PASS.** Measured latency equals the ratified `active_dim + 5` at every legal dimension; back-to-back throughput hits the theoretical maximum; both latency checkers agree with zero D1/D2 violations.

## Open follow-up (non-blocking)

`+5` is confirmed empirically, not yet derived from first principles against the pipeline's true minimum achievable depth. Whether it can be reduced by further optimization is a future design question, tracked separately from the current contract.
