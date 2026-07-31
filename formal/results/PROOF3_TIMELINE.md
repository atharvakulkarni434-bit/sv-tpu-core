# Proof 3 (2×2 Functional Correctness) — Verification Campaign Log

**Owner:** Atharva
**Status:** PROVEN — 2026-07-22, 03:08 EDT
**Bound:** Infinite
**Engine:** Hp
**Final report:** `formal/results/twobytwo_correct_FINALREPORT.txt`

This document is the narrative companion to the four reports in
`formal/results/`. The reports show *what* the tool found at each stage;
this doc records *why* — the RTL change that triggered the whole
campaign, the bug that blocked the first attempts, and the engine/
checkpoint strategy that eventually closed the proof. Cross-referenced
from `BUGS.md` and SpecDoc Part D.

---

## Timeline

**Jul 18 — DiP migration**
RTL transitioned from the horizontal-activation systolic array to the
DiP (Diagonal-Input, Permuted weight-stationary) dataflow. This changed
port wiring and timing contracts across `systolic_array.sv`, `pe.sv`,
and `deskew_capture.sv` — see each file's header for the architectural
rationale (Abdelmaksoud, Agwa, Prodromakis, arXiv:2412.09709v3).

**Jul 19 — port/timing fallout fixed, then Proof 3 fails immediately**
The port and timing issues introduced by the DiP migration were
resolved (see per-file comments in the three files above). First
attempts to run Proof 3 against the migrated RTL failed immediately,
not on a correctness mismatch but on a **capture timing** bug in
`deskew_capture.sv`. Three distinct failure signatures were observed
across successive fix attempts:

1. results buffer captured all zeros,
2. only row 1 captured — row 2 never latched,
3. row 1's data was captured into *both* the row 1 and row 2 buffers.

Waveform inspection at each stage confirmed the underlying MAC
arithmetic was already correct — the right numbers were visibly present
on the bus — the bug was purely *when* the deskew logic latched them,
not what the array computed. This was fixed in `deskew_capture.sv` (see
its header for the corrected `N + r` per-output-row capture-cycle
formula). This fix is what took Proof 3 from immediate counterexample
to actually running.

**Jul 20, evening — first real runs (20 min, then 1 hr)**
→ `formal/results/twobytwo_correct_report_maxbound_evidence-1hrRun`
Established the property's max bound (state space diameter) at **71**.

**Jul 20 night → Jul 21 early AM — 8 hr run, bound 0 → 50–51**
→ `formal/results/twobytwo_correct_bounded71_report_8hrs`
Multiple engines active; `Ht` shown leading in this window, `Hp` also
present.

**Jul 21 — engine triage**
Reviewed engine-by-engine contribution across the 8hr run: only `Hp`
was making real bound progress on `ap_2x2_functional_correctness`;
other engines contributed nothing to this specific property. Adopted a
save/restore-database workflow (`restore <db>` in the `.tcl`) instead
of re-proving from bound 0 on every run.

**Jul 21, 4pm → 12am — restore from bound 50, narrow engines**
Restored the 8hr-run database, re-ran with `Hp` plus two other
candidate engines over an 8hr window.
→ `formal/results/twobytwo_correct_bounded71_report_16hrs`
Progress: bound 50 → 64. Again, only `Hp` advanced the bound; the two
additional engines contributed nothing across the full 8hr window and
were dropped going forward.

**Jul 22, 12:15am → ~4am — restore from bound 64, Hp only**
Restored the 16hr-run database, ran `Hp` exclusively.
→ `formal/results/twobytwo_correct_FINALREPORT.txt`
`ap_2x2_functional_correctness`: **proven, Infinite, 6687.922s.** The
engine closed the proof and stopped on its own, before the 8hr time
budget for that session was used.

**Jul 22, morning**
Reviewed the final report, confirmed PROVEN across all 13 assertions
and 21 covers, archived screenshots/logs/data, pushed to the repo.

---

## Total formal compute time

Roughly 20min + 1hr + 8hr + 8hr + ~4hr ≈ **21 hours** of JasperGold
runtime across three resumed sessions, spanning Jul 20 evening through
Jul 22 early morning (elapsed wall-clock across the weekend was longer,
including the Jul 18–19 RTL/timing fix work that preceded any of this).

---

## Key lessons

1. **An immediately-failing proof after an RTL migration is worth a
   waveform check before touching the property itself.** All three
   early failure modes here were capture-timing bugs downstream of the
   DiP migration, not flaws in the property or the underlying math —
   the array's dot products were visibly correct on the bus the whole
   time.
2. **Engines are not interchangeable on a given property.** Across two
   separate 8hr windows, only `Hp` advanced the bound on
   `ap_2x2_functional_correctness`; every other engine tried
   contributed nothing. Profiling engine contribution after the first
   long run and narrowing down avoided burning further compute on
   engines that weren't helping.
3. **Save/restore made multi-session convergence possible at all.**
   Without `restore <db>` + re-`prove -all`, each session would have
   restarted from bound 0. This should be the default pattern for any
   property that doesn't close within the first several-hour run, not
   a fallback reached for late.

---

## Open items this campaign does not resolve

- SpecDoc Part D still describes Proof 3 via its fallback ladder
  (k-induction → 1×1 → honest documentation). That section needs
  updating to reflect the direct PROVEN result — no fallback was
  needed.
- The two `SPEC NOTE`s in `formal/mmu_formal.sv`'s header (the
  2³²-vs-2⁶⁴ combination-count wording in Part D, and the DiP-vs-
  controller 2N vs 2N−1 latency question) are unrelated to this
  campaign and remain open.
