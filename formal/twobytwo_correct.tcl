# resume_bound50_to71.tcl
# Resumes ap_2x2_functional_correctness from saved database at bound 50,
# pushing toward the completeness bound of 71.
#
# Evidence from prior runs:
#   - Ht:  bound 23 - 71, 3454.649s  -> stalled, dropped from this run.
#   - Hp:  bound 50 - 71, 27235.095s -> only engine to make progress so far, kept.
#   - N:   not yet tried on this property; included as a structurally distinct
#          full-proof engine (part of Jasper's own default {Ht Hp N B} set).
#   - Tri: not yet tried on this property; included as a parallel cex-hunter
#          (per JasperGold help: provides only trace attempts and min_length
#          updates, cannot itself return a full proof).

restore /nethome/akulkarni434/Documents/sv-tpu-core/formal/results/8HrTest1

prove -all -engine_mode { Hp N Tri } -iter 72 -time_limit 8h

report -all -file results/twobytwo_correct_bounded71_report.txt -force

check_cov -measure -type stimuli
check_cov -report -type stimuli