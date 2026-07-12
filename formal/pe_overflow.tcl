# pe_overflow.tcl — JasperGold script for Proof 1 (Accumulator Overflow)
clear -all

analyze -sv09 [list \
    ../rtl/pe.sv \
    pe_formal.sv \
]

# Coverage setup MUST come before elaborate (ECOV062 otherwise).
check_cov -init -type stimuli

elaborate -top pe

clock clk
reset -expression {!rst_n}

prove -all

report
check_cov -measure -type stimuli
check_cov -report -type stimuli