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
- **Date:** 
---
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
**Bug 4 — When the assert  property is evaluating past's, so should the disables**
- **Found by:** Atharva / Formal Proof 1
- **Symptom:** CEX given, but a clear timing mismatch. Look below.
- **Root cause:** Ok, essentially, the functional equivalence property
                  is evaluating past properties. So, it should be disabled on: a reset NOW, a reset on the PAST cycle since signals were invalid then, and a pe_clear on the PAST cycle. NOTE: not a pe clear on this cycle, since as mentioned before, pe clear is a synchronus signal, and changes are defined to happen on the NEXT cycle if it is asserted NOW. Hence, pe_clear past = disable, since past + 1 = present.
- **Fix:** Added past flags to reset before too. Note: as BUG 3 states, these past flags also need all 4 flags in the extended declaration.
- **Date:** 7/13/26
---
<!-- Entries added during Phase 3 integration -->
