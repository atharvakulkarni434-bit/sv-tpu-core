# pe_overflow.tcl — JasperGold script for Proof 1 (Accumulator Overflow)
clear -all

analyze -sv09 [list \
    ../rtl/pe.sv \
    pe_formal.sv \
]

check_cov -init -type stimuli

# Prevent auto-blackboxing of the multiplier (see WNL018 in prior run) —
# this proof needs REAL multiply semantics, not an abstracted function.
# If this flag name/syntax differs on your JasperGold version, run
# `help elaborate` and look for the blackbox-multiplier option.
elaborate -top pe -bbox_mul -1

clock clk
reset -expression {!rst_n}

prove -all

# Save complete proof report
report -all -file results/pe_overflow_report.txt -force

check_cov -measure -type stimuli
check_cov -report -type stimuli