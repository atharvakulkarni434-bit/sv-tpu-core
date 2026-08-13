# =============================================================================
# File:        axi_compliance.tcl
# Commented:   August 13, 2026
# Description: JasperGold formal proof script for Proof 2 (AXI-Lite Protocol
#              Compliance). Elaborates axi_lite_slave.sv with axi_formal.sv
#              bound on top and runs all properties defined there — the 2a
#              AWVALID-stability assume, the 2b STATUS_REG read-only asserts,
#              and the 2c no-spurious-BVALID assert, along with their cover
#              properties. Unlike Proof 1 (pe_formal.sv), this DUT is a
#              register/handshake block with no multiplier, so the
#              -bbox_mul workaround from BUGS.md Bug 1 does not apply here
#              and is deliberately omitted.
# =============================================================================
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
