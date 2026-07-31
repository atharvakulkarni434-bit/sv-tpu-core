# sv-tpu-core — Bug Log
Every integration bug goes here the moment it is found.
Format: symptom, test that exposed it, root cause, fix.
---
## Template
**Bug N — [Short title]**
- **Found by:** [who / which test]
- **Symptom:** What was observed
- **Root cause:** What was actually wrong
- **Fix:** What was changed
- **Date:** ---
**Bug 1 — Formal Verification Blackboxing**
- **Found by:** Atharva / Formal Proof 1
- **Symptom:** The formal tool, i.e. Jasper, was blackboxing pe.sv's
               multiplication calculation. Becuase of that, it was 
               completely ignoring all of the assumes and constraints,
               instead applying random values to the inputs, causing
               a failure within milliseconds.
- **Root cause:** As stated above, the tool was blackboxing
                  multiplication nwhen it should not have been. Blackboxing should only be used when required and/or when intended by the designer, not via the tools whims.
- **Fix:** Simply add a flag in the tcl script to stop all blackboxing
           for that formal file as a whole: 
           elaborate -top pe -bbox_mul -1
           Except, change the 'pe' flag to the actual top module being tested
- **Date:** 7/13/26
---
**Bug 2 — Disable iff's PE_Clear and synchronous signals' past clause**
- **Found by:** Atharva / Formal Proof 1
- **Symptom:** Ok, so when using a disable iff, apparently !rst_n
               by itself correctly stops the proof from being asserted on THAT VERY CYCLE. However, if there is a clear signal or something like that, you need to check on the PAST cycle, not the current. NOTE: Since rst_n is in the sensitivity list of the actual flip flop in the RTL, it does NOT need a past, since it is ASYNCHRONOUS. pe_clear is NOT in the sensitivity list, is SYNCHRONOUS, and therefore needs a past flag.
- **Root cause:** Hence, the pe_clear signal inside the disable iff
                  clause needed a past flag. 
- **Fix:** Added a past flag to the pe_clear. For future reference, keep
           keep this in mind: inside disable_iff, need past clause on synchronous signals.
- **Date:** 7/13/26
---
**Bug 3 — Past needs a clocking event**
- **Found by:** Atharva / Formal Proof 1
- **Symptom:** Proof failed/gave a warning because past needs a clocking
               event, otherwise how would it know how far to step back.
- **Root cause:** Explicitly add a clocking event via:
                  $past(pe_clear, 1, 1'b1, @(posedge clk))
                  use the above flags as necessary.
- **Fix:** Added flags to past.
- **Date:** 7/13/26
---
**Bug 4 — When the assert property is evaluating past's, so should the disables**
- **Found by:** Atharva / Formal Proof 1
- **Symptom:** CEX given, but a clear timing mismatch. Look below.
- **Root cause:** Ok, essentially, the functional equivalence property
                  is evaluating past properties. So, it should be disabled on: a reset NOW, a reset on the PAST cycle since signals were invalid then, and a pe_clear on the PAST cycle. NOTE: not a pe clear on this cycle, since as mentioned before, pe clear is a synchronus signal, and changes are defined to happen on the NEXT cycle if it is asserted NOW. Hence, pe_clear past = disable, since past + 1 = present.
- **Fix:** Added past flags to reset before too. Note: as BUG 3 states, these past flags also need all 4 flags in the extended declaration.
- **Date:** 7/13/26
---
**Bug 5 — Objection dropped before DUT finished**
- **Found by:** Cat 1 / Cat 2 debug session
- **Symptom:** The scoreboard reported "checked zero passes."
- **Root cause:** `main_phase` in every Cat 1/Cat 2 test called `phase.drop_objection()` immediately after `seq.start()` returned. The `data_driver`'s `item_done()` fires as soon as stimulus is pushed in, not when the DUT reaches `DONE`. The phase (and test) ended before `data_monitor` ever saw `done` and published a result.
- **Fix:** Added an explicit wait for the DUT's `done`/`STATUS_REG` before dropping the objection.
- **Date:** 7/29/26
---
**Bug 6 — `deskew_capture.sv` off-by-one in output-row capture timing**
- **Found by:** Cat 1 / Cat 2 debug session (cycle-accurate simulation vs. `ref_model.py`)
- **Symptom:** DUT produced real-looking but incorrect numbers.
- **Root cause:** A prior latency correction pass captured output row `r` at `flow_cycle == N+r` (one cycle late). The row actually settles at `flow_cycle == (N-1)+r`. Capturing late grabbed the accumulator after it had already started accumulating the next row's contribution.
- **Fix:** Fix applied to `deskew_capture.sv` and matching `flow_last` derivation in `mmu_controller.sv`. *NOTE: Not yet re-verified against the formal proof; pending the ~22hr 2x2 property check.*
- **Date:** 7/29/26
---
**Bug 7 — `2N` latency contract vs. actual DiP timing mismatch — CLOSED**
- **Found by:** Cat 1 / Cat 2 debug session / Spec Review
- **Symptom:** `LAT_CHK` checks failed in `mmu_scoreboard.sv`. Confirmed independently for `dim=1,2,4` (only `dim=3` happens to land on `2N` exactly).
- **Root cause:** The 2N latency contract in the scoreboard does not actually match the DiP dataflow defined in the spec doc.
- **Resolution (ratified 7/30/26):** `active_dim + 5` is the project's official latency contract (measured/confirmed for N=1..4). `2N` is rejected. Updated in `sva/mmu_controller_sva.sv` (B3), `uvm/mmu_cat6_tests.sv` (`mmu_latency_checker`), `perf/mmu_perf_checker.sv`, `formal/mmu_formal.sv` (SPEC NOTE 2), and `README.md`. `active_dim + N + 1` (an earlier candidate formula) is also superseded — it does not match the as-built RTL for `dim < N`.
- **Follow-up (open, tracked separately, not a functional bug):** `+5` is an empirically measured constant, not yet derived from first principles against the pipeline's true minimum depth. A separate item should confirm whether it can be reduced.
- **Date:** 7/29/26 (opened) / 7/30/26 (closed)
---
**Bug 8 — `wait_for_pass_done()` RAL/AXI polling hang**
- **Found by:** Cat 1 / Cat 2 debug session
- **Symptom:** A bare `UVM_FATAL: global timeout reached` occurred with no diagnostic indication of which test or line stalled. Could hang for the full 1ms global watchdog.
- **Root cause:** `wait_for_pass_done()` v1 used a tight `do/while` loop issuing `STATUS_REG` reads with no bounds and no clock-relative wait.
- **Fix:** Replaced the tight polling loop with a direct `vif.done` wait plus a bounded, named timeout that triggers a descriptive `uvm_fatal` if `done` never asserts.
- **Date:** 7/29/26
---
**Bug 9 — Lost-wakeup deadlock between `run_matmul()` and `data_driver`**
- **Found by:** Cat 1 / Cat 2 debug session (TC-011/TC-012, intermittent on TC-013)
- **Symptom:** Deadlocks observed during multi-transaction sequences (`num_txns > 1`).
- **Root cause:** The two components were synchronized within a pass, but not between passes. `data_driver` could stage transaction *i+1* and re-trigger `mmu_stim_staged` while `run_matmul` was still mid-teardown for transaction *i*. `run_matmul`'s `stim_staged.reset()` wiped the pending trigger before it could be handled.
- **Fix:** Implemented a second handshake event (`mmu_pass_release`) utilizing a consumer-owns-reset pattern (mirroring `mmu_stim_staged`) to close the race window entirely.
- **Date:** 7/29/26
---
**Bug 10 — Covergroups not overwriting during multiple runs**
- **Found by:** Coverage review / Makefile execution
- **Symptom:** Coverage files/databases from previous runs were persisting, leading to stale or inaccurate cumulative coverage metrics when tests were re-run.
- **Root cause:** The Makefile and corresponding run scripts lacked explicit commands to clear or overwrite the coverage directory/files upon launching a new execution.
- **Fix:** Added a tcl line to the Makefile flow to explicitly ensure covergroups and coverage databases overwrite each time.
- **Date:** 7/29/26
