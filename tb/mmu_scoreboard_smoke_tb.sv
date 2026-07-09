// =============================================================================
// mmu_scoreboard_smoke_tb.sv — smoke test for the DPI-backed scoreboard
//
// Same vectors as ref_model.py's own _selftest(). Expected:
//   S1-S4 PASS, S5 FAIL (deliberate mismatch), S6 FAIL (illegal N, Python raises)
//
// Arrays are fixed-size int[16] to match the DPI signature (fixed-size unpacked
// arrays map to plain C int* — open arrays would need svOpenArrayHandle).
// Only the first n*n entries are meaningful for a given N.
// =============================================================================

`timescale 1ns/1ps

module mmu_scoreboard_smoke_tb;
    import mmu_scoreboard_pkg::*;

    mmu_scoreboard sb();

    initial begin
        int act     [16];
        int wgt     [16];
        int dut_out [16];
        int i;

        sb.init();

        // ---- S1: 2x2 hand-check -> 19,22,43,50 ----
        for (i=0;i<16;i++) begin act[i]=0; wgt[i]=0; dut_out[i]=0; end
        act[0]=1; act[1]=2; act[2]=3; act[3]=4;
        wgt[0]=5; wgt[1]=6; wgt[2]=7; wgt[3]=8;
        dut_out[0]=19; dut_out[1]=22; dut_out[2]=43; dut_out[3]=50;
        sb.check_result("S1 2x2 hand-check", act, wgt, 2, dut_out);

        // ---- S2: identity weight -> passthrough (4x4) ----
        act[0]=7;   act[1]=-3;  act[2]=42;  act[3]=-100;
        act[4]=1;   act[5]=2;   act[6]=3;   act[7]=4;
        act[8]=-5;  act[9]=-6;  act[10]=-7; act[11]=-8;
        act[12]=10; act[13]=20; act[14]=30; act[15]=40;
        for (i=0;i<16;i++) wgt[i] = 0;
        wgt[0]=1; wgt[5]=1; wgt[10]=1; wgt[15]=1;
        for (i=0;i<16;i++) dut_out[i] = act[i];
        sb.check_result("S2 identity weight -> passthrough", act, wgt, 4, dut_out);

        // ---- S3: all-zero weight -> zero result ----
        for (i=0;i<16;i++) begin wgt[i]=0; dut_out[i]=0; end
        sb.check_result("S3 all-zero weight -> zero result", act, wgt, 4, dut_out);

        // ---- S4: worst-case magnitude -> -65024 each ----
        for (i=0;i<16;i++) begin act[i]=-128; wgt[i]=127; dut_out[i]=-65024; end
        sb.check_result("S4 worst-case (4x -128*127)", act, wgt, 4, dut_out);

        // ---- S5: deliberate mismatch (should FAIL) ----
        for (i=0;i<16;i++) dut_out[i] = 999;
        sb.check_result("S5 deliberate mismatch (should FAIL)", act, wgt, 4, dut_out);

        // ---- S6: illegal N -> ref_model.py must raise (should FAIL) ----
        sb.check_result("S6 illegal N=5 (ref_model should raise)", act, wgt, 5, dut_out);

        $display("\n==== mmu_scoreboard smoke test: %0d passed, %0d failed ====",
                 sb.pass_count, sb.fail_count);
        $display("(S5 and S6 are SUPPOSED to fail)");

        sb.finish_up();
        $finish;
    end
endmodule