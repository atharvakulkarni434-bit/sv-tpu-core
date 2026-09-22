#==============================================================================
# scripts/synth_sweep.tcl
# Project: sv-tpu-core
#
# Out-of-context Vivado synthesis sweep over the array parameter N.
# Non-project mode: no .xpr, no runs directory, no GUI state. Just
# read -> synth -> report, once per N.
#
# USAGE
#   From the repo root:
#     vivado -mode batch -source scripts/synth_sweep.tcl
#
#   Or inside the Vivado GUI's Tcl Console:
#     cd C:/path/to/sv-tpu-core
#     source scripts/synth_sweep.tcl
#
#   To inspect one size interactively (schematic, cell browser, timing paths):
#     set ::N_LIST 4
#     source scripts/synth_sweep.tcl
#   ...then the design stays open in memory; use Open Synthesized Design views.
#
# WHAT IT PRODUCES
#   reports/util_N<k>.rpt      hierarchical utilization
#   reports/timing_N<k>.rpt    timing summary (WNS against the target period)
#   reports/cells_N<k>.rpt     primitive census (DSP48 / LUT / FF / CARRY)
#   reports/sweep.csv          one row per N: DSP, LUT, FF, WNS, Fmax
#
# WHY OUT-OF-CONTEXT
#   mmu_synth_wrap's flattened data-plane ports are enormous: at N=4 that is
#   128 weight bits + 32 activation bits + 512 result bits, and it grows as
#   N^2. No physical package has that many pins. -mode out_of_context tells
#   Vivado to skip I/O buffer insertion and synthesize the core logic as if it
#   were a submodule of a larger design, which is exactly the measurement we
#   want: the cost of the array itself, not of a pad ring that will never
#   exist. It also means no pin constraints are needed.
#==============================================================================

# ---------------------------------------------------------------------------
# Knobs
# ---------------------------------------------------------------------------
set REPO    [file normalize [pwd]]
set PART    xc7a100tcsg324-1     ;# Artix-7 100T -1. Change to match a board.
set TOP     mmu_synth_wrap
set CLK     clk
set CLK_NS  10.0                 ;# 100 MHz target. Tighten until WNS goes negative.

# N values to sweep.
#
# IMPORTANT: do not put 8 or higher here without first widening DIM_W.
# mmu_controller.sv computes
#     assign dim_legal = (dim_n >= 3'd1) && (dim_n <= 3'(N));
# and dim_n / active_dim are hardcoded [2:0] in mmu_controller.sv,
# deskew_capture.sv and output_buffer.sv. At N=8, 3'(8) truncates to 3'd0,
# dim_legal becomes a constant 0, the FSM can never leave IDLE, load_weight
# never asserts, every weight register stays at its reset value of 0, and
# Vivado's constant propagation deletes the entire array. You get a
# successful run reporting almost no logic. See the note at the bottom.
if {![info exists ::N_LIST]} {
    set N_LIST {2 3 4 6}
}

set RTL_DIRS [list $REPO/rtl $REPO/rtl_synth]

# skew_buffer.sv is dead code: mmu_top stopped instantiating it at the DiP
# pivot. Including it just adds an unreferenced module and a second top-level
# candidate to the warning log.
set EXCLUDE {skew_buffer.sv}

# ---------------------------------------------------------------------------
# Collect sources
# ---------------------------------------------------------------------------
set SRC {}
foreach d $RTL_DIRS {
    if {![file isdirectory $d]} {
        error "Missing directory: $d (run this from the repo root)"
    }
    foreach f [lsort [glob -nocomplain $d/*.sv]] {
        if {[lsearch -exact $EXCLUDE [file tail $f]] >= 0} { continue }
        lappend SRC [file normalize $f]
    }
}
if {[llength $SRC] == 0} { error "No .sv files found under $RTL_DIRS" }

puts "==== [llength $SRC] source files ===="
foreach f $SRC { puts "   [file tail $f]" }

# ---------------------------------------------------------------------------
# Constraints: one clock, nothing else. OOC means no I/O delays to model.
# ---------------------------------------------------------------------------
set RPT $REPO/reports
file mkdir $RPT
set XDC $RPT/_ooc.xdc
set fh [open $XDC w]
puts $fh "create_clock -name clk_main -period $CLK_NS \[get_ports $CLK\]"
close $fh

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
set csv [open $RPT/sweep.csv w]
puts $csv "N,DSP48,LUT,FF,CARRY,WNS_ns,Fmax_MHz"

foreach N $N_LIST {

    puts "\n########## synthesizing N = $N ##########"

    # Fresh in-memory design each iteration.
    catch { close_design }
    catch { close_project }

    read_verilog -sv $SRC
    read_xdc $XDC

    # -flatten_hierarchy none keeps module boundaries so the hierarchical
    # utilization report attributes cells to systolic_array / pe / axi_lite_slave
    # instead of one anonymous blob. It costs a little optimization quality,
    # which is the right trade for a characterization run.
    synth_design -top $TOP \
                 -part $PART \
                 -mode out_of_context \
                 -generic N=$N \
                 -flatten_hierarchy none

    # ---- reports ----
    report_utilization    -hierarchical -file $RPT/util_N$N.rpt
    report_timing_summary -delay_type max -max_paths 10 -file $RPT/timing_N$N.rpt
    report_timing         -delay_type max -max_paths 25 -sort_by slack \
                          -file $RPT/paths_N$N.rpt

    # ---- primitive census ----
    set n_dsp   [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == MULT}]]
    set n_lut   [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == LUT}]]
    set n_ff    [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
    set n_carry [llength [get_cells -hier -quiet -filter {PRIMITIVE_GROUP == CARRY}]]

    set fh [open $RPT/cells_N$N.rpt w]
    puts $fh "N = $N   part = $PART   target = $CLK_NS ns"
    puts $fh "DSP-class (MULT) : $n_dsp"
    puts $fh "LUT              : $n_lut"
    puts $fh "FLOP_LATCH       : $n_ff"
    puts $fh "CARRY            : $n_carry"
    close $fh

    # ---- timing ----
    set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    if {$wns eq "" || $wns eq "undefined"} {
        set wns    "n/a"
        set fmax   "n/a"
    } else {
        set fmax [format "%.1f" [expr {1000.0 / ($CLK_NS - $wns)}]]
        set wns  [format "%.3f" $wns]
    }

    puts $csv "$N,$n_dsp,$n_lut,$n_ff,$n_carry,$wns,$fmax"
    flush $csv

    puts "---- N=$N : DSP=$n_dsp LUT=$n_lut FF=$n_ff CARRY=$n_carry WNS=$wns ns Fmax=$fmax MHz"
}

close $csv

puts "\n=========================================================="
puts " sweep complete -> $RPT/sweep.csv"
puts "=========================================================="
puts [exec cat $RPT/sweep.csv]

#==============================================================================
# READING THE RESULTS
#
# 1. DSP48 count vs N^2.
#    There are N*N PEs and each has exactly one multiply. If DSP == N*N, each
#    PE's MAC inferred into a single DSP48E1 and the design is doing the
#    efficient thing. If DSP is a multiple of N*N (4x is the number to watch
#    for), the multiplier was built wider than it needed to be. pe.sv does:
#
#        assign mac_term = (32'(activation_in)) * (32'(weight_q));
#
#    Both operands are sign-extended to 32 bits BEFORE the multiply. The
#    product is arithmetically identical to an 8x8 signed multiply
#    sign-extended to 32 bits, but the synthesizer is being handed a 32x32
#    multiply. A DSP48E1 is 25x18, so a true 32x32 needs several of them
#    stitched together. Vivado's width pruning may or may not see through the
#    sign extension; the report is the only way to find out. If it does not,
#    the fix is one line, and it does not change simulation results at all:
#
#        logic signed [15:0] prod;
#        assign prod     = activation_in * weight_q;   // 8x8 -> 16, natural width
#        assign mac_term = 32'(prod);                  // extend AFTER
#
#    Either outcome is worth knowing cold. "I checked whether my MAC inferred
#    a single DSP and here is what the tool actually did" is a much stronger
#    answer than "it's a MAC, so it maps to a DSP."
#
# 2. Where the critical path lands (paths_N*.rpt).
#    Weight-stationary with a registered accumulator per PE means the worst
#    path SHOULD be local: activation_out register -> multiplier -> adder ->
#    accum_out register, inside one PE. If instead the worst path runs through
#    several PEs, something you believe is registered is not.
#    One thing to look at specifically: pe.sv accumulates vertically
#    (accum_in comes from the PE above, accum_out goes to the PE below) and
#    every hop is registered, so column depth should NOT show up as a single
#    long path. Confirm that, because it is the core claim of the systolic
#    structure and an interviewer can ask you to prove it from the timing report.
#
# 3. Scaling shape.
#    LUT and FF should grow roughly as N^2 (the array dominates) with a fixed
#    offset from axi_lite_slave and mmu_controller. WNS should stay roughly
#    FLAT as N grows, because a systolic array's whole point is that the
#    critical path is one PE regardless of array size. If Fmax degrades with N,
#    find out where: likely candidates are deskew_capture's comparison logic
#    against dim_n, or output_buffer's masking loop, both of which are
#    N-wide combinational structures rather than pipelined ones.
#
# 4. The DIM_W ceiling.
#    Only N = 1..7 are functional today. Making the sweep go to 16 or 32 (the
#    sizes that would make a real scaling story) means parameterizing the
#    dim width: DIM_W = $clog2(N+1), and replacing every hardcoded [2:0] in
#    mmu_controller.sv, deskew_capture.sv and output_buffer.sv. That is a
#    contained change and a genuinely good next commit, because "parameterized"
#    is currently true of the array and not of the control plane.
#==============================================================================
