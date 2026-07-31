# resume_bound64_to71.tcl
# Resumes ap_2x2_functional_correctness from saved database at bound 64.
# Remaining gap to completeness bound (71): 7 cycles.
#
# Evidence:
#   - Hp: bound 64 - 71, 28091.270s cumulative -> sole engine producing
#     progress across two consecutive 8h runs (50->64 this run). Kept.
#   - N, Tri: dropped again -- confirmed absent from the final results
#     table entirely; contributed nothing to this property in the prior run.

restore /nethome/akulkarni434/Documents/sv-tpu-core/formal/results/16hrsdb

prove -all -engine_mode { Hp } -iter 72 -time_limit 8h

report -all -file results/twobytwo_correct_bounded71_report_v3.txt -force

check_cov -measure -type stimuli
check_cov -report -type stimuli