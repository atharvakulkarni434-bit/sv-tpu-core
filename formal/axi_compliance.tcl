# axi_compliance.tcl — JasperGold script for Proof 2 (AXI-Lite Protocol Compliance)
clear -all

analyze -sv09 [list \
    ../rtl/axi_lite_slave.sv \
    axi_formal.sv \
]

check_cov -init -type stimuli

# No multiplier in this DUT — the -bbox_mul workaround from Proof 1
# (BUGS.md Bug 1) doesn't apply to a register/handshake-only block.
# Left un-set deliberately; don't cargo-cult the flag in.
elaborate -top axi_lite_slave

clock clk
reset -expression {!rst_n}

prove -all

report -all -file results/axi_compliance_report.txt -force

check_cov -measure -type stimuli
check_cov -report -type stimuli