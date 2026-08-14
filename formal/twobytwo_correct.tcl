# =============================================================================
# File:        twobytwo_correct.tcl
# Commented:   August 14, 2026
# Description: JasperGold resume script for ap_2x2_functional_correctness
#              (Proof 3, twobytwo_correct.tcl / mmu_formal.sv) — continues
#              bounded proof search from a saved database checkpointed at
#              bound 64, targeting the completeness bound of 71 (7 cycles
#              of remaining gap). Restricts the engine set to Hp only: per
#              the run history in the comments below, Hp was the sole
#              engine making bound progress (50->64) across the two prior
#              8h runs, while N and Tri produced nothing for this specific
#              property and are dropped again. Runs prove with an 8h time
#              limit and an iteration cap of 72, then writes a bounded
#              report (v3) and a stimuli coverage measurement/report.
# =============================================================================

restore /nethome/akulkarni434/Documents/sv-tpu-core/formal/results/16hrsdb

prove -all -engine_mode { Hp } -iter 72 -time_limit 8h

report -all -file results/twobytwo_correct_bounded71_report_v3.txt -force

check_cov -measure -type stimuli
check_cov -report -type stimuli
